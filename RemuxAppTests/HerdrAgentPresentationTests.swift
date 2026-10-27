import XCTest
@testable import Remux

/// Herdr's client's own cases for its agent projection (`client/shell/endpoint_agent_state.rs` tests),
/// with the same inputs and the statuses they expect. Herdr's client hands completions over separately,
/// keyed by its connection; Remux's connection pairs them with their snapshot, so a case Herdr feeds as a
/// mismatched companion is fed here as a snapshot without completions.
final class HerdrAgentPresentationTests: XCTestCase {
    private func snapshot(
        _ status: HerdrAgentStatus,
        stateChange: UInt64,
        revision: UInt64,
        boot: String = "endpoint-boot"
    ) throws -> HerdrSnapshot {
        try decode(boot: boot, revision: revision, agents: [HerdrServerScript.snapshotAgent(
            "agent-pane",
            tab: "tab",
            status: status,
            stateChange: stateChange
        )])
    }

    private func decode(boot: String, revision: UInt64, agents: [String]) throws -> HerdrSnapshot {
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":"w1","focused_tab_id":"tab",
         "focused_pane_id":null,"workspaces":[],"tabs":[],"panes":[],"agents":[\(agents.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    private func status(after states: [(HerdrAgentStatus, UInt64)]) throws -> HerdrAgentStatus? {
        let presentation = HerdrAgentPresentation()
        for (index, state) in states.enumerated() {
            presentation.project(try snapshot(state.0, stateChange: state.1, revision: UInt64(index) + 1), completions: nil)
        }
        return presentation.statuses["agent-pane"]
    }

    func testTheFirstSnapshotIsABaselineWhateverTheServerSays() throws {
        XCTAssertEqual(try status(after: [(.done, 4)]), .idle)
    }

    func testAnAgentAppearingIdleHasNotFinishedWork() throws {
        XCTAssertEqual(try status(after: [(.unknown, 0), (.idle, 1)]), .idle)
        let presentation = HerdrAgentPresentation()
        presentation.project(try decode(boot: "endpoint-boot", revision: 1, agents: []), completions: nil)
        presentation.project(try snapshot(.idle, stateChange: 1, revision: 2), completions: nil)
        XCTAssertEqual(presentation.statuses["agent-pane"], .idle)
    }

    func testARebindOrAStartupBlockerIsNotFinishedWork() throws {
        XCTAssertEqual(try status(after: [(.idle, 4), (.unknown, 5), (.idle, 6)]), .idle)
        XCTAssertEqual(try status(after: [(.unknown, 0), (.blocked, 1), (.idle, 2)]), .idle)
    }

    /// Work this phone never saw counts as finished only when Herdr recorded it at the agent's current
    /// state change.
    func testHerdrsRecordTellsCoalescedWorkFromARebind() throws {
        for completion: UInt64? in [nil, 6] {
            let presentation = HerdrAgentPresentation()
            presentation.project(try snapshot(.idle, stateChange: 4, revision: 1), completions: nil)
            let settled = try snapshot(.idle, stateChange: 6, revision: 2)
            presentation.project(settled, completions: completion.map { ["agent-pane": $0] } ?? [:])
            XCTAssertEqual(presentation.statuses["agent-pane"], completion == nil ? .idle : .done)
            presentation.project(settled, completions: nil)
            XCTAssertEqual(presentation.statuses["agent-pane"], completion == nil ? .idle : .done)
        }
    }

    func testHerdrsRecordOverridesWorkThisPhoneSaw() throws {
        let presentation = HerdrAgentPresentation()
        presentation.project(try snapshot(.working, stateChange: 1, revision: 1), completions: nil)
        presentation.project(try snapshot(.idle, stateChange: 2, revision: 2), completions: [:])
        XCTAssertEqual(presentation.statuses["agent-pane"], .idle)
    }

    func testARecordForAnotherStateChangeDoesNotCount() throws {
        let presentation = HerdrAgentPresentation()
        presentation.project(try snapshot(.idle, stateChange: 4, revision: 1), completions: nil)
        presentation.project(try snapshot(.idle, stateChange: 6, revision: 2), completions: ["agent-pane": 5])
        XCTAssertEqual(presentation.statuses["agent-pane"], .idle)
    }

    func testANewServerBootStartsFromABaseline() throws {
        let presentation = HerdrAgentPresentation()
        presentation.project(try snapshot(.working, stateChange: 1, revision: 1, boot: "old-boot"), completions: nil)
        presentation.project(try snapshot(.idle, stateChange: 6, revision: 1), completions: ["agent-pane": 6])
        XCTAssertEqual(presentation.statuses["agent-pane"], .idle)
    }

    func testWorkThisPhoneSawFinishIsDone() throws {
        XCTAssertEqual(try status(after: [(.working, 4), (.idle, 5)]), .done)
    }

    /// Done until the pane is on screen, for this phone alone.
    func testThePaneOnScreenAcknowledgesTheCompletion() throws {
        let viewing = HerdrAgentPresentation()
        let elsewhere = HerdrAgentPresentation()
        let working = try snapshot(.working, stateChange: 4, revision: 1)
        let finished = try snapshot(.idle, stateChange: 5, revision: 2)
        viewing.project(working, completions: nil)
        viewing.project(finished, completions: nil)
        elsewhere.project(working, completions: nil)
        elsewhere.project(finished, completions: nil)

        XCTAssertFalse(viewing.acknowledge(panes: ["other-pane"]))
        XCTAssertEqual(viewing.statuses["agent-pane"], .done)
        XCTAssertTrue(viewing.acknowledge(panes: ["agent-pane"]))
        XCTAssertEqual(viewing.statuses["agent-pane"], .idle)
        XCTAssertEqual(elsewhere.statuses["agent-pane"], .done)
    }
}
