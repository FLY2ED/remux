import Foundation
import GhosttyKit

/// One Herdr pane's renderer, over the pane terminal the engine gave it.
@MainActor
final class HerdrPaneSurface: TerminalPaneInputSink {
    let paneID: String
    let terminal: HerdrRetainedTerminal
    let renderer: TerminalPaneRenderer

    init(paneID: String, terminal: HerdrRetainedTerminal, renderer: TerminalPaneRenderer) {
        self.paneID = paneID
        self.terminal = terminal
        self.renderer = renderer
    }

    func screenSurface(id: UUID) -> GhosttyManagedSurface {
        renderer.screenSurface(id: id, inputSink: self)
    }

    // The composer's input goes through the screen model, which holds the connection.
    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool { false }

    func sendKeyEventAwaitingCommandCompletion(_ event: GhosttySurfaceKeyEvent) async -> Bool { false }
}

/// The screen model for one Herdr session, as `TmuxScreenModel` is for tmux: one connection at a time
/// to the session's server, the session's terminal engine, and a renderer for each pane terminal. It
/// reports the domain `TerminalRuntimeState` that the root reduces.
///
/// The root says whether it wants the session on screen; the model speaks the protocol as Herdr's own
/// client does for a remote session: it connects hidden, then shows the session. Frames go from the
/// connection to the engine without passing through the main actor; the model lays out the panes and
/// owns their renderers.
@MainActor
final class HerdrScreenModel {
    typealias BridgeOpener = @Sendable () async throws -> any HerdrBridgeTransport
    typealias RendererFenceFactory = @MainActor (
        HerdrTerminalEngine,
        _ paneID: String,
        HerdrRetainedTerminal
    ) -> any TerminalPaneRendererFence

    let target: SessionTarget
    let sessionInstanceID: UUID
    let terminalScreenAdapter = HerdrTerminalScreenAdapter()

    /// What the model tells its owner about the session's notifications.
    enum NotificationEvent: Equatable {
        /// A Herdr notification, with the server boot whose pane ids it uses and the names of the
        /// place it is about.
        case received(HerdrSemanticNotification, bootID: String?, place: HerdrNotificationPlace)
        /// The server restarted, so earlier notifications point at panes that are gone.
        case serverRestarted
        /// A program in the session on screen rang the bell.
        case bell
    }

    /// What the model asks of the connection and the engine, in the order it asks.
    private enum Operation: Sendable {
        /// `zoom`, when given, is the pane whose tab the show zooms, behind the show, and that tab. A show
        /// with a move to another tab right behind it shows the tab the move reaches (`holdsForMove`).
        case show(HerdrSurfaceGeometry, request: UInt64, zoom: (pane: String, tab: HerdrTabKey)?, holdsForMove: Bool)
        case hide
        case resize(HerdrSurfaceGeometry)
        case theme([HerdrHostThemeUpdate])
        case appActive(Bool)
        /// `delivered`, when given, learns whether Herdr has the input.
        case input(paneID: String, events: [HerdrInputEvent], delivered: CheckedContinuation<Bool, Never>?)
        /// Remux's move to a pane (`move(_:to:)`), by its number; a newer move replaces it before it goes.
        case move(UInt64)
        /// A `pane.zoom` of a pane's tab; the newest asked for wins (`sendZoom`).
        case zoom(String, zoomed: Bool, tab: HerdrTabKey, completing: Completion?)

        /// Tells whoever waits on the operation that it won't be carried out.
        func abandon() {
            if case .input(_, _, let delivered?) = self { delivered.resume(returning: false) }
        }
    }

    /// Remux's move to a pane: the pane, its tab, and, for a move to another tab, the show or move whose
    /// frames the engine holds until the move is done.
    private struct Move {
        let number: UInt64
        let paneID: String
        let tab: HerdrTabKey?
        let hold: UInt64?
        /// Where Herdr's answer to its focus fell among the snapshots, once it is in.
        var focused: HerdrTerminalEngine.CommandAnswer?
    }

    /// The show or move whose frames wait for a zoom, and the answer they fall back to when the zoom
    /// doesn't go or changes nothing.
    private struct Completion: Sendable {
        let request: UInt64
        let fallback: HerdrTerminalEngine.CommandAnswer?
    }

    /// One connection to the server, from opening its bridge to its end. A reconnect replaces it, and
    /// the panes keep their last frame meanwhile. Its id names its connection to the engine.
    ///
    /// Its task opens the connection, then carries out the operations one at a time, in the order they
    /// were asked for. Herdr takes the newest of a show and a hide, so that order is the session's
    /// state. No operation waits for Herdr's answer, so a hide goes out while a show is unanswered.
    @MainActor
    private final class Attempt {
        let id: UInt64
        var task: Task<Void, Never>?
        /// The connection, from the moment its bridge opened: from then on only the connection closes
        /// the bridge.
        var connection: HerdrConnection?
        /// The connection's welcome came and the model took it.
        var isOpen = false
        /// Herdr's surface switch names the snapshot's boot, so nothing is shown before one arrives.
        var hasSnapshot = false
        /// Numbers the shows, hides and moves to another tab asked for; the engine knows a show or move by
        /// its number.
        var viewRequests: UInt64 = 0
        /// The newest show's number, while the session is to be shown.
        var showRequest: UInt64?
        /// The newest show Herdr completed: its answer and a frame sent after it are in.
        var activatedRequest: UInt64?
        var activationDeadline: Task<Void, Never>?
        /// How the attempt's bridge closes, set once it is given up; nil while it is under way.
        var closeCause: HerdrBridgeCloseCause?
        /// The give-up's close of the connection.
        var closing: Task<Void, Never>?
        /// Whether the focused pane asks for every key as an escape code.
        var reportsAllKeys = false
        /// Remux's newest move, until Herdr has answered its focus and the snapshot shows its tab.
        var move: Move?
        var moves: UInt64 = 0
        private var operations: [Operation] = []
        private var operationWaiter: CheckedContinuation<Void, Never>?
        private var operationsFinished = false

        init(id: UInt64) {
            self.id = id
        }

        var ended: Bool { closeCause != nil }

        var requestedShown: Bool { showRequest != nil }

        /// The session reads as connected: the connection is open with its first snapshot and, while the
        /// session is shown, has completed a show, so the panes show its frames.
        var isReady: Bool {
            isOpen && hasSnapshot && (!requestedShown || activatedRequest != nil)
        }

        /// Ready and shown, with no show in progress: the session takes input and commands. A session
        /// shown again keeps its last frame and reads as connected meanwhile, but takes no input, as
        /// Herdr's client freezes input while a show is in progress.
        var isActivated: Bool {
            isReady && requestedShown && activatedRequest == showRequest
        }

        /// Returns once the attempt's task has returned and its give-up has closed its connection.
        func closed() async {
            await task?.value
            await closing?.value
        }

        /// Queued while the connection opens, and carried out once it is open. Only the newest size
        /// matters, as Herdr's client sends only the newest it sampled: a new size replaces every one
        /// not yet sent. A show queued before it already carries a newer size than those.
        func ask(_ operation: Operation) {
            guard !ended, !operationsFinished else {
                operation.abandon()
                return
            }
            if case .resize = operation {
                operations.removeAll { if case .resize = $0 { true } else { false } }
            }
            operations.append(operation)
            wake()
        }

        /// The next operation in the order asked, or nil once the attempt is over. An operation stays
        /// queued until taken here, so a newer size can still replace it.
        func nextOperation() async -> Operation? {
            while true {
                if operationsFinished { return nil }
                if !operations.isEmpty { return operations.removeFirst() }
                await withCheckedContinuation { operationWaiter = $0 }
            }
        }

        func finishOperations() {
            operationsFinished = true
            let abandoned = operations
            operations.removeAll()
            abandoned.forEach { $0.abandon() }
            wake()
        }

        private func wake() {
            operationWaiter?.resume()
            operationWaiter = nil
        }
    }

    /// Herdr's server closes a connection that sends no hello within 4 s of connecting; the bridge is
    /// closed before that if the screen has no size yet, and opened again once it has one.
    static let helloDeadline: Duration = .seconds(3)

    /// When a session that has connected reconnects by itself, as Herdr's client retries every endpoint,
    /// wake rules included (`endpoint/supervisor.rs`).
    struct RecoveryTiming: Sendable {
        /// The first retry after a drop; each failure in a row doubles it, up to `longestRetry`.
        var firstRetry: Duration = .milliseconds(500)
        var longestRetry: Duration = .seconds(120)
        /// A drop this long after the connection's first snapshot in the foreground starts the delays over.
        var stable: Duration = .seconds(60)
        /// A server that needs attention (incompatible, or a snapshot Remux can't read) is tried again
        /// this often.
        var recheck: Duration = .seconds(30)
        /// After the app comes back, delays are at most `wakeRetry` for `wakeWindow`.
        var wakeWindow: Duration = .seconds(30)
        var wakeRetry: Duration = .seconds(2)
    }

    /// What follows an attempt's end.
    private enum Recovery {
        /// A dropped connection: try again with growing delays, showing the last frame meanwhile.
        case retry
        /// The server needs attention: say why, and try again every `recheck`.
        case recheck
        /// The user has to act (sign-in, host key, Herdr missing), or the failure is Remux's own.
        case none
    }

    private let openBridge: BridgeOpener
    private let connectionTiming: HerdrConnection.Timing
    private let recoveryTiming: RecoveryTiming
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private let onNotification: (NotificationEvent) -> Void
    private let engine: HerdrTerminalEngine
    private let makeRendererFence: RendererFenceFactory
    private var runtime: GhosttyKitRuntime?
    private var currentTerminalSettings: TerminalSettings
    /// The colours of the current theme: Herdr gets them in the theme report, and Herdr's pane borders
    /// are drawn in them. nil when Ghostty can't give them.
    private(set) var terminalColors: GhosttyTerminalColors?
    private var reportTracker = TerminalRuntimeStateReportTracker()
    private var stopped = false
    private var failure: TerminalDisconnectReason?
    private var updatesTask: Task<Void, Never>?

    private var attempt: Attempt?
    private var attemptCount: UInt64 = 0
    private var sizeWaiter: CheckedContinuation<Void, Never>?

    /// Whether any connection reached its first snapshot. Only then does a failure reconnect by itself:
    /// a session that never opened says why.
    private var hasConnected = false
    /// A retry is waiting or under way after a drop; the session reads as reconnecting meanwhile.
    private var isReconnecting = false
    /// Failed attempts since the last stable connection, which set the next delay.
    private var failuresInARow = 0
    /// When the next attempt is due. Kept while the app is in the background, whose timer stops.
    private var recoveryDue: ContinuousClock.Instant?
    private var recoveryTimer: Task<Void, Never>?
    /// The current connection's first snapshot since it opened or the app came back, as Herdr's client
    /// counts how long a connection stayed up: time in the background doesn't count.
    private var readySince: ContinuousClock.Instant?
    private var wokeAt: ContinuousClock.Instant?

    private(set) var isSelected = false
    private var appPhase = GhosttyAppLifecyclePhase.active
    private var lastViewport: (size: CGSize, scale: CGFloat)?
    private(set) var measurement: GhosttyTerminalViewportMeasurement?
    /// When the screen first had a size, which a waiting bridge's hello deadline is held against.
    private var sizeKnownSince: ContinuousClock.Instant?

    private(set) var layout: HerdrPaneLayout?
    /// The newest snapshot, kept across a reconnect until the new connection's first.
    private var snapshot: HerdrSnapshot?
    /// The frame on screen: the connection and snapshot revision it was drawn against, and its panes.
    private var presentedFrame: (connection: UInt64, bootID: String, projectionRevision: UInt64, paneIDs: Set<String>)?
    private var agents = HerdrAgentPresentation()
    /// A pane to go to once the session is shown, and the server boot its id belongs to.
    private var pendingReveal: (paneID: String, bootID: String?)?
    /// The pane keys go to and the screen highlights: the newest snapshot's focused pane, as in
    /// Herdr's client. A pane can be focused before its first frame arrives.
    private(set) var focusedPaneID: String?
    private var ownedZoom = HerdrOwnedZoom()
    /// Tabs the user unzoomed with the pane sheet's button, which the setting leaves alone after.
    private var tabsUnzoomedByUser: Set<HerdrTabKey> = []
    private var tabMap: HerdrTabMap?
    /// The zoomed tab's panes the map had no place for when Remux last asked Herdr for its layout.
    private var askedTabMapGap: HerdrTabMapGap?
    private var terminals: [String: HerdrRetainedTerminal] = [:]
    private var surfaces: [String: HerdrPaneSurface] = [:]
    private var paneScrolls: [String: HerdrPaneScroll] = [:]
    /// Where the current scroll gesture over each pane is, in the pane's points, and the travel not
    /// yet a whole wheel step.
    private var scrollPointers: [String: CGPoint] = [:]
    private var wheelRemainders: [String: Double] = [:]
    private var presentationFailures: [String: TerminalDisconnectReason] = [:]
    private var notices = HerdrNoticePolicy(visibleFor: GhosttyTerminalCommandFailureNotice.duration)
    private var creatingTerminals: Set<ObjectIdentifier> = []
    /// Ghostty gives a terminal one renderer at a time, so a replacement waits for these to close.
    private var closingTerminals: Set<ObjectIdentifier> = []
    private var creationsDrained: CheckedContinuation<Void, Never>?
    /// Renderers whose surfaces aren't freed yet. Ghostty requires the app to outlive every surface,
    /// so a stop releases the runtime only once this is back to zero.
    private var closingRenderers = 0
    private var closesDrained: CheckedContinuation<Void, Never>?

    init(
        target: SessionTarget,
        sessionInstanceID: UUID,
        openBridge: @escaping BridgeOpener,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        onNotification: @escaping (NotificationEvent) -> Void,
        connectionTiming: HerdrConnection.Timing = HerdrConnection.Timing(),
        recoveryTiming: RecoveryTiming = RecoveryTiming(),
        engine: HerdrTerminalEngine = HerdrTerminalEngine(cellWidthPx: 1, cellHeightPx: 1),
        makeRendererFence: @escaping RendererFenceFactory = {
            HerdrPaneRendererFence(engine: $0, paneID: $1, terminal: $2)
        }
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.openBridge = openBridge
        self.onRuntimeStateChange = onRuntimeStateChange
        self.onNotification = onNotification
        self.connectionTiming = connectionTiming
        self.recoveryTiming = recoveryTiming
        self.engine = engine
        self.makeRendererFence = makeRendererFence
        currentTerminalSettings = target.terminalSettings
        terminalScreenAdapter.attach(to: self)
        do {
            runtime = try GhosttyKitRuntime(terminalSettings: target.terminalSettings)
        } catch {
            failure = Self.runtimeStartFailure
            didChange()
            return
        }
        terminalColors = try? runtime?.terminalColors()
        let engine = self.engine
        updatesTask = Task { [weak self] in
            for await update in engine.updates {
                self?.handle(update)
            }
        }
        restart()
    }

    /// True when no connection is open or opening, so the root may replace this model without dropping
    /// a session the user is attached to.
    var isDisconnected: Bool {
        guard let attempt else { return true }
        return attempt.ended
    }

    // MARK: - What the root wants

    /// Whether the root shows this session: the selected session, outside Home. A sheet over the
    /// terminal keeps it shown. Only a selected session's panes are presented to Ghostty.
    func setSelected(_ selected: Bool) {
        guard !stopped, selected != isSelected else { return }
        isSelected = selected
        // A pane asked for applies to the show it was asked for.
        if !selected { pendingReveal = nil }
        reconcilePresentationActivity()
        reconcileVisibility()
    }

    /// Goes to `paneID` as Herdr's client goes to a notification's pane: `pane.focus` takes this
    /// client to the pane's tab and focuses it there. It is sent once the session is shown, right after
    /// the show, and only on the server boot the pane id came from, while the pane is still there.
    func reveal(paneID: String, bootID: String?) {
        guard !stopped else { return }
        pendingReveal = (paneID, bootID)
        guard let attempt, isCurrent(attempt), attempt.isOpen, attempt.requestedShown,
              let paneID = takePendingReveal()
        else { return }
        move(attempt, to: paneID)
    }

    /// The pane asked for, once a snapshot is in, if it is still there on the server boot its id came
    /// from.
    private func takePendingReveal() -> String? {
        guard let reveal = pendingReveal, let snapshot else { return nil }
        pendingReveal = nil
        guard reveal.bootID.map({ $0 == snapshot.bootID }) ?? true,
              snapshot.panes.contains(where: { $0.paneID == reveal.paneID })
        else { return nil }
        return reveal.paneID
    }

    /// The background hides the session; the app's other phases leave it on screen.
    ///
    /// In the background a waiting reconnect stops and a connection still opening is given up, as in
    /// Herdr's client; an open one stays. Back from it, as in Herdr's client after a resume, a waiting
    /// reconnect runs at once and delays are short for a while; an open connection is shown again at
    /// once while it checks itself with a ping, and one that is gone fails its show or the ping.
    func handleAppLifecyclePhase(_ phase: GhosttyAppLifecyclePhase) {
        guard !stopped else { return }
        let wasBackground = appPhase == .background
        appPhase = phase
        if phase == .background, !wasBackground {
            enterBackground()
        } else if phase != .background, wasBackground {
            leaveBackground()
        }
        reconcilePresentationActivity()
        attempt?.ask(.appActive(phase != .background))
        reconcileVisibility()
        // Back in front, the user sees the frame on screen, as Herdr's client acknowledges its surface
        // when its terminal regains focus (`shell/input.rs`).
        if phase == .active { acknowledgeShownAgents() }
        didChange()
    }

    private func enterBackground() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        readySince = nil
        guard let attempt, !attempt.ended, !attempt.isOpen else { return }
        // Not a failure: it is opened again on return.
        giveUp(attempt)
        recoveryDue = recoveryDue ?? .now
    }

    private func leaveBackground() {
        wokeAt = .now
        if recoveryDue != nil { restart() }
    }

    /// Live settings: the renderers take the new appearance in place, and Herdr gets the new colours.
    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        guard !stopped, settings != currentTerminalSettings else { return }
        guard !settings.hasSameTerminalAppearance(as: currentTerminalSettings) else {
            currentTerminalSettings = settings
            return
        }
        try runtime?.applyTerminalSettings(settings)
        let themeChanged = settings.theme != currentTerminalSettings.theme
        currentTerminalSettings = settings
        if themeChanged {
            terminalColors = try? runtime?.terminalColors()
            didChange()
        }
        for surface in surfaces.values where !surface.renderer.isClosing {
            if !surface.renderer.applyTerminalConfiguration(theme: settings.theme) {
                surface.renderer.failPresentation(message: Self.configurationFailureMessage)
            }
        }
        if themeChanged, let themeReport {
            attempt?.ask(.theme(themeReport))
        }
        if let lastViewport {
            prepareViewport(size: lastViewport.size, scale: lastViewport.scale)
        }
    }

    /// The screen's size. Herdr's client sends its size on every resize; a hidden session gets it with
    /// the next show.
    func prepareViewport(size: CGSize, scale: CGFloat) {
        guard !stopped, let runtime else { return }
        lastViewport = (size, scale)
        let measured: GhosttyTerminalViewportMeasurement?
        do {
            measured = try runtime.measureTmuxViewportLayout(size: size, scale: scale)
        } catch {
            if let attempt { end(attempt, Self.viewportFailure, recovery: .none) }
            return
        }
        guard let measured, measured != measurement else { return }
        if measurement == nil { sizeKnownSince = .now }
        measurement = measured
        if let geometry { attempt?.ask(.resize(geometry)) }
        resumeSizeWaiter()
        for paneID in Array(surfaces.keys) {
            guard let surface = surfaces[paneID], let metrics = displayMetrics(for: paneID) else { continue }
            _ = surface.renderer.updateDisplay(metrics: metrics)
        }
        for paneID in Array(terminals.keys) {
            createRendererIfPossible(paneID)
        }
        didChange()
    }

    /// Ends the current connection, if any, and opens a new one. The panes keep their terminals, so
    /// the last frame stays on screen until the new connection's first. Pane failures say to reconnect,
    /// so a reconnect also tries the failed panes again: a pane Ghostty couldn't paint gets a new
    /// terminal from the new connection's first frame, and a failed renderer is replaced over its
    /// terminal now.
    ///
    /// Returns false when the model can't open a connection, because its terminal runtime didn't start
    /// or it has stopped; the root then replaces it.
    ///
    /// A reconnect the user asks for runs now and starts the delays over, as in Herdr's client.
    @discardableResult
    func reconnect() -> Bool {
        guard !stopped, runtime != nil else { return false }
        isReconnecting = false
        failuresInARow = 0
        failure = nil
        restart()
        return true
    }

    /// Closes the connection, lets the engine finish its event and free the pane producers, waits for
    /// renderers still being created, then closes every renderer, which unregisters it from the engine
    /// before freeing it, and releases the Ghostty app once every renderer closed anywhere is freed.
    ///
    /// A session on screen first takes off the zoom Remux made, as leaving the screen does, and waits for
    /// Herdr's answer within Herdr's time for a show, so the unzoom isn't lost with the connection. A new
    /// attempt can't take the zoom over, since Herdr's zoom has no owner. Closing the connection then hides
    /// the session on the server.
    func stop() async {
        guard !stopped else { return }
        let unzoom = attempt.flatMap { isCurrent($0) ? $0.connection : nil }
            .flatMap { connection in paneToUnzoom.map { (connection, $0) } }
        stopped = true
        cancelRecovery()
        if let (connection, paneID) = unzoom {
            _ = await connection.commandIfIdle(
                Self.paneZoomMethod,
                params: Self.zoomParams(paneID, zoomed: false),
                timeout: connectionTiming.activation
            )
        }
        if let attempt {
            giveUp(attempt)
            await attempt.closed()
        }
        await engine.stop()
        if !creatingTerminals.isEmpty {
            await withCheckedContinuation { creationsDrained = $0 }
        }
        for surface in surfaces.values {
            close(surface.renderer)
        }
        surfaces.removeAll()
        if closingRenderers > 0 {
            await withCheckedContinuation { closesDrained = $0 }
        }
        terminals.removeAll()
        presentationFailures.removeAll()
        layout = nil
        terminalScreenAdapter.invalidate()
        runtime = nil
    }

    // MARK: - What the screen reads

    var runtimePhase: GhosttyTerminalRuntimePhase {
        if let failure { return .failed(message: failure.message, reason: failure) }
        guard let attempt, !attempt.ended, attempt.isOpen else { return .starting }
        return .running
    }

    var isConnectionOpen: Bool {
        guard let attempt else { return false }
        return attempt.isOpen && !attempt.ended
    }

    /// The session reads as connected once its current connection is ready (`Attempt.isReady`). Until
    /// then the panes show the last connection's frame, which takes no input.
    var isConnectionReady: Bool {
        guard let attempt, isCurrent(attempt) else { return false }
        return attempt.isReady
    }

    var stateTraceLabel: String {
        if stopped { return "released" }
        if failure != nil { return "ended" }
        if isReconnecting { return "reconnecting" }
        guard let attempt, attempt.isOpen else { return "connecting" }
        guard attempt.requestedShown else { return "hidden" }
        return attempt.isActivated ? "shown" : "showing"
    }

    func paneSurface(_ paneID: String) -> HerdrPaneSurface? {
        surfaces[paneID]
    }

    /// What Herdr's notification rules read of this session, once a snapshot has arrived.
    var notificationState: HerdrNotificationSessionState? {
        guard let snapshot else { return nil }
        return HerdrNotificationSessionState(
            isShown: isSelected,
            focusedWorkspaceID: snapshot.focusedWorkspaceID,
            focusedTabID: snapshot.focusedTabID,
            agentStatuses: agents.statuses
        )
    }

    func presentation(ofPane paneID: String?) -> TerminalPanePresentation {
        guard let paneID else { return .pending }
        if let failure = presentationFailures[paneID] { return .failed(failure) }
        return surfaces[paneID]?.renderer.presentation ?? .pending
    }

    // MARK: - Input

    /// Input goes out while the session is shown on an open connection, its show completed, and its
    /// focused pane shows a frame: Herdr's client drops input before its first snapshot and while a show
    /// is in progress, and the server drops input on a hidden surface.
    var isInputAvailable: Bool {
        inputTarget != nil
    }

    private var inputTarget: (attempt: Attempt, paneID: String)? {
        guard let attempt = shownAttempt, let paneID = focusedPaneID, presentation(ofPane: paneID) == .ready else {
            return nil
        }
        return (attempt, paneID)
    }

    private var shownAttempt: Attempt? {
        guard let attempt, isCurrent(attempt), attempt.isActivated else { return nil }
        return attempt
    }

    func sendText(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard let target = inputTarget else { return .transportUnavailable }
        return send(
            HerdrInputTranslator.events(forText: text, reportsAllKeys: target.attempt.reportsAllKeys),
            to: target
        )
    }

    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard let target = inputTarget else { return .transportUnavailable }
        return send([.paste(text)], to: target)
    }

    /// A release is accepted without being sent: Herdr's client sends none from a plain terminal.
    func sendKey(_ key: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        guard let target = inputTarget else { return .transportUnavailable }
        guard let event = HerdrInputTranslator.event(for: key) else {
            return key.action == .release ? .accepted : .surfaceRejected
        }
        return send([event], to: target)
    }

    /// Input is accepted once queued behind the session's earlier operations; Herdr doesn't
    /// acknowledge input. Input over Herdr's byte limit isn't sent: Herdr would close the connection,
    /// or refuse a paste.
    private func send(
        _ events: [HerdrInputEvent],
        to target: (attempt: Attempt, paneID: String)
    ) -> FocusedTerminalInputSubmissionResult {
        let messages = HerdrInputTranslator.messages(events)
        do {
            try messages.forEach(HerdrConnection.checkLimits)
        } catch {
            presentInputFailure()
            return .surfaceRejected
        }
        for message in messages {
            target.attempt.ask(.input(paneID: target.paneID, events: message, delivered: nil))
        }
        return .accepted
    }

    /// The composer's message goes to the pane it was written in, focused or not: Herdr takes input for
    /// every pane on the shown tab. Each part returns true once Herdr has it, so the composer's pause
    /// before Enter runs from there; false when it can't go, or the connection ended first.
    func sendPasteAwaitingDelivery(_ text: String, toPane paneID: String) async -> Bool {
        guard !text.isEmpty else { return false }
        return await sendAwaitingDelivery([.paste(text)], toPane: paneID)
    }

    func sendKeyAwaitingDelivery(_ key: GhosttySurfaceKeyEvent, toPane paneID: String) async -> Bool {
        guard let event = HerdrInputTranslator.event(for: key) else { return false }
        return await sendAwaitingDelivery([event], toPane: paneID)
    }

    private func sendAwaitingDelivery(_ events: [HerdrInputEvent], toPane paneID: String) async -> Bool {
        // Herdr drops pane input while a popup is open over the tab, and still answers the ping.
        guard let attempt = shownAttempt, presentation(ofPane: paneID) == .ready, layout?.hasPopup == false,
              (try? HerdrConnection.checkLimits(events)) != nil
        else { return false }
        return await withCheckedContinuation { delivered in
            attempt.ask(.input(paneID: paneID, events: events, delivered: delivered))
        }
    }

    /// Remux's own move to a pane, the one way a tap on a pane, a notification's pane or a list of the
    /// session's places takes the session there, after the operations asked before it. Keys follow the
    /// snapshot that reports the new focus. Returns false when the session can't take input.
    func focusPane(_ paneID: String) -> Bool {
        guard let attempt, isCurrent(attempt), attempt.isActivated else { return false }
        move(attempt, to: paneID)
        return true
    }

    /// Remux's move to `paneID`; the newest wins, and an older one that hasn't gone yet doesn't go. Herdr's
    /// zoom is a flag on a tab, which shows its focused pane, so a move within the tab on screen is a
    /// `pane.focus`, as Herdr's client sends on a click. A move to another tab, or away from the tab a
    /// move is still taking the session to, changes the tab: Remux's zoom comes off the tab left while it
    /// is still on screen, since an unzoom focuses its target; `pane.focus` takes this client to the
    /// pane's tab; and once Herdr has answered it and the tab is on screen, by this move or any other
    /// way, the setting zooms the tab as a show does. The engine holds the frames meanwhile, so only the
    /// tab reached shows, as it ends up. A tab another client moves the session to stays as it is:
    /// unzooming a tab off screen would focus it and take the session back.
    private func move(_ attempt: Attempt, to paneID: String) {
        let tab = tab(ofPane: paneID)
        let pending = attempt.move
        if pending == nil, paneID == focusedPaneID { return }
        var hold: UInt64?
        if let tab, tab != onScreenTab || (pending != nil && tab != pending?.tab) {
            // A move right behind a show in progress completes that show.
            if let show = attempt.showRequest, attempt.activatedRequest != show {
                hold = show
            } else {
                attempt.viewRequests += 1
                hold = attempt.viewRequests
            }
        }
        attempt.moves += 1
        attempt.move = Move(number: attempt.moves, paneID: paneID, tab: tab, hold: hold)
        attempt.ask(.move(attempt.moves))
    }

    /// The tab on screen, as the newest snapshot has it.
    private var onScreenTab: HerdrTabKey? {
        guard let snapshot, let tabID = snapshot.focusedTabID else { return nil }
        return HerdrTabKey(bootID: snapshot.bootID, tabID: tabID)
    }

    private func tab(ofPane paneID: String) -> HerdrTabKey? {
        guard let snapshot, let tabID = snapshot.panes.first(where: { $0.paneID == paneID })?.tabID else { return nil }
        return HerdrTabKey(bootID: snapshot.bootID, tabID: tabID)
    }

    /// Herdr answered a move's focus. One that failed or didn't go ends its move and lets its frames
    /// show; a move replaced meanwhile leaves them to the one that replaced it.
    private func moveFocused(_ number: UInt64, attempt: Attempt, reply: Result<HerdrCommandReply, Error>) {
        guard isCurrent(attempt) else { return }
        switch reply {
        case .success:
            notices.succeeded(Self.paneFocusMethod, bootID: layout?.bootID)
        case .failure(let error):
            presentFailure(of: Self.paneFocusMethod, label: Self.focusFailureLabel, error)
        }
        guard var move = attempt.move, move.number == number else { return }
        guard let answer = try? reply.get() else {
            attempt.move = nil
            if let hold = move.hold { settle(Completion(request: hold, fallback: nil), attempt: attempt) }
            return
        }
        move.focused = HerdrTerminalEngine.CommandAnswer(sentAfter: answer.sentAfter, answeredAfter: answer.answeredAfter)
        attempt.move = move
        moveArrived(attempt)
    }

    /// A move is done once Herdr has answered its focus and the snapshot shows its pane's tab. A move to
    /// another tab then ends with the setting's zoom of the tab reached, as a show does; its frames wait
    /// for that zoom's answer, or, without one, for the focus's.
    private func moveArrived(_ attempt: Attempt) {
        guard let move = attempt.move, let focused = move.focused, move.tab == nil || move.tab == onScreenTab
        else { return }
        attempt.move = nil
        guard let hold = move.hold, let tab = move.tab else { return }
        let completion = Completion(request: hold, fallback: focused)
        if let paneID = paneToZoomOnShow {
            attempt.ask(.zoom(paneID, zoomed: true, tab: tab, completing: completion))
        } else {
            settle(completion, attempt: attempt)
        }
    }

    /// The show or move's frames show without waiting for a zoom.
    private func settle(_ completion: Completion, attempt: Attempt) {
        let feed = HerdrEngineFeed(engine: engine, connection: attempt.id)
        Task { await feed.settle(request: completion.request, answer: completion.fallback) }
    }

    private func presentFailure(of method: String, label: String, _ failure: Error) {
        let error = failure as? HerdrCommandError
            ?? .failed(code: "invalid_response", message: failure.localizedDescription)
        if notices.shows(method, failedWith: error, bootID: layout?.bootID) {
            terminalScreenAdapter.presentFailure(label)
        }
    }

    // MARK: - Zoom

    /// The pane sheet's zoom button: Herdr zooms or unzooms the focused pane's tab, after the commands
    /// already asked for. Every `pane.zoom` focuses its target first, so this is the pane the session is
    /// on, or on its way to. A tab the user unzooms isn't zoomed again as the session comes back on
    /// screen, as tmux keeps a user's choice for a window. Returns false when the session can't take it.
    func setFocusedPaneZoomed(_ zoomed: Bool) -> Bool {
        guard let attempt, isCurrent(attempt), attempt.isActivated,
              let paneID = attempt.move?.paneID ?? focusedPaneID,
              let tab = attempt.move?.tab ?? onScreenTab
        else { return false }
        if zoomed {
            tabsUnzoomedByUser.remove(tab)
        } else {
            tabsUnzoomedByUser.insert(tab)
        }
        attempt.ask(.zoom(paneID, zoomed: zoomed, tab: tab, completing: nil))
        return true
    }

    /// The pane sheet is opening. A zoomed tab's map places the panes its frame doesn't draw from the
    /// newest full layout Herdr reported, and a tab zoomed before Remux saw it, as by another client
    /// while the setting is off, has none. Herdr's endpoint has no layout query, so Remux asks for the
    /// zoom the tab already has: Herdr changes nothing and answers with the tab's full layout, which
    /// fills the map as any zoom's answer does. It asks once for each set of missing panes, and only
    /// when no command is in flight, since Herdr refuses one then.
    func fillTabMapIfNeeded() {
        guard let attempt, isCurrent(attempt), let connection = attempt.connection, attempt.isActivated,
              let layout, let tab = layout.tab, tab.zoomed, let snapshot, snapshot.bootID == layout.bootID,
              snapshot.focusedTabID == tab.tabID, let paneID = snapshot.focusedPaneID
        else { return }
        let gap = HerdrTabMapGap(
            tab: HerdrTabKey(bootID: layout.bootID, tabID: tab.tabID),
            paneIDs: Set(layout.panes.lazy.map(\.paneID).filter { self.mapRect(ofPane: $0) == nil })
        )
        guard !gap.paneIDs.isEmpty, gap != askedTabMapGap else { return }
        askedTabMapGap = gap
        Task { [weak self] in
            let sent = await connection.sendCommandIfIdle(
                Self.paneZoomMethod,
                params: Self.zoomParams(paneID, zoomed: true)
            ) { [weak self] reply in
                Task { @MainActor [weak self] in
                    self?.zoomAnswered(reply.map(\.json), bootID: gap.tab.bootID, reportingFailure: false)
                }
            }
            // Held back by a command in flight, the gap is asked for at the next opening.
            if !sent, self?.askedTabMapGap == gap { self?.askedTabMapGap = nil }
        }
    }

    /// A `pane.zoom` of `paneID`'s tab, after the commands asked before it; one asked for before that
    /// hasn't gone yet doesn't go. It goes while `tab` is on screen, so Herdr takes it from a client on
    /// screen: at once, or, as after a quick return while the leave's unzoom is still unanswered, once the
    /// command in flight is answered, unless the session has left or another client has taken it to
    /// another tab meanwhile. The show or move it is `completing` completes once Herdr has answered it, on
    /// a frame from after it; a zoom that fails, doesn't go or changes nothing leaves that to the fallback.
    private func sendZoom(
        _ paneID: String,
        zoomed: Bool,
        tab: HerdrTabKey,
        completing: Completion?,
        on connection: HerdrConnection,
        feed: HerdrEngineFeed
    ) async {
        await connection.dropWaitingCommands(Self.paneZoomMethod)
        await connection.sendCommandWhileShown(
            Self.paneZoomMethod,
            params: Self.zoomParams(paneID, zoomed: zoomed),
            onTab: tab.tabID
        ) { [weak self] reply in
            if let completing {
                Task { await feed.settle(request: completing.request, answer: Self.zoomAnswer(reply) ?? completing.fallback) }
            }
            Task { @MainActor [weak self] in
                self?.zoomAnswered(reply.map(\.json), bootID: tab.bootID, reportingFailure: completing == nil)
            }
        }
    }

    /// What a show or move needs of Herdr's answer to its zoom: the tab, and where the zoom fell among the
    /// snapshots; nil when the zoom failed or changed nothing, as on a tab zoomed already.
    private nonisolated static func zoomAnswer(
        _ reply: Result<HerdrCommandReply, Error>
    ) -> HerdrTerminalEngine.CommandAnswer? {
        guard let reply = try? reply.get(), let result = try? HerdrPaneZoomResult(reply: reply.json),
              result.zoomChanged
        else { return nil }
        return HerdrTerminalEngine.CommandAnswer(
            sentAfter: reply.sentAfter,
            answeredAfter: reply.answeredAfter,
            zoom: (result.layout.tabID, result.zoomed)
        )
    }

    /// The setting zooms the tab on screen as the session is shown: the focused pane, when the tab has
    /// more than one pane and the user hasn't unzoomed it. It is asked even when the tab is zoomed
    /// already: Herdr's answer says whether Remux changed anything, and where the tab's panes sit for the
    /// pane sheet's map.
    private var paneToZoomOnShow: String? {
        guard currentTerminalSettings.zoomMultipaneWindowsByDefault, let snapshot,
              let tabID = snapshot.focusedTabID, let paneID = snapshot.focusedPaneID,
              snapshot.panes.count(where: { $0.tabID == tabID }) > 1,
              !tabsUnzoomedByUser.contains(HerdrTabKey(bootID: snapshot.bootID, tabID: tabID))
        else { return nil }
        return paneID
    }

    /// The pane to unzoom the zoom Remux made with as the session leaves the screen, if it made one on
    /// the tab on screen.
    private var paneToUnzoom: String? {
        snapshot.flatMap(ownedZoom.paneToUnzoom(in:))
    }

    /// Remux's zoom comes off the tab on screen as the session leaves it, first, while Herdr still takes
    /// commands from this client. It goes only if no command is in flight: one that waited for the lane
    /// would hold the leave back, so the zoom then stays, as when the app can't clean up at all.
    private func undoZoomOnScreen(on connection: HerdrConnection) async {
        guard let paneID = paneToUnzoom, let bootID = snapshot?.bootID else { return }
        _ = await connection.sendCommandIfIdle(
            Self.paneZoomMethod,
            params: Self.zoomParams(paneID, zoomed: false)
        ) { [weak self] reply in
            Task { @MainActor [weak self] in
                self?.zoomAnswered(reply.map(\.json), bootID: bootID, reportingFailure: false)
            }
        }
    }

    /// Herdr's answer records or forgets the zoom Remux made, and gives the tab's map; an answer that
    /// comes after the stop changes nothing.
    private func zoomAnswered(_ answer: Result<Data, Error>, bootID: String, reportingFailure: Bool) {
        guard !stopped else { return }
        let result: HerdrPaneZoomResult
        do {
            result = try HerdrPaneZoomResult(reply: try answer.get())
        } catch {
            if reportingFailure { presentFailure(of: Self.paneZoomMethod, label: Self.zoomFailureLabel, error) }
            return
        }
        if reportingFailure { notices.succeeded(Self.paneZoomMethod, bootID: bootID) }
        ownedZoom.record(result, bootID: bootID)
        tabMap = HerdrTabMap(
            bootID: bootID,
            tabID: result.layout.tabID,
            rects: Dictionary(result.layout.panes.map { ($0.paneID, $0.rect) }) { first, _ in first }
        )
        didChange()
    }

    /// Where `paneID` sits in the tab on screen, for the pane sheet's map: from the newest full layout of
    /// the tab Herdr reported.
    func mapRect(ofPane paneID: String) -> HerdrSurfaceRect? {
        guard let layout, let tab = layout.tab, let tabMap, tabMap.bootID == layout.bootID, tabMap.tabID == tab.tabID
        else { return nil }
        return tabMap.rects[paneID]
    }

    static func zoomParams(_ paneID: String, zoomed: Bool) -> [String: String] {
        ["pane_id": paneID, "mode": zoomed ? "on" : "off"]
    }

    // MARK: - Scrolling

    /// History lines per wheel step, as Herdr's client sends by default. A program that reads the mouse,
    /// or takes the wheel as arrow keys, gets one report or key per step instead.
    static let wheelLines: UInt16 = 3

    /// Where a scroll gesture over the pane is; its wheel steps are reported at that cell, as Herdr's
    /// client reports the pointer's.
    func setScrollPointer(_ point: CGPoint, inPane paneID: String) {
        scrollPointers[paneID] = point
    }

    /// A scroll gesture's travel over a pane becomes Herdr wheel steps the way Ghostty turns travel into
    /// lines for tmux: one step per cell height, the rest kept for the next. Herdr decides what a step
    /// does: it scrolls the pane's history, or goes to the program as a wheel report or an arrow key. As
    /// in Herdr's client, scrolling another pane focuses it.
    func scroll(_ event: GhosttySurfaceMouseScrollEvent, inPane paneID: String) -> Bool {
        let momentum = event.mods.momentum
        // A cancelled gesture, as when the program's mouse mode changes, sends none of its travel.
        guard momentum != .cancelled else {
            wheelRemainders[paneID] = nil
            return true
        }
        if momentum == .began { wheelRemainders[paneID] = 0 }
        defer {
            if momentum == .ended { wheelRemainders[paneID] = nil }
        }
        guard let attempt = shownAttempt, let measurement, presentation(ofPane: paneID) == .ready,
              let area = layout?.panes.first(where: { $0.paneID == paneID })?.innerRect
        else { return false }
        if momentum == .began, paneID != focusedPaneID { _ = focusPane(paneID) }

        let cellHeight = Double(measurement.cellMetrics.pixelHeight)
        let travel = (wheelRemainders[paneID] ?? 0) + event.deltaY
        let steps = (travel / cellHeight).rounded(.towardZero)
        wheelRemainders[paneID] = travel - steps * cellHeight
        guard steps != 0 else { return true }

        let scale = measurement.cellMetrics.contentScale
        let point = scrollPointers[paneID] ?? .zero
        func cell(_ points: CGFloat, size: UInt32, count: UInt16) -> UInt16 {
            let index = Int((Double(points) * scale / Double(max(size, 1))).rounded(.down))
            return UInt16(min(max(index, 0), Int(max(count, 1)) - 1))
        }
        let wheel = HerdrMouseEvent(
            kind: steps > 0 ? .scrollUp : .scrollDown,
            column: cell(point.x, size: measurement.cellMetrics.pixelWidth, count: area.width),
            row: cell(point.y, size: measurement.cellMetrics.pixelHeight, count: area.height),
            lines: Self.wheelLines
        )
        let events = Array(repeating: HerdrInputEvent.mouse(wheel), count: Int(steps.magnitude))
        return send(events, to: (attempt, paneID)) == .accepted
    }

    private func applyScroll(toPane paneID: String) {
        guard let scroll = paneScrolls[paneID],
              let managed = surfaces[paneID]?.renderer.managedSurface
        else { return }
        managed.setRemoteScroll(scroll.scrollState, route: scroll.route)
    }

    private func inputFailed(_ attemptID: UInt64) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        presentInputFailure()
    }

    /// A failure Remux finds itself, which Herdr's rules don't hold back. It replaces any notice on
    /// screen, as Herdr's client keeps one.
    private func presentInputFailure() {
        notices.replaced()
        terminalScreenAdapter.presentFailure(Self.inputFailureLabel)
    }

    /// Herdr refused input, with its reason; the same refusal isn't repeated while it is on screen.
    private func inputRefused(_ attemptID: UInt64, message: String) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt),
              notices.showsRefusedInput(message, bootID: layout?.bootID)
        else { return }
        terminalScreenAdapter.presentFailure(Self.inputFailureLabel)
    }

    private func keyboardReportAllChanged(_ attemptID: UInt64, _ enabled: Bool) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        attempt.reportsAllKeys = enabled
    }

    // MARK: - Connection

    /// Gives up the current attempt, if any, and starts a new one: the session's first connection, a
    /// reconnect the user asks for, and a reconnect by itself, when its delay is up or the app comes back.
    /// The panes keep their terminals, so the last frame stays on screen until the new connection's
    /// first; pane failures say to reconnect, so the failed panes are tried again. A recheck keeps saying
    /// what needs attention until it connects.
    private func restart() {
        cancelRecovery()
        if let attempt { giveUp(attempt) }
        attemptCount += 1
        let attempt = Attempt(id: attemptCount)
        self.attempt = attempt
        readySince = nil
        attempt.task = Task { [weak self] in await self?.run(attempt) }
        retryFailedPanes()
        reconcilePresentationActivity()
        didChange()
    }

    /// Once the connection is open, the attempt's operations are carried out in order.
    private func run(_ attempt: Attempt) async {
        let feed = HerdrEngineFeed(engine: engine, connection: attempt.id)
        guard let size = await connectionAndScreenSize(for: attempt, feed: feed),
              let connection = attempt.connection
        else { return }
        // Frames can arrive before `open` returns; the engine paints them at the hello's cell size.
        await engine.setCellSize(widthPx: size.cellWidthPx, heightPx: size.cellHeightPx)
        await engine.beginConnection(attempt.id)
        do {
            try await connection.open(
                hello: HerdrHello(
                    cellWidthPx: size.cellWidthPx,
                    cellHeightPx: size.cellHeightPx,
                    cols: size.cols,
                    rows: size.rows,
                    surfaceActive: false
                ),
                appActive: appPhase != .background
            )
        } catch {
            if isCurrent(attempt) {
                end(attempt, disconnectReason(connectionFailedWith: error), recovery: Self.recovery(connectionFailedWith: error, opened: false))
            }
            return
        }
        guard isCurrent(attempt) else { return }
        attempt.isOpen = true
        if let themeReport { attempt.ask(.theme(themeReport)) }
        reconcileVisibility()
        reconcilePresentationActivity()
        didChange()
        while let operation = await attempt.nextOperation() {
            guard isCurrent(attempt) else {
                operation.abandon()
                break
            }
            await perform(operation, on: connection, feed: feed, attempt: attempt)
        }
    }

    /// The attempt's connection, in `attempt.connection`, and the screen's size for its hello, or nil when
    /// the attempt is over. The bridge opens at once, so its setup overlaps the screen's first layout, and
    /// goes straight to the connection, which the attempt's give-up closes. A connection still waiting for
    /// a size at the hello deadline is closed, and another opens once the size is known.
    private func connectionAndScreenSize(for attempt: Attempt, feed: HerdrEngineFeed) async -> HerdrSurfaceGeometry? {
        while true {
            // Herdr's clock starts when the bridge reaches its socket, which can be before the opening
            // returns.
            let deadline = ContinuousClock.now + Self.helloDeadline
            let transport: any HerdrBridgeTransport
            do {
                transport = try await openBridge()
            } catch {
                // A cancelled opening releases what it claimed.
                if isCurrent(attempt) {
                    let reason = disconnectReason(openingBridgeFailedWith: error)
                    end(attempt, reason, recovery: Self.recovery(openingBridgeFailedWith: error, reason: reason))
                }
                return nil
            }
            // A bridge that opens after the attempt was given up closes the way the give-up decided.
            if let cause = attempt.closeCause {
                await transport.close(cause)
                return nil
            }
            let connection = HerdrConnection(
                transport: transport,
                timing: connectionTiming,
                onEvent: Self.eventHandler(feed: feed, attemptID: attempt.id, model: self)
            )
            attempt.connection = connection
            if let size = await screenSize(for: attempt, until: deadline) { return size }
            guard isCurrent(attempt) else { return nil }
            await connection.close(.finished)
            attempt.connection = nil
            guard await screenSize(for: attempt, until: nil) != nil else { return nil }
        }
    }

    /// Each operation returns once its messages are queued on the connection; Herdr's answer to a show
    /// comes back separately, and the engine says when a frame completing it is painted.
    private func perform(
        _ operation: Operation,
        on connection: HerdrConnection,
        feed: HerdrEngineFeed,
        attempt: Attempt
    ) async {
        let attemptID = attempt.id
        switch operation {
        case .show(let geometry, let request, let zoom, let holdsForMove):
            await feed.beginActivation(
                request: request,
                columns: geometry.cols,
                rows: geometry.rows,
                zoomed: zoom != nil || holdsForMove
            )
            await connection.sendShow(geometry) { [weak self] result in
                switch result {
                case .success(let floor):
                    Task { await feed.acknowledgeActivation(request: request, floor: floor) }
                case .failure(let error):
                    Task { @MainActor [weak self] in self?.showFailed(attemptID, request: request, error: error) }
                }
            }
            if let zoom {
                let completion = Completion(request: request, fallback: nil)
                await sendZoom(zoom.pane, zoomed: true, tab: zoom.tab, completing: completion, on: connection, feed: feed)
            }
        case .hide:
            // The session is off screen and takes no input either way. Frames from here on show what
            // leaving does, so the engine holds them before anything goes out.
            await feed.endActivation()
            await undoZoomOnScreen(on: connection)
            // A hide Herdr doesn't confirm leaves only its stale foreground on the server.
            await connection.sendHide()
        case .resize(let geometry):
            await feed.resizeActivation(columns: geometry.cols, rows: geometry.rows)
            await connection.resize(geometry)
            await engine.setCellSize(widthPx: geometry.cellWidthPx, heightPx: geometry.cellHeightPx)
        case .theme(let updates):
            for update in updates {
                await connection.reportHostTheme(update)
            }
        case .appActive(let active):
            await connection.setAppActive(active)
        case .input(let paneID, let events, let delivered):
            do {
                try await connection.send(events, toPane: paneID)
            } catch {
                if let delivered {
                    // The composer says what didn't go.
                    delivered.resume(returning: false)
                } else if (error as? HerdrInputError) != .connectionEnded {
                    // The connection's end is reported when the reader sees it.
                    inputFailed(attemptID)
                }
                return
            }
            guard let delivered else { return }
            // Herdr acknowledges no input, but answers a ping only after reading everything sent before
            // it. Later operations don't wait for the answer.
            Task { delivered.resume(returning: await connection.confirmAlive()) }
        case .move(let number):
            // A newer move replaced it before it went.
            guard let move = attempt.move, move.number == number else { return }
            // An older move's focus that hasn't gone doesn't go; for a move to another tab, nor does a
            // zoom for the tab left.
            await connection.dropWaitingCommands(Self.paneFocusMethod)
            if let hold = move.hold {
                await feed.holdForMove(request: hold)
                await connection.dropWaitingCommands(Self.paneZoomMethod)
                if move.tab != onScreenTab { await undoZoomOnScreen(on: connection) }
            }
            await connection.sendCommandWhileShown(Self.paneFocusMethod, params: ["pane_id": move.paneID]) {
                [weak self] reply in
                Task { @MainActor [weak self] in self?.moveFocused(number, attempt: attempt, reply: reply) }
            }
        case .zoom(let paneID, let zoomed, let tab, let completing):
            await sendZoom(paneID, zoomed: zoomed, tab: tab, completing: completing, on: connection, feed: feed)
        }
    }

    /// Frames and snapshots go to the engine from the connection's reader; only what the model acts on
    /// comes to the main actor, and nothing here waits for a reply from the connection.
    private static func eventHandler(
        feed: HerdrEngineFeed,
        attemptID: UInt64,
        model: HerdrScreenModel
    ) -> @Sendable (HerdrConnectionEvent) async -> Void {
        { [weak model] event in
            guard let model else { return }
            switch event {
            case .snapshot(let snapshot, let completions):
                await feed.receive(snapshot)
                Task { @MainActor in model.snapshotArrived(attemptID, snapshot, completions: completions) }
            case .surface(let output):
                await feed.receive(output)
            case .ended(let error):
                await model.connectionEnded(attemptID, error)
            case .inputRefused(let message):
                Task { @MainActor in model.inputRefused(attemptID, message: message) }
            case .keyboardReportAll(let enabled):
                Task { @MainActor in model.keyboardReportAllChanged(attemptID, enabled) }
            case .notification(let notification):
                Task { @MainActor in model.notificationArrived(attemptID, notification) }
            case .bell:
                Task { @MainActor in model.bellRang(attemptID) }
            case .clipboard:
                break
            }
        }
    }

    /// Whether `attempt` is the model's and still under way: an ended one's late events and a bridge
    /// that opens after it ended are dropped.
    private func isCurrent(_ attempt: Attempt) -> Bool {
        !stopped && self.attempt === attempt && !attempt.ended
    }

    private var geometry: HerdrSurfaceGeometry? {
        guard let measurement else { return nil }
        return HerdrSurfaceGeometry(
            cellWidthPx: measurement.cellMetrics.pixelWidth,
            cellHeightPx: measurement.cellMetrics.pixelHeight,
            cols: measurement.controlViewport.columns,
            rows: measurement.controlViewport.rows
        )
    }

    /// The screen's size once it has one, or nil when the attempt is over or `deadline` passed before
    /// the screen first had a size. A size known only after the deadline is too late even if it's known
    /// before the bridge's opening returns: Herdr's clock may already have run out.
    private func screenSize(
        for attempt: Attempt,
        until deadline: ContinuousClock.Instant?
    ) async -> HerdrSurfaceGeometry? {
        let timer = deadline.map { deadline in
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                // A wait that ended first cancelled its timer, which then wakes no later wait.
                guard !Task.isCancelled else { return }
                self?.resumeSizeWaiter()
            }
        }
        defer { timer?.cancel() }
        while isCurrent(attempt) {
            if let geometry, let sizeKnownSince, deadline.map({ sizeKnownSince <= $0 }) ?? true {
                return geometry
            }
            if let deadline, ContinuousClock.now >= deadline { return nil }
            await withCheckedContinuation { sizeWaiter = $0 }
        }
        return nil
    }

    private func resumeSizeWaiter() {
        sizeWaiter?.resume()
        sizeWaiter = nil
    }

    private func snapshotArrived(_ attemptID: UInt64, _ snapshot: HerdrSnapshot, completions: [String: UInt64]?) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        if appPhase != .background, readySince == nil { readySince = .now }
        if let previous = self.snapshot?.bootID, previous != snapshot.bootID {
            onNotification(.serverRestarted)
        }
        self.snapshot = snapshot
        ownedZoom.reconcile(with: snapshot)
        moveArrived(attempt)
        agents.project(snapshot, completions: completions)
        acknowledgeShownAgents()
        if snapshot.focusedPaneID != focusedPaneID {
            focusedPaneID = snapshot.focusedPaneID
            reconcilePresentationActivity()
            didChange()
        }
        guard !attempt.hasSnapshot else { return }
        attempt.hasSnapshot = true
        hasConnected = true
        failure = nil
        reconcileVisibility()
        didChange()
    }

    /// Herdr sends its notifications to every connection, shown or hidden; the owner decides what
    /// reaches the screen. The boot is known once this connection's first snapshot is in.
    private func notificationArrived(_ attemptID: UInt64, _ notification: HerdrSemanticNotification) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        let snapshot = attempt.hasSnapshot ? self.snapshot : nil
        onNotification(.received(
            notification,
            bootID: snapshot?.bootID,
            place: HerdrNotificationPlace(notification, in: snapshot)
        ))
    }

    /// Herdr rings only the session in front, which the connection checks; a bell that comes after the
    /// session left the screen has no one to ring for.
    private func bellRang(_ attemptID: UInt64) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt), isSelected else { return }
        onNotification(.bell)
    }

    /// The panes on screen show their agents as they are now, as Herdr's client counts a pane it
    /// presents while its terminal has focus as seen (`endpoint_agent_state.rs` `acknowledge_surface`):
    /// only a frame drawn against the newest snapshot shows its agents, so an older frame still on screen
    /// acknowledges nothing.
    private func acknowledgeShownAgents() {
        guard appPhase == .active, let attempt = shownAttempt, let frame = presentedFrame,
              frame.connection == attempt.id, let snapshot,
              frame.bootID == snapshot.bootID, frame.projectionRevision == snapshot.revision
        else { return }
        agents.acknowledge(panes: frame.paneIDs)
    }

    private func connectionEnded(_ attemptID: UInt64, _ error: HerdrConnectionError) {
        guard let attempt, attempt.id == attemptID else { return }
        end(attempt, error.terminalDisconnectReason(on: target.server), recovery: Self.recovery(connectionFailedWith: error, opened: true))
    }

    /// Ends the attempt and reports why. A connection Remux closes sends no `ended` event, so whoever
    /// finds the reason reports it here. `unresponsive` when Herdr didn't answer in time.
    private func end(
        _ attempt: Attempt,
        _ reason: TerminalDisconnectReason,
        recovery: Recovery,
        unresponsive: Bool = false
    ) {
        guard isCurrent(attempt) else { return }
        giveUp(attempt, unresponsive: unresponsive)
        let stayedUp = readySince.map { ContinuousClock.now - $0 >= recoveryTiming.stable } ?? false
        readySince = nil
        // A session that never opened says why instead of retrying.
        switch hasConnected ? recovery : .none {
        case .retry:
            failure = nil
            isReconnecting = true
            // A connection that stayed up starts the delays over, as in Herdr's client.
            if stayedUp { failuresInARow = 0 }
            failuresInARow += 1
            scheduleRecovery(after: retryDelay())
        case .recheck:
            failure = reason
            isReconnecting = false
            scheduleRecovery(after: recoveryTiming.recheck)
        case .none:
            failure = reason
            isReconnecting = false
            cancelRecovery()
        }
        reconcilePresentationActivity()
        didChange()
    }

    /// 0.5 s after the first failure, doubling with each one in a row up to 2 min, and at most the wake
    /// delay for a while after the app comes back.
    private func retryDelay() -> Duration {
        var delay = recoveryTiming.firstRetry
        for _ in 1..<max(failuresInARow, 1) {
            delay = min(delay * 2, recoveryTiming.longestRetry)
        }
        if let wokeAt, ContinuousClock.now < wokeAt + recoveryTiming.wakeWindow {
            delay = min(delay, recoveryTiming.wakeRetry)
        }
        return delay
    }

    private func scheduleRecovery(after delay: Duration) {
        recoveryDue = .now + delay
        startRecoveryTimer()
    }

    /// The background stops the timer; the due time stays for the return.
    private func startRecoveryTimer() {
        recoveryTimer?.cancel()
        guard appPhase != .background, let due = recoveryDue else { return }
        recoveryTimer = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.restart()
        }
    }

    private func cancelRecovery() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        recoveryDue = nil
    }

    /// Gives the attempt up, once, whatever ends it: a failure, a replacement, the background or a stop.
    /// Its operations end, its opening stops, the engine drops what its connection still sends, and the
    /// connection closes, telling the bridge whether Herdr went silent or the attempt was still opening.
    /// A bridge that opens afterwards closes the same way.
    private func giveUp(_ attempt: Attempt, unresponsive: Bool = false) {
        guard !attempt.ended else { return }
        let cause: HerdrBridgeCloseCause = unresponsive ? .unresponsive
            : attempt.isOpen ? .finished : .givenUpWhileOpening
        attempt.closeCause = cause
        attempt.finishOperations()
        attempt.task?.cancel()
        attempt.activationDeadline?.cancel()
        if attempt === self.attempt { resumeSizeWaiter() }
        Task { [engine, id = attempt.id] in await engine.endConnection(id) }
        if let connection = attempt.connection {
            attempt.closing = Task { await connection.close(cause) }
        }
    }

    /// Shows the session while the root wants it on screen and hides it otherwise. Herdr takes the
    /// newest of a show and a hide, so each change is sent at once, even while the last is unanswered.
    private func reconcileVisibility() {
        guard let attempt, isCurrent(attempt), attempt.isOpen, attempt.hasSnapshot, let geometry
        else { return }
        let wanted = isSelected && appPhase != .background
        guard wanted != attempt.requestedShown else { return }
        attempt.viewRequests += 1
        attempt.showRequest = wanted ? attempt.viewRequests : nil
        attempt.move = nil
        attempt.activationDeadline?.cancel()
        attempt.activationDeadline = nil
        if wanted {
            awaitActivation(of: attempt, request: attempt.viewRequests)
            // A move to another tab right behind the show takes the setting's zoom to the tab it reaches,
            // and the show completes on that tab.
            let reveal = takePendingReveal()
            let movesAway = reveal.flatMap(tab(ofPane:)).map { $0 != onScreenTab } ?? false
            attempt.ask(.show(
                geometry,
                request: attempt.viewRequests,
                zoom: movesAway ? nil : paneToZoomOnShow.flatMap { pane in onScreenTab.map { (pane, $0) } },
                holdsForMove: movesAway
            ))
            if let reveal { move(attempt, to: reveal) }
        } else {
            attempt.ask(.hide)
        }
        // Input is offered only once a show completes, and closes as soon as a hide is asked.
        didChange()
    }

    /// Herdr's answer and a frame sent after it must both be in within the show's time, as in Herdr's
    /// client (`activation.rs`); a show that doesn't complete is rolled back like one Herdr refused.
    private func awaitActivation(of attempt: Attempt, request: UInt64) {
        let attemptID = attempt.id
        attempt.activationDeadline = Task { [weak self, deadline = connectionTiming.activation] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.activationTimedOut(attemptID, request: request)
        }
    }

    private func activated(_ request: UInt64, connection: UInt64) {
        guard let attempt, isCurrent(attempt), attempt.id == connection, request == attempt.showRequest
        else { return }
        attempt.activatedRequest = request
        attempt.activationDeadline?.cancel()
        attempt.activationDeadline = nil
        acknowledgeShownAgents()
        didChange()
    }

    private func activationTimedOut(_ attemptID: UInt64, request: UInt64) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt),
              request == attempt.showRequest, attempt.activatedRequest != request
        else { return }
        attempt.showRequest = nil
        end(attempt, Self.activationTimeout, recovery: .retry, unresponsive: true)
    }

    /// Herdr's client rolls a refused show back and stays on what it showed before; a Remux session
    /// screen has nothing else to show, so the connection ends, which takes the session off Herdr's
    /// screen, and the session reconnects. A show Herdr doesn't answer runs out of its time instead.
    private func showFailed(_ attemptID: UInt64, request: UInt64, error: Error) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt),
              request == attempt.showRequest
        else { return }
        if case .connectionEnded? = error as? HerdrCommandError { return }
        attempt.showRequest = nil
        end(attempt, TerminalDisconnectReason(kind: .runtime, message: error.localizedDescription), recovery: .retry)
    }

    /// Herdr stores a client's theme and uses it whenever that client is in front, so one full report
    /// before the first show, and one after each theme change, keeps the server on the phone's theme.
    /// Being full, each report also replaces an appearance Herdr would otherwise keep over the next
    /// background. Without a report Herdr uses another client's colours; nothing else is lost.
    private var themeReport: [HerdrHostThemeUpdate]? {
        guard let terminalColors else { return nil }
        return Self.hostTheme(terminalColors, appearance: currentTerminalSettings.theme.isLight ? .light : .dark)
    }

    /// As Herdr's client reports its terminal: the appearance, then the colours.
    static func hostTheme(
        _ colors: GhosttyTerminalColors,
        appearance: HerdrHostThemeUpdate.Appearance
    ) -> [HerdrHostThemeUpdate] {
        func rgb(_ color: GhosttyTerminalColors.Color) -> HerdrRGB {
            HerdrRGB(red: color.red, green: color.green, blue: color.blue)
        }
        var palette: [UInt8: HerdrRGB] = [:]
        for (index, color) in colors.palette.prefix(256).enumerated() {
            palette[UInt8(index)] = rgb(color)
        }
        return [
            .appearance(appearance),
            .defaultColor(.foreground, rgb(colors.foreground)),
            .defaultColor(.background, rgb(colors.background)),
            .paletteColors(palette),
        ]
    }

    // MARK: - Panes

    private func handle(_ update: HerdrEngineUpdate) {
        guard !stopped else { return }
        switch update {
        case .paneTerminal(let paneID, let terminal):
            terminals[paneID] = terminal
            presentationFailures.removeValue(forKey: paneID)
            if let surface = surfaces[paneID], surface.terminal !== terminal {
                closeSurface(paneID)
            }
            createRendererIfPossible(paneID)
        case .layout(let layout):
            self.layout = layout
            if let tab = layout.tab, !tab.zoomed {
                let drawn = layout.panes.compactMap { pane in pane.hasTextArea ? pane.innerRect.map { (pane.paneID, $0) } : nil }
                tabMap = HerdrTabMap(
                    bootID: layout.bootID,
                    tabID: tab.tabID,
                    rects: Dictionary(drawn) { first, _ in first }
                )
            }
            let shown = Set(layout.panes.lazy.filter(\.hasTextArea).map(\.paneID))
            terminals = terminals.filter { shown.contains($0.key) }
            presentationFailures = presentationFailures.filter { shown.contains($0.key) }
            scrollPointers = scrollPointers.filter { shown.contains($0.key) }
            wheelRemainders = wheelRemainders.filter { shown.contains($0.key) }
            for paneID in Array(surfaces.keys) where !shown.contains(paneID) {
                closeSurface(paneID)
            }
            for paneID in shown {
                if let surface = surfaces[paneID], let metrics = displayMetrics(for: paneID) {
                    _ = surface.renderer.updateDisplay(metrics: metrics)
                } else {
                    createRendererIfPossible(paneID)
                }
            }
            reconcilePresentationActivity()
        case .presented(let bootID, let projectionRevision, let paneIDs, let connection):
            presentedFrame = (connection, bootID, projectionRevision, paneIDs)
            acknowledgeShownAgents()
            // Only what counts as seen follows it; the screen has nothing new to show.
            return
        case .paneScroll(let scrolls):
            paneScrolls = scrolls
            for paneID in surfaces.keys {
                applyScroll(toPane: paneID)
            }
            // Only the panes' scroll views follow it; the screen has nothing new to show.
            return
        case .paneTerminalFailed(let paneID):
            presentationFailures[paneID] = Self.paneFailure
            surfaces[paneID]?.renderer.failPresentation(message: Self.paneFailure.message)
        case .rendererWakeFailed(let paneID):
            surfaces[paneID]?.renderer.failPresentation(message: Self.rendererFailureMessage)
        case .failed(let error, let connection):
            if let attempt, attempt.id == connection {
                end(attempt, error.terminalDisconnectReason(on: target.server), recovery: Self.recovery(connectionFailedWith: error, opened: true))
            }
        case .activated(let request, let connection):
            activated(request, connection: connection)
        }
        didChange()
    }

    private func displayMetrics(for paneID: String) -> GhosttySurfaceDisplayMetrics? {
        guard let measurement,
              let area = layout?.panes.first(where: { $0.paneID == paneID })?.innerRect
        else { return nil }
        return measurement.displayMetrics(columns: UInt32(area.width), rows: UInt32(area.height))
    }

    private func retryFailedPanes() {
        presentationFailures.removeAll()
        for paneID in Array(terminals.keys) {
            createRendererIfPossible(paneID)
        }
        for (paneID, surface) in surfaces {
            guard case .failed = surface.renderer.presentation else { continue }
            surfaces.removeValue(forKey: paneID)
            let terminal = ObjectIdentifier(surface.terminal)
            closingTerminals.insert(terminal)
            close(surface.renderer) { [weak self] in
                guard let self else { return }
                closingTerminals.remove(terminal)
                createRendererIfPossible(paneID)
                didChange()
            }
        }
        didChange()
    }

    private func createRendererIfPossible(_ paneID: String) {
        guard !stopped, let runtime,
              let terminal = terminals[paneID],
              surfaces[paneID]?.terminal !== terminal,
              !closingTerminals.contains(ObjectIdentifier(terminal)),
              presentationFailures[paneID] == nil,
              let metrics = displayMetrics(for: paneID),
              creatingTerminals.insert(ObjectIdentifier(terminal)).inserted
        else { return }
        TerminalPaneRenderer.create(
            app: runtime.appHandle,
            terminal: terminal,
            fence: makeRendererFence(engine, paneID, terminal),
            writeInput: nil,
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: metrics,
            theme: currentTerminalSettings.theme,
            diagnosticName: "herdr pane=\(paneID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(paneID, terminal: terminal) }
        ) { [weak self, runtime] result in
            guard let self else {
                // Nothing waits for this close, so it keeps the Ghostty app alive itself.
                if case .success(let renderer) = result {
                    renderer.close { withExtendedLifetime(runtime) {} }
                }
                return
            }
            self.rendererCreated(result, paneID: paneID, terminal: terminal)
        }
    }

    private func rendererCreated(
        _ result: Result<TerminalPaneRenderer, TerminalPaneRenderer.CreateError>,
        paneID: String,
        terminal: HerdrRetainedTerminal
    ) {
        creatingTerminals.remove(ObjectIdentifier(terminal))
        defer { resumeCreationDrainIfQuiescent() }
        // The engine may have replaced or dropped the terminal while its renderer was being registered.
        let isCurrentTerminal = !stopped && terminals[paneID] === terminal
        switch result {
        case .failure(let error):
            guard isCurrentTerminal else { return }
            presentationFailures[paneID] = TerminalDisconnectReason(
                kind: .runtime,
                message: "Terminal renderer could not be created. Reconnect to try again."
            )
            GhosttyRuntimeTrace.diagnostics(
                "herdrPane.createFailed pane=\(paneID) error=\(String(describing: error))"
            )
        case .success(let renderer):
            guard isCurrentTerminal, let metrics = displayMetrics(for: paneID) else {
                close(renderer)
                return
            }
            let surface = HerdrPaneSurface(paneID: paneID, terminal: terminal, renderer: renderer)
            surfaces[paneID] = surface
            terminalScreenAdapter.makeScreenSurface(for: surface)
            applyScroll(toPane: paneID)
            renderer.onPresentationChange = { [weak self] in self?.didChange() }
            // Settings and the pane's size may have changed while the renderer was being registered.
            if !renderer.applyTerminalConfiguration(theme: currentTerminalSettings.theme)
                || !renderer.updateDisplay(metrics: metrics) {
                renderer.failPresentation(message: Self.configurationFailureMessage)
            }
            reconcilePresentationActivity()
        }
        didChange()
    }

    private func rendererFailed(_ paneID: String, terminal: HerdrRetainedTerminal) {
        guard let surface = surfaces[paneID], surface.terminal === terminal else { return }
        surface.renderer.failPresentation(message: Self.rendererFailureMessage)
        didChange()
    }

    /// Only the selected session's panes are presented. Without an open connection the panes show a
    /// frozen frame, so none is focused: Herdr's client shows no cursor while its session isn't online.
    private func reconcilePresentationActivity() {
        let sceneActive = appPhase == .active
        let live = failure == nil && isConnectionOpen
        for (paneID, surface) in surfaces {
            let inLayout = layout?.panes.contains { $0.paneID == paneID } == true
            surface.renderer.setSceneActive(sceneActive)
            surface.renderer.setPresented(isSelected && inLayout)
            surface.renderer.setFocused(isSelected && live && inLayout && paneID == focusedPaneID)
        }
    }

    private func closeSurface(_ paneID: String) {
        guard let surface = surfaces.removeValue(forKey: paneID) else { return }
        close(surface.renderer)
    }

    /// Every renderer is closed here, so a stop can wait for all of them; `completion` runs once the
    /// renderer's surface is freed.
    private func close(
        _ renderer: TerminalPaneRenderer,
        completion: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        closingRenderers += 1
        renderer.close { [weak self] in
            completion()
            self?.rendererClosed()
        }
    }

    private func rendererClosed() {
        closingRenderers -= 1
        guard closingRenderers == 0, let continuation = closesDrained else { return }
        closesDrained = nil
        continuation.resume()
    }

    private func resumeCreationDrainIfQuiescent() {
        guard creatingTerminals.isEmpty, let continuation = creationsDrained else { return }
        creationsDrained = nil
        continuation.resume()
    }

    // MARK: - Reporting

    private func didChange() {
        guard !stopped else { return }
        // A reconnect reads as one until the session is ready again, shown or not.
        if isConnectionReady { isReconnecting = false }
        terminalScreenAdapter.objectWillChange.send()
        let readiness = terminalScreenAdapter.terminalScreenPresentationProjection.readiness
        var state = TerminalReadinessProjector.runtimeState(readiness)
        // Reconnecting by itself, the session keeps its last frame and says so until it is back.
        if isReconnecting, state == .connecting { state = .reconnecting(.transportLoss) }
        let source: TerminalRuntimeStateUpdateSource = readiness.phase == .running ? .readiness : .runtime
        guard reportTracker.shouldReport(state: state, source: source) else { return }
        onRuntimeStateChange(TerminalRuntimeStateUpdate(
            workspaceID: target.workspace.id,
            instanceID: sessionInstanceID,
            state: state,
            source: source
        ))
    }

    private static let runtimeStartFailure = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal runtime failed to initialize"
    )

    private static let viewportFailure = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal viewport failed to initialize"
    )

    private static let paneFailure = TerminalDisconnectReason(
        kind: .runtime,
        message: "Terminal pane could not be painted. Reconnect to try again."
    )

    private static let activationTimeout = TerminalDisconnectReason(
        kind: .transportIO,
        message: "Herdr didn't show the session in time."
    )

    nonisolated static let paneFocusMethod = "pane.focus"
    nonisolated static let paneZoomMethod = "pane.zoom"
    private static let inputFailureLabel = "input"
    private static let focusFailureLabel = "select pane"
    private static let zoomFailureLabel = "zoom pane"

    private static let rendererFailureMessage = "Terminal renderer is unavailable. Reconnect to try again."
    private static let configurationFailureMessage =
        "Terminal renderer could not apply its current configuration. Reconnect to try again."

    private func disconnectReason(openingBridgeFailedWith error: Error) -> TerminalDisconnectReason {
        (error as? HerdrBridgeError)?.terminalDisconnectReason(on: target.server)
            ?? GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
    }

    private func disconnectReason(connectionFailedWith error: Error) -> TerminalDisconnectReason {
        (error as? HerdrConnectionError)?.terminalDisconnectReason(on: target.server)
            ?? TerminalDisconnectReason(kind: .unknown, message: error.localizedDescription)
    }

    /// As Herdr's client sorts an endpoint's failures (`supervisor.rs`, `remote/saved.rs`): a dropped or
    /// broken connection is retried, a server that can't talk to Remux needs attention. Remux leaves
    /// sign-in, host key and a missing Herdr to the repair panel, whose actions fix them. `opened` says
    /// whether the connection had opened before it failed.
    private static func recovery(connectionFailedWith error: Error, opened: Bool) -> Recovery {
        switch error as? HerdrConnectionError {
        case .closed?, .transport?, .unresponsive?, .handshakeTimedOut?, .serverShutdown?:
            return .retry
        case .wire(.invalidControl(let kind))? where kind.hasPrefix("shell.snapshot."):
            return .recheck
        case .wire(.unnegotiatedSnapshot)?:
            return .recheck
        case .wire?:
            return .retry
        case .outdated?, .rejected?, .incompatible?:
            return .recheck
        case .bridge(let error)?:
            return recovery(bridgeFailedWith: error, opened: opened)
        case nil:
            return .none
        }
    }

    /// A bridge that exits once its connection is open is a drop, as Herdr's client retries any endpoint
    /// that disconnects: Herdr's bridge exits by itself after a minute with nothing to carry, which an app
    /// in the background can't prevent. One that exits while opening says why: Herdr is missing or
    /// couldn't start.
    private static func recovery(bridgeFailedWith error: HerdrBridgeError, opened: Bool) -> Recovery {
        switch error {
        case .remoteExit, .channel:
            .retry
        case .program:
            opened ? .retry : .none
        }
    }

    /// An SSH failure is retried when the server couldn't be reached or the link broke.
    private static func recovery(openingBridgeFailedWith error: Error, reason: TerminalDisconnectReason) -> Recovery {
        if let error = error as? HerdrBridgeError { return recovery(bridgeFailedWith: error, opened: false) }
        switch reason.kind {
        case .serverUnreachable, .transportIO, .unknown:
            return .retry
        default:
            return .none
        }
    }
}

extension HerdrConnectionError {
    /// Why the session on `server` ended, as its screen tells it.
    func terminalDisconnectReason(on server: SavedServer) -> TerminalDisconnectReason {
        let message = errorDescription ?? "The connection to Herdr failed."
        switch self {
        case .bridge(let error):
            return error.terminalDisconnectReason(on: server)
        case .closed, .transport, .unresponsive, .handshakeTimedOut:
            return TerminalDisconnectReason(kind: .transportIO, message: message)
        case .serverShutdown(let reason):
            // Herdr says why: it's shutting down, or a live update is handing over to a new server.
            return TerminalDisconnectReason(
                kind: .remoteExit,
                message: "Herdr stopped on \(server.displayName).",
                detail: reason.flatMap { $0.isEmpty ? nil : $0 }
            )
        case .outdated(let version):
            // As Herdr's own client says: the install may already be new, and only the running server old.
            let running = version.map { "Herdr \($0) is running" } ?? "An older Herdr is running"
            return TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: "\(running) on \(server.displayName). Update Herdr, then restart its server."
            )
        case .rejected(_, let reason):
            return TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: Self.incompatibleMessage(on: server),
                detail: reason.isEmpty ? nil : reason
            )
        case .incompatible:
            return TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: Self.incompatibleMessage(on: server)
            )
        case .wire:
            return TerminalDisconnectReason(kind: .runtime, message: message)
        }
    }
}

extension HerdrConnectionError {
    private static func incompatibleMessage(on server: SavedServer) -> String {
        "Herdr on \(server.displayName) doesn't work with this version of Remux."
    }
}

extension HerdrBridgeError {
    /// The same whether opening the bridge failed or its first read reported the failure: the live bridge
    /// opens before Herdr's executable is looked up.
    func terminalDisconnectReason(on server: SavedServer) -> TerminalDisconnectReason {
        let message = errorDescription ?? "The bridge to Herdr failed."
        switch self {
        case .program(let failure):
            return BackendProblem(failure, path: server.herdrExecutablePath).disconnectReason(for: .herdr)
        case .remoteExit(_, let stderr):
            return TerminalDisconnectReason(
                kind: .remoteExit,
                message: "The server closed the connection before Herdr started.",
                detail: RemoteProgramCommand.startupMessage(in: stderr)
            )
        case .channel:
            return TerminalDisconnectReason(kind: .transportIO, message: message)
        }
    }
}

extension HerdrPaneLayout.Pane {
    /// A pane with no text area, or one the frame doesn't draw, has no terminal.
    var hasTextArea: Bool {
        guard let innerRect else { return false }
        return innerRect.width > 0 && innerRect.height > 0
    }
}

extension HerdrPaneScroll {
    /// Herdr routes a wheel step to a program that reads the mouse first, then to one on the alternate
    /// screen as an arrow key, and otherwise scrolls the pane's history.
    var route: GhosttySurfaceScrollRoute {
        if mouseReporting { return .mouseReport }
        if alternateScreenActive { return .altScreenCursor }
        return .remoteHistory
    }

    /// The server's numbers aren't trusted to fit: a history too long to add the rows to is capped first,
    /// so the total, the position and the rows stay consistent.
    var scrollState: GhosttySurfaceScrollState {
        let history = min(maxLinesFromBottom, UInt64.max - rows)
        let fromBottom = min(linesFromBottom, history)
        return GhosttySurfaceScrollState(
            total: history + rows,
            offset: history - fromBottom,
            len: rows,
            cellOffset: 0
        )
    }
}
