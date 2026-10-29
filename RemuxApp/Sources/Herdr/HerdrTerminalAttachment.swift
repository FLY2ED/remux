import Foundation
import GhosttyKit

/// One direct attach to a Herdr terminal over a bridge of its own, as `herdr terminal attach` makes it. The
/// direct terminal protocol is Herdr's private one, which a newer Herdr may change (`protocol/endpoint.rs`),
/// so anything unexpected on it, a message Remux can't decode or a frame of a size it didn't ask for, ends
/// the attach as failed, and its owner shows the terminal another way.
/// While attached the terminal runs at this client's size, and Herdr's resize lock keeps it there whatever
/// other clients do; when this client leaves, Herdr gives the size back (`server/headless.rs`
/// `attach_terminal_client`, `remove_client`). Frames are terminal bytes, written for a terminal as Herdr's
/// client draws in, fed into a terminal of its own whose renderer this wakes, as the engine does for panes.
/// The attach carries the terminal's size and its frames; input, the wheel's too, goes to the terminal
/// another way, which Herdr encodes for the program's modes.
actor HerdrTerminalAttachment {
    enum Event: Sendable {
        /// The first frame's terminal; later frames of another size come as `grid`.
        case terminal(HerdrRetainedTerminal, columns: UInt16, rows: UInt16)
        case grid(columns: UInt16, rows: UInt16)
        /// Whether the program reads the mouse, which Herdr sends as it changes, from the attach on
        /// (`server/headless/render.rs` `stream_host_mouse_capture_mode`).
        case mouseCapture(Bool)
        /// Nothing follows.
        case ended(Ending)
    }

    enum Ending: Equatable, Sendable {
        case detached
        /// Another direct client holds the terminal, and Herdr refuses another without a takeover, which is
        /// never asked for.
        case held(String)
        /// Herdr asks to try again, as while an agent reads the terminal.
        case busy(String)
        /// Herdr refused the attach for another reason.
        case refused(String)
        /// Herdr refused the attach because it has no terminal of that id.
        case missing(String)
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
    typealias BridgeOpener = @Sendable () async throws -> any HerdrBridgeTransport

    nonisolated let updates: AsyncStream<Event>
    nonisolated let terminalID: String
    private let continuation: AsyncStream<Event>.Continuation
    private let openBridge: BridgeOpener
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
        openBridge: @escaping BridgeOpener,
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

    /// Leaves the terminal; Herdr gives its size back to the client that had it, as it also does once the
    /// bridge closes. A path that takes no write doesn't hold the bridge open: past the deadline Herdr has to
    /// answer, it closes as unresponsive, which fails the write.
    func detach() async {
        guard ending == nil else { return }
        let transport = transport
        end(.detached)
        guard let transport else { return }
        let overdue = Task { [welcomeDeadline] () -> Bool in
            guard (try? await Task.sleep(for: welcomeDeadline)) != nil else { return false }
            await transport.close(.unresponsive)
            return true
        }
        try? await transport.write(HerdrDirectTerminalClientMessage.detach.frame)
        overdue.cancel()
        if await !overdue.value { await transport.close(.finished) }
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
        case .shutdown(let reason):
            // Herdr's reasons: "detached" after a detach and "terminal attach failed: …" for a refused attach,
            // "… already has an attached client …" when another client holds the terminal, "… has a read in
            // progress; retry" while an agent reads it and "… not found" when there is no such terminal
            // (`server/headless.rs`), "terminal attach ended: …" once the terminal is gone
            // (`server/headless/render.rs`).
            if reason == Self.detachedReason {
                end(.detached)
            } else if let reason, reason.hasPrefix(Self.endedPrefix) {
                end(.closed(reason))
            } else if terminal == nil, let reason, reason.contains(Self.heldReason) {
                end(.held(reason))
            } else if terminal == nil, let reason, reason.hasSuffix(Self.retrySuffix) {
                end(.busy(reason))
            } else if terminal == nil, let reason, reason.hasSuffix(Self.missingSuffix) {
                end(.missing(reason))
            } else if terminal == nil {
                end(.refused(reason ?? "Herdr refused the attach."))
            } else {
                end(.failed(reason ?? "Herdr ended the attach."))
            }
        case .mouseCapture(let enabled):
            continuation.yield(.mouseCapture(enabled))
        case .keyboardProtocol, .skipped:
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
            // Herdr's client draws in a terminal that clusters graphemes, as Ghostty's do.
            guard producer.resizeAndFeed(
                columns: frame.columns,
                rows: frame.rows,
                cellWidthPx: geometry.cellWidthPx,
                cellHeightPx: geometry.cellHeightPx,
                bytes: HerdrPanePainter.graphemeClustering + frame.bytes
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

    private func welcomeOverdue() {
        guard !welcomed, ending == nil else { return }
        end(.failed("Herdr didn't answer the attach."), closing: .unresponsive)
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

    /// The first ending wins; the producer goes, and a renderer over its terminal keeps the last frame. The
    /// bridge closes once, for `closing`, except on a detach, which closes it itself.
    private func end(_ reason: Ending, closing: HerdrBridgeCloseCause = .finished) {
        guard ending == nil else { return }
        ending = reason
        producer = nil
        renderer = nil
        continuation.yield(.ended(reason))
        continuation.finish()
        if reason != .detached, let transport {
            Task { await transport.close(closing) }
        }
    }

    private static let detachedReason = "detached"
    private static let endedPrefix = "terminal attach ended"
    private static let heldReason = "already has an attached client"
    private static let retrySuffix = "; retry"
    private static let missingSuffix = " not found"

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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
