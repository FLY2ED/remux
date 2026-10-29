import XCTest
@testable import Remux

/// A window sheet's row: how it shows its most urgent agent, and what VoiceOver reads for it.
final class GhosttyWindowRowListTests: XCTestCase {
    private typealias Window = GhosttyWindowSelectionSheetRenderProjection.Window

    private func window(
        _ status: TerminalAgentStatus?,
        index: Int = 2,
        paneCount: Int = 2,
        isSelected: Bool = false,
        name: String? = "review"
    ) -> Window {
        Window(
            id: UUID(),
            displayName: name ?? "\(index)",
            displayIndex: index,
            totalCount: 3,
            paneCount: paneCount,
            isSelected: isSelected,
            focusedPreviewPaneID: nil,
            agentStatus: status,
            contents: .init(name: name, programs: [.agent("codex"), .terminal], activity: "Fix the tests")
        )
    }

    /// Work turns a spinner; a blocked, done or idle agent is its dot on the front mark; a tab without
    /// agents, or whose agents' state isn't known yet, shows neither.
    func testARowShowsWorkAsASpinnerAndOtherStatesAsADot() {
        XCTAssertEqual(
            [.working, .blocked, .done, .idle, .unknown, nil].map { window($0).rowAgentMark },
            [.spinner, .dot(.blocked), .dot(.done), .dot(.idle), nil, nil]
        )
    }

    /// VoiceOver reads the tab's place, its name when the user gave it one, its panes, its agent's state
    /// as the row shows one, and whether it is on screen; what it is doing is the row's value.
    func testVoiceOverReadsARowsPlaceNamePanesAndState() {
        XCTAssertEqual(
            window(.blocked, isSelected: true).rowAccessibilityLabel(topLevelNoun: .tab),
            "Tab 2 of 3, review, 2 panes, agent blocked, active"
        )
        XCTAssertEqual(
            window(.working, index: 1, paneCount: 1, name: nil).rowAccessibilityLabel(topLevelNoun: .tab),
            "Tab 1 of 3, 1 pane, agent working"
        )
        XCTAssertEqual(window(.unknown).rowAccessibilityLabel(topLevelNoun: .tab), "Tab 2 of 3, review, 2 panes")
        XCTAssertNil(window(nil, name: nil).rowName)
    }
}
