import Foundation
import GhosttyKit

/// The panes the engine last painted for one connection's tab, in the frame's cells.
struct HerdrPaneLayout: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let paneID: String
        /// The pane's text area: its terminal's size, and where it sits in the frame.
        let innerRect: HerdrSurfaceRect
        /// The pane's name as Herdr's pane navigator lists it, from the snapshot.
        var name = ""
        /// The directory of the pane's foreground program, else of its shell; empty when unknown.
        var path = ""
    }

    /// The tab the surface shows: the snapshot's focused tab.
    struct Tab: Equatable, Sendable {
        let tabID: String
        let label: String
    }

    let bootID: String
    let tab: Tab?
    let columns: UInt16
    let rows: UInt16
    let panes: [Pane]
    /// The lines Herdr draws around and between the panes, which the crop leaves out of the panes.
    let borders: [HerdrBorderLine]
    /// Whether a popup is open over the tab. It takes the tab's input meanwhile.
    let hasPopup: Bool
}

/// Where a pane's history viewport is and what its program asks of the mouse, from Herdr's surface.
struct HerdrPaneScroll: Equatable, Sendable {
    /// Lines the viewport is above the bottom of the history, and how far up it can go.
    let linesFromBottom: UInt64
    let maxLinesFromBottom: UInt64
    let rows: UInt64
    let mouseReporting: Bool
    let alternateScreenActive: Bool
}

/// What the engine tells its main-actor owner, in order.
enum HerdrEngineUpdate: Sendable {
    /// A new terminal for a pane, already painted; the owner creates its renderer with a
    /// `HerdrPaneRendererFence`. It replaces an earlier terminal for the same pane, whose renderer the
    /// owner closes.
    case paneTerminal(paneID: String, terminal: HerdrRetainedTerminal)
    /// Follows the terminals of the new panes it lists.
    case layout(HerdrPaneLayout)
    /// Each listed pane's scrolling, whenever any of it changed. Kept out of the layout because the
    /// history grows with every line a program prints.
    case paneScroll([String: HerdrPaneScroll])
    /// Ghostty couldn't make or paint the pane's terminal. It isn't painted again until the pane leaves
    /// the layout or a new connection begins; a terminal it already had keeps its last frame.
    case paneTerminalFailed(paneID: String)
    /// Waking the pane's renderer failed and its registration is dropped, as for a tmux pane.
    case rendererWakeFailed(paneID: String)
    /// A surface Remux can't index came over `connection`. Nothing more of it is painted; the owner
    /// ends that connection.
    case failed(HerdrConnectionError, connection: UInt64)
    /// The show `request` on `connection` completed: a frame that arrived after it, at or after the floor
    /// Herdr acknowledged and at the requested size, is painted. Follows that frame's layout.
    case activated(request: UInt64, connection: UInt64)
    /// The frame on screen now was drawn against snapshot `projectionRevision` and shows these panes,
    /// whose agents the user can see. Comes before that frame's layout.
    case presented(bootID: String, projectionRevision: UInt64, paneIDs: Set<String>, connection: UInt64)
}

/// One connection's way into the engine. Once a later connection begins, this one's events are
/// dropped, so a replaced connection's late frames never reach the panes.
struct HerdrEngineFeed: Sendable {
    let engine: HerdrTerminalEngine
    let connection: UInt64

    func receive(_ snapshot: HerdrSnapshot) async {
        await engine.receive(snapshot, connection: connection)
    }

    func receive(_ output: HerdrSurfaceDecoder.Output) async {
        await engine.receive(output, connection: connection)
    }

    func beginActivation(request: UInt64, columns: UInt16, rows: UInt16) async {
        await engine.beginActivation(request: request, columns: columns, rows: rows, connection: connection)
    }

    func acknowledgeActivation(request: UInt64, floor: UInt64) async {
        await engine.acknowledgeActivation(request: request, floor: floor, connection: connection)
    }

    func resizeActivation(columns: UInt16, rows: UInt16) async {
        await engine.resizeActivation(columns: columns, rows: rows, connection: connection)
    }

    func endActivation() async {
        await engine.endActivation(connection: connection)
    }
}

enum HerdrRendererRegistrationError: Error, Equatable {
    case engineEnded
    /// The pane was dropped, or shows a newer terminal than the renderer's.
    case terminalGone
    case alreadyRegistered
    case rendererWakeFailed
}

/// Turns a session's frames into each pane's terminal, off the main thread, as the tmux client does on
/// its writer queue. It takes the decoder's output in wire order, one connection at a time, applies
/// Herdr's presentation rules, paints every listed pane into its own terminal, and wakes the pane's
/// renderer.
///
/// Every method runs to completion without suspending, so one event is fully painted before the next
/// one, a registration or a stop is taken. The owner learns of terminals and layouts through `updates`;
/// nothing here waits for the main actor.
actor HerdrTerminalEngine {
    nonisolated let updates: AsyncStream<HerdrEngineUpdate>

    private enum State {
        case running
        case failed
        case stopped
    }

    private struct PaintedSurface: Equatable {
        let bootID: String
        let projectionRevision: UInt64
        let surfaceRevision: UInt64
    }

    private struct PresentedFrame: Equatable {
        let bootID: String
        let projectionRevision: UInt64
        let paneIDs: Set<String>
    }

    /// A show in progress, as Herdr's client tracks one (`activation/model.rs`): only frames painted
    /// after it began count, so the last frame from before a hide never completes it.
    private struct Activation {
        let request: UInt64
        var columns: UInt16
        var rows: UInt16
        /// The projection revision Herdr's acknowledgement returned, once it arrives.
        var floor: UInt64?
        /// The newest frame painted since the activation began, or since the size last changed.
        var painted: (projectionRevision: UInt64, columns: UInt16, rows: UInt16)?
    }

    /// Makes a pane's producer for a terminal of the given columns and rows.
    typealias ProducerFactory = @Sendable (_ columns: UInt16, _ rows: UInt16) throws -> any HerdrPaneProducing

    private struct Pane {
        let producer: any HerdrPaneProducing
        /// The terminal handed to the owner; a renderer registers only over this one.
        let terminal: HerdrRetainedTerminal
        /// What the terminal shows: the last paint Ghostty accepted.
        var painted: HerdrPanePainter.Painted
        /// The images the terminal holds and shows, as of that paint.
        var images: HerdrPaneImages
        var renderer: HerdrRendererSurface?
    }

    private let continuation: AsyncStream<HerdrEngineUpdate>.Continuation
    private var state = State.running
    /// The connection whose events are painted; zero until the first begins.
    private var connection: UInt64 = 0
    private var presentation = HerdrPresentation()
    /// Kept across connections: its keys name their bytes, and each scene keeps only what Herdr counts
    /// as delivered.
    private var images = HerdrImageStore()
    private var panes: [String: Pane] = [:]
    /// Listed panes whose terminal Ghostty couldn't make or paint, until the next connection.
    private var failedPaneIDs: Set<String> = []
    private var bootID: String?
    private var paintedSurface: PaintedSurface?
    private var presentedFrame: PresentedFrame?
    private var activation: Activation?
    private var layout: HerdrPaneLayout?
    private var paneScrolls: [String: HerdrPaneScroll] = [:]
    /// Herdr's border lines in the frame painted last. A patch never changes them, since
    /// `HerdrPresentation` takes only patches inside the panes' text areas and scrollbar columns, so
    /// they are read again only once a surface or a snapshot may have changed what is presented.
    private var borders: [HerdrBorderLine] = []
    private var bordersMayHaveChanged = true
    private var cellWidthPx: UInt32
    private var cellHeightPx: UInt32
    private let makeProducer: ProducerFactory

    init(
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        makeProducer: @escaping ProducerFactory = { try HerdrPaneProducer(columns: $0, rows: $1) }
    ) {
        (updates, continuation) = AsyncStream.makeStream()
        self.cellWidthPx = max(cellWidthPx, 1)
        self.cellHeightPx = max(cellHeightPx, 1)
        self.makeProducer = makeProducer
    }

    // MARK: - Frames

    /// Herdr's revisions restart with each connection, so the new one starts a new presentation. The
    /// panes keep their terminals and last paint: the same server boot's next frame is painted as a
    /// change from it, and until then the last frame stays on screen. A pane Ghostty couldn't paint
    /// gets a new terminal from that frame.
    func beginConnection() -> HerdrEngineFeed {
        connection += 1
        if state == .failed { state = .running }
        presentation = HerdrPresentation()
        paintedSurface = nil
        presentedFrame = nil
        activation = nil
        failedPaneIDs.removeAll()
        return HerdrEngineFeed(engine: self, connection: connection)
    }

    // MARK: - Showing

    /// A show for `columns` x `rows` is about to go out. Herdr sends no frames to a hidden session, so
    /// every frame painted from here on answers this show or a later one.
    fileprivate func beginActivation(request: UInt64, columns: UInt16, rows: UInt16, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        activation = Activation(request: request, columns: max(columns, 1), rows: max(rows, 1))
    }

    /// Herdr's answer to the show: its projection revision, which a frame completing it must reach.
    fileprivate func acknowledgeActivation(request: UInt64, floor: UInt64, connection: UInt64) {
        guard state == .running, connection == self.connection, activation?.request == request else { return }
        activation?.floor = floor
        completeActivationIfPainted()
    }

    /// The screen's size changed while the show is in progress: only a frame at the new size completes
    /// it, as Herdr's client drops its evidence on a resize.
    fileprivate func resizeActivation(columns: UInt16, rows: UInt16, connection: UInt64) {
        guard connection == self.connection, activation != nil else { return }
        activation?.columns = max(columns, 1)
        activation?.rows = max(rows, 1)
        activation?.painted = nil
    }

    fileprivate func endActivation(connection: UInt64) {
        guard connection == self.connection else { return }
        activation = nil
    }

    /// Herdr's client checks the pair again at completion: a snapshot that arrived after the painted
    /// frame waits for its own frame.
    private func completeActivationIfPainted() {
        guard let activation, let floor = activation.floor, let painted = activation.painted,
              presentation.presented?.surface.projectionRevision == painted.projectionRevision,
              painted.projectionRevision >= floor,
              painted.columns == activation.columns, painted.rows == activation.rows
        else { return }
        self.activation = nil
        continuation.yield(.activated(request: activation.request, connection: connection))
    }

    fileprivate func receive(_ snapshot: HerdrSnapshot, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        presentation.receive(snapshot)
        bordersMayHaveChanged = true
        paintPresented()
    }

    fileprivate func receive(_ output: HerdrSurfaceDecoder.Output, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        switch output {
        case .surface(let surface):
            images.receive(surface.graphics)
            do {
                try presentation.receive(surface)
            } catch {
                state = .failed
                continuation.yield(.failed(.wire(error), connection: connection))
                return
            }
            bordersMayHaveChanged = true
        case .patch(let patch):
            // A rejected patch leaves the current frame until the next full surface.
            _ = presentation.receive(patch)
        }
        paintPresented()
    }

    /// A new cell size, from the screen's font or scale: the terminals keep their grids.
    func setCellSize(widthPx: UInt32, heightPx: UInt32) {
        guard state != .stopped, widthPx > 0, heightPx > 0,
              widthPx != cellWidthPx || heightPx != cellHeightPx
        else { return }
        cellWidthPx = widthPx
        cellHeightPx = heightPx
        for (paneID, var pane) in panes {
            let result = pane.producer.resize(
                columns: pane.painted.area.width,
                rows: pane.painted.area.height,
                cellWidthPx: widthPx,
                cellHeightPx: heightPx
            )
            guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
                fail(paneID: paneID)
                continue
            }
            wake(&pane, paneID: paneID)
            panes[paneID] = pane
        }
    }

    /// Ends the engine: nothing is painted or woken again, and every producer is freed. Renderers keep
    /// the terminals they hold until they close.
    func stop() {
        guard state != .stopped else { return }
        state = .stopped
        panes.removeAll()
        failedPaneIDs.removeAll()
        continuation.finish()
    }

    private func paintPresented() {
        guard let (snapshot, surface) = presentation.presented else { return }
        let presented = PaintedSurface(
            bootID: surface.bootID,
            projectionRevision: surface.projectionRevision,
            surfaceRevision: surface.surfaceRevision
        )
        guard presented != paintedSurface else { return }
        paintedSurface = presented
        if surface.bootID != bootID {
            // Pane ids belong to one server boot.
            panes.removeAll()
            failedPaneIDs.removeAll()
            bootID = surface.bootID
        }
        let cursor = HerdrPanePainter.paneCursor(of: surface)
        for pane in surface.panes {
            paint(
                HerdrPanePainter.Painted(frame: surface.frame, area: pane.innerRect, cursor: cursor),
                images: HerdrPaneImages.Scene(surface.graphics, pane: pane),
                paneID: pane.paneID
            )
        }
        let listed = Set(surface.panes.map(\.paneID))
        panes = panes.filter { listed.contains($0.key) }
        failedPaneIDs.formIntersection(listed)
        if bordersMayHaveChanged {
            borders = HerdrBorderLine.lines(in: surface)
            bordersMayHaveChanged = false
        }
        let frame = PresentedFrame(bootID: surface.bootID, projectionRevision: surface.projectionRevision, paneIDs: listed)
        if frame != presentedFrame {
            presentedFrame = frame
            continuation.yield(.presented(
                bootID: frame.bootID,
                projectionRevision: frame.projectionRevision,
                paneIDs: frame.paneIDs,
                connection: connection
            ))
        }
        publishLayout(of: surface, snapshot: snapshot)
        publishScroll(of: surface)
        if activation != nil {
            // Counted even when no cell changed: the frame is the screen Herdr shows now.
            activation?.painted = (surface.projectionRevision, surface.frame.width, surface.frame.height)
            completeActivationIfPainted()
        }
    }

    private func paint(_ next: HerdrPanePainter.Painted, images scene: HerdrPaneImages.Scene, paneID: String) {
        let area = next.area
        guard area.width > 0, area.height > 0 else {
            // A pane with no text area has no terminal; it gets a new one when it has room again.
            panes.removeValue(forKey: paneID)
            failedPaneIDs.remove(paneID)
            return
        }
        guard !failedPaneIDs.contains(paneID) else { return }
        guard var pane = panes[paneID] else {
            createPane(paneID: paneID, painted: next, images: scene)
            return
        }
        let result: ghostty_terminal_producer_result_e
        if pane.painted.area.width == area.width, pane.painted.area.height == area.height {
            let bytes = HerdrPanePainter.update(from: pane.painted, to: next)
                + pane.images.update(to: scene, from: images)
            guard !bytes.isEmpty else {
                pane.painted = next
                panes[paneID] = pane
                return
            }
            result = pane.producer.feed(bytes)
        } else {
            pane.images.terminalResized()
            result = pane.producer.resizeAndFeed(
                columns: area.width,
                rows: area.height,
                cellWidthPx: cellWidthPx,
                cellHeightPx: cellHeightPx,
                bytes: HerdrPanePainter.repaint(next) + pane.images.update(to: scene, from: images)
            )
        }
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            fail(paneID: paneID)
            return
        }
        pane.painted = next
        wake(&pane, paneID: paneID)
        panes[paneID] = pane
    }

    private func createPane(paneID: String, painted: HerdrPanePainter.Painted, images scene: HerdrPaneImages.Scene) {
        let producer: any HerdrPaneProducing
        let terminal: HerdrRetainedTerminal
        do {
            producer = try makeProducer(painted.area.width, painted.area.height)
            terminal = try producer.retainTerminal()
        } catch {
            fail(paneID: paneID)
            return
        }
        // The cell size goes in with the first paint, before the terminal is shown.
        var paneImages = HerdrPaneImages()
        let result = producer.resizeAndFeed(
            columns: painted.area.width,
            rows: painted.area.height,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            bytes: HerdrPanePainter.repaint(painted) + paneImages.update(to: scene, from: images)
        )
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            fail(paneID: paneID)
            return
        }
        panes[paneID] = Pane(producer: producer, terminal: terminal, painted: painted, images: paneImages)
        continuation.yield(.paneTerminal(paneID: paneID, terminal: terminal))
    }

    private func publishLayout(of surface: HerdrPaneSurfaceFrame, snapshot: HerdrSnapshot) {
        let tab = snapshot.tabs.first { $0.tabID == snapshot.focusedTabID }
        let next = HerdrPaneLayout(
            bootID: surface.bootID,
            tab: tab.map { HerdrPaneLayout.Tab(tabID: $0.tabID, label: $0.label) },
            columns: surface.frame.width,
            rows: surface.frame.height,
            panes: surface.panes.map {
                HerdrPaneLayout.Pane(
                    paneID: $0.paneID,
                    innerRect: $0.innerRect,
                    name: Self.name(ofPane: $0.paneID, in: snapshot),
                    path: Self.path(ofPane: $0.paneID, in: snapshot)
                )
            },
            borders: borders,
            hasPopup: surface.popup != nil
        )
        guard next != layout else { return }
        layout = next
        continuation.yield(.layout(next))
    }

    private func publishScroll(of surface: HerdrPaneSurfaceFrame) {
        var next: [String: HerdrPaneScroll] = [:]
        for pane in surface.panes {
            next[pane.paneID] = HerdrPaneScroll(
                linesFromBottom: pane.scroll?.offsetFromBottom ?? 0,
                maxLinesFromBottom: pane.scroll?.maxOffsetFromBottom ?? 0,
                rows: pane.scroll?.viewportRows ?? UInt64(pane.innerRect.height),
                mouseReporting: pane.mouseReporting,
                alternateScreenActive: pane.alternateScreenActive
            )
        }
        guard next != paneScrolls else { return }
        paneScrolls = next
        continuation.yield(.paneScroll(next))
    }

    /// The pane's name as Herdr's pane navigator lists it within its tab: its manual label or its
    /// agent's name, else its title, else its agent's kind, else "terminal", numbered by its place
    /// among the tab's panes when the tab has more than one. The navigator also names the tab and, for
    /// a one-pane tab, may name the pane after its tab or workspace; those parts are left out, since
    /// the pane sheet shows one tab. The snapshot carries a title only for an agent's pane.
    private static func name(ofPane paneID: String, in snapshot: HerdrSnapshot) -> String {
        let pane = snapshot.panes.first { $0.paneID == paneID }
        let agent = snapshot.agents.first { $0.paneID == paneID }
        let name = pane?.label ?? agent?.name
        let title = agent?.title ?? agent?.terminalTitleStripped
        let kind = agent?.agent ?? agent?.displayAgent
        let paneName = name ?? title ?? kind ?? "terminal"
        let tabPanes = pane.map { pane in snapshot.panes.filter { $0.tabID == pane.tabID } } ?? []
        guard tabPanes.count > 1, let index = tabPanes.firstIndex(where: { $0.paneID == paneID }) else {
            return paneName
        }
        return "\(paneName) · \(index + 1)"
    }

    /// The directory of the pane's foreground program, as tmux's current path is, else of its shell.
    private static func path(ofPane paneID: String, in snapshot: HerdrSnapshot) -> String {
        let pane = snapshot.panes.first { $0.paneID == paneID }
        return [pane?.foregroundCWD, pane?.cwd].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private func wake(_ pane: inout Pane, paneID: String) {
        guard let renderer = pane.renderer else { return }
        guard ghostty_terminal_surface_terminal_changed(renderer.handle) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            pane.renderer = nil
            continuation.yield(.rendererWakeFailed(paneID: paneID))
            return
        }
    }

    /// Frees the pane's producer; a renderer over its terminal keeps the last frame Ghostty accepted.
    private func fail(paneID: String) {
        panes.removeValue(forKey: paneID)
        failedPaneIDs.insert(paneID)
        continuation.yield(.paneTerminalFailed(paneID: paneID))
    }

    // MARK: - Renderer registration

    /// Admits a renderer over the pane's current terminal to the engine's wakes. One renderer per pane.
    func register(
        _ surface: HerdrRendererSurface,
        paneID: String,
        terminal: HerdrRetainedTerminal
    ) -> Result<Void, HerdrRendererRegistrationError> {
        guard state != .stopped else { return .failure(.engineEnded) }
        guard var pane = panes[paneID], pane.terminal === terminal else { return .failure(.terminalGone) }
        guard pane.renderer == nil else { return .failure(.alreadyRegistered) }
        // A paint between the renderer's creation and now didn't wake it.
        guard ghostty_terminal_surface_terminal_changed(surface.handle) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            return .failure(.rendererWakeFailed)
        }
        pane.renderer = surface
        panes[paneID] = pane
        return .success(())
    }

    /// After this returns, the engine never wakes `surface` again, so its owner may free it.
    func unregister(_ surface: HerdrRendererSurface, paneID: String) {
        guard var pane = panes[paneID], pane.renderer == surface else { return }
        pane.renderer = nil
        panes[paneID] = pane
    }
}

/// The lifetime fence for a renderer over a Herdr pane's terminal: registration and unregistration
/// go through the engine, so an unregistration completes only once no wake of that surface can run.
@MainActor
final class HerdrPaneRendererFence: TerminalPaneRendererFence {
    private let engine: HerdrTerminalEngine
    private let paneID: String
    private let terminal: HerdrRetainedTerminal

    init(engine: HerdrTerminalEngine, paneID: String, terminal: HerdrRetainedTerminal) {
        self.engine = engine
        self.paneID = paneID
        self.terminal = terminal
    }

    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [engine, paneID, terminal] in
            let result = await engine.register(surface, paneID: paneID, terminal: terminal)
            completion(result.mapError { $0 as any Error })
        }
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [engine, paneID] in
            await engine.unregister(surface, paneID: paneID)
            completion()
        }
    }
}
