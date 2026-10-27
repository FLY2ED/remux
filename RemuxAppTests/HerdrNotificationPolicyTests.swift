import UIKit
import XCTest
@testable import Remux

/// Herdr's client's notification rules, with Herdr's own cases (`client/shell/notifications.rs` tests)
/// and the times, delay and checks of `notification_policy.rs`.
final class HerdrNotificationPolicyTests: XCTestCase {
    private let start = ContinuousClock.now
    private let agents = SavedWorkspace.ID()
    private let other = SavedWorkspace.ID()
    private var policy = HerdrNotificationPolicy()
    private var sessions: [SavedWorkspace.ID: HerdrNotificationSessionState] = [:]

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start + .milliseconds(Int(seconds * 1000))
    }

    private func origin(_ workspaceID: SavedWorkspace.ID) -> HerdrNotificationPolicy.Origin {
        HerdrNotificationPolicy.Origin(
            workspaceID: workspaceID,
            sessionName: workspaceID == agents ? "agents" : "other",
            serverName: "mini",
            bootID: "boot",
            place: HerdrNotificationPlace(workspace: "web", tab: "review")
        )
    }

    private func receive(
        _ kind: HerdrSemanticNotification.Kind,
        _ title: String,
        pane: String? = nil,
        tab: String? = nil,
        workspace: String? = nil,
        from workspaceID: SavedWorkspace.ID? = nil,
        at seconds: Double
    ) throws {
        let frame = HerdrServerScript.notification(kind, title: title, workspace: workspace, tab: tab, pane: pane)
        guard case .semanticNotification(let notification) = try HerdrServerMessage.decode(Array(frame.dropFirst(4)))
        else { return XCTFail("not a notification") }
        policy.receive(notification, from: origin(workspaceID ?? agents), at: at(seconds)) { self.sessions[$0] }
    }

    private func advance(to seconds: Double) {
        policy.advance(to: at(seconds)) { sessions[$0] }
    }

    private var shown: String? { policy.visible?.banner.notification.title }

    private func session(
        shown: Bool = false,
        tab: String = "t1",
        workspace: String = "w1",
        _ statuses: [String: HerdrAgentStatus] = [:]
    ) -> HerdrNotificationSessionState {
        HerdrNotificationSessionState(isShown: shown, focusedWorkspaceID: workspace, focusedTabID: tab, agentStatuses: statuses)
    }

    // MARK: - Showing one at a time

    func testNotificationsShowOneAtATimeInTheOrderTheyCame() throws {
        try receive(.custom, "first", pane: "first", at: 0)
        try receive(.custom, "second", pane: "second", at: 0)
        XCTAssertEqual(shown, "first")

        advance(to: 5)
        XCTAssertEqual(shown, "second")
        advance(to: 10)
        XCTAssertNil(shown)
        XCTAssertNil(policy.nextDeadline)
    }

    func testEachKindStaysOnScreenForHerdrsTime() {
        XCTAssertEqual(HerdrNotificationPolicy.displayTime(of: .needsAttention), .seconds(8))
        XCTAssertEqual(HerdrNotificationPolicy.displayTime(of: .finished), .seconds(5))
        XCTAssertEqual(HerdrNotificationPolicy.displayTime(of: .updateInstalled), .seconds(3))
        XCTAssertEqual(HerdrNotificationPolicy.displayTime(of: .custom), .seconds(5))
    }

    func testAtMostEightWaitAndTheOldestGoesFirst() throws {
        for index in 0...9 {
            try receive(.custom, "n\(index)", at: 0)
        }
        XCTAssertEqual(shown, "n0")
        var titles: [String] = []
        for step in 1...9 {
            advance(to: Double(step) * 5)
            shown.map { titles.append($0) }
        }
        XCTAssertEqual(titles, (2...9).map { "n\($0)" })
    }

    /// A newer notification for a pane replaces the one on screen, waiting or due.
    func testANewerNotificationForAPaneReplacesItsEarlierOne() throws {
        sessions[agents] = session(["p1": .blocked, "p2": .blocked])
        try receive(.custom, "p1 first", pane: "p1", at: 0)
        try receive(.custom, "p2", pane: "p2", at: 0)
        try receive(.custom, "p2 again", pane: "p2", at: 1)
        XCTAssertEqual(shown, "p1 first")
        try receive(.custom, "p1 again", pane: "p1", at: 2)
        XCTAssertEqual(shown, "p2 again")
        advance(to: 7)
        XCTAssertEqual(shown, "p1 again")

        try receive(.custom, "same pane, other session", pane: "p1", from: other, at: 8)
        XCTAssertEqual(shown, "p1 again")
    }

    func testTheBannerOnScreenGoesWhenDismissedAndTheNextShows() throws {
        try receive(.custom, "first", at: 0)
        try receive(.custom, "second", at: 0)
        let first = try XCTUnwrap(policy.visible?.banner)
        policy.dismiss(first.id, at: at(1)) { self.sessions[$0] }
        XCTAssertEqual(shown, "second")
        policy.dismiss(first.id, at: at(2)) { self.sessions[$0] }
        XCTAssertEqual(shown, "second", "dismissing a banner no longer on screen took another")
        XCTAssertEqual(policy.visible?.until, at(6))
    }

    /// Herdr's case: retiring one machine keeps another machine's notifications.
    func testRetiringASessionKeepsTheOthersNotifications() throws {
        try receive(.custom, "agents", at: 0)
        try receive(.custom, "other", from: other, at: 0)
        try receive(.custom, "agents later", at: 0)
        policy.retire(agents, at: at(1)) { self.sessions[$0] }
        XCTAssertEqual(shown, "other")
        advance(to: 6)
        XCTAssertNil(shown)
    }

    // MARK: - Agent notifications

    /// An agent's notification waits Herdr's default delay, then shows if the agent still needs it.
    func testAnAgentsNotificationWaitsTheDelayAndShowsIfStillTrue() throws {
        sessions[agents] = session(["p2": .blocked])
        try receive(.needsAttention, "claude needs attention", pane: "p2", tab: "t2", at: 0)
        XCTAssertNil(shown)
        XCTAssertEqual(policy.nextDeadline, at(1))
        advance(to: 1)
        XCTAssertEqual(shown, "claude needs attention")
        XCTAssertEqual(policy.visible?.until, at(9))
    }

    func testAnAgentThatMovedOnShowsNothing() throws {
        sessions[agents] = session(["p2": .blocked, "p3": .working])
        try receive(.needsAttention, "attention", pane: "p2", tab: "t2", at: 0)
        try receive(.finished, "finished", pane: "p3", tab: "t2", at: 0)
        sessions[agents] = session(["p2": .working, "p3": .idle])
        advance(to: 1)
        XCTAssertNil(shown)
        XCTAssertNil(policy.nextDeadline)
    }

    /// Herdr's word that an agent finished is a hint: it shows only while the agent reads as done, and a
    /// finished notification for no pane never shows.
    func testAFinishedAgentShowsOnlyWhileDone() throws {
        sessions[agents] = session(["p2": .working])
        try receive(.finished, "done", pane: "p2", tab: "t2", at: 0)
        sessions[agents] = session(["p2": .done])
        advance(to: 1)
        XCTAssertEqual(shown, "done")

        try receive(.finished, "no pane", at: 2)
        advance(to: 3)
        XCTAssertEqual(shown, "done")
        advance(to: 6)
        XCTAssertNil(shown)
        XCTAssertNil(policy.nextDeadline)
    }

    /// Without the delay a finished agent still reading as working would get a moment for the snapshot
    /// that says otherwise; the delay uses that moment up, as in Herdr's client with its default delay.
    func testAFinishedAgentStillWorkingWhenDueShowsNothing() throws {
        sessions[agents] = session(["p2": .working])
        try receive(.finished, "done", pane: "p2", tab: "t2", at: 0)
        advance(to: 1)
        XCTAssertNil(shown)
        XCTAssertNil(policy.nextDeadline)
    }

    func testAnAgentNotSeenYetGetsNoBanner() throws {
        try receive(.needsAttention, "attention", pane: "p2", tab: "t2", at: 0)
        advance(to: 1)
        XCTAssertNil(shown)
    }

    func testCustomNotificationsShowAtOnceAndAnUpdateAfterTheDelay() throws {
        try receive(.updateInstalled, "updated", at: 0)
        XCTAssertNil(shown)
        try receive(.custom, "custom", at: 0.5)
        XCTAssertEqual(shown, "custom")
        advance(to: 1)
        XCTAssertEqual(shown, "custom")
        advance(to: 5.5)
        XCTAssertEqual(shown, "updated")
        XCTAssertEqual(policy.visible?.until, at(8.5))
    }

    // MARK: - The tab on screen

    /// Nothing shows for the tab on screen, or with no tab for the workspace on screen; another tab, a
    /// session not on screen, or a notification about no place shows.
    func testNothingShowsForTheTabOnScreen() throws {
        sessions[agents] = session(shown: true, tab: "t1", ["p1": .blocked, "p2": .blocked])
        sessions[other] = session(shown: false, tab: "t1", ["p1": .blocked])
        try receive(.needsAttention, "this tab", pane: "p1", tab: "t1", at: 0)
        try receive(.needsAttention, "this workspace", pane: "p2", workspace: "w1", at: 0)
        try receive(.custom, "no place", at: 0)
        advance(to: 1)
        XCTAssertEqual(shown, "no place")
        advance(to: 6)
        XCTAssertNil(shown)

        try receive(.needsAttention, "other tab", pane: "p2", tab: "t2", at: 10)
        try receive(.needsAttention, "other session", pane: "p1", tab: "t1", from: other, at: 10)
        advance(to: 11)
        XCTAssertEqual(shown, "other tab")
        advance(to: 19)
        XCTAssertEqual(shown, "other session")
    }

    // MARK: - Waiting behind the banner on screen

    /// A banner on screen until 5 s, and waiting behind it the given agent notifications, about panes
    /// `p2`, `p3` and so on in tab `t2`, all still true when they fall due at 1 s.
    private func waitBehindABanner(_ notifications: [(HerdrSemanticNotification.Kind, String)]) throws {
        try receive(.custom, "on screen", at: 0)
        for (index, (kind, title)) in notifications.enumerated() {
            try receive(kind, title, pane: "p\(index + 2)", tab: "t2", at: 0)
        }
        advance(to: 1)
        XCTAssertEqual(shown, "on screen")
    }

    func testAWaitingBannerWhoseAgentIsNoLongerWaitingIsDropped() throws {
        sessions[agents] = session(["p2": .blocked])
        try waitBehindABanner([(.needsAttention, "attention")])
        sessions[agents] = session(["p2": .working])
        advance(to: 5)
        XCTAssertNil(shown)
        XCTAssertNil(policy.nextDeadline)
    }

    func testAWaitingBannerForTheTabNowOnScreenIsDropped() throws {
        sessions[agents] = session(["p2": .blocked])
        try waitBehindABanner([(.needsAttention, "attention")])
        sessions[agents] = session(shown: true, tab: "t2", ["p2": .blocked])
        advance(to: 5)
        XCTAssertNil(shown)
    }

    /// A finished agent that reads as working again by the time its turn comes has resumed.
    func testAWaitingFinishedBannerWhoseAgentWorksAgainIsDropped() throws {
        sessions[agents] = session(["p2": .done])
        try waitBehindABanner([(.finished, "done")])
        sessions[agents] = session(["p2": .working])
        advance(to: 5)
        XCTAssertNil(shown)
        XCTAssertNil(policy.nextDeadline)
    }

    func testTheFirstWaitingBannerStillTrueShows() throws {
        sessions[agents] = session(["p2": .blocked, "p3": .blocked])
        try waitBehindABanner([(.needsAttention, "stale"), (.needsAttention, "still waiting")])
        sessions[agents] = session(["p2": .working, "p3": .blocked])
        advance(to: 5)
        XCTAssertEqual(shown, "still waiting")
        XCTAssertEqual(policy.visible?.until, at(13))
    }

    // MARK: - Bells

    /// A notification is paired with a bell that rang up to a tenth of a second before or after it came,
    /// and stays paired whatever rings later; one apart from any bell isn't.
    func testANotificationThatCameWithABellStaysPairedWithIt() throws {
        sessions[agents] = session(["p2": .blocked, "p3": .blocked, "p4": .done])
        policy.ringBell(at: at(0))
        try receive(.needsAttention, "after a bell", pane: "p2", tab: "t2", at: 0.05)
        try receive(.needsAttention, "apart", pane: "p3", tab: "t2", at: 0.5)
        try receive(.finished, "before a bell", pane: "p4", tab: "t2", at: 0.7)
        policy.ringBell(at: at(0.75))
        policy.ringBell(at: at(0.95))

        var shownBanners: [(String, Bool)] = []
        for seconds in [1.05, 1.5, 1.7] {
            advance(to: seconds)
            let banner = try XCTUnwrap(policy.visible?.banner)
            shownBanners.append((banner.notification.title, banner.cameWithBell))
            policy.dismiss(banner.id, at: at(seconds)) { self.sessions[$0] }
        }
        XCTAssertEqual(shownBanners.map { $0.0 }, ["after a bell", "apart", "before a bell"])
        XCTAssertEqual(shownBanners.map { $0.1 }, [true, false, true])
    }
}

/// A banner vibrates when it shows, by its kind, including one whose turn comes after waiting; nothing
/// vibrates on a notification's arrival or when no agent's banner shows. A bell vibrates at once, and one
/// that came with an agent's notification stands for its banner, whatever rings after.
@MainActor
final class HerdrNotificationCenterTests: XCTestCase {
    /// A center over one shown session with tab `t1` in front, on a clock the test moves. It records each
    /// alert, and each vibration `HapticRules` plays for them.
    @MainActor
    private final class Harness {
        let center: HerdrNotificationCenter
        var state = HerdrNotificationSessionState(
            isShown: true,
            focusedWorkspaceID: "w1",
            focusedTabID: "t1",
            agentStatuses: [:]
        )
        var vibrations: [HapticAlert] = []
        var felt: [UINotificationFeedbackGenerator.FeedbackType] = []
        private let clock = ManualClock()
        private var rules = HapticRules()
        private let origin = HerdrNotificationPolicy.Origin(
            workspaceID: SavedWorkspace.ID(),
            sessionName: "agents",
            serverName: "mini",
            bootID: "boot",
            place: HerdrNotificationPlace(workspace: "web", tab: "review")
        )

        init() {
            center = HerdrNotificationCenter(clock: clock)
            center.sessions = { [unowned self] _ in state }
            center.vibrate = { [unowned self] alert in
                vibrations.append(alert)
                if let feedback = rules.feedback(for: alert, at: clock.now) { felt.append(feedback) }
            }
        }

        func receive(
            _ kind: HerdrSemanticNotification.Kind,
            _ title: String,
            pane: String? = nil,
            tab: String? = nil
        ) throws {
            let frame = HerdrServerScript.notification(kind, title: title, tab: tab, pane: pane)
            guard case .semanticNotification(let notification) = try HerdrServerMessage.decode(Array(frame.dropFirst(4)))
            else { return XCTFail("not a notification") }
            center.receive(notification, from: origin)
        }

        /// Moves the clock on by `duration`, then waits until the center's timer has handled everything
        /// that fell due by then.
        func pass(_ duration: Duration) async throws {
            clock.advance(by: duration)
            let giveUp = ContinuousClock.now + .seconds(5)
            while let due = center.nextDeadline, due <= clock.now {
                guard ContinuousClock.now < giveUp else { return XCTFail("the center didn't handle what fell due") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        var shownTitle: String? { center.banner?.notification.title }
    }

    func testAnAgentsBannerVibratesWhenItShowsAndWhenItsTurnComes() async throws {
        let harness = Harness()
        harness.state.agentStatuses = ["w1:p2": .blocked, "w1:p3": .done]
        try harness.receive(.needsAttention, "claude needs attention", pane: "w1:p2", tab: "t2")
        try harness.receive(.finished, "codex finished", pane: "w1:p3", tab: "t2")
        XCTAssertEqual(harness.vibrations, [], "a notification vibrated on arrival")

        try await harness.pass(HerdrNotificationPolicy.delay)
        let attention = try XCTUnwrap(harness.center.banner)
        XCTAssertEqual(attention.notification.title, "claude needs attention")
        XCTAssertEqual(harness.vibrations, [.agentNeedsYou(cameWithBell: false)])

        harness.center.dismiss(attention.id)
        XCTAssertEqual(harness.shownTitle, "codex finished")
        XCTAssertEqual(harness.vibrations, [.agentNeedsYou(cameWithBell: false), .agentFinished(cameWithBell: false)])
    }

    /// Nothing vibrates for the tab on screen, for an agent that moved on while waiting its turn, or for a
    /// custom or update banner.
    func testOnlyAnAgentsBannerThatShowsVibrates() async throws {
        let harness = Harness()
        harness.state.agentStatuses = ["w1:p2": .blocked, "w1:p3": .blocked]
        try harness.receive(.custom, "build passed")
        try harness.receive(.needsAttention, "claude needs attention", pane: "w1:p3", tab: "t2")
        try harness.receive(.needsAttention, "on screen", pane: "w1:p2", tab: "t1")
        try harness.receive(.updateInstalled, "herdr updated")
        let custom = try XCTUnwrap(harness.center.banner)
        XCTAssertEqual(custom.notification.title, "build passed")

        try await harness.pass(HerdrNotificationPolicy.delay)
        XCTAssertEqual(harness.center.banner, custom, "the custom banner left before the others waited behind it")
        harness.state.agentStatuses["w1:p3"] = .working
        harness.center.dismiss(custom.id)
        XCTAssertEqual(harness.shownTitle, "herdr updated")
        XCTAssertEqual(harness.vibrations, [])
    }

    func testABellVibratesAtOnce() {
        let harness = Harness()
        harness.center.ringBell()
        XCTAssertEqual(harness.vibrations, [.bell])
    }

    /// A bell and a needs-attention notification at 0 s, another bell at 0.5 s: the banner that shows at
    /// 1 s doesn't vibrate, since its own bell already did.
    func testABannerWhoseBellVibratedStaysSilentAfterALaterBell() async throws {
        let harness = Harness()
        harness.state.agentStatuses = ["w1:p2": .blocked]
        harness.center.ringBell()
        try harness.receive(.needsAttention, "claude needs attention", pane: "w1:p2", tab: "t2")
        try await harness.pass(.milliseconds(500))
        harness.center.ringBell()

        try await harness.pass(.milliseconds(500))
        XCTAssertEqual(harness.shownTitle, "claude needs attention")
        XCTAssertEqual(harness.felt, [.warning, .warning])
    }

    func testABellJustAfterANotificationStandsForItsBanner() async throws {
        let harness = Harness()
        harness.state.agentStatuses = ["w1:p2": .blocked]
        try harness.receive(.needsAttention, "claude needs attention", pane: "w1:p2", tab: "t2")
        try await harness.pass(.milliseconds(20))
        harness.center.ringBell()

        try await harness.pass(.milliseconds(980))
        XCTAssertEqual(harness.shownTitle, "claude needs attention")
        XCTAssertEqual(harness.felt, [.warning])
    }

    /// Two agents wait behind a banner, one whose notification came with a bell and one apart from any;
    /// after more bells, the first shows without vibrating and the second vibrates.
    func testAWaitingBannerWhoseBellVibratedStaysSilentWhenItsTurnComes() async throws {
        let harness = Harness()
        harness.state.agentStatuses = ["w1:p2": .blocked, "w1:p3": .blocked]
        try harness.receive(.custom, "build passed")
        let custom = try XCTUnwrap(harness.center.banner)
        harness.center.ringBell()
        try harness.receive(.needsAttention, "with the bell", pane: "w1:p2", tab: "t2")
        try await harness.pass(.milliseconds(300))
        try harness.receive(.needsAttention, "apart", pane: "w1:p3", tab: "t2")
        try await harness.pass(.milliseconds(1100))
        XCTAssertEqual(harness.center.banner, custom, "the custom banner left before the others waited behind it")

        harness.center.ringBell()
        try await harness.pass(.milliseconds(150))
        harness.center.ringBell()
        try await harness.pass(.milliseconds(150))
        XCTAssertEqual(harness.felt, [.warning, .warning, .warning])

        harness.center.dismiss(custom.id)
        let paired = try XCTUnwrap(harness.center.banner)
        XCTAssertEqual(paired.notification.title, "with the bell")
        XCTAssertEqual(harness.felt.count, 3, "the banner whose bell vibrated vibrated again")

        harness.center.dismiss(paired.id)
        XCTAssertEqual(harness.shownTitle, "apart")
        XCTAssertEqual(harness.felt, [.warning, .warning, .warning, .warning])
    }
}
