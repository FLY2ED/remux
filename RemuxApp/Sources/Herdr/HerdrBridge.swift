import Foundation
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

enum HerdrBridgeError: Error, Equatable, LocalizedError {
    /// Herdr isn't on the server, or couldn't run, or ran and failed.
    case program(RemoteProgramFailure)
    /// The run ended before it got to Herdr: the login shell or the server's startup files failed.
    case remoteExit(status: Int, stderr: String)
    case channel(String)

    var errorDescription: String? {
        switch self {
        case .program(let failure):
            let problem = BackendProblem(failure, path: nil)
            return [problem.message(for: .herdr), problem.detail].compactMap { $0 }.joined(separator: " ")
        case .remoteExit(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "herdr exited with status \(status)." : detail
        case .channel(let detail):
            return "The SSH channel to Herdr failed: \(detail)."
        }
    }
}

/// What a bridge carries, which decides whether the server may end it while it is quiet.
enum HerdrBridgeKind: Sendable {
    /// The session's connection: with `--idle-timeout-v1` where the host supports it, as Herdr's own
    /// client runs its background bridges.
    case session
    /// A direct attach to one terminal, which is quiet while the terminal is, so it has no idle timeout,
    /// as Herdr's client runs its interactive attach (`remote/attach.rs` `bridge_command`); the SSH
    /// connection's own liveness bounds it.
    case terminal
}

/// `herdr remote-client-bridge` on an SSH exec channel: the bridge copies its stdin to the session's
/// client socket and the socket to its stdout, so the channel carries the endpoint protocol unchanged.
///
/// The channel has no pty, so stderr stays out of the protocol stream, and stdout up to the ready marker
/// (`RemoteProgramCommand`) is skipped, so text from the server's startup files never reaches the
/// protocol. Reads are on demand: the SSH window refills only as the connection reads, so a phone that
/// stops reading holds the server back once the current window (2 MiB, as with OpenSSH) is used, and
/// `--idle-timeout-v1` (where the host supports it) bounds how long the server keeps it.
final class HerdrSSHBridge: HerdrBridgeTransport, @unchecked Sendable {
    private enum State {
        case running
        /// nil for an ordinary end of stream.
        case ended(Error?)
    }

    private let lock = NIOLock()
    private var chunks: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Error>?
    /// Writes the channel hasn't taken yet, by number; closing fails them.
    private var pendingWrites: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextWrite: UInt64 = 0
    /// The channel failed a write. The stream's end keeps what the server said, such as an exit status
    /// that names Herdr missing, but the SSH connection isn't offered again.
    private var writeFailed = false
    private var state = State.running
    private var stderr = RemoteProgramMessages()
    private var readyLine = RemoteProgramCommand.ReadyLine()
    private var connection: RemuxSSHExecConnection?

    private init() {}

    static func open(
        using claimedRoot: RemuxSSHClaimedRoot,
        herdrExecutable: String,
        session: String,
        kind: HerdrBridgeKind,
        trace: RemuxTransportStartupTrace
    ) async throws -> HerdrSSHBridge {
        let bridge = HerdrSSHBridge()
        let connection = try await RemuxSSHExecSession.open(
            using: claimedRoot,
            command: command(herdrExecutable: herdrExecutable, session: session, kind: kind),
            pseudoTerminal: false,
            readsOnDemand: true,
            trace: trace,
            onData: { [bridge] type, data in bridge.receive(type, data) },
            onFinish: { [bridge] status, error in bridge.finish(status: status, error: error) }
        )
        bridge.lock.withLock { bridge.connection = connection }
        return bridge
    }

    /// Runs the bridge for `session`. A session's bridge has `--idle-timeout-v1` when `herdr status client
    /// --json` reports `remote_bridge_idle_timeout: true` (Linux and macOS hosts), as Herdr's own client
    /// does for its background bridges; a terminal's never does. No locale is forced, since the bridge may
    /// start the server, whose panes inherit the environment.
    static func command(herdrExecutable: String, session: String, kind: HerdrBridgeKind) -> String {
        let idleTimeout = #"if "$resolved" status client --json 2> /dev/null | grep -Eq "\"remote_bridge_idle_timeout\": *true"; then exec "$resolved" --session "$session" remote-client-bridge --idle-timeout-v1; fi"#
        return RemoteProgramCommand.command(program: herdrExecutable, arguments: [session], body: [
            #"session=$(printf %b "$2")"#,
        ] + (kind == .session ? [idleTimeout] : []) + [
            #"exec "$resolved" --session "$session" remote-client-bridge"#,
        ])
    }

    // MARK: - HerdrBridgeTransport

    func read() async throws -> [UInt8]? {
        enum Outcome {
            case chunk([UInt8])
            case ended(Error?)
            case wait
        }
        return try await withCheckedThrowingContinuation { continuation in
            let (outcome, connection) = lock.withLock { () -> (Outcome, RemuxSSHExecConnection?) in
                if !chunks.isEmpty { return (.chunk(chunks.removeFirst()), nil) }
                if case .ended(let error) = state { return (.ended(error), nil) }
                assert(waiter == nil, "HerdrBridgeTransport allows one read at a time")
                waiter = continuation
                return (.wait, self.connection)
            }
            switch outcome {
            case .chunk(let bytes):
                continuation.resume(returning: bytes)
            case .ended(let error?):
                continuation.resume(throwing: error)
            case .ended(nil):
                continuation.resume(returning: nil)
            case .wait:
                connection?.requestRead()
            }
        }
    }

    /// After the stream ended, a write reports why it ended. A write completes once the channel has
    /// taken it, which needs the server to read; closing fails a write still waiting for that.
    func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let started = lock.withLock { () -> Result<(UInt64, RemuxSSHExecConnection), Error> in
                if case .ended(let error) = state {
                    return .failure(error ?? HerdrBridgeError.channel("the bridge has ended"))
                }
                guard let connection else {
                    return .failure(HerdrBridgeError.channel("the bridge has ended"))
                }
                nextWrite += 1
                pendingWrites[nextWrite] = continuation
                return .success((nextWrite, connection))
            }
            switch started {
            case .failure(let error):
                continuation.resume(throwing: error)
            case .success(let (id, connection)):
                connection.write(Data(bytes)) { [self] error in
                    completeWrite(id, error: error)
                }
            }
        }
    }

    /// Ends the stream here at once: a waiting read returns nil and waiting writes fail, without
    /// waiting for the server, whose answer never comes on a dead path.
    ///
    /// Whether the SSH connection may carry the next opening is decided here. It may when nothing says
    /// the path is bad, as Herdr's client keeps its shared SSH connection for its next bridge whatever
    /// ended the last. It may not when the closer doubts the path, having given up waiting for the
    /// welcome or heard nothing in time, or when the channel failed, a write included: it is given back
    /// as not reusable before returning, so a reconnect right after never gets it again, which needs
    /// nothing from the server. A reusable close finishes in the background, since it waits for the
    /// server to answer the channel close.
    func close(_ cause: HerdrBridgeCloseCause) async {
        let (connection, disposition, writes) = lock.withLock { () -> (RemuxSSHExecConnection?, RemuxSSHRootLeaseDisposition, [CheckedContinuation<Void, Error>]) in
            var channelFailed = writeFailed
            if case .ended(let error?) = state, case .channel(_)? = error as? HerdrBridgeError {
                channelFailed = true
            }
            let connection = self.connection
            self.connection = nil
            let writes = Array(pendingWrites.values)
            pendingWrites.removeAll()
            return (connection, cause == .finished && !channelFailed ? .reusable : .invalidated, writes)
        }
        finish(status: nil, error: nil)
        lock.withLock { chunks.removeAll() }
        writes.forEach { $0.resume(throwing: HerdrBridgeError.channel("the bridge has ended")) }
        guard let connection else { return }
        switch disposition {
        case .invalidated:
            await connection.close(disposition: .invalidated)
        case .reusable:
            Task { await connection.close(disposition: .reusable) }
        }
    }

    // MARK: - Channel callbacks (NIO event loop)

    /// A delivery can hold only stderr or startup output, which the connection never sees; then the
    /// waiting read is still owed data, so another read is requested. NIOSSH allows that from here: it
    /// delivers the rest of the batch in order or reads from the connection.
    private func receive(_ type: SSHChannelData.DataType, _ data: Data) {
        let (waiter, bytes, rearm) = lock.withLock { () -> (CheckedContinuation<[UInt8]?, Error>?, [UInt8], RemuxSSHExecConnection?) in
            guard type == .channel else {
                stderr.append(data)
                return (nil, [], self.waiter == nil ? nil : connection)
            }
            // Closed here: nothing reads any more.
            if connection == nil, case .ended = state { return (nil, [], nil) }
            let bytes = readyLine.output(from: data)
            guard !bytes.isEmpty else { return (nil, [], self.waiter == nil ? nil : connection) }
            if let waiter = self.waiter {
                self.waiter = nil
                return (waiter, bytes, nil)
            }
            chunks.append(bytes)
            return (nil, [], nil)
        }
        waiter?.resume(returning: bytes)
        rearm?.requestRead()
    }

    /// A failed write is recorded before the writer hears of it, so the close it leads to never offers
    /// the SSH connection again, even when the channel's own end hasn't arrived yet.
    private func completeWrite(_ id: UInt64, error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if error != nil { writeFailed = true }
            return pendingWrites.removeValue(forKey: id)
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func finish(status: Int?, error: Error?) {
        let waiter = lock.withLock { () -> (CheckedContinuation<[UInt8]?, Error>, Error?)? in
            guard case .running = state else { return nil }
            let ending = Self.ending(status: status, error: error, stderr: stderr.text)
            state = .ended(ending)
            guard let waiter = self.waiter else { return nil }
            self.waiter = nil
            return (waiter, ending)
        }
        guard let waiter else { return }
        let (continuation, ending) = waiter
        if let ending {
            continuation.resume(throwing: ending)
        } else {
            continuation.resume(returning: nil)
        }
    }

    private static func ending(status: Int?, error: Error?, stderr: String) -> Error? {
        if let error {
            return HerdrBridgeError.channel(String(describing: error))
        }
        guard let status, status != 0 else { return nil }
        return RemoteProgramFailure(exitStatus: status, stderr: stderr).map(HerdrBridgeError.program)
            ?? HerdrBridgeError.remoteExit(status: status, stderr: stderr)
    }
}
