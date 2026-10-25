import Foundation
import XCTest
@testable import Remux

/// The words for each problem, in each place that says it.
final class BackendProblemTests: XCTestCase {
    func testNothingFoundOnAutomatic() {
        let problem = BackendProblem(.notFound, path: nil)
        XCTAssertEqual(problem, .notFound)
        XCTAssertEqual(problem.sessionRowLine(for: .tmux), "tmux not found · Set path")
        XCTAssertEqual(problem.pathNote(for: .tmux), "Remux couldn't find tmux on this server.")
        XCTAssertEqual(
            problem.message(for: .herdr),
            "Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."
        )
        XCTAssertNil(problem.detail)
        XCTAssertTrue(problem.isFixedByPath)
    }

    func testNothingThatCanRunAtThePathSet() {
        let problem = BackendProblem(.notFound, path: "/opt/tools/tmux")
        XCTAssertEqual(problem, .notAtPath("/opt/tools/tmux"))
        XCTAssertEqual(problem.sessionRowLine(for: .tmux), "Can't run tmux · Check path")
        XCTAssertEqual(problem.pathNote(for: .tmux), "Remux can't run tmux from this path.")
        XCTAssertEqual(
            problem.message(for: .tmux),
            "Remux can't run tmux from /opt/tools/tmux. Check the path in Edit Server."
        )
        XCTAssertTrue(problem.isFixedByPath)
    }

    func testAProgramTheServerCannotStart() {
        let message = "sh: 1: exec: /opt/tools/tmux: Exec format error"
        let atPath = BackendProblem(.couldNotStart(message), path: "/opt/tools/tmux")
        XCTAssertEqual(atPath.sessionRowLine(for: .tmux), "Running tmux failed · Check path")
        XCTAssertEqual(atPath.pathNote(for: .tmux), "Running it failed:")
        XCTAssertEqual(atPath.detail, message)
        XCTAssertEqual(atPath.message(for: .tmux), "Running /opt/tools/tmux failed.")
        XCTAssertEqual(BackendProblem(.couldNotStart(message), path: nil).message(for: .tmux), "Running tmux failed.")
        XCTAssertTrue(atPath.isFixedByPath)
    }

    /// The program ran and reported an error: its path isn't the cause, so there is no "Check path".
    func testAProgramThatRanAndFailed() {
        let problem = BackendProblem(.failed("protocol version mismatch (client 8, server 7)"), path: nil)
        XCTAssertEqual(problem.sessionRowLine(for: .tmux), "Running tmux failed")
        XCTAssertEqual(problem.pathNote(for: .tmux), "Running it failed:")
        XCTAssertEqual(problem.message(for: .tmux), "Running tmux failed.")
        XCTAssertEqual(problem.detail, "protocol version mismatch (client 8, server 7)")
        XCTAssertFalse(problem.isFixedByPath)

        let silent = BackendProblem(.failed(""), path: nil)
        XCTAssertNil(silent.detail)
        XCTAssertEqual(silent.pathNote(for: .tmux), "Running it failed.")
    }

    func testAnOldHerdr() {
        let problem = BackendProblem.unsupportedVersion(HerdrVersion(major: 0, minor: 9, patch: 2))
        XCTAssertEqual(problem.sessionRowLine(for: .herdr), "Herdr 0.9.2 is too old · Needs 0.9.3")
        XCTAssertEqual(problem.pathNote(for: .herdr), "Herdr 0.9.2 is installed. Remux needs 0.9.3 or later.")
        XCTAssertEqual(
            problem.message(for: .herdr),
            "Herdr 0.9.2 on this server is too old. Remux needs 0.9.3 or later."
        )
        XCTAssertFalse(problem.isFixedByPath)
    }

    /// Anything Edit Server or an update fixes leaves the backend unavailable, which doesn't reconnect on its
    /// own; a program that ran and failed is a session that ended.
    func testOnTheSessionsScreen() {
        let unavailable = BackendProblem(.couldNotStart("sh: 1: exec: /opt/tools/herdr: Permission denied"), path: nil)
            .disconnectReason(for: .herdr)
        XCTAssertEqual(unavailable, TerminalDisconnectReason(
            kind: .backendUnavailable(.herdr),
            message: "Running Herdr failed.",
            detail: "sh: 1: exec: /opt/tools/herdr: Permission denied"
        ))
        XCTAssertFalse(unavailable.allowsAutomaticReconnect)

        let ended = BackendProblem(.failed("lost server"), path: nil).disconnectReason(for: .tmux)
        XCTAssertEqual(ended, TerminalDisconnectReason(
            kind: .remoteExit,
            message: "Running tmux failed.",
            detail: "lost server"
        ))
    }

    func testDiscoveryErrorsThatAreTheProgramsAreProblems() {
        XCTAssertEqual(
            BackendProblem(discoveryError: RemoteProgramFailure.notFound, path: "/opt/herdr"),
            .notAtPath("/opt/herdr")
        )
        XCTAssertEqual(
            BackendProblem(
                discoveryError: HerdrSessionDiscoveryError.unsupportedVersion(HerdrVersion(major: 0, minor: 9, patch: 0)),
                path: nil
            ),
            .unsupportedVersion(HerdrVersion(major: 0, minor: 9, patch: 0))
        )
        XCTAssertNil(BackendProblem(discoveryError: HerdrSessionDiscoveryError.incompleteOutput, path: nil))
        XCTAssertNil(BackendProblem(
            discoveryError: TmuxSessionDiscoveryError.remoteExit(status: 1, stderr: "This account is currently not available.\n"),
            path: nil
        ))
    }
}
