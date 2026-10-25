import Foundation
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

enum HerdrBridgeError: Error, Equatable, LocalizedError {
    case herdrNotFound
    case herdrNotExecutable
    case remoteExit(status: Int, stderr: String)
    case channel(String)

    var errorDescription: String? {
        switch self {
        case .herdrNotFound:
            return "Install Herdr on this server or update Executable Path."
        case .herdrNotExecutable:
            return "Check the Herdr executable and its permissions, then try again."
        case .remoteExit(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "herdr exited with status \(status)." : detail
        case .channel(let detail):
            return "The SSH channel to Herdr failed: \(detail)."
        }
    }
}

/// `herdr remote-client-bridge` on an SSH exec channel: the bridge copies its stdin to the session's
/// client socket and the socket to its stdout, so the channel carries the endpoint protocol unchanged.
///
/// The channel has no pty, so stderr stays out of the protocol stream, and stdout up to Herdr's ready
/// marker (`HerdrRemoteCommand`) is skipped, so text from the server's startup files never reaches the
/// protocol. Reads are on demand: the SSH window refills only as the connection reads, so a phone that
/// stops reading holds the server back once the current window (2 MiB, as with OpenSSH) is used, and
/// `--idle-timeout-v1` (where the host supports it) bounds how long the server keeps it.
final class HerdrSSHBridge: HerdrBridgeTransport, @unchecked Sendable {
    /// The tail is kept: the markers and the bridge's own error come last, after any startup noise.
    private static let stderrLimit = 8 * 1024

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
    private var state = State.running
    private var stderr = Data()
    private var readyLine = HerdrRemoteCommand.ReadyLine()
    private var connection: RemuxSSHExecConnection?

    private init() {}

    static func open(
        using claimedRoot: RemuxSSHClaimedRoot,
        herdrExecutable: String,
        session: String,
        trace: RemuxTransportStartupTrace
    ) async throws -> HerdrSSHBridge {
        let bridge = HerdrSSHBridge()
        let connection = try await RemuxSSHExecSession.open(
            using: claimedRoot,
            command: command(herdrExecutable: herdrExecutable, session: session),
            pseudoTerminal: false,
            readsOnDemand: true,
            trace: trace,
            onData: { [bridge] type, data in bridge.receive(type, data) },
            onFinish: { [bridge] status, error in bridge.finish(status: status, error: error) }
        )
        bridge.lock.withLock { bridge.connection = connection }
        return bridge
    }

    /// Runs the bridge for `session`, with `--idle-timeout-v1` when `herdr status client --json`
    /// reports `remote_bridge_idle_timeout: true` (Linux and macOS hosts), as Herdr's own client does
    /// for its background bridges. No locale is forced, since the bridge may start the server, whose
    /// panes inherit the environment.
    static func command(herdrExecutable: String, session: String) -> String {
        HerdrRemoteCommand.command(herdrExecutable: herdrExecutable, arguments: [session], body: [
            #"session=$(printf %b "$2")"#,
            #"if "$resolved" status client --json 2> /dev/null | grep -Eq "\"remote_bridge_idle_timeout\": *true"; then exec "$resolved" --session "$session" remote-client-bridge --idle-timeout-v1; fi"#,
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
    /// waiting for the server, whose answer never comes on a dead path. A failed channel, or a caller
    /// that saw the path go silent, gives the SSH connection back as not reusable before returning, so
    /// a reconnect right after never gets it again; that needs nothing from the server. A reusable
    /// close finishes in the background, since it waits for the server to answer the channel close.
    func close(reusable: Bool) async {
        let (connection, disposition, writes) = lock.withLock { () -> (RemuxSSHExecConnection?, RemuxSSHRootLeaseDisposition, [CheckedContinuation<Void, Error>]) in
            let channelFailed: Bool
            if case .ended(let error?) = state, case .channel(_)? = error as? HerdrBridgeError {
                channelFailed = true
            } else {
                channelFailed = false
            }
            let connection = self.connection
            self.connection = nil
            let writes = Array(pendingWrites.values)
            pendingWrites.removeAll()
            return (connection, reusable && !channelFailed ? .reusable : .invalidated, writes)
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
                if stderr.count > Self.stderrLimit {
                    stderr.removeFirst(stderr.count - Self.stderrLimit)
                }
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

    private func completeWrite(_ id: UInt64, error: Error?) {
        guard let continuation = lock.withLock({ pendingWrites.removeValue(forKey: id) }) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func finish(status: Int?, error: Error?) {
        let waiter = lock.withLock { () -> (CheckedContinuation<[UInt8]?, Error>, Error?)? in
            guard case .running = state else { return nil }
            let ending = Self.ending(status: status, error: error, stderr: String(decoding: stderr, as: UTF8.self))
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
        switch status {
        case 127? where stderr.contains(HerdrRemoteCommand.notFoundMarker):
            return HerdrBridgeError.herdrNotFound
        case 126? where stderr.contains(HerdrRemoteCommand.notExecutableMarker):
            return HerdrBridgeError.herdrNotExecutable
        case let status? where status != 0:
            return HerdrBridgeError.remoteExit(status: status, stderr: stderr)
        default:
            return nil
        }
    }
}
