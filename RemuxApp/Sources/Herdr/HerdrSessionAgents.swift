import Foundation

/// One Herdr session's agents as the phone shows them, from its newest snapshot: each agent's state, from
/// its status by `HerdrAgentPresentation`, and its place, in the snapshot's order, which is Herdr's agent
/// list's by default (`agent_panel_sort = "spaces"`). A tab, workspace or session shows its most urgent
/// agent, as Herdr's client rolls tabs and workspaces up from the statuses it shows
/// (`client/shell/endpoint_agent_state.rs` `project_aggregate_status`).
struct HerdrSessionAgents: Equatable, Sendable {
    struct Agent: Identifiable, Equatable, Sendable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        /// As Herdr's agent list names it (`client/shell/agent_sidebar.rs` `agent_row`).
        let name: String
        /// Its workspace, then its tab when the workspace has more than one or the tab has a label of its
        /// own, as Herdr's agent list places it.
        let place: String
        let state: TerminalAgentState

        var id: String { paneID }
    }

    /// The server boot the agents' pane ids belong to.
    let bootID: String
    let agents: [Agent]

    init(_ snapshot: HerdrSnapshot, statuses: [String: HerdrAgentStatus]) {
        bootID = snapshot.bootID
        agents = snapshot.agents.map { agent in
            let status = statuses[agent.paneID] ?? agent.agentStatus
            let workspace = snapshot.workspaces.first { $0.workspaceID == agent.workspaceID }
            let tabs = snapshot.tabs.filter { $0.workspaceID == agent.workspaceID }
            let tab = tabs.first { $0.tabID == agent.tabID }.flatMap { tabs.count > 1 || $0.customLabel ? $0 : nil }
            return Agent(
                paneID: agent.paneID,
                workspaceID: agent.workspaceID,
                tabID: agent.tabID,
                name: agent.displayAgent ?? agent.name ?? agent.agent ?? agent.title ?? "agent",
                place: [workspace?.label, tab?.label].compactMap { $0 }.joined(separator: " › "),
                state: TerminalAgentState(status.terminalStatus, word: agent.label(for: status))
            )
        }
    }

    /// The session's most urgent agent, if it has any.
    var status: TerminalAgentStatus? {
        agents.lazy.map(\.state.status).max()
    }

    func status(ofWorkspace workspaceID: String) -> TerminalAgentStatus? {
        agents.lazy.filter { $0.workspaceID == workspaceID }.map(\.state.status).max()
    }

    func status(ofTab tabID: String) -> TerminalAgentStatus? {
        agents.lazy.filter { $0.tabID == tabID }.map(\.state.status).max()
    }

    func state(ofPane paneID: String) -> TerminalAgentState? {
        agents.first { $0.paneID == paneID }?.state
    }
}

extension HerdrAgentStatus {
    var terminalStatus: TerminalAgentStatus {
        switch self {
        case .unknown: .unknown
        case .idle: .idle
        case .working: .working
        case .done: .done
        case .blocked: .waiting
        }
    }
}

/// The agents of every open Herdr session, for the sheets that show them across sessions. Each session's
/// model reports its agents as they change, and this keeps the newest report of each until the session
/// closes.
@MainActor
final class HerdrAgentDirectory: ObservableObject {
    @Published private(set) var sessions: [SavedWorkspace.ID: HerdrSessionAgents] = [:]

    /// `agents` nil: the session closed.
    func update(_ agents: HerdrSessionAgents?, of workspaceID: SavedWorkspace.ID) {
        guard sessions[workspaceID] != agents else { return }
        sessions[workspaceID] = agents
    }
}
