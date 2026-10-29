import Foundation
import GhosttyKit

/// The grid a popup gets: the panes' grid inside Herdr's frame, whose lines take its outer cells, as Herdr's
/// client blits a popup's terminal inside its box, or the whole grid when it is too small for a frame
/// (`GhosttyTerminalViewportPresentationProjection.Popup.content(in:)`). Cells of the panes' font, never
/// scaled, so the popup's text is the panes' size and the keyboard takes rows, not size.
struct HerdrPopupGrid: Equatable, Sendable, CustomStringConvertible {
    let columns: UInt16
    let rows: UInt16

    /// The popup's cells on the panes' grid of `columns` x `rows`; nil for an empty grid.
    init?(in columns: UInt16, rows: UInt16) {
        let grid = GhosttyTerminalGridSize(columns: UInt32(columns), rows: UInt32(rows))
        guard let content = GhosttyTerminalViewportPresentationProjection.Popup.content(in: grid) else { return nil }
        self.init(columns: UInt16(content.columns), rows: UInt16(content.rows))
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

/// The renderer of the popup over the tab: over its attachment's terminal, or over the terminal the engine
/// paints from Herdr's popup frame when it can't be attached. Either way its input goes as Herdr's client
/// sends a popup's (`HerdrPopupController.Input`).
@MainActor
final class HerdrPopupTerminalSurface: TerminalPaneInputSink {
    let terminalID: String
    let terminal: HerdrRetainedTerminal
    let renderer: TerminalPaneRenderer
    /// Over the attachment's terminal, rather than the one painted from Herdr's frame.
    let isAttached: Bool
    /// The composer's input for this popup's terminal, which learns whether Herdr has it.
    private let deliver: ([HerdrInputEvent]) async -> Bool
    /// The grid the renderer draws.
    fileprivate(set) var grid: HerdrPopupGrid

    fileprivate init(
        terminalID: String,
        terminal: HerdrRetainedTerminal,
        renderer: TerminalPaneRenderer,
        isAttached: Bool,
        deliver: @escaping ([HerdrInputEvent]) async -> Bool,
        grid: HerdrPopupGrid
    ) {
        self.terminalID = terminalID
        self.terminal = terminal
        self.renderer = renderer
        self.isAttached = isAttached
        self.deliver = deliver
        self.grid = grid
    }

    func screenSurface(id: UUID) -> GhosttyManagedSurface {
        renderer.screenSurface(id: id, inputSink: self)
    }

    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool {
        guard !text.isEmpty else { return false }
        return await deliver([.paste(text)])
    }

    func sendKeyEventAwaitingCommandCompletion(_ event: GhosttySurfaceKeyEvent) async -> Bool {
        guard let event = HerdrInputTranslator.event(for: event) else { return false }
        return await deliver([event])
    }
}

/// The popup Herdr shows over the tab on screen, while the phone shows it. Herdr's client draws a popup at
/// a share of its screen; Remux instead attaches straight to the popup's terminal, as `herdr terminal
/// attach` does, at the grid that fills the terminal area at the panes' font. Herdr's resize lock then keeps
/// the popup at the phone's size whatever other clients do, until the phone lets it go and Herdr gives the
/// size back, so the phone holds the popup only while it is on the phone's screen. When Herdr refuses the
/// attach or it fails, the popup's frame is drawn as Herdr sends it to this client, at the panes' font.
/// Its input goes as Herdr's client sends a popup's either way, which Herdr encodes for the program's modes
/// and which makes the phone the client Herdr sends the program's clipboard writes to.
///
/// Three grids are kept apart: the one the area holds, which goes to Herdr once the area settles; the one
/// Herdr's frames have; and the one the renderer draws, which follows the frames', so the screen always
/// shows whole frames. Each attach has a generation, so nothing from an attach let go reaches the screen.
@MainActor
final class HerdrPopupController {
    typealias AttachmentFactory = @MainActor (_ terminalID: String, HerdrTerminalAttachment.Geometry) -> HerdrTerminalAttachment
    typealias FrameFenceFactory = @MainActor (_ terminalID: String, HerdrRetainedTerminal) -> any TerminalPaneRendererFence

    /// The popup's input, as Herdr's client sends a popup's.
    struct Input {
        /// Typing, read as Herdr's client reads a terminal's for the popup's keyboard modes.
        let text: (String) -> FocusedTerminalInputSubmissionResult
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
    private let input: Input
    /// Herdr refused the attach because another device holds the popup.
    private let onHeldElsewhere: () -> Void
    /// A new renderer, which the screen gives its surface.
    private let onSurface: (HerdrPopupTerminalSurface) -> Void
    private let onChange: () -> Void

    private var runtime: GhosttyKitRuntime?
    private var theme: TerminalTheme
    /// The popup open over the tab, which takes the tab's input.
    private(set) var popup: HerdrPaneLayout.Popup?
    /// Herdr leaves the popup out of its surface, which is too small to box it, and only the attach shows it.
    private var omitted = false
    private var held = false
    private var activity = RendererActivity()
    private var cell: GhosttyTerminalCellDisplayMetrics?
    /// The panes' grid, which the popup is framed on.
    private var viewport: (columns: UInt16, rows: UInt16)?
    /// The grid inside the frame now.
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
    /// The popup Herdr asked to attach to again, once (`Ending.busy`), and the wait before it.
    private var retried: String?
    private var retry: Task<Void, Never>?

    /// How long the area must stay put before its grid goes to Herdr: the keyboard and rotation move the
    /// area, and each resize makes the program redraw.
    static let settleDelay: Duration = .milliseconds(150)
    /// How long to wait before attaching again when Herdr asks to try again.
    static let retryDelay: Duration = .milliseconds(250)

    init(
        theme: TerminalTheme,
        makeAttachment: @escaping AttachmentFactory,
        makeFrameFence: @escaping FrameFenceFactory,
        paintFrames: @escaping (Bool, UInt64) -> Void,
        input: Input,
        onHeldElsewhere: @escaping () -> Void,
        onSurface: @escaping (HerdrPopupTerminalSurface) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.theme = theme
        self.makeAttachment = makeAttachment
        self.makeFrameFence = makeFrameFence
        self.paintFrames = paintFrames
        self.input = input
        self.onHeldElsewhere = onHeldElsewhere
        self.onSurface = onSurface
        self.onChange = onChange
    }

    // MARK: - What the model tells

    func setRuntime(_ runtime: GhosttyKitRuntime?) {
        self.runtime = runtime
        reconcile()
    }

    /// The layout's popup, on a surface of `surfaceColumns` x `surfaceRows`. Another terminal id is another
    /// popup. Herdr leaves a popup out of a surface under 6 x 4 cells, where it can't box it, though the popup
    /// is still open and takes the tab's input (`popup_size.rs` `resolve_popup_geometry`): an attached popup
    /// stays then, until its attach ends or a surface Herdr could box it in comes without it.
    func update(_ next: HerdrPaneLayout.Popup?, surfaceColumns: UInt16, surfaceRows: UInt16) {
        if next == nil, popup != nil, attached != nil, surfaceColumns < 6 || surfaceRows < 4 {
            omitted = true
            return
        }
        omitted = false
        guard next != popup else { return }
        let replaced = next?.terminalID != popup?.terminalID
        popup = next
        if replaced {
            release()
            framed = framed.filter { $0 == next?.terminalID }
            retried = nil
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

    /// The panes' cell and grid, from the screen's font, scale and size.
    func setViewport(cell next: GhosttyTerminalCellDisplayMetrics, columns: UInt16, rows: UInt16) {
        guard next != cell || viewport.map({ $0.columns != columns || $0.rows != rows }) ?? true else { return }
        cell = next
        viewport = (columns, rows)
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
    func retryAttach() {
        framed.removeAll()
        retried = nil
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
        return input.text(text)
    }

    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        return input.send([.paste(text)])
    }

    func sendKey(_ key: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        guard let event = HerdrInputTranslator.event(for: key) else {
            return key.action == .release ? .accepted : .surfaceRejected
        }
        return input.send([event])
    }

    /// A swipe's wheel steps, a row each, up for positive `rows`, as Herdr's client sends a popup's wheel: on
    /// the keys' queue, so a key after a swipe comes after all of its steps. Herdr routes each as the program
    /// asks, a mouse report, cursor keys on the alternate screen, or the terminal's history.
    func scroll(rows: Int, column: UInt16, row: UInt16) -> Bool {
        guard takesInput else { return false }
        guard rows != 0 else { return true }
        let wheel = HerdrMouseEvent(
            kind: rows > 0 ? .scrollUp : .scrollDown,
            column: column,
            row: row,
            modifiers: [],
            lines: 1
        )
        return input.send(Array(repeating: .mouse(wheel), count: Int(rows.magnitude))) == .accepted
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
            if attached == nil, retry == nil, let requested, let cell {
                attach(popup.terminalID, grid: requested, cell: cell)
            }
        }
    }

    private func planGrid() {
        guard let viewport, cell != nil,
              let next = HerdrPopupGrid(in: viewport.columns, rows: viewport.rows),
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
        if omitted {
            // Nothing else shows a popup Herdr leaves out of its surface.
            GhosttyRuntimeTrace.diagnostics("popup attach ended while left out terminal=\(terminalID) ending=\(ending)")
            release()
            return
        }
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
        case .busy(let reason) where retried != terminalID:
            // Once: Herdr asks to try again while an agent reads the terminal, which takes a moment.
            GhosttyRuntimeTrace.diagnostics("popup attach busy terminal=\(terminalID) reason=\(reason)")
            retried = terminalID
            closeSurface()
            retry = Task { [weak self] in
                try? await Task.sleep(for: Self.retryDelay)
                guard !Task.isCancelled, let self else { return }
                self.retry = nil
                self.reconcile()
            }
            return
        case .busy(let reason), .refused(let reason):
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
            "popup layout terminal=\(popup.terminalID) viewport=\(viewport.map { "\($0.columns)x\($0.rows)" } ?? "-") "
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
        let terminalID = popup.terminalID
        let deliver = input.deliver
        creating = ObjectIdentifier(terminal)
        TerminalPaneRenderer.create(
            app: runtime.appHandle,
            terminal: terminal,
            fence: HerdrTerminalAttachmentFence(attachment: attached.attachment, terminal: terminal),
            writeInput: nil,
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: grid.displayMetrics(cell: cell),
            theme: theme,
            diagnosticName: "herdr popup=\(terminalID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(terminal) }
        ) { [weak self, runtime] result in
            guard let self, self.creating == ObjectIdentifier(terminal), self.attached?.generation == generation else {
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
                    isAttached: true,
                    deliver: { await deliver(terminalID, $0) },
                    grid: current
                )
                self.surface = surface
                self.onSurface(surface)
                self.applyActivity()
                self.logLayout()
            case .failure:
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
        let deliver = input.deliver
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
                    isAttached: false,
                    deliver: { await deliver(terminalID, $0) },
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
        surface.renderer.close { [runtime] in withExtendedLifetime(runtime) {} }
    }

    private func detach() {
        retry?.cancel()
        retry = nil
        guard let attached else { return }
        self.attached = nil
        attached.listening?.cancel()
        settle?.cancel()
        asked = nil
        Task { await attached.attachment.detach() }
    }

    /// The phone lets the popup go: Herdr gives its size back, and its renderer closes. A popup Herdr leaves
    /// out goes with its attach.
    private func release() {
        let holding = attached != nil || surface != nil || creating != nil || frameTerminal != nil || omitted
        detach()
        creating = nil
        closeSurface()
        setPaintsFrames(false)
        frameTerminal = nil
        if omitted {
            omitted = false
            popup = nil
        }
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
