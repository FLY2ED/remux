import SwiftUI

/// Which agents the Agents list shows, by Herdr's names for its agent filters (`client/shell/overlays.rs`).
enum SessionAgentsFilter: CaseIterable, Hashable {
    case all
    case blocked
    case done

    var title: String {
        switch self {
        case .all: "All"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }

    func includes(_ status: TerminalAgentStatus) -> Bool {
        switch self {
        case .all: true
        case .blocked: status == .blocked
        case .done: status == .done
        }
    }
}

/// Every agent of the open Herdr sessions, by session in the Sessions list's order, each session's agents
/// in Herdr's order, as Herdr's client lists its agents by machine (`client/shell/endpoint_agents.rs`).
struct SessionAgentsProjection: Equatable {
    struct Session: Identifiable, Equatable {
        let id: SavedWorkspace.ID
        /// The server, then the session unless it is Herdr's default one, as the banner names them.
        let title: String
        let runtimeState: TerminalRuntimeState
        /// The server boot the agents' pane ids belong to.
        let bootID: String?
        let agents: [HerdrAgentPresentation.Agent]

        /// Not connected, so its agents' states may be out of date; Herdr's list dims them.
        var isStale: Bool {
            runtimeState != .connected
        }
    }

    let sessions: [Session]

    /// `agents` gives an open Herdr session's agents.
    init(
        activeSessions: [ActiveSessionSwitcherItem],
        agents: (SavedWorkspace.ID) -> HerdrAgentPresentation?
    ) {
        sessions = activeSessions.compactMap { session in
            guard let presentation = agents(session.id), !presentation.agents.isEmpty else { return nil }
            let isDefault = session.sessionName == HerdrNotificationBannerContent.defaultSessionName
            return Session(
                id: session.id,
                title: isDefault ? session.serverName : "\(session.serverName) · \(session.sessionName)",
                runtimeState: session.runtimeState,
                bootID: presentation.bootID,
                agents: presentation.agents
            )
        }
    }

    func count(_ filter: SessionAgentsFilter) -> Int {
        sessions.reduce(0) { count, session in
            count + session.agents.count(where: { filter.includes($0.state.status) })
        }
    }

    /// The sessions with agents `filter` shows, with only those agents.
    func sessions(_ filter: SessionAgentsFilter) -> [Session] {
        sessions.compactMap { session in
            let agents = session.agents.filter { filter.includes($0.state.status) }
            guard !agents.isEmpty else { return nil }
            return Session(
                id: session.id,
                title: session.title,
                runtimeState: session.runtimeState,
                bootID: session.bootID,
                agents: agents
            )
        }
    }
}

/// The Sessions sheet's Agents list: filters for every agent, those blocked and those done, then each
/// session's agents under its name. A row opens the agent's pane.
struct SessionAgentsList: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let projection: SessionAgentsProjection
    @Binding var filter: SessionAgentsFilter
    let onOpen: (SessionAgentsProjection.Session, HerdrAgentPresentation.Agent) -> Void

    var body: some View {
        let sessions = projection.sessions(filter)
        VStack(spacing: 0) {
            filterBar
            List {
                ForEach(sessions) { session in
                    Section {
                        ForEach(session.agents) { agent in
                            Button {
                                onOpen(session, agent)
                            } label: {
                                SessionAgentRow(agent: agent, session: session)
                            }
                            .buttonStyle(.plain)
                            .sessionSwitcherListRow(accessibilityIdentifier: "terminal.agents.agent")
                        }
                    } header: {
                        SessionSwitcherSectionHeader(title: session.title)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if sessions.isEmpty {
                    emptyResults
                }
            }
            .accessibilityIdentifier("terminal.agents.list")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(SessionAgentsFilter.allCases, id: \.self) { option in
                let isSelected = option == filter
                let count = projection.count(option)
                Button {
                    Haptic.selection()
                    filter = option
                } label: {
                    Text("\(option.title) \(count)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? chromeStyle.accentForeground : TerminalSelectionSheetPalette.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? chromeStyle.accent : TerminalSelectionSheetPalette.controlFill,
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityValue(count == 1 ? "1 agent" : "\(count) agents")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("terminal.agents.filter.\(option.title.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var emptyResults: some View {
        let title = switch filter {
        case .all: "No Agents"
        case .blocked: "No Agents Blocked"
        case .done: "No Agents Done"
        }
        return ContentUnavailableView {
            Label(title, systemImage: "terminal")
        } description: {
            if filter == .all {
                Text("Agents in your open Herdr sessions appear here.")
            }
        }
    }
}

/// One agent: its dot, its name over its place, and its state.
private struct SessionAgentRow: View {
    let agent: HerdrAgentPresentation.Agent
    let session: SessionAgentsProjection.Session

    var body: some View {
        HStack(spacing: 12) {
            TerminalAgentDot(status: agent.state.status, size: 10, isStale: session.isStale)

            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)

                if !agent.place.isEmpty {
                    Text(agent.place)
                        .font(.footnote)
                        .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(agent.state.word)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.isStale ? TerminalAgentStatus.unknown.color : agent.state.status.color)
                .lineLimit(1)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens its pane")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = [agent.name, agent.place, agent.state.word].filter { !$0.isEmpty }
        if session.isStale {
            parts.append(TerminalRuntimeStatusPresentation.projection(for: session.runtimeState).label)
        }
        return parts.joined(separator: ", ")
    }
}
