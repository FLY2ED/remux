import Foundation

/// What's wrong with tmux or Herdr on a server, as running it found, in the words of each place that says it:
/// the server page, its path in Edit Server, New Session, and the session's screen.
enum BackendProblem: Equatable, Sendable {
    /// Automatic found nothing that can run.
    case notFound
    /// Nothing that can run is at the path set in Edit Server.
    case notAtPath(String)
    /// The server found it but couldn't start it, in the shell's words. `path` is the one set in Edit Server,
    /// nil for Automatic.
    case couldNotStart(path: String?, message: String)
    /// It ran and reported an error, in its own words; empty when it said nothing.
    case failed(String)
    /// A version older than the backend's oldest supported one, as it reports its version.
    case unsupportedVersion(String)

    /// `path` is the one set in Edit Server, nil for Automatic.
    init(_ failure: RemoteProgramFailure, path: String?) {
        switch failure {
        case .notFound:
            self = path.map(Self.notAtPath) ?? .notFound
        case .couldNotStart(let message):
            self = .couldNotStart(path: path, message: message)
        case .failed(let message):
            self = .failed(message)
        }
    }

    /// A discovery that failed because of the backend's program; nil for any other failure.
    init?(discoveryError error: Error, path: String?) {
        if let failure = error as? RemoteProgramFailure {
            self.init(failure, path: path)
        } else if case .unsupportedVersion(let version)? = error as? HerdrSessionDiscoveryError {
            self = .unsupportedVersion(version.description)
        } else {
            return nil
        }
    }

    /// Nothing that can run was found, on Automatic or at the path set.
    var isNotFound: Bool {
        switch self {
        case .notFound, .notAtPath: true
        case .couldNotStart, .failed, .unsupportedVersion: false
        }
    }

    /// Setting the backend's path in Edit Server is the fix.
    var isFixedByPath: Bool {
        switch self {
        case .notFound, .notAtPath, .couldNotStart: true
        case .failed, .unsupportedVersion: false
        }
    }

    /// The server's own words, shown under the sentence that introduces them.
    var detail: String? {
        switch self {
        case .couldNotStart(_, let message), .failed(let message):
            message.isEmpty ? nil : message
        case .notFound, .notAtPath, .unsupportedVersion:
            nil
        }
    }

    /// On a saved session of the backend, in place of when it was last opened.
    func sessionRowLine(for backend: SessionBackend) -> String {
        let name = backend.displayName
        return switch self {
        case .notFound: "\(name) not found · Set path"
        case .notAtPath: "Can't run \(name) · Check path"
        case .couldNotStart: "Running \(name) failed · Check path"
        case .failed: "Running \(name) failed"
        case .unsupportedVersion(let version):
            "\(name) \(version) is too old · Needs \(backend.minimumSupportedVersion)"
        }
    }

    /// Under the backend's path in Edit Server, above `detail`.
    func pathNote(for backend: SessionBackend) -> String {
        let name = backend.displayName
        return switch self {
        case .notFound: "Remux couldn't find \(name) on this server."
        case .notAtPath: "Remux can't run \(name) from this path."
        case .couldNotStart, .failed: detail == nil ? "Running it failed." : "Running it failed:"
        case .unsupportedVersion(let version):
            "\(name) \(version) is installed. Remux needs \(backend.minimumSupportedVersion) or later."
        }
    }

    /// On the session's screen and in New Session, above `detail`.
    func message(for backend: SessionBackend) -> String {
        let name = backend.displayName
        return switch self {
        case .notFound:
            "Remux couldn't find \(name) on this server. Install it, or set its path in Edit Server."
        case .notAtPath(let path):
            "Remux can't run \(name) from \(path). Check the path in Edit Server."
        case .couldNotStart(let path, _):
            "Running \(path ?? name) failed."
        case .failed:
            "Running \(name) failed."
        case .unsupportedVersion(let version):
            "\(name) \(version) on this server is too old. Remux needs \(backend.minimumSupportedVersion) or later."
        }
    }

    /// A program that ran and failed is a session that ended; anything Edit Server or an update fixes leaves
    /// the backend unavailable.
    func disconnectReason(for backend: SessionBackend) -> TerminalDisconnectReason {
        let kind: TerminalDisconnectReason.Kind = switch self {
        case .failed: .remoteExit
        case .notFound, .notAtPath, .couldNotStart, .unsupportedVersion: .backendUnavailable(backend)
        }
        return TerminalDisconnectReason(kind: kind, message: message(for: backend), detail: detail)
    }
}

extension SavedServer {
    /// The path set in Edit Server for `backend`'s program; nil for Automatic.
    func executablePath(for backend: SessionBackend) -> String? {
        switch backend {
        case .tmux: tmuxExecutablePath
        case .herdr: herdrExecutablePath
        }
    }
}
