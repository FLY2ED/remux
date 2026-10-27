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
        XCTAssertEqual(feedback(.agentNeedsYou(cameWithBell: false), at: 1.5), .warning)
        XCTAssertEqual(feedback(.agentFinished(cameWithBell: false), at: 3), .success)
    }

    func testABurstOfBellsVibratesAtMostOnceATenthOfASecond() {
        let played = [0, 0.05, 0.09, 0.1, 0.15, 0.2, 0.35].filter { feedback(.bell, at: $0) != nil }
        XCTAssertEqual(played, [0, 0.1, 0.2, 0.35])
    }

    /// Banners and bells share the spacing: an agent's banner right after a bell, or a bell right after
    /// a banner, adds nothing.
    func testBannersAndBellsShareTheSpacing() {
        XCTAssertEqual(feedback(.agentNeedsYou(cameWithBell: false), at: 1), .warning)
        XCTAssertNil(feedback(.bell, at: 1.05))
        XCTAssertNil(feedback(.agentFinished(cameWithBell: false), at: 1.08))
        XCTAssertEqual(feedback(.bell, at: 1.1), .warning)
    }

    /// A bell and an agent's notification come together within a tenth of a second, in either order.
    func testABellAndANotificationComeTogetherWithinATenthOfASecond() {
        XCTAssertTrue(HapticRules.cameTogether(at(1), at(1)))
        XCTAssertTrue(HapticRules.cameTogether(at(1), at(1.09)))
        XCTAssertTrue(HapticRules.cameTogether(at(1.09), at(1)))
        XCTAssertFalse(HapticRules.cameTogether(at(1), at(1.1)))
        XCTAssertFalse(HapticRules.cameTogether(at(1.1), at(1)))
    }

    /// The bell that came with an agent's notification already vibrated, so its banner doesn't.
    func testABannerWhoseNotificationCameWithABellDoesNotVibrate() {
        XCTAssertEqual(feedback(.bell, at: 0), .warning)
        XCTAssertNil(feedback(.agentNeedsYou(cameWithBell: true), at: 1))
        XCTAssertNil(feedback(.agentFinished(cameWithBell: true), at: 2))
        XCTAssertEqual(feedback(.agentNeedsYou(cameWithBell: false), at: 3), .warning)
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
        XCTAssertNil(feedback(.agentNeedsYou(cameWithBell: false), at: 2))
        XCTAssertNil(feedback(.agentFinished(cameWithBell: false), at: 4))
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
