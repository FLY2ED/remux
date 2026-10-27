import UIKit
import XCTest
@testable import Remux

/// What the user feels from Herdr's bells and banners: the notification center's alerts as `HapticRules`
/// plays them. A bell that came with an agent's notification stands for its banner, whatever rings after,
/// including while the banner waits its turn.
@MainActor
final class HerdrNotificationVibrationTests: XCTestCase {
    /// A center over one shown session with tab `t1` in front and agents waiting in panes `w1:p2` and
    /// `w1:p3` of tab `t2`, recording each vibration played.
    @MainActor
    private final class Harness {
        let center = HerdrNotificationCenter()
        var rules = HapticRules()
        var felt: [UINotificationFeedbackGenerator.FeedbackType] = []
        private let origin = HerdrNotificationPolicy.Origin(
            workspaceID: SavedWorkspace.ID(),
            sessionName: "agents",
            serverName: "mini",
            bootID: "boot",
            place: HerdrNotificationPlace(workspace: "web", tab: "review")
        )

        init() {
            let state = HerdrNotificationSessionState(
                isShown: true,
                focusedWorkspaceID: "w1",
                focusedTabID: "t1",
                agentStatuses: ["w1:p2": .blocked, "w1:p3": .blocked]
            )
            center.sessions = { _ in state }
            center.vibrate = { [unowned self] alert in
                if let feedback = rules.feedback(for: alert, at: .now) { felt.append(feedback) }
            }
        }

        func receive(_ kind: HerdrSemanticNotification.Kind, _ title: String, pane: String? = nil) throws {
            let frame = HerdrServerScript.notification(kind, title: title, tab: pane == nil ? nil : "t2", pane: pane)
            guard case .semanticNotification(let notification) = try HerdrServerMessage.decode(Array(frame.dropFirst(4)))
            else { return XCTFail("not a notification") }
            center.receive(notification, from: origin)
        }

        func waitForBanner() async throws -> HerdrNotificationPolicy.Banner {
            let deadline = ContinuousClock.now + .seconds(3)
            while center.banner == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return try XCTUnwrap(center.banner, "no banner")
        }
    }

    /// A bell and a needs-attention notification at 0 s, another bell at 0.5 s: the banner that shows at
    /// 1 s doesn't vibrate, since its own bell already did.
    func testABannerWhoseBellVibratedStaysSilentAfterALaterBell() async throws {
        let harness = Harness()
        harness.center.ringBell()
        try harness.receive(.needsAttention, "claude needs attention", pane: "w1:p2")
        try await Task.sleep(for: .milliseconds(500))
        harness.center.ringBell()

        let banner = try await harness.waitForBanner()
        XCTAssertEqual(banner.notification.title, "claude needs attention")
        XCTAssertEqual(harness.felt, [.warning, .warning])
    }

    func testABellJustAfterANotificationStandsForItsBanner() async throws {
        let harness = Harness()
        try harness.receive(.needsAttention, "claude needs attention", pane: "w1:p2")
        try await Task.sleep(for: .milliseconds(20))
        harness.center.ringBell()

        let banner = try await harness.waitForBanner()
        XCTAssertEqual(banner.notification.title, "claude needs attention")
        XCTAssertEqual(harness.felt, [.warning])
    }

    /// Two agents wait behind a banner, one whose notification came with a bell and one apart from any;
    /// after more bells, the first shows without vibrating and the second vibrates.
    func testAWaitingBannerWhoseBellVibratedStaysSilentWhenItsTurnComes() async throws {
        let harness = Harness()
        try harness.receive(.custom, "build passed")
        let custom = try XCTUnwrap(harness.center.banner)
        harness.center.ringBell()
        try harness.receive(.needsAttention, "with the bell", pane: "w1:p2")
        try await Task.sleep(for: .milliseconds(300))
        try harness.receive(.needsAttention, "apart", pane: "w1:p3")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(harness.center.banner, custom)

        harness.center.ringBell()
        try await Task.sleep(for: .milliseconds(150))
        harness.center.ringBell()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.felt, [.warning, .warning, .warning])

        harness.center.dismiss(custom.id)
        let paired = try XCTUnwrap(harness.center.banner)
        XCTAssertEqual(paired.notification.title, "with the bell")
        XCTAssertEqual(harness.felt.count, 3, "the banner whose bell vibrated vibrated again")

        harness.center.dismiss(paired.id)
        XCTAssertEqual(harness.center.banner?.notification.title, "apart")
        XCTAssertEqual(harness.felt, [.warning, .warning, .warning, .warning])
    }
}
