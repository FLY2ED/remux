import UIKit
import XCTest
@testable import Remux

/// Which vibration each alert plays, how bursts and a bell with an agent's notification come down to
/// one, and the Haptics switches.
final class HapticRulesTests: XCTestCase {
    private let start = ContinuousClock.now
    private var rules = HapticRules()

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start + .milliseconds(Int((seconds * 1000).rounded()))
    }

    private func feedback(
        _ alert: HapticAlert,
        at seconds: Double
    ) -> UINotificationFeedbackGenerator.FeedbackType? {
        rules.feedback(for: alert, at: at(seconds))
    }

    func testEachAlertPlaysItsVibration() {
        XCTAssertEqual(feedback(.bell, at: 0), .warning)
        XCTAssertEqual(feedback(.agentNeedsYou(arrived: at(0.5)), at: 1.5), .warning)
        XCTAssertEqual(feedback(.agentFinished(arrived: at(2)), at: 3), .success)
    }

    func testABurstOfBellsVibratesAtMostOnceATenthOfASecond() {
        let played = [0, 0.05, 0.09, 0.1, 0.15, 0.2, 0.35].filter { feedback(.bell, at: $0) != nil }
        XCTAssertEqual(played, [0, 0.1, 0.2, 0.35])
    }

    /// Banners and bells share the spacing: an agent's banner right after a bell, or a bell right after
    /// a banner, adds nothing.
    func testBannersAndBellsShareTheSpacing() {
        XCTAssertEqual(feedback(.agentNeedsYou(arrived: at(0)), at: 1), .warning)
        XCTAssertNil(feedback(.bell, at: 1.05))
        XCTAssertNil(feedback(.agentFinished(arrived: at(0.5)), at: 1.08))
        XCTAssertEqual(feedback(.bell, at: 1.1), .warning)
    }

    /// A bell that came with an agent's notification already vibrated, so the banner that shows a second
    /// later doesn't, whichever came first; a bell well apart from the notification doesn't count.
    func testABellWithAnAgentsNotificationVibratesOnce() {
        XCTAssertEqual(feedback(.bell, at: 0.05), .warning)
        XCTAssertNil(feedback(.agentNeedsYou(arrived: at(0)), at: 1))

        XCTAssertEqual(feedback(.bell, at: 2), .warning)
        XCTAssertNil(feedback(.agentFinished(arrived: at(2.06)), at: 3.06))

        XCTAssertEqual(feedback(.bell, at: 4), .warning)
        XCTAssertEqual(feedback(.agentNeedsYou(arrived: at(4.5)), at: 5.5), .warning)
    }

    func testBothSwitchesAreOnByDefault() {
        XCTAssertTrue(rules.allows(.bellsAndAgents))
        XCTAssertTrue(rules.allows(.keysAndButtons))
    }

    func testTurningOffBellsAndAgentsSilencesEveryAlertAndKeepsKeys() {
        var settings = TerminalSettings.default
        settings.vibratesForBellsAndAgents = false
        rules.follow(settings)

        XCTAssertNil(feedback(.bell, at: 0))
        XCTAssertNil(feedback(.agentNeedsYou(arrived: at(1)), at: 2))
        XCTAssertNil(feedback(.agentFinished(arrived: at(3)), at: 4))
        XCTAssertFalse(rules.allows(.bellsAndAgents))
        XCTAssertTrue(rules.allows(.keysAndButtons))

        settings.vibratesForBellsAndAgents = true
        rules.follow(settings)
        XCTAssertEqual(feedback(.bell, at: 5), .warning)
    }

    func testTurningOffKeysAndButtonsKeepsAlerts() {
        var settings = TerminalSettings.default
        settings.vibratesForKeysAndButtons = false
        rules.follow(settings)

        XCTAssertFalse(rules.allows(.keysAndButtons))
        XCTAssertTrue(rules.allows(.bellsAndAgents))
        XCTAssertEqual(feedback(.bell, at: 0), .warning)
    }
}
