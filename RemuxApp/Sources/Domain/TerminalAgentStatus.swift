import Foundation

/// An agent's state as Remux shows it, from what the session's backend reports. The cases are in Herdr's
/// order of how much each needs the user (`client/shell.rs` `status_priority`), so the greatest of a group
/// of agents is the one the group shows.
enum TerminalAgentStatus: Int, Comparable, Sendable {
    /// Running, before its state is known.
    case unknown
    /// Ready for a new task, with any finished work already seen on this phone.
    case idle
    case working
    /// Finished work no one has looked at on this phone yet.
    case done
    /// Needs the user: a question, or a permission to grant.
    case blocked

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Herdr's words for the states (`client/shell/agent_sidebar.rs` `sidebar_status_text`).
    var word: String {
        switch self {
        case .unknown, .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .blocked: "blocked"
        }
    }
}

/// One agent's state on a tile or a row: its status, and the word for it, which the agent's own labels
/// can give.
struct TerminalAgentState: Equatable, Sendable {
    let status: TerminalAgentStatus
    let word: String

    init(_ status: TerminalAgentStatus, word: String? = nil) {
        self.status = status
        self.word = word ?? status.word
    }
}
