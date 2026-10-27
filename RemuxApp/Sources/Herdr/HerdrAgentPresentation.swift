import Foundation

/// Each agent's status as this phone shows it, by Herdr's client's rules (`endpoint_agent_state.rs`).
///
/// Herdr's `done` only says no client in front has looked at the pane, so each client decides for
/// itself: an agent that is idle after finishing work reads as done until its pane is on this phone's
/// screen. Work counts as finished when Herdr recorded a completion at the agent's current state change,
/// or, for a snapshot sent without that record, when this phone saw the agent working. Completions from
/// before the phone first heard from a server boot count as seen.
struct HerdrAgentPresentation {
    private var bootID: String?
    /// The newest state change of each agent that was on screen.
    private var acknowledged: [String: UInt64] = [:]
    /// The state change at which each agent finished work it hasn't started again since.
    private var completed: [String: UInt64] = [:]
    private var working: Set<String> = []
    private var agents: [HerdrSnapshot.Agent] = []

    /// Each agent pane's status, from the newest snapshot.
    private(set) var statuses: [String: HerdrAgentStatus] = [:]

    mutating func project(_ snapshot: HerdrSnapshot, completions: [String: UInt64]?) {
        if bootID != snapshot.bootID {
            bootID = snapshot.bootID
            acknowledged = Dictionary(snapshot.agents.map { ($0.paneID, $0.stateChangeSeq) }) { $1 }
            completed.removeAll()
            working.removeAll()
        }
        let paneIDs = Set(snapshot.agents.map(\.paneID))
        acknowledged = acknowledged.filter { paneIDs.contains($0.key) }
        completed = completed.filter { paneIDs.contains($0.key) }
        working.formIntersection(paneIDs)
        for agent in snapshot.agents {
            let paneID = agent.paneID
            switch agent.agentStatus {
            case .working:
                working.insert(paneID)
                completed[paneID] = nil
            case .blocked:
                completed[paneID] = nil
            case .idle, .done:
                let observedWork = working.remove(paneID) != nil
                let finished = completions.map { $0[paneID] == agent.stateChangeSeq }
                    ?? (observedWork || completed[paneID] == agent.stateChangeSeq)
                completed[paneID] = finished ? agent.stateChangeSeq : nil
            case .unknown:
                working.remove(paneID)
                completed[paneID] = nil
            }
        }
        agents = snapshot.agents
        updateStatuses()
    }

    /// The panes on this phone's screen: their agents' current states count as seen. Returns whether a
    /// status changed.
    @discardableResult
    mutating func acknowledge(panes paneIDs: Set<String>) -> Bool {
        var changed = false
        for agent in agents where paneIDs.contains(agent.paneID) {
            if acknowledged[agent.paneID, default: 0] < agent.stateChangeSeq {
                acknowledged[agent.paneID] = agent.stateChangeSeq
                changed = true
            }
        }
        if changed { updateStatuses() }
        return changed
    }

    private mutating func updateStatuses() {
        statuses = Dictionary(agents.map { ($0.paneID, status(of: $0)) }) { $1 }
    }

    private func status(of agent: HerdrSnapshot.Agent) -> HerdrAgentStatus {
        switch agent.agentStatus {
        case .idle, .done:
            guard let completion = completed[agent.paneID],
                  acknowledged[agent.paneID].map({ $0 < completion }) ?? true
            else { return .idle }
            return .done
        case let status:
            return status
        }
    }
}
