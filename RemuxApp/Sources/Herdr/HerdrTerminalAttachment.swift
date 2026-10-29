import Foundation
import GhosttyKit

/// One direct attach to a Herdr terminal over a bridge of its own, as `herdr terminal attach` makes it. The
/// direct terminal protocol is Herdr's private one, which a newer Herdr may change (`protocol/endpoint.rs`),
/// so anything unexpected on it, a message Remux can't decode or a frame of a size it didn't ask for, ends
/// the attach as failed, and its owner shows the terminal another way.
/// While attached the terminal runs at this client's size, and Herdr's resize lock keeps it there whatever
/// other clients do; when this client leaves, Herdr gives the size back (`server/headless.rs`
/// `attach_terminal_client`, `remove_client`). Frames are terminal bytes, fed into a terminal of its own
/// whose renderer this wakes, as the engine does for panes.
actor HerdrTerminalAttachment {
    enum Event: Sendable {
        /// The first frame's terminal; later frames of another size come as `grid`.
        case terminal(HerdrRetainedTerminal, columns: UInt16, rows: UInt16)
        case grid(columns: UInt16, rows: UInt16)
        /// Nothing follows.
        case ended(Ending)
    }

    enum Ending: Equatable, Sendable {
        case detached
        /// Another direct client holds the terminal, and Herdr refuses another without a takeover, which is
        /// never asked for.
        case held(String)
        /// Herdr refused the attach for another reason, as when the terminal is gone or an agent is reading
        /// it.
        case refused(String)
        /// The terminal is gone, as when its program exits.
        case closed(String)
        /// The bridge or the stream failed, or Herdr ended the connection for another reason.
        case failed(String)
    }

    /// The terminal's size in cells, and the cell in pixels, which Herdr passes on to the program.
    struct Geometry: Equatable, Sendable {
        let columns: UInt16
        let rows: UInt16
        let cellWidthPx: UInt32
        let cellHeightPx: UInt32
    }

    typealias ProducerFactory = @Sendable (_ columns: UInt16, _ rows: UInt16) throws -> any HerdrPaneProducing

    nonisolated let updates: AsyncStream<Event>
    nonisolated let terminalID: String
    private let continuation: AsyncStream<Event>.Continuation
    private let openBridge: HerdrScreenModel.BridgeOpener
    private let makeProducer: ProducerFactory
    private let welcomeDeadline: Duration
    private var geometry: Geometry
    private var transport: (any HerdrBridgeTransport)?
    private var splitter = HerdrFrameSplitter()
    private var welcomed = false
    private var producer: (any HerdrPaneProducing)?
    private var terminal: HerdrRetainedTerminal?
    private var grid: (columns: UInt16, rows: UInt16)?
    private var renderer: HerdrRendererSurface?
    private var keyboard = KeyboardProtocol()
    private var sentGeometry: Geometry?
    /// The sizes asked for, oldest first, that Herdr's frames may still have: frames for an earlier one can
    /// be on their way when a resize goes.
    private var askedSizes: [(columns: UInt16, rows: UInt16)] = []
    private var pendingResize: Geometry?
    private var resizing = false
    private var ending: Ending?

    init(
        terminalID: String,
        geometry: Geometry,
        openBridge: @escaping HerdrScreenModel.BridgeOpener,
        welcomeDeadline: Duration = .seconds(10),
        makeProducer: @escaping ProducerFactory = { try HerdrPaneProducer(columns: $0, rows: $1) }
    ) {
        self.terminalID = terminalID
        self.geometry = geometry
        self.openBridge = openBridge
        self.welcomeDeadline = welcomeDeadline
        self.makeProducer = makeProducer
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Opens the bridge and attaches; the stream reports the rest. Returns when the connection ends.
    func run() async {
        let transport: any HerdrBridgeTransport
        do {
            transport = try await openBridge()
        } catch {
            end(.failed(Self.describe(error)))
            return
        }
        guard ending == nil else {
            await transport.close(.finished)
            return
        }
        self.transport = transport
        sentGeometry = geometry
        asked(geometry)
        do {
            try await transport.write(HerdrDirectTerminalClientMessage.hello(
                columns: geometry.columns,
                rows: geometry.rows,
                cellWidthPx: geometry.cellWidthPx,
                cellHeightPx: geometry.cellHeightPx
            ).frame + HerdrDirectTerminalClientMessage.attach(terminalID: terminalID, takeover: false).frame)
        } catch {
            end(.failed(Self.describe(error)))
            return
        }
        let deadline = Task { [welcomeDeadline] in
            try await Task.sleep(for: welcomeDeadline)
            await self.welcomeOverdue()
        }
        defer { deadline.cancel() }
        do {
            while ending == nil, let chunk = try await transport.read() {
                splitter.append(chunk)
                while ending == nil, let payload = try splitter.nextPayload() {
                    receive(try HerdrDirectTerminalServerMessage.decode(payload))
                }
            }
            end(.failed("The connection to Herdr ended."))
        } catch {
            end(.failed(Self.describe(error)))
        }
    }

    /// True once the bytes are written to the bridge; Herdr doesn't acknowledge input.
    func send(_ bytes: [UInt8]) async -> Bool {
        guard !bytes.isEmpty else { return true }
        return await write(.input(bytes))
    }

    func scroll(_ direction: HerdrDirectTerminalClientMessage.ScrollDirection, lines: UInt16, column: UInt16?, row: UInt16?) async {
        _ = await write(.scroll(direction, lines: lines, column: column, row: row))
    }

    /// The newest size goes; one asked for while another is being written replaces any still waiting.
    func resize(to next: Geometry) async {
        geometry = next
        guard transport != nil else { return }
        pendingResize = next
        guard !resizing else { return }
        resizing = true
        defer { resizing = false }
        while let geometry = pendingResize {
            pendingResize = nil
            guard geometry != sentGeometry else { continue }
            sentGeometry = geometry
            asked(geometry)
            guard await write(.resize(
                columns: geometry.columns,
                rows: geometry.rows,
                cellWidthPx: geometry.cellWidthPx,
                cellHeightPx: geometry.cellHeightPx
            )) else { return }
        }
    }

    /// Leaves the terminal; Herdr gives its size back to the client that had it.
    func detach() async {
        guard ending == nil else { return }
        let transport = transport
        end(.detached)
        guard let transport else { return }
        try? await transport.write(HerdrDirectTerminalClientMessage.detach.frame)
        await transport.close(.finished)
    }

    // MARK: - Renderer registration

    /// Admits a renderer over the current terminal to the wakes. One renderer at a time.
    func register(_ surface: HerdrRendererSurface, terminal: HerdrRetainedTerminal) -> Result<Void, HerdrRendererRegistrationError> {
        guard ending == nil else { return .failure(.engineEnded) }
        guard self.terminal === terminal else { return .failure(.terminalGone) }
        guard renderer == nil else { return .failure(.alreadyRegistered) }
        // A frame between the renderer's creation and now didn't wake it.
        guard ghostty_terminal_surface_terminal_changed(surface.handle) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            return .failure(.rendererWakeFailed)
        }
        renderer = surface
        return .success(())
    }

    /// After this returns, the attachment never wakes `surface` again, so its owner may free it.
    func unregister(_ surface: HerdrRendererSurface) {
        guard renderer == surface else { return }
        renderer = nil
    }

    // MARK: - Receiving

    private func receive(_ message: HerdrDirectTerminalServerMessage) {
        switch message {
        case .welcome(let version, let terminalBytes, let error):
            if let error {
                end(.refused(error))
            } else if version != HerdrDirectTerminalClientMessage.protocolVersion || !terminalBytes {
                end(.refused("Herdr \(version) speaks another terminal protocol."))
            } else {
                welcomed = true
            }
        case .frame(let frame):
            show(frame)
        case .keyboardProtocol(let kittyFlags, let modifyOtherKeysLevel):
            let sequences = keyboard.change(kittyFlags: kittyFlags, modifyOtherKeysLevel: modifyOtherKeysLevel)
            if let producer, !sequences.isEmpty, producer.feed(sequences) != GHOSTTY_TERMINAL_PRODUCER_RESULT_OK {
                end(.failed("The terminal couldn't be drawn."))
            }
        case .shutdown(let reason):
            // Herdr's reasons: "detached" after a detach and "terminal attach failed: …" for a refused attach,
            // "… already has an attached client …" when another client holds the terminal
            // (`server/headless.rs`), "terminal attach ended: …" once the terminal is gone
            // (`server/headless/render.rs`).
            if reason == Self.detachedReason {
                end(.detached)
            } else if let reason, reason.hasPrefix(Self.endedPrefix) {
                end(.closed(reason))
            } else if terminal == nil, let reason, reason.contains(Self.heldReason) {
                end(.held(reason))
            } else if terminal == nil {
                end(.refused(reason ?? "Herdr refused the attach."))
            } else {
                end(.failed(reason ?? "Herdr ended the attach."))
            }
        case .mouseCapture, .skipped:
            break
        }
    }

    /// Herdr draws an attached terminal at the size asked, at least one cell each way
    /// (`server/client_transport.rs` `clamp_terminal_size`).
    private func asked(_ geometry: Geometry) {
        askedSizes.append((max(geometry.columns, 1), max(geometry.rows, 1)))
    }

    private func show(_ frame: HerdrDirectTerminalFrame) {
        // Herdr draws each frame at the newest size it has, so once one comes at a size, frames of the sizes
        // asked before it don't.
        guard let index = askedSizes.firstIndex(where: { $0.columns == frame.columns && $0.rows == frame.rows }) else {
            end(.failed("Herdr sent a \(frame.columns)x\(frame.rows) frame for another size."))
            return
        }
        askedSizes.removeFirst(index)
        if let producer, let grid {
            let resized = grid.columns != frame.columns || grid.rows != frame.rows
            let result = resized
                ? producer.resizeAndFeed(
                    columns: frame.columns,
                    rows: frame.rows,
                    cellWidthPx: geometry.cellWidthPx,
                    cellHeightPx: geometry.cellHeightPx,
                    bytes: frame.bytes
                )
                : producer.feed(frame.bytes)
            guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
                end(.failed("The terminal couldn't be drawn."))
                return
            }
            if resized {
                self.grid = (frame.columns, frame.rows)
                continuation.yield(.grid(columns: frame.columns, rows: frame.rows))
            }
        } else {
            let producer: any HerdrPaneProducing
            let terminal: HerdrRetainedTerminal
            do {
                producer = try makeProducer(frame.columns, frame.rows)
                terminal = try producer.retainTerminal()
            } catch {
                end(.failed("The terminal couldn't be drawn."))
                return
            }
            // Pastes go bracketed, which Herdr unwraps and pastes the way the program asks; the keyboard
            // protocol may have come before the first frame.
            let setup = Self.bracketedPaste + keyboard.current
            guard producer.resizeAndFeed(
                columns: frame.columns,
                rows: frame.rows,
                cellWidthPx: geometry.cellWidthPx,
                cellHeightPx: geometry.cellHeightPx,
                bytes: setup + frame.bytes
            ) == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
                end(.failed("The terminal couldn't be drawn."))
                return
            }
            self.producer = producer
            self.terminal = terminal
            grid = (frame.columns, frame.rows)
            continuation.yield(.terminal(terminal, columns: frame.columns, rows: frame.rows))
        }
        wake()
    }

    private func wake() {
        guard let renderer else { return }
        if ghostty_terminal_surface_terminal_changed(renderer.handle) != GHOSTTY_TERMINAL_SURFACE_RESULT_OK {
            self.renderer = nil
        }
    }

    private func welcomeOverdue() async {
        guard !welcomed, ending == nil else { return }
        let transport = transport
        end(.failed("Herdr didn't answer the attach."))
        await transport?.close(.unresponsive)
    }

    // MARK: - Writing and ending

    private func write(_ message: HerdrDirectTerminalClientMessage) async -> Bool {
        guard ending == nil, let transport else { return false }
        do {
            try await transport.write(message.frame)
            return true
        } catch {
            end(.failed(Self.describe(error)))
            return false
        }
    }

    /// The first ending wins; the producer goes, and a renderer over its terminal keeps the last frame.
    private func end(_ reason: Ending) {
        guard ending == nil else { return }
        ending = reason
        producer = nil
        renderer = nil
        continuation.yield(.ended(reason))
        continuation.finish()
        if reason != .detached, let transport {
            Task { await transport.close(.finished) }
        }
    }

    private static let detachedReason = "detached"
    private static let endedPrefix = "terminal attach ended"
    private static let heldReason = "already has an attached client"
    private static let bracketedPaste = Array("\u{1b}[?2004h".utf8)

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// The keyboard protocol on the attachment's terminal, changed with the sequences Herdr's client
    /// writes to its own terminal (`terminal_modes.rs` `set_direct_host_keyboard_protocol`), so the
    /// renderer encodes keys the way the program asked.
    struct KeyboardProtocol: Equatable {
        private(set) var kittyFlags: UInt16?
        private(set) var modifyOtherKeysLevel: UInt8 = 0

        /// The sequences that set the protocol now in effect on a new terminal.
        var current: [UInt8] {
            var bytes: [UInt8] = []
            if let kittyFlags { bytes += Array("\u{1b}[>\(kittyFlags)u".utf8) }
            if modifyOtherKeysLevel != 0 { bytes += Array("\u{1b}[>4;\(modifyOtherKeysLevel)m".utf8) }
            return bytes
        }

        mutating func change(kittyFlags flags: UInt16, modifyOtherKeysLevel level: UInt8) -> [UInt8] {
            let nextFlags = flags == 0 ? nil : flags
            var bytes: [UInt8] = []
            if kittyFlags != nextFlags {
                if kittyFlags != nil { bytes += Array("\u{1b}[<1u".utf8) }
                if let nextFlags { bytes += Array("\u{1b}[>\(nextFlags)u".utf8) }
            }
            if modifyOtherKeysLevel != level {
                bytes += Array("\u{1b}[>4;\(level)m".utf8)
            }
            kittyFlags = nextFlags
            modifyOtherKeysLevel = level
            return bytes
        }
    }
}

/// The lifetime fence for a renderer over an attachment's terminal: registration and unregistration go
/// through the attachment, so an unregistration completes only once no wake of that surface can run.
@MainActor
final class HerdrTerminalAttachmentFence: TerminalPaneRendererFence {
    private let attachment: HerdrTerminalAttachment
    private let terminal: HerdrRetainedTerminal

    init(attachment: HerdrTerminalAttachment, terminal: HerdrRetainedTerminal) {
        self.attachment = attachment
        self.terminal = terminal
    }

    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [attachment, terminal] in
            let result = await attachment.register(surface, terminal: terminal)
            completion(result.mapError { $0 as any Error })
        }
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [attachment] in
            await attachment.unregister(surface)
            completion()
        }
    }
}
