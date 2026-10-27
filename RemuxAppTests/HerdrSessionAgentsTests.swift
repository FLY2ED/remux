import SwiftUI
import XCTest
@testable import Remux

/// A Herdr snapshot as JSON, with workspaces and tabs of its own, decoded as Remux decodes Herdr's.
enum HerdrSnapshotJSON {
    struct Tab {
        let id: String
        let workspace: String
        let label: String
        var customLabel = false
        /// What Herdr's server rolls up for the tab, which the phone's own statuses replace.
        var agentStatus: HerdrAgentStatus = .unknown
    }

    static func snapshot(
        boot: String = "boot",
        workspaces: [(id: String, label: String)],
        tabs: [Tab],
        agents: [String]
    ) throws -> HerdrSnapshot {
        let workspaceEntries = workspaces.enumerated().map { index, workspace in
            """
            {"workspace_id":"\(workspace.id)","active_tab_id":"\(tabs.first { $0.workspace == workspace.id }?.id ?? "")",
             "number":\(index + 1),"label":"\(workspace.label)","custom_label":true,"focused":\(index == 0),
             "agent_status":"unknown"}
            """
        }
        let tabEntries = tabs.enumerated().map { index, tab in
            """
            {"tab_id":"\(tab.id)","workspace_id":"\(tab.workspace)","number":\(index + 1),"label":"\(tab.label)",
             "custom_label":\(tab.customLabel),"zoomed":false,"focused":\(index == 0),
             "agent_status":"\(tab.agentStatus.rawValue)"}
            """
        }
        let json = """
        {"boot_id":"\(boot)","revision":1,"focused_workspace_id":"\(workspaces.first?.id ?? "")",
         "focused_tab_id":"\(tabs.first?.id ?? "")","focused_pane_id":null,
         "workspaces":[\(workspaceEntries.joined(separator: ","))],"tabs":[\(tabEntries.joined(separator: ","))],
         "panes":[],"agents":[\(agents.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    /// Workspace `api` (`w1`) with tabs `agents` (`t1`) and `auth` (`t2`), and workspace `web` (`w2`) with
    /// its one tab `main` (`t3`).
    static func twoWorkspaces(agents: [String], webTabLabelled: Bool = false) throws -> HerdrSnapshot {
        try snapshot(
            workspaces: [("w1", "api"), ("w2", "web")],
            tabs: [
                Tab(id: "t1", workspace: "w1", label: "agents"),
                Tab(id: "t2", workspace: "w1", label: "auth"),
                Tab(id: "t3", workspace: "w2", label: webTabLabelled ? "dev" : "1", customLabel: webTabLabelled),
            ],
            agents: agents
        )
    }
}

final class HerdrSessionAgentsTests: XCTestCase {
    private func agent(
        _ paneID: String,
        workspace: String = "w1",
        tab: String = "t1",
        status: HerdrAgentStatus = .working,
        stateLabels: [(state: String, word: String)] = []
    ) -> String {
        HerdrServerScript.snapshotAgent(
            paneID,
            agent: "claude",
            workspace: workspace,
            tab: tab,
            status: status,
            stateLabels: stateLabels
        )
    }

    /// Herdr's order of how much each status needs the user (`client/shell.rs` `status_priority`):
    /// blocked, done, working, idle, unknown.
    private static let herdrOrder: [HerdrAgentStatus] = [.blocked, .done, .working, .idle, .unknown]

    /// A tab, a workspace and the session show their most urgent agent by Herdr's order, from the statuses
    /// the phone shows; a tab or workspace without agents shows none.
    func testEachPlaceShowsItsMostUrgentAgentInHerdrsOrder() throws {
        let snapshot = try HerdrSnapshotJSON.twoWorkspaces(agents: [
            agent("w1:p1"),
            agent("w1:p2"),
            agent("w2:p1", workspace: "w2", tab: "t3"),
        ])
        for (index, urgent) in Self.herdrOrder.enumerated() {
            for calmer in Self.herdrOrder[index...] {
                let agents = HerdrSessionAgents(snapshot, statuses: ["w1:p1": calmer, "w1:p2": urgent, "w2:p1": calmer])
                XCTAssertEqual(agents.status(ofTab: "t1"), urgent.terminalStatus, "\(urgent) over \(calmer)")
                XCTAssertEqual(agents.status(ofWorkspace: "w1"), urgent.terminalStatus, "\(urgent) over \(calmer)")
                XCTAssertEqual(agents.status, urgent.terminalStatus, "\(urgent) over \(calmer)")
                XCTAssertEqual(agents.status(ofTab: "t3"), calmer.terminalStatus)
            }
        }
        let agents = HerdrSessionAgents(snapshot, statuses: [:])
        XCTAssertNil(agents.status(ofTab: "t2"))
        XCTAssertNil(HerdrSessionAgents(try HerdrSnapshotJSON.twoWorkspaces(agents: []), statuses: [:]).status)
    }

    /// The phone's statuses decide, done until seen on this phone, as Herdr's client rolls its own up:
    /// not the server's roll-up, nor the server's status for the agent.
    func testThePhonesStatusesDecideNotTheServers() throws {
        let snapshot = try HerdrSnapshotJSON.snapshot(
            workspaces: [("w1", "api")],
            tabs: [HerdrSnapshotJSON.Tab(id: "t1", workspace: "w1", label: "agents", agentStatus: .blocked)],
            agents: [agent("w1:p1", status: .idle)]
        )
        let finished = HerdrSessionAgents(snapshot, statuses: ["w1:p1": .done])
        XCTAssertEqual(finished.status(ofTab: "t1"), .done)
        XCTAssertEqual(finished.state(ofPane: "w1:p1"), TerminalAgentState(.done))

        let seen = HerdrSessionAgents(snapshot, statuses: ["w1:p1": .idle])
        XCTAssertEqual(seen.status(ofTab: "t1"), .idle)
    }

    /// An agent is named as Herdr's agent list names it: its display name, else its name, else its kind,
    /// else its title; it is placed in its workspace, then its tab when the workspace has more than one or
    /// the tab has a label of its own.
    func testAnAgentIsNamedAndPlacedAsHerdrsAgentListDoes() throws {
        func named(_ name: String?, displayAgent: String?, agent: String?, title: String?) throws -> String? {
            let snapshot = try HerdrSnapshotJSON.twoWorkspaces(agents: [HerdrServerScript.snapshotAgent(
                "w1:p1",
                name: name,
                title: title,
                agent: agent,
                displayAgent: displayAgent
            )])
            return HerdrSessionAgents(snapshot, statuses: [:]).agents.first?.name
        }
        XCTAssertEqual(try named("fixer", displayAgent: "Claude Code", agent: "claude", title: "Fix tests"), "Claude Code")
        XCTAssertEqual(try named("fixer", displayAgent: nil, agent: "claude", title: "Fix tests"), "fixer")
        XCTAssertEqual(try named(nil, displayAgent: nil, agent: "claude", title: "Fix tests"), "claude")
        XCTAssertEqual(try named(nil, displayAgent: nil, agent: nil, title: "Fix tests"), "Fix tests")
        XCTAssertEqual(try named(nil, displayAgent: nil, agent: nil, title: nil), "agent")

        let places = { (labelled: Bool) in
            HerdrSessionAgents(
                try HerdrSnapshotJSON.twoWorkspaces(
                    agents: [self.agent("w1:p1", tab: "t2"), self.agent("w2:p1", workspace: "w2", tab: "t3")],
                    webTabLabelled: labelled
                ),
                statuses: [:]
            ).agents.map(\.place)
        }
        XCTAssertEqual(try places(false), ["api › auth", "web"])
        XCTAssertEqual(try places(true), ["api › auth", "web › dev"])
    }

    /// Each state takes Herdr's colour from the themes Herdr pairs by default: Catppuccin Mocha in dark
    /// appearance and Latte in light (`app/state.rs` `catppuccin`, `catppuccin_latte`).
    func testStatesTakeHerdrsColoursForTheAppearance() {
        let herdr: [(TerminalAgentStatus, mocha: [Int], latte: [Int])] = [
            (.working, [249, 226, 175], [223, 142, 29]),
            (.waiting, [243, 139, 168], [210, 15, 57]),
            (.done, [148, 226, 213], [23, 146, 153]),
            (.idle, [166, 227, 161], [64, 160, 43]),
            (.unknown, [108, 112, 134], [156, 160, 176]),
        ]
        func rgb(_ status: TerminalAgentStatus, _ style: UIUserInterfaceStyle) -> [Int] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(status.color)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue].map { Int(($0 * 255).rounded()) }
        }
        for (status, mocha, latte) in herdr {
            XCTAssertEqual(rgb(status, .dark), mocha, "\(status)")
            XCTAssertEqual(rgb(status, .light), latte, "\(status)")
        }
    }

    /// An agent's state is in Herdr's words, with one word for an agent that needs the user, unless the
    /// agent's own labels give the state a word, as Herdr's client words it.
    func testAnAgentsStateIsInHerdrsWordsUnlessItsLabelsGiveOne() throws {
        func state(_ status: HerdrAgentStatus, labels: [(state: String, word: String)] = []) throws -> TerminalAgentState? {
            let snapshot = try HerdrSnapshotJSON.twoWorkspaces(agents: [agent("w1:p1", status: status, stateLabels: labels)])
            return HerdrSessionAgents(snapshot, statuses: ["w1:p1": status]).state(ofPane: "w1:p1")
        }
        XCTAssertEqual(try state(.blocked), TerminalAgentState(.waiting, word: "waiting"))
        XCTAssertEqual(try state(.done), TerminalAgentState(.done, word: "done"))
        XCTAssertEqual(try state(.working), TerminalAgentState(.working, word: "working"))
        XCTAssertEqual(try state(.idle), TerminalAgentState(.idle, word: "idle"))
        XCTAssertEqual(try state(.unknown), TerminalAgentState(.unknown, word: "idle"))

        let labels = [(state: "blocked", word: "needs review"), (state: "done", word: "ready")]
        XCTAssertEqual(try state(.blocked, labels: labels), TerminalAgentState(.waiting, word: "needs review"))
        XCTAssertEqual(try state(.done, labels: labels), TerminalAgentState(.done, word: "ready"))
        XCTAssertEqual(try state(.working, labels: labels), TerminalAgentState(.working, word: "working"))
    }
}
