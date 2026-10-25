import Foundation

enum TmuxSessionDiscoveryError: Error, Equatable, LocalizedError {
    /// The command ended before the ready marker, or without tmux's path after it.
    case incompleteOutput
    case invalidUTF8
    /// The run ended before it got to tmux: the login shell or the server's startup files failed.
    case remoteExit(status: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case .incompleteOutput:
            return "The tmux command on this server ended before its output."
        case .invalidUTF8:
            return "The tmux session list was not valid UTF-8."
        case .remoteExit(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "The command on this server exited with status \(status)."
                : detail
        }
    }
}

enum TmuxSessionDiscovery {
    static func discover(
        using claimedRoot: RemuxSSHClaimedRoot,
        tmuxExecutable: String,
        trace: RemuxTransportStartupTrace
    ) async throws -> SessionListing {
        let result = try await RemuxSSHExecSession.run(
            using: claimedRoot,
            command: SSHTmuxControlCommandBuilder.listSessionsCommand(
                tmuxExecutable: tmuxExecutable
            ),
            stdin: nil,
            trace: trace
        )
        return try listing(from: result)
    }

    /// A tmux that isn't found or fails throws `RemoteProgramFailure`; a tmux without a server running has no
    /// sessions.
    static func listing(from result: RemuxSSHExecResult) throws -> SessionListing {
        guard result.exitStatus == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            guard let failure = RemoteProgramFailure(exitStatus: result.exitStatus, stderr: stderr) else {
                throw TmuxSessionDiscoveryError.remoteExit(status: result.exitStatus, stderr: stderr)
            }
            guard case .failed(let message) = failure,
                  isMissingTmuxServer(exitStatus: result.exitStatus, message: message)
            else {
                throw failure
            }
            return SessionListing(executablePath: try output(result.stdout).path, sessions: [])
        }
        let (path, names) = try output(result.stdout)
        return SessionListing(
            executablePath: path,
            sessions: names.map { DiscoveredSession(name: $0, isRunning: true) }
        )
    }

    /// After the ready marker: where the script found tmux, then one session name per line.
    private static func output(_ stdout: Data) throws -> (path: String, names: [String]) {
        var readyLine = RemoteProgramCommand.ReadyLine()
        let output = readyLine.output(from: stdout)
        guard readyLine.isFound else { throw TmuxSessionDiscoveryError.incompleteOutput }
        guard let text = String(data: Data(output), encoding: .utf8) else {
            throw TmuxSessionDiscoveryError.invalidUTF8
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let path = lines.first, !path.isEmpty else { throw TmuxSessionDiscoveryError.incompleteOutput }

        var names: [String] = []
        var seen = Set<String>()
        for line in lines.dropFirst() {
            let name = String(line)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return (String(path), names)
    }

    private static func isMissingTmuxServer(exitStatus: Int, message: String) -> Bool {
        guard exitStatus == 1 else { return false }
        return message.hasPrefix("no server running on ")
            || (
                message.hasPrefix("error connecting to ")
                    && message.hasSuffix("(No such file or directory)")
            )
    }
}
