import Foundation
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

/// The end of a stream: its last bytes as text, and an escaped preview of fewer of them for traces.
private struct SSHTmuxBoundedStreamPreview: Equatable, Sendable {
    private static let limit = 2048
    private static let previewLimit = 240

    private(set) var byteCount = 0
    private var bytes = Data()

    var preview: String? {
        guard !bytes.isEmpty else { return nil }
        return GhosttyRuntimeTrace.preview(bytes.suffix(Self.previewLimit), limit: Self.previewLimit)
    }

    var text: String? {
        bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }

        byteCount += data.count

        if data.count >= Self.limit {
            bytes = Data(data.suffix(Self.limit))
            return
        }

        let retainedPrefixCount = max(0, Self.limit - data.count)
        if bytes.count > retainedPrefixCount {
            bytes = Data(bytes.suffix(retainedPrefixCount))
        }
        bytes.append(data)
    }
}

struct SSHTmuxStartupDiagnostics: Equatable, Sendable, CustomStringConvertible {
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let extendedDataByteCount: Int
    let stderrPreview: String?
    let extendedDataPreview: String?
    /// Output before tmux's first protocol line: login-shell output and, on a
    /// pseudo-terminal, the launch script's stderr.
    let startupOutputPreview: String?
    /// The end of every message the launch could have written, wherever it arrived, as text.
    let messages: String

    var isEmpty: Bool {
        stdoutByteCount == 0 &&
            stderrByteCount == 0 &&
            extendedDataByteCount == 0
    }

    var description: String {
        var fields = [
            "stdout_bytes=\(stdoutByteCount)",
            "stderr_bytes=\(stderrByteCount)",
            "extended_bytes=\(extendedDataByteCount)",
        ]
        if let startupOutputPreview {
            fields.append("startup_preview=\"\(startupOutputPreview)\"")
        }
        if let stderrPreview {
            fields.append("stderr_preview=\"\(stderrPreview)\"")
        }
        if let extendedDataPreview {
            fields.append("extended_preview=\"\(extendedDataPreview)\"")
        }
        return fields.joined(separator: " ")
    }
}

private struct SSHTmuxStartupDiagnosticsAccumulator: Equatable, Sendable {
    private var stdout = SSHTmuxBoundedStreamPreview()
    private var startupOutput = SSHTmuxBoundedStreamPreview()
    private var stderr = SSHTmuxBoundedStreamPreview()
    private var extendedData = SSHTmuxBoundedStreamPreview()

    mutating func recordStdout(_ data: Data) {
        stdout.append(data)
    }

    mutating func recordStartupOutput(_ data: Data) {
        startupOutput.append(data)
    }

    mutating func recordStderr(_ data: Data) {
        stderr.append(data)
    }

    mutating func recordExtendedData(_ data: Data) {
        extendedData.append(data)
    }

    func snapshot() -> SSHTmuxStartupDiagnostics? {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: stdout.byteCount,
            stderrByteCount: stderr.byteCount,
            extendedDataByteCount: extendedData.byteCount,
            stderrPreview: stderr.preview,
            extendedDataPreview: extendedData.preview,
            startupOutputPreview: startupOutput.preview,
            messages: [startupOutput.text, stderr.text].compactMap { $0 }.joined(separator: "\n")
        )
        return diagnostics.isEmpty ? nil : diagnostics
    }
}

enum SSHTmuxControlChannelDataRoute: Equatable, Sendable {
    /// tmux control-mode bytes. `isFirst` marks the start of the protocol.
    case controlOutput(Data, isFirst: Bool)
    /// Stdout before tmux's first protocol line, kept only as diagnostics.
    case startupOutput
    case stderr
    case extendedData
}

/// Splits the channel into tmux's control protocol and everything else. The
/// protocol starts at tmux's first reply guard, `%begin <time> <number>
/// <flags>`, which a plain control client receives before anything else
/// (tmux's cmdq_guard). Anything earlier on stdout came from the login shell
/// or the launch script, including their stderr, which a pty merges into
/// stdout. A line there that merely starts with `%` must not start the
/// protocol: the native parser skips an unknown `%` line but breaks on the
/// next line that doesn't start with `%`.
final class SSHTmuxControlChannelDataRouter: @unchecked Sendable {
    /// A longer line can't be a reply guard.
    private static let maximumReplyGuardLength = 64

    private let lock = NIOLock()
    private var protocolStarted = false
    private var atLineStart = true
    /// The current line while it can still be tmux's first reply guard. It
    /// can span chunks, so it is held back until the line ends.
    private var candidateLine: Data?
    private var startupDiagnostics = SSHTmuxStartupDiagnosticsAccumulator()

    var diagnostics: SSHTmuxStartupDiagnostics? {
        lock.withLock {
            startupDiagnostics.snapshot()
        }
    }

    func route(
        type: SSHChannelData.DataType,
        data: Data
    ) -> SSHTmuxControlChannelDataRoute {
        lock.withLock {
            switch type {
            case .channel:
                startupDiagnostics.recordStdout(data)
                if protocolStarted {
                    return .controlOutput(data, isFirst: false)
                }
                guard let output = protocolOutput(startingIn: data) else {
                    return .startupOutput
                }
                protocolStarted = true
                return .controlOutput(output, isFirst: true)

            case .stdErr:
                startupDiagnostics.recordStderr(data)
                return .stderr

            default:
                startupDiagnostics.recordExtendedData(data)
                return .extendedData
            }
        }
    }

    /// tmux's output from its first reply guard on, once that line has ended
    /// in `data`; nil while it hasn't. Everything before it is recorded as
    /// startup output.
    private func protocolOutput(startingIn data: Data) -> Data? {
        var startupOutput = Data()
        for index in data.indices {
            let byte = data[index]
            if atLineStart, byte == UInt8(ascii: "%") {
                candidateLine = Data()
            }
            atLineStart = byte == UInt8(ascii: "\n")
            guard var line = candidateLine else {
                startupOutput.append(byte)
                continue
            }
            line.append(byte)
            if byte == UInt8(ascii: "\n") {
                candidateLine = nil
                if Self.isReplyGuard(line) {
                    startupDiagnostics.recordStartupOutput(startupOutput)
                    line.append(contentsOf: data[data.index(after: index)...])
                    return line
                }
                startupOutput.append(line)
            } else if line.count > Self.maximumReplyGuardLength {
                candidateLine = nil
                startupOutput.append(line)
            } else {
                candidateLine = line
            }
        }
        startupDiagnostics.recordStartupOutput(startupOutput)
        return nil
    }

    /// Reads a line the way the native parser reads a reply guard:
    /// `%begin`, then three unsigned numbers, an optional `\r`, nothing else.
    private static func isReplyGuard(_ line: Data) -> Bool {
        var text = line
        if text.last == UInt8(ascii: "\n") { text.removeLast() }
        if text.last == UInt8(ascii: "\r") { text.removeLast() }
        let fields = text.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0].elementsEqual("%begin".utf8) else { return false }
        return fields.dropFirst().allSatisfy { field in
            !field.isEmpty && field.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }
    }
}
