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
    /// The view request `request` on `connection` completed: a frame that arrived after it, at or after
    /// the floor Herdr acknowledged, at the requested size and showing what its last command did, is
    /// painted. Follows that frame's layout.
    case activated(request: UInt64, connection: UInt64)
    /// The frame on screen now was drawn against snapshot `projectionRevision` and shows these panes,
    /// whose agents the user can see. Comes before that frame's layout.
    case presented(bootID: String, projectionRevision: UInt64, paneIDs: Set<String>, connection: UInt64)
}

/// One connection's way into the engine, named by its owner's attempt. Once that connection ends or a
/// later one begins, its events are dropped, so a replaced connection's late frames never reach the
/// panes.
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

    func retarget(request: UInt64, columns: UInt16, rows: UInt16) async {
        await engine.retarget(request: request, columns: columns, rows: rows, connection: connection)
    }

    func settle(request: UInt64, answer: HerdrTerminalEngine.CommandAnswer?) async {
        await engine.settle(request: request, answer: answer, connection: connection)
    }

    func acknowledgeActivation(show: UInt64, floor: UInt64) async {
        await engine.acknowledgeActivation(show: show, floor: floor, connection: connection)
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
        /// No connection's frames are painted: none has begun, the last one ended, or it sent a surface
        /// Remux can't index. The next connection to begin is painted.
        case idle
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

    private struct PresentedFrame: Equatable {
        let bootID: String
        let projectionRevision: UInt64
        let paneIDs: Set<String>
    }

    /// A view request in progress, as Herdr's client tracks an activation (`activation/model.rs`): a
    /// show, or a move that took over the one in progress or started on the frame on screen. Only frames
    /// that arrive after it began count, so the last frame from before a hide never completes a show.
    private struct Activation {
        var request: UInt64
        /// The show whose answer gives the floor; nil for a move on a session whose show completed, which
        /// met its floor.
        let show: UInt64?
        var columns: UInt16
        var rows: UInt16
        /// The projection revision Herdr's acknowledgement returned, once it arrives.
        var floor: UInt64?
        /// The request's last command: waiting for Herdr's answer until the screen settles it.
        var awaited: Awaited = .pending
        /// The snapshots since the request began, while it waits for its last command.
        var snapshots: [HerdrSnapshot] = []
        /// The newest frame since the activation began, or since the size last changed.
        var received: (projectionRevision: UInt64, columns: UInt16, rows: UInt16)?

        mutating func record(_ snapshot: HerdrSnapshot) {
            if case .none = awaited { return }
            guard snapshots.last.map({ $0.revision < snapshot.revision }) ?? true else { return }
            snapshots.append(snapshot)
        }

        /// Whether a frame drawn against `snapshot` can complete the request. As in Herdr's client, it
        /// does once the command is answered and the snapshot shows what the command asked for, whether
        /// that snapshot came before the answer or after it. Herdr answers through a separate thread, so
        /// another client can change the place before the answer arrives: a snapshot from after the
        /// command that showed it, or any from after the answer, then admits every later one, as a split
        /// ends a zoom.
        func admits(_ snapshot: HerdrSnapshot) -> Bool {
            switch awaited {
            case .none:
                return true
            case .pending:
                return false
            case .answered(let answer):
                if answer.reached(snapshot) { return true }
                let anchor = snapshots.first { recorded in
                    recorded.revision > answer.answeredAfter
                        || (recorded.revision > answer.sentAfter && answer.reached(recorded))
                }
                guard let anchor else { return false }
                return snapshot.revision >= anchor.revision
            }
        }
    }

    /// The request's last command: none to wait for, waiting for Herdr's answer, or answered.
    enum Awaited: Sendable {
        case none
        case pending
        case answered(CommandAnswer)
    }

    /// Herdr's answer to the last command a view request waits for.
    struct CommandAnswer: Sendable {
        /// The revisions of the newest snapshot when the command went out and when its answer came.
        let sentAfter: UInt64
        let answeredAfter: UInt64
        /// Whether a snapshot shows what the command asked for: the pane focused, the tab zoomed.
        let reached: @Sendable (HerdrSnapshot) -> Bool
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
    private var state = State.idle
    /// The newest connection begun or ended; its events are painted while running.
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
    /// Frames are drawn as they come, except after a hide and during a view request. Frames Herdr sends
    /// as a hide goes out show what leaving did, such as undoing the zoom, so the frame from before the
    /// hide stays until the next show; and a show's frame from before its zoom would flash the unzoomed
    /// tab, as a move's would flash the tab left and the tab reached unzoomed, so a request draws only the
    /// frame that completes it.
    private var holdsFrames = false
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
    /// gets a new terminal from that frame. Connections are numbered in the order their owner made them,
    /// so one that begins after a newer one began or ended changes nothing.
    @discardableResult
    func beginConnection(_ connection: UInt64) -> HerdrEngineFeed {
        let feed = HerdrEngineFeed(engine: self, connection: connection)
        guard state != .stopped, connection > self.connection else { return feed }
        self.connection = connection
        state = .running
        presentation = HerdrPresentation()
        paintedSurface = nil
        presentedFrame = nil
        activation = nil
        holdsFrames = false
        failedPaneIDs.removeAll()
        return feed
    }

    /// The connection's owner gave it up: nothing it still sends is painted, and the panes keep their
    /// last frame.
    func endConnection(_ connection: UInt64) {
        guard state != .stopped, connection >= self.connection else { return }
        self.connection = connection
        state = .idle
    }

    // MARK: - Showing

    /// A show for `columns` x `rows` is about to go out as view request `request`. Herdr sends no frames
    /// to a hidden session, so every frame from here on answers this show or a later request. Frames are
    /// held until the request completes.
    fileprivate func beginActivation(request: UInt64, columns: UInt16, rows: UInt16, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        activation = Activation(request: request, show: request, columns: max(columns, 1), rows: max(rows, 1))
        holdsFrames = true
    }

    /// A move is about to go out as view request `request`, for a screen of `columns` x `rows`. It takes
    /// over the request in progress, keeping its show's floor and frames, as Herdr's client retargets an
    /// activation; else it starts on the frame on screen, which a move that changes nothing completes on.
    /// Frames are held until it completes, so neither the tab left nor the tab reached shows on the way.
    fileprivate func retarget(request: UInt64, columns: UInt16, rows: UInt16, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        if activation == nil {
            let surface = presentation.presented?.surface
            activation = Activation(
                request: request,
                show: nil,
                columns: max(columns, 1),
                rows: max(rows, 1),
                floor: 0,
                received: surface.map { ($0.projectionRevision, $0.frame.width, $0.frame.height) }
            )
        } else {
            activation?.request = request
            activation?.awaited = .pending
            activation?.snapshots.removeAll()
        }
        holdsFrames = true
    }

    /// Herdr's answer to the show: its projection revision, which a frame completing it, or a move that
    /// took it over, must reach.
    fileprivate func acknowledgeActivation(show: UInt64, floor: UInt64, connection: UInt64) {
        guard state == .running, connection == self.connection, activation?.show == show else { return }
        activation?.floor = floor
        completeActivationIfReady()
    }

    /// Herdr's answer to the request's last command, or nil when there is none to wait for: a command
    /// that failed or didn't go, or a show that sends none. It then completes on the frames it has. The
    /// answer of a request a newer one took over changes nothing.
    fileprivate func settle(
        request: UInt64,
        answer: CommandAnswer?,
        connection: UInt64
    ) {
        guard state == .running, connection == self.connection, activation?.request == request else { return }
        activation?.awaited = answer.map(Awaited.answered) ?? .none
        completeActivationIfReady()
    }

    /// The screen's size changed while a request is in progress: only a frame at the new size completes
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
                state = .idle
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

    /// Draws the presented frame unless frames are held; a request in progress takes it as its newest
    /// frame, counted even when no cell changed, since it is the screen Herdr shows now.
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
