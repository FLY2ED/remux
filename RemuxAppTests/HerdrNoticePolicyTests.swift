import XCTest
@testable import Remux

/// The notice rules of Herdr's client (`client/shell/actions.rs`), on their own.
final class HerdrNoticePolicyTests: XCTestCase {
    func testAnUnavailableServerIsShownOncePerBoot() {
        var policy = HerdrNoticePolicy(visibleFor: .zero)
        let unavailable = HerdrCommandError.failed(code: "server_unavailable", message: "Herdr is restarting")
        XCTAssertTrue(policy.shows("pane.focus", failedWith: unavailable, bootID: "a"))
        XCTAssertFalse(policy.shows("pane.zoom", failedWith: unavailable, bootID: "a"))
        XCTAssertTrue(policy.shows("pane.focus", failedWith: unavailable, bootID: "b"))
    }

    func testARefusalIsShownAgainOnceTheLastOneIsGone() {
        var policy = HerdrNoticePolicy(visibleFor: .zero)
        let refused = HerdrCommandError.failed(code: "pane_not_found", message: "pane not found")
        XCTAssertTrue(policy.shows("pane.focus", failedWith: refused, bootID: "a"))
        XCTAssertTrue(policy.shows("pane.focus", failedWith: refused, bootID: "a"))
    }

    func testAnswersThatNoLongerApplyAndAnEndedConnectionSayNothing() {
        var policy = HerdrNoticePolicy(visibleFor: .seconds(4))
        for code in ["stale_target", "stale_content", "confirmation_required"] {
            XCTAssertFalse(policy.shows("pane.focus", failedWith: .failed(code: code, message: ""), bootID: "a"), code)
        }
        XCTAssertFalse(policy.shows("pane.focus", failedWith: .connectionEnded, bootID: "a"))
    }

    func testATimeoutIsShownAgainOnlyAfterTheActionWorks() {
        var policy = HerdrNoticePolicy(visibleFor: .zero)
        XCTAssertTrue(policy.shows("pane.focus", failedWith: .timedOut(method: "pane.focus"), bootID: "a"))
        XCTAssertFalse(policy.shows("pane.focus", failedWith: .failed(code: "endpoint_timeout", message: ""), bootID: "a"))
        XCTAssertTrue(policy.shows("pane.zoom", failedWith: .timedOut(method: "pane.zoom"), bootID: "a"))
        policy.succeeded("pane.focus", bootID: "a")
        XCTAssertTrue(policy.shows("pane.focus", failedWith: .timedOut(method: "pane.focus"), bootID: "a"))
    }
}
