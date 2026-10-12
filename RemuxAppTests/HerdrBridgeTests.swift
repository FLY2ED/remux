import Foundation
import XCTest
@testable import Remux

/// The bridge launch command. Its behaviour over real SSH against Herdr v0.9.3 (flag choice, markers,
/// handshake, the bridge exiting when the client goes away) is checked by remux-docs
/// `evidence/herdr-bridge-ssh-20261011/`, which runs this exact script.
final class HerdrBridgeTests: XCTestCase {
    func testCommandKeepsTheExecutableAndSessionOutOfTheLoginShell() {
        let executable = "/home/owner's tools/herdr; touch pwned"
        let session = "work'; rm -rf ~"

        let command = HerdrSSHBridge.command(herdrExecutable: executable, session: session)

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertFalse(command.contains(executable))
        XCTAssertFalse(command.contains(session))
        XCTAssertTrue(command.hasSuffix(
            " remux \(RemoteShellArgument.octalEncoded(executable)) \(RemoteShellArgument.octalEncoded(session))"
        ))
    }

    /// The script sits inside single quotes, so a single quote in it would end the quoting early: only
    /// the script's two and each argument's two may appear.
    func testScriptContainsNoSingleQuote() {
        let command = HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default")
        XCTAssertEqual(command.filter { $0 == "'" }.count, 6)
    }

    func testCommandAsksForTheIdleTimeoutOnlyWhereHerdrReportsIt() {
        let command = HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default")
        XCTAssertTrue(command.contains(#""$resolved" status client --json"#))
        XCTAssertTrue(command.contains(#"remote_bridge_idle_timeout\": *true"#))
        XCTAssertTrue(command.contains(#"--session "$session" remote-client-bridge --idle-timeout-v1"#))
        XCTAssertTrue(command.contains(#"exec "$resolved" --session "$session" remote-client-bridge' remux"#))
    }
}
