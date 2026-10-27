import Foundation

struct GhosttyTopLevelSurface: Identifiable, Equatable {
    let id: UUID
    let name: String
    let leafIDs: [UUID]
    let focusedLeafID: UUID?
    /// Its most urgent agent, when the backend reports agents.
    let agentStatus: TerminalAgentStatus?

    init(
        id: UUID = UUID(),
        name: String = "",
        leafIDs: [UUID],
        focusedLeafID: UUID? = nil,
        agentStatus: TerminalAgentStatus? = nil
    ) {
        self.id = id
        self.name = name
        self.leafIDs = leafIDs
        self.focusedLeafID = focusedLeafID.flatMap { leafIDs.contains($0) ? $0 : nil }
        self.agentStatus = agentStatus
    }

    var resolvedFocusedLeafID: UUID? {
        focusedLeafID ?? leafIDs.first
    }
}
