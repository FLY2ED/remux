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

    let target: SessionTarget
    let sessionInstanceID: UUID
    let terminalScreenAdapter = HerdrTerminalScreenAdapter()

    /// What the model asks of the connection and the engine, in the order it asks.
    private enum Operation: Sendable {
        case show(HerdrSurfaceGeometry, request: UInt64)
        case hide
        case resize(HerdrSurfaceGeometry)
        case theme([HerdrHostThemeUpdate])
        case appActive(Bool)
    }

    /// One connection to the server, from opening its bridge to its end. A reconnect replaces it, and
    /// the panes keep their last frame meanwhile.
    ///
    /// Its task opens the connection, then carries out the operations one at a time, in the order they
    /// were asked for. Herdr takes the newest of a show and a hide, so that order is the session's
    /// state. No operation waits for Herdr's answer, so a hide goes out while a show is unanswered.
    @MainActor
    private final class Attempt {
        let id: UInt64
        var task: Task<Void, Never>?
        /// The bridge, while the hello waits for the screen's size.
        var transport: (any HerdrBridgeTransport)?
        var connection: HerdrConnection?
        var feed: HerdrEngineFeed?
        /// Herdr's surface switch names the snapshot's boot, so nothing is shown before one arrives.
        var hasSnapshot = false
        var requestedShown = false
        var visibilityRequests: UInt64 = 0
        var ended = false
        private var operations: [Operation] = []
        private var operationWaiter: CheckedContinuation<Void, Never>?
        private var operationsFinished = false

        init(id: UInt64) {
            self.id = id
        }

        /// Queued while the connection opens, and carried out once it is open. Only the newest size
        /// matters, as Herdr's client sends only the newest it sampled: a new size replaces every one
        /// not yet sent. A show queued before it already carries a newer size than those.
        func ask(_ operation: Operation) {
            guard !ended, !operationsFinished else { return }
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
            operations.removeAll()
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

    private let openBridge: BridgeOpener
    private let connectionTiming: HerdrConnection.Timing
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private let engine: HerdrTerminalEngine
    private var runtime: GhosttyKitRuntime?
    private var currentTerminalSettings: TerminalSettings
    private var reportTracker = TerminalRuntimeStateReportTracker()
    private var stopped = false
    private var failure: TerminalDisconnectReason?
    private var updatesTask: Task<Void, Never>?

    private var attempt: Attempt?
    private var attemptCount: UInt64 = 0
    private var sizeWaiter: CheckedContinuation<Void, Never>?

    private var isSelected = false
    private var appPhase = GhosttyAppLifecyclePhase.active
    private var lastViewport: (size: CGSize, scale: CGFloat)?
    private(set) var measurement: GhosttyTerminalViewportMeasurement?

    private(set) var layout: HerdrPaneLayout?
    private var terminals: [String: HerdrRetainedTerminal] = [:]
    private var surfaces: [String: HerdrPaneSurface] = [:]
    private var presentationFailures: [String: TerminalDisconnectReason] = [:]
    private var creatingTerminals: Set<ObjectIdentifier> = []
    /// Ghostty gives a terminal one renderer at a time, so a replacement waits for these to close.
    private var closingTerminals: Set<ObjectIdentifier> = []
    private var creationsDrained: CheckedContinuation<Void, Never>?

    init(
        target: SessionTarget,
        sessionInstanceID: UUID,
        openBridge: @escaping BridgeOpener,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        connectionTiming: HerdrConnection.Timing = HerdrConnection.Timing(),
        engine: HerdrTerminalEngine = HerdrTerminalEngine(cellWidthPx: 1, cellHeightPx: 1)
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.openBridge = openBridge
        self.onRuntimeStateChange = onRuntimeStateChange
        self.connectionTiming = connectionTiming
        self.engine = engine
        currentTerminalSettings = target.terminalSettings
        terminalScreenAdapter.attach(to: self)
        do {
            runtime = try GhosttyKitRuntime(terminalSettings: target.terminalSettings)
        } catch {
            failure = Self.runtimeStartFailure
            didChange()
            return
        }
        let engine = self.engine
        updatesTask = Task { [weak self] in
            for await update in engine.updates {
                self?.handle(update)
            }
        }
        startAttempt()
    }

    /// True when no connection is open or opening, so the root may replace this model without dropping
    /// a session the user is attached to.
    var isDisconnected: Bool {
        guard let attempt else { return true }
        return attempt.ended
    }

    // MARK: - What the root wants

    /// Whether the root shows this session: the selected session, outside Home. A sheet over the
    /// terminal keeps it shown.
    func setSelected(_ selected: Bool) {
        guard !stopped, selected != isSelected else { return }
        isSelected = selected
        reconcileVisibility()
    }

    /// The background hides the session; the app's other phases leave it on screen.
    func handleAppLifecyclePhase(_ phase: GhosttyAppLifecyclePhase) {
        guard !stopped else { return }
        appPhase = phase
        reconcilePresentationActivity()
        attempt?.ask(.appActive(phase != .background))
        reconcileVisibility()
        didChange()
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
            if let attempt { end(attempt, Self.viewportFailure) }
            return
        }
        guard let measured, measured != measurement else { return }
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
    func reconnect() {
        guard !stopped, runtime != nil else { return }
        if let attempt { retire(attempt) }
        startAttempt()
        retryFailedPanes()
    }

    /// Closes the connection, lets the engine finish its event and free the pane producers, waits for
    /// renderers still being created, then closes every renderer, which unregisters it from the engine
    /// before freeing it.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        resumeSizeWaiter()
        if let attempt {
            attempt.finishOperations()
            attempt.task?.cancel()
            if let connection = attempt.connection {
                await connection.close()
            } else if let transport = attempt.transport {
                await transport.close(reusable: true)
            }
            // An opening still under way closes what it opened once it sees the stop.
            await attempt.task?.value
        }
        await engine.stop()
        if !creatingTerminals.isEmpty {
            await withCheckedContinuation { creationsDrained = $0 }
        }
        await closeAllSurfaces()
        terminals.removeAll()
        presentationFailures.removeAll()
        layout = nil
        terminalScreenAdapter.invalidate()
        runtime = nil
    }

    // MARK: - What the screen reads

    var runtimePhase: GhosttyTerminalRuntimePhase {
        if let failure { return .failed(message: failure.message, reason: failure) }
        return attempt?.connection == nil ? .starting : .running
    }

    var isConnectionOpen: Bool {
        guard let attempt else { return false }
        return attempt.connection != nil && !attempt.ended
    }

    var stateTraceLabel: String {
        if stopped { return "released" }
        if failure != nil { return "ended" }
        guard let attempt, attempt.connection != nil else { return "connecting" }
        return attempt.requestedShown ? "shown" : "hidden"
    }

    func paneSurface(_ paneID: String) -> HerdrPaneSurface? {
        surfaces[paneID]
    }

    func presentation(ofPane paneID: String?) -> TerminalPanePresentation {
        guard let paneID else { return .pending }
        if let failure = presentationFailures[paneID] { return .failed(failure) }
        return surfaces[paneID]?.renderer.presentation ?? .pending
    }

    // MARK: - Connection

    private func startAttempt() {
        attemptCount += 1
        let attempt = Attempt(id: attemptCount)
        self.attempt = attempt
        failure = nil
        attempt.task = Task { [weak self] in await self?.run(attempt) }
        reconcilePresentationActivity()
        didChange()
    }

    /// Once the connection is open, the attempt's operations are carried out in order.
    private func run(_ attempt: Attempt) async {
        // Whoever retires the attempt closes its bridge.
        guard let (transport, size) = await bridgeAndScreenSize(for: attempt) else { return }
        // Frames can arrive before `open` returns; the engine paints them at the hello's cell size.
        await engine.setCellSize(widthPx: size.cellWidthPx, heightPx: size.cellHeightPx)
        let feed = await engine.beginConnection()
        guard isCurrent(attempt) else { return }
        attempt.feed = feed
        let connection: HerdrConnection
        do {
            connection = try await HerdrConnection.open(
                transport: transport,
                hello: HerdrHello(
                    cellWidthPx: size.cellWidthPx,
                    cellHeightPx: size.cellHeightPx,
                    cols: size.cols,
                    rows: size.rows,
                    surfaceActive: false
                ),
                appActive: appPhase != .background,
                timing: connectionTiming,
                onEvent: Self.eventHandler(feed: feed, attemptID: attempt.id, model: self)
            )
        } catch {
            guard isCurrent(attempt) else { return }
            end(attempt, Self.disconnectReason(connectionFailedWith: error))
            return
        }
        guard isCurrent(attempt), !attempt.ended else {
            await connection.close()
            return
        }
        attempt.transport = nil
        attempt.connection = connection
        if let themeReport { attempt.ask(.theme(themeReport)) }
        reconcileVisibility()
        reconcilePresentationActivity()
        didChange()
        while let operation = await attempt.nextOperation() {
            guard isCurrent(attempt) else { break }
            await perform(operation, on: connection, attemptID: attempt.id)
        }
    }

    /// A bridge and the screen size for its hello, or nil when the attempt is over. The bridge opens at
    /// once, so its setup overlaps the screen's layout. A bridge still waiting for a size at the hello
    /// deadline is closed, and another opens once the size arrives.
    private func bridgeAndScreenSize(
        for attempt: Attempt
    ) async -> (any HerdrBridgeTransport, HerdrSurfaceGeometry)? {
        while true {
            // Herdr's clock starts when the bridge reaches its socket, which can be before the opening
            // returns.
            let deadline = ContinuousClock.now + Self.helloDeadline
            guard let transport = await openTransport(for: attempt) else { return nil }
            if let size = await screenSize(for: attempt, until: deadline) { return (transport, size) }
            guard isCurrent(attempt) else { return nil }
            attempt.transport = nil
            await transport.close(reusable: true)
            guard await screenSize(for: attempt, until: nil) != nil else { return nil }
        }
    }

    /// The attempt's bridge, or nil when the opening failed, which is reported, or the attempt is over.
    private func openTransport(for attempt: Attempt) async -> (any HerdrBridgeTransport)? {
        let transport: any HerdrBridgeTransport
        do {
            transport = try await openBridge()
        } catch {
            // A cancelled opening releases what it claimed.
            if isCurrent(attempt) { end(attempt, Self.disconnectReason(openingBridgeFailedWith: error)) }
            return nil
        }
        guard isCurrent(attempt) else {
            await transport.close(reusable: true)
            return nil
        }
        attempt.transport = transport
        return transport
    }

    /// Each operation returns once its messages are queued on the connection; Herdr's answer to a show
    /// comes back separately.
    private func perform(_ operation: Operation, on connection: HerdrConnection, attemptID: UInt64) async {
        switch operation {
        case .show(let geometry, let request):
            await connection.sendShow(geometry) { [weak self] result in
                guard case .failure(let error) = result else { return }
                Task { @MainActor [weak self] in self?.showFailed(attemptID, request: request, error: error) }
            }
        case .hide:
            // The session is off screen and takes no input either way; a hide Herdr doesn't confirm
            // leaves only its stale foreground on the server.
            await connection.sendHide()
        case .resize(let geometry):
            await connection.resize(geometry)
            await engine.setCellSize(widthPx: geometry.cellWidthPx, heightPx: geometry.cellHeightPx)
        case .theme(let updates):
            for update in updates {
                await connection.reportHostTheme(update)
            }
        case .appActive(let active):
            await connection.setAppActive(active)
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
            case .snapshot(let snapshot):
                await feed.receive(snapshot)
                Task { @MainActor in model.snapshotArrived(attemptID) }
            case .surface(let output):
                await feed.receive(output)
            case .ended(let error):
                await model.connectionEnded(attemptID, error)
            case .bell, .notification, .clipboard, .inputRefused:
                break
            }
        }
    }

    private func isCurrent(_ attempt: Attempt) -> Bool {
        !stopped && self.attempt === attempt
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

    /// The screen's size once it has one, or nil when the attempt is over or `deadline` passed first.
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
            if let geometry { return geometry }
            if let deadline, ContinuousClock.now >= deadline { return nil }
            await withCheckedContinuation { sizeWaiter = $0 }
        }
        return nil
    }

    private func resumeSizeWaiter() {
        sizeWaiter?.resume()
        sizeWaiter = nil
    }

    private func snapshotArrived(_ attemptID: UInt64) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt), !attempt.hasSnapshot else { return }
        attempt.hasSnapshot = true
        reconcileVisibility()
    }

    private func connectionEnded(_ attemptID: UInt64, _ error: HerdrConnectionError) {
        guard let attempt, attempt.id == attemptID else { return }
        end(attempt, error.terminalDisconnectReason)
    }

    /// Ends the attempt and reports why. A connection Remux closes sends no `ended` event, so whoever
    /// finds the reason reports it here.
    private func end(_ attempt: Attempt, _ reason: TerminalDisconnectReason) {
        guard isCurrent(attempt), !attempt.ended else { return }
        failure = reason
        retire(attempt)
        reconcilePresentationActivity()
        didChange()
    }

    private func retire(_ attempt: Attempt) {
        attempt.ended = true
        attempt.finishOperations()
        attempt.task?.cancel()
        if attempt === self.attempt { resumeSizeWaiter() }
        if let connection = attempt.connection {
            Task { await connection.close() }
        } else if let transport = attempt.transport {
            Task { await transport.close(reusable: true) }
        }
    }

    /// Shows the session while the root wants it on screen and hides it otherwise. Herdr takes the
    /// newest of a show and a hide, so each change is sent at once, even while the last is unanswered.
    private func reconcileVisibility() {
        guard let attempt, isCurrent(attempt), !attempt.ended, attempt.hasSnapshot,
              attempt.connection != nil, let geometry
        else { return }
        let wanted = isSelected && appPhase != .background
        guard wanted != attempt.requestedShown else { return }
        attempt.requestedShown = wanted
        attempt.visibilityRequests += 1
        attempt.ask(wanted ? .show(geometry, request: attempt.visibilityRequests) : .hide)
    }

    /// Herdr's client rolls a failed show back and stays on what it showed before; a Remux session
    /// screen has nothing else to show, so the connection ends and the root offers a reconnect.
    private func showFailed(_ attemptID: UInt64, request: UInt64, error: Error) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt),
              request == attempt.visibilityRequests
        else { return }
        if case .connectionEnded? = error as? HerdrCommandError { return }
        attempt.requestedShown = false
        end(attempt, Self.disconnectReason(showFailedWith: error))
    }

    /// Herdr stores a client's theme and uses it whenever that client is in front, so one full report
    /// before the first show, and one after each theme change, keeps the server on the phone's theme.
    /// Being full, each report also replaces an appearance Herdr would otherwise keep over the next
    /// background. Without a report Herdr uses another client's colours; nothing else is lost.
    private var themeReport: [HerdrHostThemeUpdate]? {
        guard let colors = try? runtime?.terminalColors() else { return nil }
        return Self.hostTheme(colors, appearance: currentTerminalSettings.theme.isLight ? .light : .dark)
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
            let shown = Set(layout.panes.lazy.filter(\.hasTextArea).map(\.paneID))
            terminals = terminals.filter { shown.contains($0.key) }
            presentationFailures = presentationFailures.filter { shown.contains($0.key) }
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
        case .paneTerminalFailed(let paneID):
            presentationFailures[paneID] = Self.paneFailure
            surfaces[paneID]?.renderer.failPresentation(message: Self.paneFailure.message)
        case .rendererWakeFailed(let paneID):
            surfaces[paneID]?.renderer.failPresentation(message: Self.rendererFailureMessage)
        case .failed(let error, let connection):
            if let attempt, attempt.feed?.connection == connection {
                end(attempt, error.terminalDisconnectReason)
            }
        }
        didChange()
    }

    private func displayMetrics(for paneID: String) -> GhosttySurfaceDisplayMetrics? {
        guard let measurement,
              let pane = layout?.panes.first(where: { $0.paneID == paneID })
        else { return nil }
        return measurement.displayMetrics(
            columns: UInt32(pane.innerRect.width),
            rows: UInt32(pane.innerRect.height)
        )
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
            surface.renderer.close { [weak self] in
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
            fence: HerdrPaneRendererFence(engine: engine, paneID: paneID, terminal: terminal),
            writeInput: nil,
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: metrics,
            theme: currentTerminalSettings.theme,
            diagnosticName: "herdr pane=\(paneID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(paneID, terminal: terminal) }
        ) { [weak self] result in
            guard let self else {
                if case .success(let renderer) = result { renderer.close() }
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
                renderer.close()
                return
            }
            surfaces[paneID] = HerdrPaneSurface(paneID: paneID, terminal: terminal, renderer: renderer)
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

    /// Without an open connection the panes show a frozen frame, so none is focused: Herdr's client
    /// shows no cursor while its session isn't online.
    private func reconcilePresentationActivity() {
        let sceneActive = appPhase == .active
        let live = failure == nil && isConnectionOpen
        for (paneID, surface) in surfaces {
            let pane = layout?.panes.first { $0.paneID == paneID }
            surface.renderer.setSceneActive(sceneActive)
            surface.renderer.setPresented(pane != nil)
            surface.renderer.setFocused(live && pane?.focused == true)
        }
    }

    private func closeSurface(_ paneID: String) {
        surfaces.removeValue(forKey: paneID)?.renderer.close()
    }

    private func closeAllSurfaces() async {
        let closing = Array(surfaces.values)
        surfaces.removeAll()
        guard !closing.isEmpty else { return }
        await withCheckedContinuation { continuation in
            var remaining = closing.count
            for surface in closing {
                surface.renderer.close {
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }
            }
        }
    }

    private func resumeCreationDrainIfQuiescent() {
        guard creatingTerminals.isEmpty, let continuation = creationsDrained else { return }
        creationsDrained = nil
        continuation.resume()
    }

    // MARK: - Reporting

    private func didChange() {
        guard !stopped else { return }
        terminalScreenAdapter.objectWillChange.send()
        let readiness = terminalScreenAdapter.terminalScreenPresentationProjection.readiness
        let state = TerminalReadinessProjector.runtimeState(readiness)
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

    private static let rendererFailureMessage = "Terminal renderer is unavailable. Reconnect to try again."
    private static let configurationFailureMessage =
        "Terminal renderer could not apply its current configuration. Reconnect to try again."

    private static func disconnectReason(openingBridgeFailedWith error: Error) -> TerminalDisconnectReason {
        switch error as? HerdrBridgeError {
        case .herdrNotFound?, .herdrNotExecutable?:
            return TerminalDisconnectReason(kind: .profile, message: error.localizedDescription)
        case .remoteExit?:
            return TerminalDisconnectReason(kind: .remoteExit, message: error.localizedDescription)
        case .channel?:
            return TerminalDisconnectReason(kind: .transportIO, message: error.localizedDescription)
        case nil:
            return GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
        }
    }

    private static func disconnectReason(connectionFailedWith error: Error) -> TerminalDisconnectReason {
        (error as? HerdrConnectionError)?.terminalDisconnectReason
            ?? TerminalDisconnectReason(kind: .unknown, message: error.localizedDescription)
    }

    private static func disconnectReason(showFailedWith error: Error) -> TerminalDisconnectReason {
        if case .timedOut? = error as? HerdrCommandError {
            return TerminalDisconnectReason(kind: .transportIO, message: error.localizedDescription)
        }
        return TerminalDisconnectReason(kind: .runtime, message: error.localizedDescription)
    }
}

extension HerdrConnectionError {
    var terminalDisconnectReason: TerminalDisconnectReason {
        let message = errorDescription ?? "The connection to Herdr failed."
        switch self {
        case .closed, .transport, .unresponsive, .handshakeTimedOut:
            return TerminalDisconnectReason(kind: .transportIO, message: message)
        case .serverShutdown:
            return TerminalDisconnectReason(kind: .remoteExit, message: message)
        case .rejected, .incompatible, .wire:
            return TerminalDisconnectReason(kind: .runtime, message: message)
        }
    }
}

extension HerdrPaneLayout.Pane {
    /// A pane with no text area has no terminal.
    var hasTextArea: Bool {
        innerRect.width > 0 && innerRect.height > 0
    }
}
