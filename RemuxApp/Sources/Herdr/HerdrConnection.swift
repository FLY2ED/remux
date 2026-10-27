import Foundation

/// The byte stream to a Herdr server: the bridge's stdin and stdout. Reads are pulled: the next
/// bytes are read only when the connection asks, so a screen that falls behind holds the server back
/// instead of buffering without bound.
protocol HerdrBridgeTransport: Sendable {
    /// The next bytes from the server, or nil at the end of the stream. A stream that ended badly
    /// throws its reason, with text for the user where the transport has it. One read at a time: the
    /// connection is the only reader.
    func read() async throws -> [UInt8]?
    func write(_ bytes: [UInt8]) async throws
    /// Ends the stream at once: a pending read returns nil, pending writes fail, and the call doesn't
    /// wait for the other side. `cause` says what the closer knows of the path, which decides whether
    /// whatever carries the stream may carry the next one.
    func close(_ cause: HerdrBridgeCloseCause) async
}

/// Why a bridge closes, as far as its closer knows. Whether the channel itself failed is the bridge's
/// own to know.
enum HerdrBridgeCloseCause: Equatable, Sendable {
    /// Nothing says the path is bad: Remux closed an open connection, or the connection ended on what
    /// came from the other side, as Herdr refusing the hello or shutting down, or the bridge's stream
    /// ending.
    case finished
    /// Given up before the connection opened, so whether the path still works is unknown.
    case givenUpWhileOpening
    /// Herdr didn't answer in time.
    case unresponsive
}

/// What a connection hands to its screen, in wire order. Events can arrive before `open` returns.
enum HerdrConnectionEvent: Sendable {
    /// With the agent completions Herdr sent for exactly this snapshot, when it sent them.
    case snapshot(HerdrSnapshot, completions: [String: UInt64]?)
    /// A full surface or a patch, decoded from every surface message in wire order, also while
    /// hidden.
    case surface(HerdrSurfaceDecoder.Output)
    case bell(count: UInt16)
    case notification(HerdrSemanticNotification)
    /// Base64 of a program's OSC 52 clipboard write.
    case clipboard(base64: String)
    /// Herdr refused an input message (a paste over its limit); the connection stays.
    case inputRefused(message: String)
    /// Whether the focused pane asks for every key as an escape code.
    case keyboardReportAll(Bool)
    /// The connection ended; nothing follows.
    case ended(HerdrConnectionError)
}

enum HerdrConnectionError: Error, Equatable, LocalizedError {
    /// The server rejected the hello (`unsupported_generation`, `no_common_core`, `invalid_surface`,
    /// `invalid_hello`).
    case rejected(code: String, message: String)
    /// The running server is older than Remux supports, as Herdr's client tells: it answers with the binary
    /// welcome (no version), or lacks surface activation or health checks.
    case outdated(serverVersion: String?)
    case incompatible(String)
    case handshakeTimedOut
    case wire(HerdrWireError)
    case serverShutdown(reason: String?)
    case closed
    /// The bridge to Herdr failed, as it reports it: Herdr missing or unrunnable on the server, or the
    /// bridge exiting.
    case bridge(HerdrBridgeError)
    /// The stream failed; the text is for the user.
    case transport(String)
    /// No bytes arrived for a while after a health ping, or no snapshot after connecting.
    case unresponsive

    var errorDescription: String? {
        switch self {
        case .rejected(_, let message):
            return "Herdr refused the connection: \(message)"
        case .outdated(let version):
            return "This Herdr server\(version.map { " (\($0))" } ?? "") needs an update."
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
        case .bridge(let error):
            return error.errorDescription
        case .transport(let detail):
            return detail
        case .unresponsive:
            return "Herdr stopped responding."
        }
    }
}

enum HerdrCommandError: Error, Equatable, LocalizedError {
    /// The server doesn't advertise the method; only this action is unavailable.
    case unsupported(method: String)
    case noSnapshot
    /// No reply in time. As in Herdr's client, the lane frees and the late reply is dropped when it
    /// comes; until the server finishes, another command may get `endpoint_busy`.
    case timedOut(method: String)
    /// `client_shell.surface.set` answered with the other state.
    case notAcknowledged
    case failed(code: String, message: String)
    case connectionEnded
    /// The command waited for the lane, and the session left the screen first.
    case notSent

    var errorDescription: String? {
        switch self {
        case .unsupported(let method):
            return "This Herdr server doesn't support \(method)."
        case .noSnapshot:
            return "Herdr hasn't sent its session yet."
        case .timedOut:
            return "Herdr didn't answer in time."
        case .notAcknowledged:
            return "Herdr didn't switch the session."
        case .failed(_, let message):
            return message
        case .connectionEnded:
            return "The connection to Herdr ended."
        case .notSent:
            return "The session left the screen before Herdr could take this."
        }
    }
}

/// Input Remux doesn't send. Over either of Herdr's per-message limits, Herdr refuses a pure paste or
/// closes the connection.
enum HerdrInputError: Error, Equatable, LocalizedError {
    /// Herdr drops input from a client that isn't showing the session.
    case inactive
    case connectionEnded
    case tooManyEvents(Int)
    case tooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .inactive:
            return "This Herdr session isn't on screen."
        case .connectionEnded:
            return "The connection to Herdr ended."
        case .tooManyEvents:
            return "That's more input than Herdr accepts at once."
        case .tooLarge(let bytes):
            return "That's \(bytes) bytes; Herdr accepts up to 1 MiB at once."
        }
    }
}

/// A command's reply, and where it fell among the session's snapshots. Herdr sends snapshots and replies
/// in one ordered stream and applies a command before it replies, so a snapshot received before the
/// command went out was built before it, and one received after the reply was built after it.
struct HerdrCommandReply: Sendable {
    let json: Data
    /// The revision of the newest snapshot when the command went out.
    let sentAfter: UInt64
    /// The revision of the newest snapshot when the reply came.
    let answeredAfter: UInt64
}

/// One endpoint connection to a Herdr server (generation 1). It owns its bridge from the moment it is
/// made: only the connection closes it, whether its owner closes the connection, the welcome doesn't
/// come in time, or the connection fails.
///
/// It sends Remux's hello and checks the welcome, then reads server messages in order and hands them to
/// its screen, reading again only after the screen has taken them. Surface messages are decoded here,
/// with the negotiated encodings, as Herdr's client decodes them in its reader, so the decoder sees
/// every one of them in order from the first. All writes go through one ordered
/// writer. Commands run one at a time; `client_shell.surface.set` bypasses that lane, because Herdr
/// answers it even while a command is in flight. Timings and rules follow Herdr's own client unless a
/// comment gives Remux's reason.
actor HerdrConnection {
    struct Timing: Sendable {
        /// Remux's SSH channel is open before this starts. Herdr allows 60 s because its window also
        /// covers the SSH connect; what remains here is bounded by the bridge, which gives up after 5 s
        /// if the server won't start and reads a running server's status within 0.5 s.
        var welcome: Duration = .seconds(10)
        /// Herdr's health rule: a ping after this long with nothing received, and the connection fails
        /// when nothing arrives this long after it, or when no snapshot has come this long after
        /// connecting. Herdr gives the first snapshot as long as a remote server's setup.
        var pingAfterSilence: Duration = .seconds(5)
        var unansweredPing: Duration = .seconds(10)
        var firstSnapshot: Duration = .seconds(60)
        /// Health is checked when one of the limits above is due. While the screen takes messages
        /// nothing is read, so that time isn't silence and no limit runs; the check looks again this
        /// soon after, which bounds how late a first-snapshot limit that passed meanwhile is found.
        var deliveryRecheck: Duration = .seconds(1)
        /// Herdr's command timeout.
        var command: Duration = .seconds(60)
        /// Herdr's activation timeout: a show's answer and a frame after it must both come within it. The
        /// screen holds a show to it; the connection only sends the show and reads the answer.
        var activation: Duration = .seconds(5)
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

    /// What the welcome offered, once it came.
    private(set) var negotiated: Negotiated?
    private let transport: any HerdrBridgeTransport
    private let timing: Timing
    private let onEvent: @Sendable (HerdrConnectionEvent) async -> Void
    /// When the welcome came.
    private var openedAt = ContinuousClock.now

    private var splitter = HerdrFrameSplitter()
    /// Made again with the welcome's encodings.
    private var decoder = HerdrSurfaceDecoder(deltaNegotiated: false, scrollNegotiated: false)
    private var bootID: String?
    /// The newest agent completions, waiting for the snapshot they belong to.
    private var pendingCompletions: HerdrAgentCompletions?
    private var isActive = false
    private var ended = false
    /// Why the connection ended, for the reader to report; nil after a close Remux asked for.
    private var endReason: HerdrConnectionError?
    private var appActive = false
    /// When bytes last arrived, or reading resumed after the screen took the previous ones.
    private var lastProgress = ContinuousClock.now
    /// The screen is taking messages, so nothing is read; that time isn't server silence.
    private var delivering = false
    /// A message has come since the welcome. Herdr's server answers pings only once its main loop has
    /// registered the client, which a busy server can put off after the welcome; until then only the
    /// first-snapshot limit applies.
    private var heardSinceWelcome = false
    private var outstandingPing: (data: String, sentAt: ContinuousClock.Instant)?
    /// Back from the background, a ping goes out at once instead of after the next silence.
    private var probeDue = false
    /// Alive checks waiting for their own ping's reply, each with when its reply limit started.
    private var pongWaiters: [String: (since: ContinuousClock.Instant, waiter: CheckedContinuation<Bool, Never>)] = [:]
    private var nextID: UInt64 = 0

    private var writeQueue: [[UInt8]] = []
    private var isWriting = false

    /// A request awaiting its final chunk. After a cancellation, or for a hide sent without waiting,
    /// nobody waits, but the entry stays until the reply, or a command's timeout, frees the lane.
    private struct Pending {
        var waiter: Waiter?
        var data: [UInt8] = []
        var holdsLane: Bool
    }

    private enum Waiter {
        /// A caller awaiting the reply's JSON.
        case caller(CheckedContinuation<Data, Error>)
        /// A show sent with `sendShow`: its answer goes to `answered`.
        case show(answered: @Sendable (Result<UInt64, Error>) -> Void)
        /// A command sent without a caller awaiting it, after the snapshot `sentAfter`: its reply goes
        /// to `answered`.
        case command(answered: CommandAnswered, sentAfter: UInt64)
    }

    /// Gets a command's reply, or its failure.
    typealias CommandAnswered = @Sendable (Result<HerdrCommandReply, Error>) -> Void

    /// Waiting for the lane: a caller, or a command for a show (`sendCommandWhileShown`).
    private enum LaneWaiter {
        case caller(CheckedContinuation<Void, Error>)
        case command(QueuedCommand)
    }

    private struct QueuedCommand {
        let method: String
        let params: any Encodable & Sendable
        let answered: CommandAnswered
    }

    private var pending: [String: Pending] = [:]
    private var laneBusy = false
    private var nextTicket: UInt64 = 0
    private var laneWaiters: [(ticket: UInt64, waiter: LaneWaiter)] = []
    /// The newest snapshot's revision on this connection.
    private var snapshotRevision: UInt64 = 0
    private var healthTask: Task<Void, Never>?

    // MARK: - Opening

    /// Takes over `transport`, which only the connection closes from here on.
    init(
        transport: any HerdrBridgeTransport,
        timing: Timing = Timing(),
        onEvent: @escaping @Sendable (HerdrConnectionEvent) async -> Void
    ) {
        self.transport = transport
        self.timing = timing
        self.onEvent = onEvent
    }

    /// Sends the hello, waits for the welcome and starts reading. `appActive` starts the health check
    /// when the app is in the foreground (`setAppActive`). Throws why it didn't open: what the server or
    /// the bridge said, no welcome in time, or `CancellationError` once its owner closed it.
    func open(hello: HerdrHello, appActive: Bool) async throws {
        // Neither a stalled write nor a read ends by itself, so the deadline ends the connection, whose
        // bridge then ends both.
        let deadline = Task {
            try await Task.sleep(for: self.timing.welcome)
            await self.end(.handshakeTimedOut)
        }
        defer { deadline.cancel() }
        do {
            guard !ended else { throw HerdrConnectionError.closed }
            // A failed write ends the stream, and the read then reports why.
            try? await transport.write(HerdrClientMessage.hello(hello).frame)
            let welcome = try await readWelcome()
            try Self.validate(welcome)
            guard !ended else { throw HerdrConnectionError.closed }
            let negotiated = Negotiated(
                serverVersion: welcome.serverVersion,
                methods: Set(welcome.methods),
                delta: welcome.capabilities.contains("surface_delta"),
                scroll: welcome.capabilities.contains("surface_scroll")
            )
            self.negotiated = negotiated
            decoder = HerdrSurfaceDecoder(deltaNegotiated: negotiated.delta, scrollNegotiated: negotiated.scroll)
            isActive = hello.surfaceActive
        } catch {
            await end(Self.connectionError(error))
            throw endReason ?? CancellationError()
        }
        start(appActive: appActive)
    }

    private func readWelcome() async throws -> HerdrWelcome {
        while true {
            if let payload = try splitter.nextPayload() {
                let message = try HerdrServerMessage.decode(payload)
                // A server older than the endpoint protocol answers with the binary welcome; Herdr's
                // client says to update it.
                if case .unused(tag: 0) = message {
                    throw HerdrConnectionError.outdated(serverVersion: nil)
                }
                guard case .control(let kind, let data) = message,
                      kind == HerdrControlKind.welcome,
                      case .welcome(let welcome) = try HerdrEndpointControl.parse(kind: kind, data: data)
                else {
                    throw HerdrConnectionError.incompatible("its first message wasn't a welcome")
                }
                return welcome
            }
            guard let chunk = try await transport.read() else { throw HerdrConnectionError.closed }
            splitter.append(chunk)
        }
    }

    /// Herdr's client checks the same fields, then refuses a remote server without surface activation
    /// or health checks. Herdr's surface activation also requires the presentation fence; Remux doesn't
    /// use the fence, so it doesn't require it.
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
        guard welcome.capabilities.contains("surface_interest"),
              welcome.capabilities.contains("health_check"),
              welcome.methods.contains(surfaceSetMethod)
        else {
            throw HerdrConnectionError.outdated(serverVersion: welcome.serverVersion)
        }
    }

    private static func connectionError(_ error: Error) -> HerdrConnectionError {
        switch error {
        case let error as HerdrConnectionError:
            return error
        case let error as HerdrWireError:
            return .wire(error)
        case let error as HerdrBridgeError:
            return .bridge(error)
        case let error as LocalizedError:
            return .transport(error.errorDescription ?? "The connection to Herdr failed.")
        default:
            return .transport("The connection to Herdr failed: \(String(describing: error)).")
        }
    }

    private func start(appActive: Bool) {
        openedAt = .now
        Task { await self.readLoop() }
        self.appActive = appActive
        startHealthCheck()
    }

    // MARK: - Reading

    /// The only place events go out, so `.ended` follows whatever the screen was given and never
    /// overlaps it.
    private func readLoop() async {
        do {
            try await deliverBuffered()
            while !ended {
                guard let chunk = try await transport.read() else {
                    throw HerdrConnectionError.closed
                }
                guard !ended else { break }
                lastProgress = .now
                splitter.append(chunk)
                try await deliverBuffered()
            }
        } catch {
            await end(Self.connectionError(error))
        }
        if let endReason {
            await onEvent(.ended(endReason))
        }
    }

    /// Hands every complete message to the screen before the next read.
    private func deliverBuffered() async throws {
        delivering = true
        defer {
            delivering = false
            lastProgress = .now
        }
        while !ended, let payload = try splitter.nextPayload() {
            try await route(try HerdrServerMessage.decode(payload))
        }
    }

    /// While the session is hidden, bells, clipboard writes, input refusals and the focused pane's
    /// keyboard mode are dropped, as in Herdr's client; Herdr sends the keyboard mode again when the
    /// session is shown. Surfaces are still decoded and delivered. A surface the decoder can't apply
    /// ends the connection, as in Herdr's client.
    private func route(_ message: HerdrServerMessage) async throws {
        heardSinceWelcome = true
        switch message {
        case .control(let kind, let data):
            switch try HerdrEndpointControl.parse(kind: kind, data: data) {
            case .snapshot(let snapshot):
                bootID = snapshot.bootID
                snapshotRevision = snapshot.revision
                await onEvent(.snapshot(snapshot, completions: takeCompletions(for: snapshot)))
            case .agentCompletions(let completions):
                receive(completions)
            case .surfaceReuse(let reuse):
                await onEvent(.surface(try decoder.decode(.reuse(reuse))))
            case .surfaceDelta(let delta):
                await onEvent(.surface(try decoder.decode(.delta(delta))))
            case .surfaceScroll(let scroll):
                await onEvent(.surface(try decoder.decode(.scroll(scroll))))
            case .healthPong(let data):
                if outstandingPing?.data == data { outstandingPing = nil }
                pongWaiters.removeValue(forKey: data)?.waiter.resume(returning: true)
            case .welcome, .ignored:
                break
            }
        case .paneSurface(let surface):
            await onEvent(.surface(try decoder.decode(.full(surface))))
        case .paneSurfacePatch(let patch):
            await onEvent(.surface(try decoder.decode(.patch(patch))))
        case .responseChunk(let chunk):
            receive(chunk)
        case .terminalBell(let count):
            if isActive { await onEvent(.bell(count: count)) }
        case .semanticNotification(let notification):
            await onEvent(.notification(notification))
        case .clipboard(let base64):
            if isActive { await onEvent(.clipboard(base64: base64)) }
        case .clientShellError(let message):
            if isActive { await onEvent(.inputRefused(message: message)) }
        case .keyboardReportAll(let enabled):
            if isActive { await onEvent(.keyboardReportAll(enabled)) }
        case .serverShutdown(let reason):
            throw HerdrConnectionError.serverShutdown(reason: reason)
        case .mouseCapture, .windowTitle, .reloadSoundConfig, .notify, .unused:
            // Remux reads mouse state from each pane's surface flags, shows no outer title and plays
            // no terminal sounds.
            break
        }
    }

    /// As Herdr's client keeps them (`endpoint_agent_state.rs`): the newest unless an older revision of
    /// the same boot arrives late.
    private func receive(_ completions: HerdrAgentCompletions) {
        if let pending = pendingCompletions, pending.bootID == completions.bootID,
           pending.revision >= completions.revision {
            return
        }
        pendingCompletions = completions
    }

    /// Every snapshot takes the waiting completions; they count only for the snapshot they were sent
    /// with.
    private func takeCompletions(for snapshot: HerdrSnapshot) -> [String: UInt64]? {
        defer { pendingCompletions = nil }
        guard let pending = pendingCompletions, pending.bootID == snapshot.bootID,
              pending.revision == snapshot.revision
        else { return nil }
        return pending.completions
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

    /// Shows the session as Herdr's own client does: the tab takes this size (at least one cell each
    /// way), the surface activates, then the phone takes focus. Returns once the show is queued, so a
    /// caller sending its calls one after another can send a hide behind it while it is unanswered.
    /// `answered` gets the projection floor from `surface.set`, which the next full surface reaches, or
    /// why the show failed. Herdr answers a show even while a command is in flight; how long to wait for
    /// the answer is the caller's.
    func sendShow(_ geometry: HerdrSurfaceGeometry, answered: @escaping @Sendable (Result<UInt64, Error>) -> Void) {
        guard !ended else {
            answered(.failure(HerdrCommandError.connectionEnded))
            return
        }
        let request: (id: String, message: HerdrClientMessage)
        do {
            request = try surfaceSet(active: true)
        } catch {
            answered(.failure(error))
            return
        }
        isActive = true
        register(request.id, waiter: .show(answered: answered), holdsLane: false, timeout: nil,
                 method: Self.surfaceSetMethod,
                 sending: [.shellResize(Self.atLeastOneCell(geometry)), request.message, .focus(true)])
    }

    /// Hides the session and returns once the hide is queued; its answer isn't waited for. Focus goes
    /// first, while still active: deactivation keeps the stored focus, so without it the next show's
    /// focus would be ignored. A command waiting to follow the show doesn't go: Herdr refuses commands
    /// from a hidden session, and the next show sends its own.
    func sendHide() {
        guard !ended, let request = try? surfaceSet(active: false) else { return }
        isActive = false
        let dropped = laneWaiters.compactMap { if case .command(let command) = $0.waiter { command } else { nil } }
        laneWaiters.removeAll { if case .command = $0.waiter { true } else { false } }
        dropped.forEach { $0.answered(.failure(HerdrCommandError.notSent)) }
        register(request.id, waiter: nil, holdsLane: false, timeout: nil,
                 method: Self.surfaceSetMethod, sending: [.focus(false), request.message])
    }

    /// Gives the session on screen a new size, as Herdr's client does whenever its terminal resizes,
    /// also while a show is still being answered. Herdr's client sends sizes only to the session it
    /// shows; a hidden one gets its size with the next show, so nothing is sent while hidden.
    func resize(_ geometry: HerdrSurfaceGeometry) {
        guard isActive else { return }
        enqueue(.shellResize(Self.atLeastOneCell(geometry)))
    }

    private static func atLeastOneCell(_ geometry: HerdrSurfaceGeometry) -> HerdrSurfaceGeometry {
        HerdrSurfaceGeometry(
            cellWidthPx: geometry.cellWidthPx,
            cellHeightPx: geometry.cellHeightPx,
            cols: max(geometry.cols, 1),
            rows: max(geometry.rows, 1)
        )
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

    /// As in Herdr's client, the reply must confirm the show.
    private static func shownRevision(from data: Data) throws -> UInt64 {
        struct Reply: Decodable {
            struct Result: Decodable {
                let active: Bool
                let projectionRevision: UInt64

                private enum CodingKeys: String, CodingKey {
                    case active
                    case projectionRevision = "projection_revision"
                }
            }

            let result: Result
        }
        guard let result = try? JSONDecoder().decode(Reply.self, from: data).result else {
            throw HerdrConnectionError.incompatible("its surface.set reply couldn't be read")
        }
        guard result.active else { throw HerdrCommandError.notAcknowledged }
        return result.projectionRevision
    }

    // MARK: - Input

    /// Sends input to a pane. Fails without sending while the session is hidden or when the message is
    /// over Herdr's limits.
    func send(_ events: [HerdrInputEvent], toPane paneID: String) throws {
        try checkCanSend(events)
        enqueue(.paneInput(paneID: paneID, events: events))
    }

    func send(_ events: [HerdrInputEvent], toPopup terminalID: String) throws {
        try checkCanSend(events)
        enqueue(.popupInput(terminalID: terminalID, events: events))
    }

    /// Herdr stores the update and applies it when this client is in front, so it is sent even while
    /// hidden.
    func reportHostTheme(_ update: HerdrHostThemeUpdate) {
        enqueue(.hostTheme(update))
    }

    private func checkCanSend(_ events: [HerdrInputEvent]) throws {
        guard !ended else { throw HerdrInputError.connectionEnded }
        guard isActive else { throw HerdrInputError.inactive }
        try Self.checkLimits(events)
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
    /// time, as in Herdr's client; a later one waits for the lane, which frees when the reply arrives or
    /// the command times out. A command cancelled while it waits is never sent; one cancelled after it
    /// was sent stops waiting, and its reply or timeout still frees the lane.
    func command(_ method: String, params: some Encodable & Sendable) async throws -> Data {
        guard negotiated?.methods.contains(method) == true else { throw HerdrCommandError.unsupported(method: method) }
        try await acquireLane()
        let id = makeID("c")
        let message: HerdrClientMessage
        do {
            try Task.checkCancellation()
            guard !ended else { throw HerdrCommandError.connectionEnded }
            guard let bootID else { throw HerdrCommandError.noSnapshot }
            message = try HerdrClientMessage.endpointRequest(bootID: bootID, id: id, method: method, params: params)
        } catch {
            releaseLane()
            throw error
        }
        return try await reply(to: id, method: method, holdsLane: true, timeout: timing.command, sending: [message])
    }

    /// Sends a command only if it can go at once: the session is shown and no command is in flight.
    /// Returns whether it went, once it is queued behind everything sent before it; `answered` gets its
    /// reply, with the JSON `command` returns, or its failure within `timeout` (Herdr's command timeout
    /// unless given). Herdr refuses a command while another is in flight or while the session is hidden
    /// (`endpoint_requests.rs`), so one that would have to wait isn't sent.
    func sendCommandIfIdle(
        _ method: String,
        params: some Encodable & Sendable,
        timeout: Duration? = nil,
        answered: @escaping CommandAnswered
    ) -> Bool {
        guard !ended, isActive, !laneBusy, negotiated?.methods.contains(method) == true else { return false }
        laneBusy = true
        guard send(method, params: params, timeout: timeout, answered: answered) else {
            releaseLane()
            return false
        }
        return true
    }

    /// `sendCommandIfIdle`, waiting for the reply: nil when the command didn't go.
    func commandIfIdle(
        _ method: String,
        params: some Encodable & Sendable,
        timeout: Duration? = nil
    ) async -> Result<Data, Error>? {
        await withCheckedContinuation { continuation in
            let sent = sendCommandIfIdle(method, params: params, timeout: timeout) { result in
                continuation.resume(returning: result.map(\.json))
            }
            if !sent { continuation.resume(returning: nil) }
        }
    }

    /// Sends a command for the show just sent: at once if no command is in flight, else once the lane
    /// frees, unless a hide comes first (`sendHide`). Returns false, sending nothing, when the session
    /// isn't shown or the server lacks the method; a command that waited and was dropped fails with
    /// `notSent`.
    func sendCommandWhileShown(
        _ method: String,
        params: some Encodable & Sendable,
        answered: @escaping CommandAnswered
    ) -> Bool {
        guard !ended, isActive, negotiated?.methods.contains(method) == true else { return false }
        guard laneBusy else {
            laneBusy = true
            guard send(method, params: params, timeout: nil, answered: answered) else {
                releaseLane()
                return false
            }
            return true
        }
        nextTicket += 1
        let command = QueuedCommand(method: method, params: params, answered: answered)
        laneWaiters.append((nextTicket, .command(command)))
        return true
    }

    /// Registers and queues a command that holds the lane; false when it can't be encoded.
    private func send(
        _ method: String,
        params: any Encodable & Sendable,
        timeout: Duration?,
        answered: @escaping CommandAnswered
    ) -> Bool {
        guard let bootID else { return false }
        let id = makeID("c")
        guard let message = try? HerdrClientMessage.endpointRequest(bootID: bootID, id: id, method: method, params: params)
        else { return false }
        register(id, waiter: .command(answered: answered, sentAfter: snapshotRevision), holdsLane: true,
                 timeout: timeout ?? timing.command, method: method, sending: [message])
        return true
    }

    private func reply(
        to id: String,
        method: String,
        holdsLane: Bool,
        timeout: Duration,
        sending messages: [HerdrClientMessage]
    ) async throws -> Data {
        guard !ended else { throw HerdrCommandError.connectionEnded }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id, waiter: .caller(continuation), holdsLane: holdsLane, timeout: timeout,
                         method: method, sending: messages)
            }
        } onCancel: {
            Task { await self.stopWaiting(for: id) }
        }
    }

    /// Registers the reply for `id`, then queues `messages` in order, all before any other actor work,
    /// so a step's messages go out together and its reply can't arrive unregistered. A request without
    /// a `timeout` waits for its reply until the connection ends.
    private func register(
        _ id: String,
        waiter: Waiter?,
        holdsLane: Bool,
        timeout: Duration?,
        method: String,
        sending messages: [HerdrClientMessage]
    ) {
        pending[id] = Pending(waiter: waiter, holdsLane: holdsLane)
        messages.forEach(enqueue)
        guard let timeout else { return }
        Task {
            try? await Task.sleep(for: timeout)
            await self.expire(id, method: method)
        }
    }

    private func resolve(_ waiter: Waiter?, with result: Result<Data, Error>) {
        switch waiter {
        case .caller(let continuation)?:
            continuation.resume(with: result)
        case .show(let answered)?:
            answered(result.flatMap { data in Result { try Self.shownRevision(from: data) } })
        case .command(let answered, let sentAfter)?:
            answered(result.map { HerdrCommandReply(json: $0, sentAfter: sentAfter, answeredAfter: snapshotRevision) })
        case nil:
            break
        }
    }

    /// Herdr's client retires a request that didn't answer in time: the caller fails, the lane frees,
    /// and the late reply is dropped, as `receive` drops every reply to an unknown request.
    private func expire(_ id: String, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        resolve(request.waiter, with: .failure(HerdrCommandError.timedOut(method: method)))
        if request.holdsLane { releaseLane() }
    }

    private func stopWaiting(for id: String) {
        guard var request = pending[id], case .caller(let continuation)? = request.waiter else { return }
        request.waiter = nil
        pending[id] = request
        continuation.resume(throwing: CancellationError())
    }

    private func receive(_ chunk: HerdrResponseChunk) {
        guard var request = pending[chunk.requestID] else { return }
        if request.waiter != nil {
            request.data += chunk.data
        }
        guard chunk.isFinal else {
            pending[chunk.requestID] = request
            return
        }
        pending[chunk.requestID] = nil
        if request.holdsLane { releaseLane() }
        guard let waiter = request.waiter else { return }
        let data = Data(request.data)
        struct Failure: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
            }

            let error: Body?
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data), let error = failure.error {
            resolve(waiter, with: .failure(HerdrCommandError.failed(code: error.code, message: error.message)))
        } else {
            resolve(waiter, with: .success(data))
        }
    }

    /// Takes the lane, waiting in line while it's busy. A waiter whose task is cancelled leaves the
    /// line without the lane.
    private func acquireLane() async throws {
        guard laneBusy else {
            laneBusy = true
            return
        }
        nextTicket += 1
        let ticket = nextTicket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                laneWaiters.append((ticket, .caller(continuation)))
            }
        } onCancel: {
            Task { await self.leaveLine(ticket) }
        }
    }

    private func leaveLine(_ ticket: UInt64) {
        guard let index = laneWaiters.firstIndex(where: { $0.ticket == ticket }),
              case .caller(let continuation) = laneWaiters[index].waiter
        else { return }
        laneWaiters.remove(at: index)
        continuation.resume(throwing: CancellationError())
    }

    /// Passes the lane straight to the next waiter. A command that can't be sent passes it on to the one
    /// after it.
    private func releaseLane() {
        while !laneWaiters.isEmpty {
            switch laneWaiters.removeFirst().waiter {
            case .caller(let continuation):
                continuation.resume()
                return
            case .command(let command):
                if send(command.method, params: command.params, timeout: nil, answered: command.answered) { return }
                command.answered(.failure(HerdrCommandError.notSent))
            }
        }
        laneBusy = false
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    // MARK: - Health

    /// While the app is open, Herdr's health rule runs (`Timing`). Two differences, each with a Remux
    /// reason: any bytes count, not only whole messages, because a picture can be a 32 MiB message
    /// still arriving over cellular; and time the screen spends taking messages doesn't count, since
    /// nothing is read then. In the background nothing is sent: pings from a suspended phone would keep
    /// a bridge that isn't reading alive.
    ///
    /// Back from the background, as Herdr's client after a resume, the reply limits start over and a
    /// ping goes out at once: a suspended phone's connection may be gone without a word, and a reply
    /// already waiting unread mustn't be taken for silence.
    func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        outstandingPing = nil
        probeDue = active
        if active {
            let now = ContinuousClock.now
            pongWaiters = pongWaiters.mapValues { (now, $0.waiter) }
        }
        startHealthCheck()
    }

    private func startHealthCheck() {
        healthTask?.cancel()
        healthTask = nil
        guard appActive, !ended else { return }
        healthTask = Task { await self.monitorHealth() }
    }

    /// Sends a ping with a fresh id and reports whether its own reply came back. Herdr answers a ping
    /// only after reading everything sent before it. As with the health check's ping, one left
    /// unanswered ends the connection once nothing has arrived for `unansweredPing` after the server has
    /// sent something, and the health check, which runs while the app is open, keeps that limit too.
    func confirmAlive() async -> Bool {
        guard !ended else { return false }
        let data = makeID("alive")
        return await withCheckedContinuation { continuation in
            pongWaiters[data] = (.now, continuation)
            enqueue(.healthPing(data: data))
            // Its reply limit can come before the check's next time.
            startHealthCheck()
        }
    }

    private func monitorHealth() async {
        while appActive, !ended, !Task.isCancelled {
            try? await Task.sleep(until: nextHealthCheck(), clock: .continuous)
            guard appActive, !ended, !Task.isCancelled else { return }
            if delivering { continue }
            let now = ContinuousClock.now
            if bootID == nil, now - openedAt >= timing.firstSnapshot {
                await end(.unresponsive)
                return
            }
            if let ping = outstandingPing, lastProgress > ping.sentAt {
                outstandingPing = nil
            }
            if heardSinceWelcome, let since = oldestUnansweredPing,
               now - max(since, lastProgress) >= timing.unansweredPing {
                await end(.unresponsive)
                return
            }
            if outstandingPing == nil, probeDue || now - lastProgress >= timing.pingAfterSilence {
                probeDue = false
                let data = makeID("ping")
                outstandingPing = (data, now)
                enqueue(.healthPing(data: data))
            }
        }
    }

    /// The earliest time a health limit can be due, so the check sleeps until then instead of waking on
    /// a schedule. Bytes that arrive meanwhile only move the limits later, which the check finds when it
    /// wakes: an unanswered ping is answered by bytes that come later, and the next ping is due a
    /// silence after them, so the check looks again no later than that.
    private func nextHealthCheck() -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        if delivering { return now + timing.deliveryRecheck }
        if probeDue { return now }
        var due: ContinuousClock.Instant
        if let ping = outstandingPing, lastProgress <= ping.sentAt {
            due = now + timing.pingAfterSilence
            if heardSinceWelcome { due = min(due, ping.sentAt + timing.unansweredPing) }
        } else {
            due = lastProgress + timing.pingAfterSilence
        }
        // Before the server has sent anything, bytes that come later start an alive check's limit no
        // earlier than now.
        if let since = pongWaiters.values.map(\.since).min() {
            due = min(due, (heardSinceWelcome ? max(since, lastProgress) : now) + timing.unansweredPing)
        }
        if bootID == nil { due = min(due, openedAt + timing.firstSnapshot) }
        return due
    }

    /// The oldest ping still waiting for its reply: the health check's until any bytes answer it, and an
    /// alive check's until its own reply comes.
    private var oldestUnansweredPing: ContinuousClock.Instant? {
        let alive = pongWaiters.values.map(\.since).min()
        guard let health = outstandingPing?.sentAt else { return alive }
        return min(health, alive ?? health)
    }

    // MARK: - Ending

    /// Ends the connection; no `ended` event follows, not even for an end found earlier that the screen
    /// hasn't been told about yet. Nothing is written first: Herdr removes an endpoint client whose
    /// stream ends just as one that sends `Detach`, and the bridge passes the end of its input on.
    /// `cause` is what the owner knows of the path.
    func close(_ cause: HerdrBridgeCloseCause) async {
        endReason = nil
        guard !ended else { return }
        await finish(cause)
    }

    /// The reader reports `error` once the screen has taken what it was given.
    private func end(_ error: HerdrConnectionError) async {
        guard !ended else { return }
        endReason = error
        switch error {
        case .unresponsive, .handshakeTimedOut:
            await finish(.unresponsive)
        default:
            await finish(.finished)
        }
    }

    /// The one way the connection ends: every waiter learns it, then the bridge closes with `cause`.
    private func finish(_ cause: HerdrBridgeCloseCause) async {
        ended = true
        isActive = false
        healthTask?.cancel()
        healthTask = nil
        writeQueue.removeAll()
        let ending = pending.values
        pending.removeAll()
        for request in ending {
            resolve(request.waiter, with: .failure(HerdrCommandError.connectionEnded))
        }
        for check in pongWaiters.values {
            check.waiter.resume(returning: false)
        }
        pongWaiters.removeAll()
        let waiters = laneWaiters
        laneWaiters.removeAll()
        laneBusy = false
        for (_, waiter) in waiters {
            switch waiter {
            case .caller(let continuation):
                continuation.resume(throwing: HerdrCommandError.connectionEnded)
            case .command(let command):
                command.answered(.failure(HerdrCommandError.connectionEnded))
            }
        }
        await transport.close(cause)
    }
}
