import Foundation
import GhosttyKit

/// The tab the engine last painted for one connection, and its panes, in the frame's cells.
struct HerdrPaneLayout: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let paneID: String
        /// The pane's text area: its terminal's size, and where it sits in the frame. Nil for a pane the
        /// frame doesn't draw, as a zoomed tab draws only its focused pane.
        let innerRect: HerdrSurfaceRect?
        /// The pane's name as Herdr's pane navigator lists it, from the snapshot.
        var name = ""
        /// The directory of the pane's foreground program, else of its shell; empty when unknown.
        var path = ""
    }

    /// The tab the surface shows: the snapshot's focused tab.
    struct Tab: Equatable, Sendable {
        let tabID: String
        let label: String
        /// Whether the tab is zoomed: the frame then draws only its focused pane.
        let zoomed: Bool
    }

    let bootID: String
    let tab: Tab?
    let columns: UInt16
    let rows: UInt16
    /// The tab's panes in Herdr's order, as the snapshot lists them, also those the frame doesn't draw.
    let panes: [Pane]
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
    /// Herdr acknowledged, at the requested size and showing the zoom the show carried, is painted.
    /// Follows that frame's layout.
    case activated(request: UInt64, connection: UInt64)
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

    func beginActivation(request: UInt64, columns: UInt16, rows: UInt16, zoomed: Bool = false) async {
        await engine.beginActivation(
            request: request,
            columns: columns,
            rows: rows,
            zoomed: zoomed,
            connection: connection
        )
    }

    func settleZoom(request: UInt64, tab: (tabID: String, zoomed: Bool)?) async {
        await engine.settleZoom(request: request, tab: tab, connection: connection)
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

        init(of surface: HerdrPaneSurfaceFrame) {
            bootID = surface.bootID
            projectionRevision = surface.projectionRevision
            surfaceRevision = surface.surfaceRevision
        }
    }

    /// A show in progress, as Herdr's client tracks one (`activation/model.rs`): only frames that arrive
    /// after it began count, so the last frame from before a hide never completes it.
    private struct Activation {
        let request: UInt64
        var columns: UInt16
        var rows: UInt16
        /// The projection revision Herdr's acknowledgement returned, once it arrives.
        var floor: UInt64?
        /// The zoom the show carries.
        var zoom: ShowZoom
        /// For a show carrying a zoom, each snapshot's revision and tabs' zoom, from the one current as
        /// the show began.
        var snapshots: [(revision: UInt64, zoomed: [String: Bool])] = []
        /// The newest frame since the activation began, or since the size last changed.
        var received: (projectionRevision: UInt64, columns: UInt16, rows: UInt16)?

        mutating func record(_ snapshot: HerdrSnapshot) {
            if case .none = zoom { return }
            guard snapshots.last.map({ $0.revision < snapshot.revision }) ?? true else { return }
            snapshots.append((
                snapshot.revision,
                Dictionary(snapshot.tabs.map { ($0.tabID, $0.zoomed) }) { first, _ in first }
            ))
        }

        /// Whether a frame drawn against `snapshot` can complete the show. Herdr can draw the show's frame
        /// before it applies the zoom behind it, and answer the zoom before or after the zoomed frame, so
        /// once it has answered, the show completes on a frame no older than the first snapshot since the
        /// show began that shows the tab as the answer left it. Every snapshot from that one on came after
        /// the zoom, also one where another client has since undone it, as a split ends a zoom; the show's
        /// frame from before the zoom is older.
        func admits(_ snapshot: HerdrSnapshot) -> Bool {
            switch zoom {
            case .none:
                return true
            case .pending:
                return false
            case .answered(let tabID, let zoomed):
                // A tab that is gone has nothing left to show.
                guard let first = snapshots.first(where: { ($0.zoomed[tabID] ?? zoomed) == zoomed }) else {
                    return false
                }
                return snapshot.revision >= first.revision
            }
        }
    }

    /// The zoom sent behind a show: none, waiting for Herdr's answer, or the tab and its zoom after it.
    enum ShowZoom: Sendable {
        case none
        case pending
        case answered(tabID: String, zoomed: Bool)
    }

    /// Makes a pane's producer for a terminal of the given columns and rows.
    typealias ProducerFactory = @Sendable (_ columns: UInt16, _ rows: UInt16) throws -> any HerdrPaneProducing

    private struct Pane {
        let producer: any HerdrPaneProducing
        /// The terminal handed to the owner; a renderer registers only over this one.
        let terminal: HerdrRetainedTerminal
        /// What the terminal shows: the last paint Ghostty accepted.
        var painted: HerdrPanePainter.Painted
        var renderer: HerdrRendererSurface?
    }

    private let continuation: AsyncStream<HerdrEngineUpdate>.Continuation
    private var state = State.running
    /// The connection whose events are painted; zero until the first begins.
    private var connection: UInt64 = 0
    private var presentation = HerdrPresentation()
    private var panes: [String: Pane] = [:]
    /// Listed panes whose terminal Ghostty couldn't make or paint, until the next connection.
    private var failedPaneIDs: Set<String> = []
    private var bootID: String?
    private var paintedSurface: PaintedSurface?
    private var activation: Activation?
    /// Frames are drawn as they come, except after a hide and during a show carrying Remux's zoom. Frames
    /// Herdr sends as a hide goes out show what leaving did, such as undoing the zoom, so the frame from
    /// before the hide stays until the next show; and a show's frame from before its zoom would flash the
    /// unzoomed tab, so that show draws only the frame that completes it.
    private var holdsFrames = false
    private var layout: HerdrPaneLayout?
    private var paneScrolls: [String: HerdrPaneScroll] = [:]
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
        activation = nil
        holdsFrames = false
        failedPaneIDs.removeAll()
        return HerdrEngineFeed(engine: self, connection: connection)
    }

    // MARK: - Showing

    /// A show for `columns` x `rows` is about to go out, with Remux's zoom behind it when `zoomed`.
    /// Herdr sends no frames to a hidden session, so every frame from here on answers this show or a
    /// later one.
    fileprivate func beginActivation(
        request: UInt64,
        columns: UInt16,
        rows: UInt16,
        zoomed: Bool,
        connection: UInt64
    ) {
        guard state == .running, connection == self.connection else { return }
        activation = Activation(
            request: request,
            columns: max(columns, 1),
            rows: max(rows, 1),
            zoom: zoomed ? .pending : .none
        )
        if let snapshot = presentation.snapshot { activation?.record(snapshot) }
        holdsFrames = zoomed
    }

    /// Herdr's answer to the show: its projection revision, which a frame completing it must reach.
    fileprivate func acknowledgeActivation(request: UInt64, floor: UInt64, connection: UInt64) {
        guard state == .running, connection == self.connection, activation?.request == request else { return }
        activation?.floor = floor
        completeActivationIfReady()
    }

    /// Herdr's answer to the zoom behind the show: the tab and its zoom after it, or nil when the zoom
    /// didn't go or failed, and the show then completes as one without a zoom.
    fileprivate func settleZoom(
        request: UInt64,
        tab: (tabID: String, zoomed: Bool)?,
        connection: UInt64
    ) {
        guard state == .running, connection == self.connection, activation?.request == request else { return }
        activation?.zoom = tab.map { .answered(tabID: $0.tabID, zoomed: $0.zoomed) } ?? .none
        completeActivationIfReady()
    }

    /// The screen's size changed while the show is in progress: only a frame at the new size completes
    /// it, as Herdr's client drops its evidence on a resize.
    fileprivate func resizeActivation(columns: UInt16, rows: UInt16, connection: UInt64) {
        guard connection == self.connection, activation != nil else { return }
        activation?.columns = max(columns, 1)
        activation?.rows = max(rows, 1)
        activation?.received = nil
    }

    /// The session is hidden: frames are held until the next show.
    fileprivate func endActivation(connection: UInt64) {
        guard connection == self.connection else { return }
        activation = nil
        holdsFrames = true
    }

    /// Herdr's client checks the pair again at completion: a snapshot that arrived after the received
    /// frame waits for its own frame. A held completing frame is drawn now, and frames are drawn as they
    /// come from then on.
    private func completeActivationIfReady() {
        guard let activation, let floor = activation.floor, let received = activation.received,
              let (snapshot, surface) = presentation.presented,
              surface.projectionRevision == received.projectionRevision,
              received.projectionRevision >= floor,
              received.columns == activation.columns, received.rows == activation.rows,
              activation.admits(snapshot)
        else { return }
        self.activation = nil
        if holdsFrames {
            holdsFrames = false
            draw(surface, snapshot: snapshot)
        }
        continuation.yield(.activated(request: activation.request, connection: connection))
    }

    fileprivate func receive(_ snapshot: HerdrSnapshot, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        presentation.receive(snapshot)
        activation?.record(snapshot)
        paintPresented()
    }

    fileprivate func receive(_ output: HerdrSurfaceDecoder.Output, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        switch output {
        case .surface(let surface):
            do {
                try presentation.receive(surface)
            } catch {
                state = .failed
                continuation.yield(.failed(.wire(error), connection: connection))
                return
            }
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

    /// Draws the presented frame unless frames are held; a show in progress takes it as its newest frame,
    /// counted even when no cell changed, since it is the screen Herdr shows now.
    private func paintPresented() {
        guard let (snapshot, surface) = presentation.presented,
              PaintedSurface(of: surface) != paintedSurface
        else { return }
        if !holdsFrames { draw(surface, snapshot: snapshot) }
        if activation != nil {
            activation?.received = (surface.projectionRevision, surface.frame.width, surface.frame.height)
            completeActivationIfReady()
        }
    }

    private func draw(_ surface: HerdrPaneSurfaceFrame, snapshot: HerdrSnapshot) {
        paintedSurface = PaintedSurface(of: surface)
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
                paneID: pane.paneID
            )
        }
        let listed = Set(surface.panes.map(\.paneID))
        panes = panes.filter { listed.contains($0.key) }
        failedPaneIDs.formIntersection(listed)
        publishLayout(of: surface, snapshot: snapshot)
        publishScroll(of: surface)
    }

    private func paint(_ next: HerdrPanePainter.Painted, paneID: String) {
        let area = next.area
        guard area.width > 0, area.height > 0 else {
            // A pane with no text area has no terminal; it gets a new one when it has room again.
            panes.removeValue(forKey: paneID)
            failedPaneIDs.remove(paneID)
            return
        }
        guard !failedPaneIDs.contains(paneID) else { return }
        guard var pane = panes[paneID] else {
            createPane(paneID: paneID, painted: next)
            return
        }
        let result: ghostty_terminal_producer_result_e
        if pane.painted.area.width == area.width, pane.painted.area.height == area.height {
            let bytes = HerdrPanePainter.update(from: pane.painted, to: next)
            guard !bytes.isEmpty else {
                pane.painted = next
                panes[paneID] = pane
                return
            }
            result = pane.producer.feed(bytes)
        } else {
            result = pane.producer.resizeAndFeed(
                columns: area.width,
                rows: area.height,
                cellWidthPx: cellWidthPx,
                cellHeightPx: cellHeightPx,
                bytes: HerdrPanePainter.repaint(next)
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

    private func createPane(paneID: String, painted: HerdrPanePainter.Painted) {
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
        let result = producer.resizeAndFeed(
            columns: painted.area.width,
            rows: painted.area.height,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            bytes: HerdrPanePainter.repaint(painted)
        )
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            fail(paneID: paneID)
            return
        }
        panes[paneID] = Pane(producer: producer, terminal: terminal, painted: painted)
        continuation.yield(.paneTerminal(paneID: paneID, terminal: terminal))
    }

    /// The tab's panes come from the snapshot, which lists a zoomed tab's undrawn panes too, in Herdr's
    /// order; a drawn pane it doesn't list follows them.
    private func publishLayout(of surface: HerdrPaneSurfaceFrame, snapshot: HerdrSnapshot) {
        let tab = snapshot.tabs.first { $0.tabID == snapshot.focusedTabID }
        var paneIDs = tab.map { tab in snapshot.panes.filter { $0.tabID == tab.tabID }.map(\.paneID) } ?? []
        for pane in surface.panes where !paneIDs.contains(pane.paneID) {
            paneIDs.append(pane.paneID)
        }
        let next = HerdrPaneLayout(
            bootID: surface.bootID,
            tab: tab.map { HerdrPaneLayout.Tab(tabID: $0.tabID, label: $0.label, zoomed: $0.zoomed) },
            columns: surface.frame.width,
            rows: surface.frame.height,
            panes: paneIDs.map { paneID in
                HerdrPaneLayout.Pane(
                    paneID: paneID,
                    innerRect: surface.panes.first { $0.paneID == paneID }?.innerRect,
                    name: Self.name(ofPane: paneID, in: snapshot),
                    path: Self.path(ofPane: paneID, in: snapshot)
                )
            },
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
