import Foundation

/// The byte stream to a Herdr server: the bridge's stdin and stdout. Reads are pulled: the next
/// bytes are read only when the connection asks, so a screen that falls behind holds the server back
/// instead of buffering without bound.
protocol HerdrBridgeTransport: Sendable {
    /// The next bytes from the server, or nil at the end of the stream.
    func read() async throws -> [UInt8]?
    func write(_ bytes: [UInt8]) async throws
    /// Ends the stream; a pending read returns nil.
    func close() async
}

/// What a connection hands to its screen, in wire order.
enum HerdrConnectionEvent: Sendable {
    case snapshot(HerdrSnapshot)
    /// For the surface decoder, which must see every surface message in order.
    case surface(HerdrSurfaceDecoder.Message)
    case bell(count: UInt16)
    case notification(HerdrSemanticNotification)
    /// Base64 of a program's OSC 52 clipboard write.
    case clipboard(base64: String)
    /// Herdr refused an input message (a paste over its limit); the connection stays.
    case inputRefused(message: String)
    /// The connection ended; nothing follows.
    case ended(HerdrConnectionError)
}

enum HerdrConnectionError: Error, Equatable, LocalizedError {
    /// The server rejected the hello (`unsupported_generation`, `no_common_core`, `invalid_surface`,
    /// `invalid_hello`).
    case rejected(code: String, message: String)
    case incompatible(String)
    case handshakeTimedOut
    case wire(HerdrWireError)
    case serverShutdown(reason: String?)
    case closed
    case transport(String)
    /// No bytes arrived for a while after a health ping.
    case unresponsive

    var errorDescription: String? {
        switch self {
        case .rejected(_, let message):
            return "Herdr refused the connection: \(message)"
        case .incompatible(let reason):
            return "This Herdr server isn't compatible with Remux: \(reason)."
        case .handshakeTimedOut:
            return "Herdr didn't answer."
        case .wire(let error):
            return error.errorDescription
        case .serverShutdown:
            return "The Herdr server stopped."
        case .closed:
            return "The connection to Herdr closed."
        case .transport(let detail):
            return "The connection to Herdr failed: \(detail)"
        case .unresponsive:
            return "Herdr stopped responding."
        }
    }
}

enum HerdrCommandError: Error, Equatable, LocalizedError {
    /// The server doesn't advertise the method; only this action is unavailable.
    case unsupported(method: String)
    case noSnapshot
    /// No reply in time. The command keeps the lane until its reply arrives, as in Herdr's client.
    case timedOut(method: String)
    case failed(code: String, message: String)
    case connectionEnded

    var errorDescription: String? {
        switch self {
        case .unsupported(let method):
            return "This Herdr server doesn't support \(method)."
        case .noSnapshot:
            return "Herdr hasn't sent its session yet."
        case .timedOut:
            return "Herdr didn't answer in time."
        case .failed(_, let message):
            return message
        case .connectionEnded:
            return "The connection to Herdr ended."
        }
    }
}

/// Herdr's per-message input limits (`server/client_transport.rs:47-48, 118, 572-640`). Over either,
/// Herdr refuses a pure paste or closes the connection, so Remux doesn't send.
enum HerdrInputError: Error, Equatable, LocalizedError {
    case inactive
    case tooManyEvents(Int)
    case tooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .inactive:
            return "This Herdr session isn't on screen."
        case .tooManyEvents:
            return "That's more input than Herdr accepts at once."
        case .tooLarge(let bytes):
            return "That's \(bytes) bytes; Herdr accepts up to 1 MiB at once."
        }
    }
}

/// One endpoint connection to a Herdr server (generation 1).
///
/// It sends Remux's hello and checks the welcome, then reads server messages in order and hands them to
/// its screen, reading again only after the screen has taken them. All writes go through one ordered
/// writer. Commands run one at a time; `client_shell.surface.set` bypasses that lane, because Herdr
/// answers it even while a command is in flight.
actor HerdrConnection {
    struct Timing: Sendable {
        var welcome: Duration = .seconds(10)
        /// A health ping goes out after this long with nothing received.
        var pingAfterSilence: Duration = .seconds(5)
        /// The connection fails if nothing arrives this long after a ping.
        var unansweredPing: Duration = .seconds(10)
        var healthTick: Duration = .seconds(1)
        var command: Duration = .seconds(15)
    }

    struct Negotiated: Equatable, Sendable {
        let serverVersion: String
        let methods: Set<String>
        let delta: Bool
        let scroll: Bool
    }

    static let maxInputEvents = 4096
    static let maxInputBytes = 1024 * 1024
    static let surfaceSetMethod = "client_shell.surface.set"

    nonisolated let negotiated: Negotiated
    private let transport: any HerdrBridgeTransport
    private let timing: Timing
    private let onEvent: @Sendable (HerdrConnectionEvent) async -> Void

    private var splitter: HerdrFrameSplitter
    private var bootID: String?
    private var isActive = false
    private var ended = false
    private var appActive = false
    private var lastReceived = ContinuousClock.now
    private var outstandingPing: (data: String, sentAt: ContinuousClock.Instant)?
    private var pongWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var nextID: UInt64 = 0

    private var writeQueue: [[UInt8]] = []
    private var isWriting = false

    private struct Pending {
        let method: String
        var continuation: CheckedContinuation<Data, Error>?
        var data: [UInt8] = []
        let holdsLane: Bool
    }

    private var pending: [String: Pending] = [:]
    private var laneBusy = false
    private var laneWaiters: [CheckedContinuation<Void, Never>] = []
    private var healthTask: Task<Void, Never>?

    // MARK: - Opening

    /// Sends the hello, waits for the welcome and starts reading. Delta and scroll are used only when
    /// both the hello asked for them and the server lists them.
    static func open(
        transport: any HerdrBridgeTransport,
        hello: HerdrHello,
        timing: Timing = Timing(),
        onEvent: @escaping @Sendable (HerdrConnectionEvent) async -> Void
    ) async throws -> HerdrConnection {
        do {
            try await transport.write(HerdrClientMessage.hello(hello).frame)
        } catch {
            await transport.close()
            throw HerdrConnectionError.transport(String(describing: error))
        }
        let (welcome, splitter): (HerdrWelcome, HerdrFrameSplitter)
        do {
            (welcome, splitter) = try await withThrowingTaskGroup(
                of: (HerdrWelcome, HerdrFrameSplitter)?.self
            ) { group in
                group.addTask { try await readWelcome(from: transport) }
                group.addTask {
                    try await Task.sleep(for: timing.welcome)
                    await transport.close()
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let result = first else {
                    throw HerdrConnectionError.handshakeTimedOut
                }
                return result
            }
            try validate(welcome)
        } catch {
            await transport.close()
            throw Self.connectionError(error)
        }
        let connection = HerdrConnection(
            transport: transport,
            negotiated: Negotiated(
                serverVersion: welcome.serverVersion,
                methods: Set(welcome.methods),
                delta: hello.surfaceDelta == true && welcome.capabilities.contains("surface_delta"),
                scroll: hello.surfaceScroll == true && welcome.capabilities.contains("surface_scroll")
            ),
            splitter: splitter,
            surfaceActive: hello.surfaceActive,
            timing: timing,
            onEvent: onEvent
        )
        await connection.startReading()
        return connection
    }

    private init(
        transport: any HerdrBridgeTransport,
        negotiated: Negotiated,
        splitter: HerdrFrameSplitter,
        surfaceActive: Bool,
        timing: Timing,
        onEvent: @escaping @Sendable (HerdrConnectionEvent) async -> Void
    ) {
        self.transport = transport
        self.negotiated = negotiated
        self.splitter = splitter
        self.isActive = surfaceActive
        self.timing = timing
        self.onEvent = onEvent
    }

    private static func readWelcome(
        from transport: any HerdrBridgeTransport
    ) async throws -> (HerdrWelcome, HerdrFrameSplitter) {
        var splitter = HerdrFrameSplitter()
        while true {
            if let payload = try splitter.nextPayload() {
                guard case .control(let kind, let data) = try HerdrServerMessage.decode(payload),
                      kind == HerdrControlKind.welcome,
                      case .welcome(let welcome) = try HerdrEndpointControl.parse(kind: kind, data: data)
                else {
                    throw HerdrConnectionError.incompatible("its first message wasn't a welcome")
                }
                return (welcome, splitter)
            }
            guard let chunk = try await transport.read() else { throw HerdrConnectionError.closed }
            splitter.append(chunk)
        }
    }

    /// Herdr's client checks the same fields (`client/handshake.rs:245-291`).
    private static func validate(_ welcome: HerdrWelcome) throws {
        if let error = welcome.error {
            throw HerdrConnectionError.rejected(code: error.code, message: error.message)
        }
        guard welcome.generation == 1 else {
            throw HerdrConnectionError.incompatible("it speaks endpoint generation \(welcome.generation)")
        }
        guard welcome.snapshotCodec == HerdrControlKind.snapshot,
              welcome.surfaceCodec == "shell.surface.v1",
              welcome.inputCodec == "shell.input.semantic.v1",
              welcome.blobCodec == "shell.blob.v1"
        else {
            throw HerdrConnectionError.incompatible("it uses other codecs")
        }
    }

    private static func connectionError(_ error: Error) -> HerdrConnectionError {
        switch error {
        case let error as HerdrConnectionError: return error
        case let error as HerdrWireError: return .wire(error)
        default: return .transport(String(describing: error))
        }
    }

    // MARK: - Reading

    private func startReading() {
        Task { await self.readLoop() }
    }

    private func readLoop() async {
        do {
            try await deliverBuffered()
            while !ended {
                guard let chunk = try await transport.read() else {
                    throw HerdrConnectionError.closed
                }
                guard !ended else { return }
                lastReceived = .now
                splitter.append(chunk)
                try await deliverBuffered()
            }
        } catch {
            await end(Self.connectionError(error))
        }
    }

    /// Hands every complete message to the screen before the next read.
    private func deliverBuffered() async throws {
        while !ended, let payload = try splitter.nextPayload() {
            try await route(try HerdrServerMessage.decode(payload))
        }
    }

    private func route(_ message: HerdrServerMessage) async throws {
        switch message {
        case .control(let kind, let data):
            switch try HerdrEndpointControl.parse(kind: kind, data: data) {
            case .snapshot(let snapshot):
                bootID = snapshot.bootID
                await onEvent(.snapshot(snapshot))
            case .surfaceReuse(let reuse):
                await onEvent(.surface(.reuse(reuse)))
            case .surfaceDelta(let delta):
                await onEvent(.surface(.delta(delta)))
            case .surfaceScroll(let scroll):
                await onEvent(.surface(.scroll(scroll)))
            case .healthPong(let data):
                if outstandingPing?.data == data { outstandingPing = nil }
                pongWaiters.removeValue(forKey: data)?.resume(returning: true)
            case .welcome, .ignored:
                break
            }
        case .paneSurface(let surface):
            await onEvent(.surface(.full(surface)))
        case .paneSurfacePatch(let patch):
            await onEvent(.surface(.patch(patch)))
        case .responseChunk(let chunk):
            receive(chunk)
        case .terminalBell(let count):
            await onEvent(.bell(count: count))
        case .semanticNotification(let notification):
            await onEvent(.notification(notification))
        case .clipboard(let base64):
            await onEvent(.clipboard(base64: base64))
        case .clientShellError(let message):
            await onEvent(.inputRefused(message: message))
        case .serverShutdown(let reason):
            throw HerdrConnectionError.serverShutdown(reason: reason)
        case .mouseCapture, .keyboardReportAll, .windowTitle, .reloadSoundConfig, .notify:
            // Remux reads mouse state from each pane's surface flags, encodes no keys itself, shows no
            // outer title and plays no terminal sounds.
            break
        }
    }

    // MARK: - Writing

    private func enqueue(_ message: HerdrClientMessage) {
        guard !ended else { return }
        writeQueue.append(message.frame)
        guard !isWriting else { return }
        isWriting = true
        Task { await self.drainWrites() }
    }

    private func drainWrites() async {
        while !ended, !writeQueue.isEmpty {
            let frame = writeQueue.removeFirst()
            do {
                try await transport.write(frame)
            } catch {
                await end(Self.connectionError(error))
            }
        }
        isWriting = false
    }

    // MARK: - Showing and hiding

    /// Shows the session as Herdr's own client does: the tab takes this size, the surface activates,
    /// then the phone takes focus. Returns the projection floor from `surface.set`; the next full
    /// surface is at least that revision.
    func show(_ geometry: HerdrSurfaceGeometry) async throws -> UInt64 {
        let (id, request) = try surfaceSet(active: true)
        isActive = true
        let data = try await reply(
            to: id,
            method: Self.surfaceSetMethod,
            holdsLane: false,
            sending: [.shellResize(geometry), request, .focus(true)]
        )
        return try projectionRevision(from: data)
    }

    /// Hides the session. Focus goes first, while still active: deactivation keeps the stored focus,
    /// so without it the next show's focus would be ignored.
    func hide() async throws {
        let (id, request) = try surfaceSet(active: false)
        isActive = false
        _ = try await reply(to: id, method: Self.surfaceSetMethod, holdsLane: false, sending: [.focus(false), request])
    }

    private func surfaceSet(active: Bool) throws -> (id: String, message: HerdrClientMessage) {
        guard let bootID else { throw HerdrCommandError.noSnapshot }
        let id = makeID("s")
        let message = try HerdrClientMessage.endpointRequest(
            bootID: bootID,
            id: id,
            method: Self.surfaceSetMethod,
            params: ["active": active]
        )
        return (id, message)
    }

    private func projectionRevision(from data: Data) throws -> UInt64 {
        struct Reply: Decodable {
            struct Result: Decodable {
                let projectionRevision: UInt64

                private enum CodingKeys: String, CodingKey {
                    case projectionRevision = "projection_revision"
                }
            }

            let result: Result
        }
        do {
            return try JSONDecoder().decode(Reply.self, from: data).result.projectionRevision
        } catch {
            throw HerdrConnectionError.incompatible("its surface.set reply couldn't be read")
        }
    }

    // MARK: - Input

    /// Sends input to a pane. Fails without sending while the session is hidden or when the message is
    /// over Herdr's limits.
    func send(_ events: [HerdrInputEvent], toPane paneID: String) throws {
        guard isActive, !ended else { throw HerdrInputError.inactive }
        try Self.checkLimits(events)
        enqueue(.paneInput(paneID: paneID, events: events))
    }

    func send(_ events: [HerdrInputEvent], toPopup terminalID: String) throws {
        guard isActive, !ended else { throw HerdrInputError.inactive }
        try Self.checkLimits(events)
        enqueue(.popupInput(terminalID: terminalID, events: events))
    }

    func reportHostTheme(_ update: HerdrHostThemeUpdate) {
        enqueue(.hostTheme(update))
    }

    /// Herdr's counting: a key counts its repeats, a vertical wheel event its lines, anything else one;
    /// paste text, typed text and key text count toward the byte limit.
    static func checkLimits(_ events: [HerdrInputEvent]) throws {
        var expanded = 0
        var bytes = 0
        for event in events {
            switch event {
            case .key(let key):
                let repeats = max(Int(key.repeatCount), 1)
                expanded += repeats
                bytes += (key.generatedText?.utf8.count ?? 0) * repeats
            case .text(let text), .paste(let text):
                expanded += 1
                bytes += text.utf8.count
            case .mouse(let mouse):
                switch mouse.kind {
                case .scrollUp, .scrollDown: expanded += max(Int(mouse.lines), 1)
                default: expanded += 1
                }
            }
        }
        guard expanded <= maxInputEvents else { throw HerdrInputError.tooManyEvents(expanded) }
        guard bytes <= maxInputBytes else { throw HerdrInputError.tooLarge(bytes: bytes) }
    }

    // MARK: - Commands

    /// Runs one endpoint command and returns its reply JSON (`{"id", "result"}`). Commands run one at a
    /// time; a later one waits for the lane.
    func command(_ method: String, params: some Encodable & Sendable) async throws -> Data {
        guard negotiated.methods.contains(method) else { throw HerdrCommandError.unsupported(method: method) }
        await acquireLane()
        guard !ended else {
            releaseLane()
            throw HerdrCommandError.connectionEnded
        }
        guard let bootID else {
            releaseLane()
            throw HerdrCommandError.noSnapshot
        }
        let id = makeID("c")
        let message: HerdrClientMessage
        do {
            message = try HerdrClientMessage.endpointRequest(bootID: bootID, id: id, method: method, params: params)
        } catch {
            releaseLane()
            throw error
        }
        return try await reply(to: id, method: method, holdsLane: true, sending: [message])
    }

    /// Registers the reply for `id`, then queues `messages` in order, all before any other actor work,
    /// so a step's messages go out together and its reply can't arrive unregistered.
    private func reply(
        to id: String,
        method: String,
        holdsLane: Bool,
        sending messages: [HerdrClientMessage]
    ) async throws -> Data {
        guard !ended else { throw HerdrCommandError.connectionEnded }
        let timeout = timing.command
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(method: method, continuation: continuation, holdsLane: holdsLane)
            messages.forEach(enqueue)
            Task {
                try? await Task.sleep(for: timeout)
                await self.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: String) {
        guard var request = pending[id], let continuation = request.continuation else { return }
        request.continuation = nil
        pending[id] = request
        continuation.resume(throwing: HerdrCommandError.timedOut(method: request.method))
    }

    private func receive(_ chunk: HerdrResponseChunk) {
        guard var request = pending[chunk.requestID] else { return }
        request.data += chunk.data
        guard chunk.isFinal else {
            pending[chunk.requestID] = request
            return
        }
        pending[chunk.requestID] = nil
        if request.holdsLane { releaseLane() }
        guard let continuation = request.continuation else { return }
        let data = Data(request.data)
        struct Failure: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
            }

            let error: Body?
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data), let error = failure.error {
            continuation.resume(throwing: HerdrCommandError.failed(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: data)
        }
    }

    private func acquireLane() async {
        guard laneBusy else {
            laneBusy = true
            return
        }
        await withCheckedContinuation { laneWaiters.append($0) }
    }

    /// Passes the lane straight to the next waiter.
    private func releaseLane() {
        if laneWaiters.isEmpty {
            laneBusy = false
        } else {
            laneWaiters.removeFirst().resume()
        }
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    // MARK: - Health

    /// While the app is open, a ping goes out after a silence and the connection fails if nothing
    /// arrives after it; any bytes count, so a large message still arriving is not a dead connection.
    /// In the background nothing is sent.
    func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        healthTask?.cancel()
        healthTask = nil
        outstandingPing = nil
        guard active, !ended else { return }
        healthTask = Task { await self.monitorHealth() }
    }

    /// Sends a ping with a fresh id and reports whether its own reply came back in time: the check
    /// before showing a session again after the app returns.
    func confirmAlive() async -> Bool {
        guard !ended else { return false }
        let data = makeID("alive")
        let timeout = timing.unansweredPing
        return await withCheckedContinuation { continuation in
            pongWaiters[data] = continuation
            enqueue(.healthPing(data: data))
            Task {
                try? await Task.sleep(for: timeout)
                await self.expirePong(data)
            }
        }
    }

    private func expirePong(_ data: String) {
        pongWaiters.removeValue(forKey: data)?.resume(returning: false)
    }

    private func monitorHealth() async {
        while appActive, !ended, !Task.isCancelled {
            try? await Task.sleep(for: timing.healthTick)
            guard appActive, !ended, !Task.isCancelled else { return }
            let now = ContinuousClock.now
            if let ping = outstandingPing {
                if lastReceived > ping.sentAt {
                    outstandingPing = nil
                } else if now - ping.sentAt >= timing.unansweredPing {
                    await end(.unresponsive)
                    return
                }
            } else if now - lastReceived >= timing.pingAfterSilence {
                let data = makeID("ping")
                outstandingPing = (data, now)
                enqueue(.healthPing(data: data))
            }
        }
    }

    // MARK: - Ending

    /// Detaches and closes. No `ended` event follows a close Remux asked for.
    func close() async {
        guard !ended else { return }
        try? await transport.write(HerdrClientMessage.detach.frame)
        finish()
        await transport.close()
    }

    private func end(_ error: HerdrConnectionError) async {
        guard !ended else { return }
        finish()
        await transport.close()
        await onEvent(.ended(error))
    }

    private func finish() {
        ended = true
        isActive = false
        healthTask?.cancel()
        healthTask = nil
        writeQueue.removeAll()
        for request in pending.values {
            request.continuation?.resume(throwing: HerdrCommandError.connectionEnded)
        }
        pending.removeAll()
        for waiter in pongWaiters.values {
            waiter.resume(returning: false)
        }
        pongWaiters.removeAll()
        let waiters = laneWaiters
        laneWaiters.removeAll()
        laneBusy = false
        waiters.forEach { $0.resume() }
    }
}
