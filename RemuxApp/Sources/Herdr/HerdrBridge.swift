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
            return "Herdr isn't installed on this server, or isn't on its PATH."
        case .herdrNotExecutable:
            return "The Herdr executable on this server can't be run."
        case .remoteExit(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "herdr exited with status \(status)." : detail
        case .channel(let detail):
            return detail
        }
    }
}

/// `herdr remote-client-bridge` on an SSH exec channel: the bridge copies its stdin to the session's
/// client socket and the socket to its stdout, so the channel carries the endpoint protocol unchanged.
///
/// The channel has no pty, so stderr stays out of the protocol stream. Reads are on demand: the SSH
/// window refills only as the connection reads, so a phone that stops reading holds the server back,
/// and `--idle-timeout-v1` (where the host supports it) bounds how long the server keeps it.
final class HerdrSSHBridge: HerdrBridgeTransport, @unchecked Sendable {
    static let herdrNotFoundMarker = "remux: herdr executable not found"
    static let herdrNotExecutableMarker = "remux: herdr executable cannot be executed"
    private static let stderrLimit = 8 * 1024

    private enum State {
        case running
        /// nil for an ordinary end of stream.
        case ended(Error?)
    }

    private let lock = NIOLock()
    private var chunks: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Error>?
    private var state = State.running
    private var stderr = Data()
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

    /// Runs the bridge for `session`, with `--idle-timeout-v1` when `herdr status client --json` reports
    /// `remote_bridge_idle_timeout: true` (Linux and macOS hosts; plan §8.1, Suspended phone). The
    /// executable and session name stay out of the login shell, as in the discovery command. No locale
    /// is forced, since the bridge may start the server, whose panes inherit the environment.
    static func command(herdrExecutable: String, session: String) -> String {
        [
            "exec /bin/sh -c '\(script)' remux",
            RemoteShellArgument.octalEncoded(herdrExecutable),
            RemoteShellArgument.octalEncoded(session),
        ].joined(separator: " ")
    }

    private static let script = [
        #"PATH="${PATH:+$PATH:}$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin""#,
        "export PATH",
        #"herdr=$(printf %b "$1")"#,
        #"session=$(printf %b "$2")"#,
        #"resolved=$(command -v "$herdr" 2> /dev/null)"#,
        #"if [ ! -x "$resolved" ]; then if [ -e "$herdr" ]; then echo "\#(herdrNotExecutableMarker): $herdr" >&2; exit 126; fi; echo "\#(herdrNotFoundMarker): $herdr" >&2; exit 127; fi"#,
        // The whole script sits inside single quotes, so it uses no single quote itself.
        #"if "$resolved" status client --json 2> /dev/null | grep -Eq "\"remote_bridge_idle_timeout\": *true"; then exec "$resolved" --session "$session" remote-client-bridge --idle-timeout-v1; fi"#,
        #"exec "$resolved" --session "$session" remote-client-bridge"#,
    ].joined(separator: "; ")

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

    func write(_ bytes: [UInt8]) async throws {
        guard let connection = lock.withLock({ self.connection }) else {
            throw HerdrBridgeError.channel("The Herdr bridge isn't open.")
        }
        try await connection.write(Data(bytes))
    }

    /// Closes the channel. The SSH connection stays reusable unless the channel itself failed.
    func close() async {
        let (connection, disposition) = lock.withLock { () -> (RemuxSSHExecConnection?, RemuxSSHRootLeaseDisposition) in
            if case .ended(let error?) = state, case .channel(_)? = error as? HerdrBridgeError {
                return (self.connection, .invalidated)
            }
            return (self.connection, .reusable)
        }
        await connection?.close(disposition: disposition)
        finish(status: nil, error: nil)
    }

    // MARK: - Channel callbacks (NIO event loop)

    private func receive(_ type: SSHChannelData.DataType, _ data: Data) {
        guard type == .channel else {
            lock.withLock {
                stderr.append(data)
                if stderr.count > Self.stderrLimit {
                    stderr.removeFirst(stderr.count - Self.stderrLimit)
                }
            }
            return
        }
        let bytes = Array(data)
        let waiter = lock.withLock { () -> CheckedContinuation<[UInt8]?, Error>? in
            if let waiter = self.waiter {
                self.waiter = nil
                return waiter
            }
            chunks.append(bytes)
            return nil
        }
        waiter?.resume(returning: bytes)
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
            return HerdrBridgeError.channel(error.localizedDescription)
        }
        switch status {
        case 127? where stderr.contains(herdrNotFoundMarker):
            return HerdrBridgeError.herdrNotFound
        case 126? where stderr.contains(herdrNotExecutableMarker):
            return HerdrBridgeError.herdrNotExecutable
        case let status? where status != 0:
            return HerdrBridgeError.remoteExit(status: status, stderr: stderr)
        default:
            return nil
        }
    }
}
