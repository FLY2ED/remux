import Foundation
import GhosttyKit

/// The grid a popup gets in an area: whole cells of the panes' font, never scaled, so the popup's text is
/// the panes' size and the keyboard takes rows, not size.
struct HerdrPopupGrid: Equatable, Sendable, CustomStringConvertible {
    let columns: UInt16
    let rows: UInt16

    /// The most whole cells that fit `widthPx` × `heightPx`; nil when not one does.
    init?(widthPx: UInt32, heightPx: UInt32, cell: GhosttyTerminalCellDisplayMetrics) {
        guard cell.pixelWidth > 0, cell.pixelHeight > 0 else { return nil }
        let columns = widthPx / cell.pixelWidth
        let rows = heightPx / cell.pixelHeight
        guard columns > 0, rows > 0 else { return nil }
        self.init(columns: UInt16(clamping: columns), rows: UInt16(clamping: rows))
    }

    init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }

    var description: String { "\(columns)x\(rows)" }

    func displayMetrics(cell: GhosttyTerminalCellDisplayMetrics) -> GhosttySurfaceDisplayMetrics {
        GhosttySurfaceDisplayMetrics(
            contentScale: cell.contentScale,
            pixelWidth: UInt32(columns) * cell.pixelWidth,
            pixelHeight: UInt32(rows) * cell.pixelHeight
        )
    }
}

/// Writes an attached popup's input in order. Ghostty encodes keys, text and pastes into bytes on the
/// main actor, for the terminal's modes as the program set them; one task writes them and the wheel's
/// steps, so nothing overtakes what came before it. A tracked write learns when its bytes are written.
@MainActor
final class HerdrPopupInputWriter {
    private enum Message: Sendable {
        case input([UInt8], completion: (@Sendable (Bool) -> Void)?)
        case scroll(HerdrDirectTerminalClientMessage.ScrollDirection, column: UInt16?, row: UInt16?)
    }

    private let continuation: AsyncStream<Message>.Continuation
    private var tracked: (@Sendable (Bool) -> Void)?

    init(attachment: HerdrTerminalAttachment) {
        let (messages, continuation) = AsyncStream.makeStream(of: Message.self)
        self.continuation = continuation
        Task {
            for await message in messages {
                switch message {
                case .input(let bytes, let completion):
                    let written = await attachment.send(bytes)
                    completion?(written)
                case .scroll(let direction, let column, let row):
                    await attachment.scroll(direction, lines: 1, column: column, row: row)
                }
            }
        }
    }

    /// The renderer's input callback.
    func write(_ data: Data) -> Bool {
        let completion = tracked
        tracked = nil
        continuation.yield(.input(Array(data), completion: completion))
        return true
    }

    /// One wheel step of one row.
    func scroll(_ direction: HerdrDirectTerminalClientMessage.ScrollDirection, column: UInt16?, row: UInt16?) {
        continuation.yield(.scroll(direction, column: column, row: row))
    }

    /// Runs `operation`; `completion` learns whether the bytes it encoded were written, false when it wrote
    /// none.
    func performTracked(completion: @escaping @Sendable (Bool) -> Void, _ operation: () -> Bool) {
        precondition(tracked == nil)
        tracked = completion
        _ = operation()
        guard tracked != nil else { return }
        tracked = nil
        completion(false)
    }

    func finish() {
        continuation.finish()
    }
}

/// The renderer of the popup over the tab: over its attachment's terminal, or over the terminal the engine
/// paints from Herdr's popup frame when it can't be attached.
@MainActor
final class HerdrPopupTerminalSurface: TerminalPaneInputSink {
    enum Source {
        case attachment(HerdrPopupInputWriter)
        /// Input goes as Herdr's client sends a popup's; `deliver` says whether Herdr has it.
        case frame(deliver: ([HerdrInputEvent]) async -> Bool)
    }

    let terminalID: String
    let terminal: HerdrRetainedTerminal
    let renderer: TerminalPaneRenderer
    let source: Source
    /// The grid the renderer draws.
    fileprivate(set) var grid: HerdrPopupGrid

    fileprivate init(
        terminalID: String,
        terminal: HerdrRetainedTerminal,
        renderer: TerminalPaneRenderer,
        source: Source,
        grid: HerdrPopupGrid
    ) {
        self.terminalID = terminalID
        self.terminal = terminal
        self.renderer = renderer
        self.source = source
        self.grid = grid
    }

    var isAttached: Bool {
        if case .attachment = source { true } else { false }
    }

    func screenSurface(id: UUID) -> GhosttyManagedSurface {
        renderer.screenSurface(id: id, inputSink: self)
    }

    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool {
        guard !text.isEmpty else { return false }
        switch source {
        case .attachment(let writer):
            return await tracked(writer) { $0.sendPaste(text) }
        case .frame(let deliver):
            return await deliver([.paste(text)])
        }
    }

    func sendKeyEventAwaitingCommandCompletion(_ event: GhosttySurfaceKeyEvent) async -> Bool {
        switch source {
        case .attachment(let writer):
            return await tracked(writer) { $0.sendKeyEvent(event) }
        case .frame(let deliver):
            guard let event = HerdrInputTranslator.event(for: event) else { return false }
            return await deliver([event])
        }
    }

    private func tracked(_ writer: HerdrPopupInputWriter, _ operation: (GhosttyKitControlSurface) -> Bool) async -> Bool {
        guard let control = renderer.inputControlSurface else { return false }
        return await withCheckedContinuation { continuation in
            writer.performTracked(completion: { continuation.resume(returning: $0) }) { operation(control) }
        }
    }
}

/// The popup Herdr shows over the tab on screen, while the phone shows it. Herdr's client draws a popup at
/// a share of its screen; Remux instead attaches straight to the popup's terminal, as `herdr terminal
/// attach` does, at the grid that fills the terminal area at the panes' font. Herdr's resize lock then keeps
/// the popup at the phone's size whatever other clients do, until the phone lets it go and Herdr gives the
/// size back, so the phone holds the popup only while it is on the phone's screen. When Herdr refuses the
/// attach or it fails, the popup's frame is drawn as Herdr sends it to this client, at the panes' font, and
/// its input goes as Herdr's client sends a popup's.
///
/// Three grids are kept apart: the one the area holds, which goes to Herdr once the area settles; the one
/// Herdr's frames have; and the one the renderer draws, which follows the frames', so the screen always
/// shows whole frames. Each attach has a generation, so nothing from an attach let go reaches the screen.
@MainActor
final class HerdrPopupController {
    typealias AttachmentFactory = @MainActor (_ terminalID: String, HerdrTerminalAttachment.Geometry) -> HerdrTerminalAttachment
    typealias FrameFenceFactory = @MainActor (_ terminalID: String, HerdrRetainedTerminal) -> any TerminalPaneRendererFence

    struct FrameInput {
        /// Input in the order it is typed.
        let send: ([HerdrInputEvent]) -> FocusedTerminalInputSubmissionResult
        /// The composer's input for one popup terminal, which learns whether Herdr has it; false when that
        /// popup is no longer on screen.
        let deliver: (_ terminalID: String, [HerdrInputEvent]) async -> Bool
    }

    struct RendererActivity: Equatable {
        var sceneActive = true
        var presented = false
        var focused = false
    }

    private struct Attached {
        let generation: UInt64
        let attachment: HerdrTerminalAttachment
        /// The grid of the frames that came, once the first did.
        var received: HerdrPopupGrid?
        var listening: Task<Void, Never>?
    }

    private let makeAttachment: AttachmentFactory
    private let makeFrameFence: FrameFenceFactory
    /// Tells the engine whether to paint the popup's frames, with a revision that orders the calls.
    private let paintFrames: (Bool, UInt64) -> Void
    private let frameInput: FrameInput
    /// Herdr refused the attach because another device holds the popup.
    private let onHeldElsewhere: () -> Void
    /// A new renderer, which the screen gives its surface.
    private let onSurface: (HerdrPopupTerminalSurface) -> Void
    private let onChange: () -> Void

    private var runtime: GhosttyKitRuntime?
    private var theme: TerminalTheme
    private(set) var popup: HerdrPaneLayout.Popup?
    private var held = false
    private var activity = RendererActivity()
    private var cell: GhosttyTerminalCellDisplayMetrics?
    private var area: (widthPx: UInt32, heightPx: UInt32)?
    /// The grid the area holds now.
    private(set) var requested: HerdrPopupGrid?
    /// The grid last sent to Herdr, and when.
    private var asked: (grid: HerdrPopupGrid, at: ContinuousClock.Instant)?
    private var attached: Attached?
    private var generation: UInt64 = 0
    /// Popups drawn from their frames, until they close or a reconnect.
    private var framed: Set<String> = []
    private var frameTerminal: (terminalID: String, terminal: HerdrRetainedTerminal)?
    /// Whether the engine paints the popup's frames, as last told.
    private var paintsFrames = false
    private var paintsFramesRevision: UInt64 = 0
    private(set) var surface: HerdrPopupTerminalSurface?
    private var creating: ObjectIdentifier?
    private var failure: TerminalDisconnectReason?
    private var settle: Task<Void, Never>?

    /// How long the area must stay put before its grid goes to Herdr: the keyboard and rotation move the
    /// area, and each resize makes the program redraw.
    static let settleDelay: Duration = .milliseconds(150)

    init(
        theme: TerminalTheme,
        makeAttachment: @escaping AttachmentFactory,
        makeFrameFence: @escaping FrameFenceFactory,
        paintFrames: @escaping (Bool, UInt64) -> Void,
        frameInput: FrameInput,
        onHeldElsewhere: @escaping () -> Void,
        onSurface: @escaping (HerdrPopupTerminalSurface) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.theme = theme
        self.makeAttachment = makeAttachment
        self.makeFrameFence = makeFrameFence
        self.paintFrames = paintFrames
        self.frameInput = frameInput
        self.onHeldElsewhere = onHeldElsewhere
        self.onSurface = onSurface
        self.onChange = onChange
    }

    // MARK: - What the model tells

    func setRuntime(_ runtime: GhosttyKitRuntime?) {
        self.runtime = runtime
        reconcile()
    }

    /// The layout's popup. Another terminal id is another popup.
    func update(_ next: HerdrPaneLayout.Popup?) {
        guard next != popup else { return }
        let replaced = next?.terminalID != popup?.terminalID
        popup = next
        if replaced {
            release()
            framed = framed.filter { $0 == next?.terminalID }
            failure = nil
        } else {
            followFrameGrid()
        }
        reconcile()
    }

    /// Whether the popup is on the phone's screen, which is when the phone holds it.
    func setHeld(_ next: Bool) {
        guard next != held else { return }
        held = next
        reconcile()
    }

    func setRendererActivity(_ next: RendererActivity) {
        activity = next
        applyActivity()
    }

    /// The panes' cell, from the screen's font and scale.
    func setCell(_ next: GhosttyTerminalCellDisplayMetrics?) {
        guard next != cell else { return }
        cell = next
        planGrid()
    }

    /// The whole pixels the screen has for the popup's terminal.
    func prepareArea(widthPx: UInt32, heightPx: UInt32) {
        guard area.map({ $0.widthPx != widthPx || $0.heightPx != heightPx }) ?? true else { return }
        area = (widthPx, heightPx)
        planGrid()
    }

    /// False when the renderer can't take the theme.
    func applyTheme(_ next: TerminalTheme) -> Bool {
        theme = next
        guard let surface, !surface.renderer.isClosing else { return true }
        return surface.renderer.applyTerminalConfiguration(theme: next)
    }

    /// The engine's terminal for a popup drawn from its frames.
    func takeFrameTerminal(_ terminal: HerdrRetainedTerminal, terminalID: String) {
        frameTerminal = (terminalID, terminal)
        reconcile()
    }

    func frameTerminalFailed(terminalID: String) {
        guard frameTerminal?.terminalID == terminalID else { return }
        frameTerminal = nil
        failure = Self.rendererFailure
        onChange()
    }

    func rendererWakeFailed(terminalID: String) {
        guard let surface, surface.terminalID == terminalID else { return }
        surface.renderer.failPresentation(message: Self.rendererFailureMessage)
        onChange()
    }

    /// A reconnect tries a popup that couldn't be attached again.
    func retry() {
        framed.removeAll()
        failure = nil
        reconcile()
    }

    func stop() {
        held = false
        popup = nil
        release()
    }

    // MARK: - What the screen reads

    /// Whether the popup takes the tab's input: it is on screen and the phone holds it.
    var takesInput: Bool { popup != nil && held }

    var presentation: TerminalPanePresentation {
        if let failure { return .failed(failure) }
        return surface?.renderer.presentation ?? .pending
    }

    /// The renderer's grid and the cell it draws with.
    var displayed: (grid: HerdrPopupGrid, cell: GhosttyTerminalCellDisplayMetrics)? {
        guard let surface, let cell else { return nil }
        return (surface.grid, cell)
    }

    // MARK: - Input

    func sendText(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        if let managed = attachedManagedSurface { return managed.sendInput(text) }
        return frameInput.send(HerdrInputTranslator.events(forText: text, reportsAllKeys: false))
    }

    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        if let managed = attachedManagedSurface { return managed.sendPaste(text) }
        return frameInput.send([.paste(text)])
    }

    func sendKey(_ key: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        if let managed = attachedManagedSurface { return managed.sendKeyEvent(key) }
        guard let event = HerdrInputTranslator.event(for: key) else {
            return key.action == .release ? .accepted : .surfaceRejected
        }
        return frameInput.send([event])
    }

    /// A swipe's wheel steps, a row each, up for positive `rows`: an attached popup's go through Herdr's
    /// wheel handling for the program, a framed one's as Herdr's client sends a popup's wheel.
    func scroll(rows: Int, column: UInt16, row: UInt16) -> Bool {
        guard takesInput else { return false }
        guard rows != 0 else { return true }
        let direction: HerdrDirectTerminalClientMessage.ScrollDirection = rows > 0 ? .up : .down
        if let surface, case .attachment(let writer) = surface.source {
            for _ in 0..<rows.magnitude {
                writer.scroll(direction, column: column, row: row)
            }
            return true
        }
        let wheel = HerdrMouseEvent(
            kind: rows > 0 ? .scrollUp : .scrollDown,
            column: column,
            row: row,
            modifiers: [],
            lines: 1
        )
        return frameInput.send(Array(repeating: .mouse(wheel), count: Int(rows.magnitude))) == .accepted
    }

    private var attachedManagedSurface: GhosttyManagedSurface? {
        guard let surface, surface.isAttached else { return nil }
        return surface.renderer.managedSurface
    }

    // MARK: - Holding the popup

    private func reconcile() {
        guard let popup, held, runtime != nil else {
            release()
            return
        }
        if framed.contains(popup.terminalID) {
            detach()
            setPaintsFrames(true)
            createFramedRendererIfPossible(popup)
        } else {
            setPaintsFrames(false)
            if attached == nil, let requested, let cell {
                attach(popup.terminalID, grid: requested, cell: cell)
            }
        }
    }

    private func planGrid() {
        guard let area, let cell,
              let next = HerdrPopupGrid(widthPx: area.widthPx, heightPx: area.heightPx, cell: cell),
              next != requested
        else { return }
        requested = next
        if attached?.received != nil {
            scheduleResize()
        } else {
            // Not attached yet: the attach asks for the newest grid.
            reconcile()
        }
    }

    private func scheduleResize() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.resize()
        }
    }

    private func resize() {
        guard let attached, let requested, let cell, requested != asked?.grid else { return }
        asked = (requested, .now)
        let geometry = Self.geometry(requested, cell: cell)
        Task { await attached.attachment.resize(to: geometry) }
    }

    private func attach(_ terminalID: String, grid: HerdrPopupGrid, cell: GhosttyTerminalCellDisplayMetrics) {
        generation += 1
        let generation = generation
        let attachment = makeAttachment(terminalID, Self.geometry(grid, cell: cell))
        var next = Attached(generation: generation, attachment: attachment)
        next.listening = Task { [weak self] in
            for await event in attachment.updates {
                guard let self, self.attached?.generation == generation else { return }
                self.receive(event, generation: generation)
            }
        }
        attached = next
        asked = (grid, .now)
        Task { await attachment.run() }
        GhosttyRuntimeTrace.diagnostics("popup attach terminal=\(terminalID) grid=\(grid)")
    }

    private func receive(_ event: HerdrTerminalAttachment.Event, generation: UInt64) {
        switch event {
        case .terminal(let terminal, let columns, let rows):
            let grid = HerdrPopupGrid(columns: columns, rows: rows)
            attached?.received = grid
            createAttachedRenderer(terminal: terminal, grid: grid, generation: generation)
            // The area may have changed while the attach was on its way.
            if requested != grid { scheduleResize() }
        case .grid(let columns, let rows):
            let grid = HerdrPopupGrid(columns: columns, rows: rows)
            attached?.received = grid
            if let surface, surface.isAttached, let cell {
                surface.grid = grid
                _ = surface.renderer.updateDisplay(metrics: grid.displayMetrics(cell: cell))
                logLayout()
            }
            onChange()
        case .ended(let ending):
            ended(ending)
        }
    }

    private func ended(_ ending: HerdrTerminalAttachment.Ending) {
        guard let popup else { return }
        attached?.listening?.cancel()
        attached = nil
        settle?.cancel()
        asked = nil
        // A renderer still being made for the attach closes once made.
        creating = nil
        let terminalID = popup.terminalID
        switch ending {
        case .detached:
            return
        case .closed(let reason):
            // The popup is gone; the layout without it follows.
            GhosttyRuntimeTrace.diagnostics("popup attach ended terminal=\(terminalID) reason=\(reason)")
            closeSurface()
            onChange()
            return
        case .held(let reason):
            GhosttyRuntimeTrace.diagnostics("popup attach held elsewhere terminal=\(terminalID) reason=\(reason)")
            onHeldElsewhere()
        case .refused(let reason):
            GhosttyRuntimeTrace.diagnostics("popup attach refused terminal=\(terminalID) reason=\(reason)")
        case .failed(let reason):
            GhosttyRuntimeTrace.diagnostics("popup attach failed terminal=\(terminalID) reason=\(reason)")
        }
        closeSurface()
        framed.insert(terminalID)
        reconcile()
        onChange()
    }

    /// One record per layout the renderer draws: the grid the area holds, the frames', and the renderer's,
    /// which agree once the layout settles, and how long the frames took to follow.
    private func logLayout() {
        guard let popup, let cell, let surface else { return }
        let received = attached?.received
        var settledIn = "-"
        if let asked, asked.grid == received {
            let elapsed = (ContinuousClock.now - asked.at).components
            settledIn = "\(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)ms"
            self.asked = nil
        }
        GhosttyRuntimeTrace.diagnostics(
            "popup layout terminal=\(popup.terminalID) area=\(area.map { "\($0.widthPx)x\($0.heightPx)" } ?? "-")px "
                + "scale=\(cell.contentScale) cell=\(cell.pixelWidth)x\(cell.pixelHeight)px "
                + "requested=\(requested?.description ?? "-") received=\(received?.description ?? "-") "
                + "displayed=\(surface.grid) "
                + "drawable=\(UInt32(surface.grid.columns) * cell.pixelWidth)x\(UInt32(surface.grid.rows) * cell.pixelHeight)px "
                + "cursor=\(surface.renderer.inputControlSurface?.cursorGeometry().map { "\($0.minX),\($0.minY)" } ?? "-") "
                + "settledIn=\(settledIn)"
        )
    }

    // MARK: - Renderers

    private func createAttachedRenderer(terminal: HerdrRetainedTerminal, grid: HerdrPopupGrid, generation: UInt64) {
        guard let runtime, let cell, let popup, let attached, attached.generation == generation else { return }
        closeSurface()
        let writer = HerdrPopupInputWriter(attachment: attached.attachment)
        let terminalID = popup.terminalID
        creating = ObjectIdentifier(terminal)
        TerminalPaneRenderer.create(
            app: runtime.appHandle,
            terminal: terminal,
            fence: HerdrTerminalAttachmentFence(attachment: attached.attachment, terminal: terminal),
            writeInput: { writer.write($0) },
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: grid.displayMetrics(cell: cell),
            theme: theme,
            diagnosticName: "herdr popup=\(terminalID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(terminal) }
        ) { [weak self, runtime] result in
            guard let self, self.creating == ObjectIdentifier(terminal), self.attached?.generation == generation else {
                writer.finish()
                if case .success(let renderer) = result {
                    renderer.close { withExtendedLifetime(runtime) {} }
                }
                self?.creationOutdated(terminal)
                return
            }
            self.creating = nil
            switch result {
            case .success(let renderer):
                // A newer grid may have come while the renderer was made.
                let current = self.attached?.received ?? grid
                if current != grid { _ = renderer.updateDisplay(metrics: current.displayMetrics(cell: cell)) }
                self.adopt(renderer)
                let surface = HerdrPopupTerminalSurface(
                    terminalID: terminalID,
                    terminal: terminal,
                    renderer: renderer,
                    source: .attachment(writer),
                    grid: current
                )
                self.surface = surface
                self.onSurface(surface)
                self.applyActivity()
                self.logLayout()
            case .failure:
                writer.finish()
                self.failure = Self.rendererFailure
            }
            self.onChange()
        }
    }

    private func createFramedRendererIfPossible(_ popup: HerdrPaneLayout.Popup) {
        guard let runtime, let cell, let frameTerminal, frameTerminal.terminalID == popup.terminalID,
              surface?.terminal !== frameTerminal.terminal, creating == nil
        else { return }
        let terminal = frameTerminal.terminal
        let grid = HerdrPopupGrid(columns: popup.columns, rows: popup.rows)
        let deliver = frameInput.deliver
        let terminalID = popup.terminalID
        closeSurface()
        creating = ObjectIdentifier(terminal)
        TerminalPaneRenderer.create(
            app: runtime.appHandle,
            terminal: terminal,
            fence: makeFrameFence(popup.terminalID, terminal),
            writeInput: nil,
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: grid.displayMetrics(cell: cell),
            theme: theme,
            diagnosticName: "herdr popup frame=\(popup.terminalID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(terminal) }
        ) { [weak self, runtime] result in
            guard let self, self.creating == ObjectIdentifier(terminal), self.frameTerminal?.terminal === terminal else {
                if case .success(let renderer) = result {
                    renderer.close { withExtendedLifetime(runtime) {} }
                }
                self?.creationOutdated(terminal)
                return
            }
            self.creating = nil
            switch result {
            case .success(let renderer):
                self.adopt(renderer)
                let surface = HerdrPopupTerminalSurface(
                    terminalID: popup.terminalID,
                    terminal: terminal,
                    renderer: renderer,
                    source: .frame(deliver: { await deliver(terminalID, $0) }),
                    grid: grid
                )
                self.surface = surface
                self.onSurface(surface)
                self.followFrameGrid()
                self.applyActivity()
            case .failure:
                self.failure = Self.rendererFailure
            }
            self.onChange()
        }
    }

    /// A new renderer tells the screen when it has drawn, as a pane's does, and takes the theme, which may
    /// have changed while it was made.
    private func adopt(_ renderer: TerminalPaneRenderer) {
        renderer.onPresentationChange = { [weak self] in self?.onChange() }
        if !renderer.applyTerminalConfiguration(theme: theme) {
            renderer.failPresentation(message: Self.rendererFailureMessage)
        }
    }

    /// A renderer made for a terminal the popup no longer shows: another one may wait for it.
    private func creationOutdated(_ terminal: HerdrRetainedTerminal) {
        guard creating == ObjectIdentifier(terminal) else { return }
        creating = nil
        reconcile()
    }

    /// A framed popup's renderer draws the grid Herdr's frame has.
    private func followFrameGrid() {
        guard let popup, let surface, !surface.isAttached, let cell else { return }
        let grid = HerdrPopupGrid(columns: popup.columns, rows: popup.rows)
        guard grid != surface.grid else { return }
        surface.grid = grid
        _ = surface.renderer.updateDisplay(metrics: grid.displayMetrics(cell: cell))
    }

    private func applyActivity() {
        guard let surface else { return }
        surface.renderer.setSceneActive(activity.sceneActive)
        surface.renderer.setPresented(activity.presented)
        surface.renderer.setFocused(activity.focused)
    }

    private func rendererFailed(_ terminal: HerdrRetainedTerminal) {
        guard let surface, surface.terminal === terminal else { return }
        surface.renderer.failPresentation(message: Self.rendererFailureMessage)
        onChange()
    }

    private func closeSurface() {
        guard let surface else { return }
        self.surface = nil
        if case .attachment(let writer) = surface.source { writer.finish() }
        surface.renderer.close { [runtime] in withExtendedLifetime(runtime) {} }
    }

    private func detach() {
        guard let attached else { return }
        self.attached = nil
        attached.listening?.cancel()
        settle?.cancel()
        asked = nil
        Task { await attached.attachment.detach() }
    }

    /// The phone lets the popup go: Herdr gives its size back, and its renderer closes.
    private func release() {
        let holding = attached != nil || surface != nil || creating != nil || frameTerminal != nil
        detach()
        creating = nil
        closeSurface()
        setPaintsFrames(false)
        frameTerminal = nil
        if holding { onChange() }
    }

    private func setPaintsFrames(_ paints: Bool) {
        guard paints != paintsFrames else { return }
        paintsFrames = paints
        paintsFramesRevision += 1
        paintFrames(paints, paintsFramesRevision)
    }

    private static func geometry(_ grid: HerdrPopupGrid, cell: GhosttyTerminalCellDisplayMetrics) -> HerdrTerminalAttachment.Geometry {
        HerdrTerminalAttachment.Geometry(
            columns: grid.columns,
            rows: grid.rows,
            cellWidthPx: cell.pixelWidth,
            cellHeightPx: cell.pixelHeight
        )
    }

    static let rendererFailureMessage = "Terminal renderer is unavailable. Reconnect to try again."
    private static let rendererFailure = TerminalDisconnectReason(kind: .runtime, message: rendererFailureMessage)
}

/// Herdr's accent as a client can see it: Herdr sends no palette, but draws the focused pane's border lines
/// in the accent and the others in `overlay0` (`ui/panes.rs`), and Herdr's client draws a popup's border in
/// it (`client/shell/composition.rs`).
enum HerdrPopupAccent {
    /// The accent of Herdr's default theme, Catppuccin Mocha (`app/state.rs` `Palette::catppuccin`), which
    /// Herdr's client uses without a config (`config/theme.rs`, `app/mod.rs` `theme_runtime_config`).
    static let herdrDefault = HerdrColor(raw: 0x0289_B4FA)

    /// The colour of a border line along the text area of the pane the frame was drawn focused, nil when the
    /// tab draws none there.
    static func color(in layout: HerdrPaneLayout) -> HerdrColor? {
        guard let area = layout.panes.first(where: { $0.paneID == layout.focusedPaneID })?.innerRect else { return nil }
        let left = Int(area.x), right = Int(area.x) + Int(area.width)
        let top = Int(area.y), bottom = Int(area.y) + Int(area.height)
        // Lines run in half cells along their axis; a line along an edge overlaps the edge's span.
        func overlaps(_ line: HerdrBorderLine, from start: Int, to end: Int) -> Bool {
            Int(line.start) < 2 * end && Int(line.end) > 2 * start
        }
        return layout.borders.first { line in
            let track = Int(line.track)
            switch line.axis {
            case .horizontal:
                return (track == top - 1 || track == bottom) && overlaps(line, from: left, to: right)
            case .vertical:
                return (track == left - 1 || track == right || track == right + 1) && overlaps(line, from: top, to: bottom)
            }
        }?.color
    }
}
