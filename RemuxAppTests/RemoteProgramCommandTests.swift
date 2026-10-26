import Foundation
import XCTest
@testable import Remux

/// The launcher both backends run through, and how a failed run is read. The runs below were captured from
/// the app's commands on Debian (dash, and bash as /bin/sh) and Alpine (busybox).
final class RemoteProgramCommandTests: XCTestCase {
    func testCommandKeepsTheProgramAndArgumentsOutOfTheLoginShell() {
        let program = "/home/owner's tools/tmux; touch pwned"
        let argument = "work'; rm -rf ~"

        let command = RemoteProgramCommand.command(program: program, arguments: [argument], body: ["exit 0"])

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertFalse(command.contains(program))
        XCTAssertFalse(command.contains(argument))
        XCTAssertTrue(command.hasSuffix(
            "' sh \(RemoteShellArgument.octalEncoded(program)) \(RemoteShellArgument.octalEncoded(argument))"
        ))
    }

    /// The script sits inside single quotes, so a single quote in it would end the quoting early: only the
    /// script's two and each argument's two may appear.
    func testScriptContainsNoSingleQuote() {
        let commands = [
            SSHTmuxControlCommandBuilder.listSessionsCommand(tmuxExecutable: "tmux"),
            SSHTmuxControlCommandBuilder.controlSessionCommand(
                tmuxExecutable: "tmux",
                sessionName: "main",
                opening: .attach,
                initialViewport: .default
            ),
            SSHTmuxControlCommandBuilder.controlSessionCommand(
                tmuxExecutable: "tmux",
                sessionName: "main",
                opening: .create,
                initialViewport: .default
            ),
            HerdrSessionDiscovery.listSessionsCommand(herdrExecutable: "herdr"),
            HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default"),
        ]
        XCTAssertEqual(commands.map { $0.filter { $0 == "'" }.count }, [4, 6, 6, 4, 6])
    }

    /// After the user's PATH: where Herdr's client looks for Herdr, mise's shims, MacPorts, Guix and Snap,
    /// then the system folders.
    func testProgramIsLookedForWherePackageManagersInstallIt() {
        let command = RemoteProgramCommand.command(program: "tmux", body: [])
        for folder in [
            "$HOME/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin",
            "$HOME/.nix-profile/bin", "/etc/profiles/per-user/${USER:-}/bin", "/nix/var/nix/profiles/default/bin",
            "/run/current-system/sw/bin", "$HOME/.local/share/mise/shims", "/opt/local/bin",
            "$HOME/.guix-profile/bin", "/run/current-system/profile/bin", "/snap/bin", "/usr/bin", "/bin",
        ] {
            XCTAssertTrue(command.contains(folder), folder)
        }
        XCTAssertTrue(command.contains(#"PATH="${PATH:+$PATH:}$HOME/.local/bin:"#), "the user's PATH comes first")
    }

    /// As Herdr's client does with its own: output starts after the line that is exactly the marker (a
    /// trailing carriage return allowed), however the stream is split.
    func testOutputStartsAfterTheReadyMarkersLine() {
        let stream = Array("motd remux-ready:1 not alone\nremux-ready:10\n\nremux-ready:1\r\npayload".utf8)
        for split in [1, 3, 7, stream.count] {
            var line = RemoteProgramCommand.ReadyLine()
            var output: [UInt8] = []
            for start in stride(from: 0, to: stream.count, by: split) {
                output += line.output(from: stream[start..<min(start + split, stream.count)])
            }
            XCTAssertTrue(line.isFound, "split \(split)")
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "payload", "split \(split)")
        }
        var missing = RemoteProgramCommand.ReadyLine()
        XCTAssertEqual(missing.output(from: Array("no marker here\n".utf8)), [])
        XCTAssertFalse(missing.isFound)
    }

    // MARK: - Failed runs

    func testNothingThatCanRunIsNotFound() {
        XCTAssertEqual(RemoteProgramFailure(exitStatus: 127, stderr: "remux: not found: herdr\n"), .notFound)
    }

    /// The shell's own line is the message: dash, busybox, bash's first of two lines, and macOS's /bin/sh (bash
    /// 3.2), whose failed `exec` exits 1.
    func testAShellThatCannotStartTheProgramSaysWhy() {
        let runs: [(Int, String, String)] = [
            (1, "\nremux-ready:1\nsh: /opt/tools/tmux: cannot execute binary file\nsh: /opt/tools/tmux: Undefined error: 0\n",
             "sh: /opt/tools/tmux: cannot execute binary file"),
            (1, "\nremux-ready:1\nsh: /opt/tools/tmux: /nonexistent/interpreter: bad interpreter: No such file or directory\n",
             "sh: /opt/tools/tmux: /nonexistent/interpreter: bad interpreter: No such file or directory"),
            (126, "\nremux-ready:1\nsh: 1: exec: /opt/tools/tmux: Exec format error\n",
             "sh: 1: exec: /opt/tools/tmux: Exec format error"),
            (126, "\nremux-ready:1\nsh: line 1: /opt/tools/tmux: cannot execute binary file: Exec format error\nsh: line 1: /opt/tools/tmux: Success\n",
             "sh: line 1: /opt/tools/tmux: cannot execute binary file: Exec format error"),
            (127, "\nremux-ready:1\nsh: exec: line 0: /opt/tools/tmux: not found\n",
             "sh: exec: line 0: /opt/tools/tmux: not found"),
        ]
        for (status, stderr, message) in runs {
            XCTAssertEqual(RemoteProgramFailure(exitStatus: status, stderr: stderr), .couldNotStart(message))
        }
    }

    func testAProgramThatRanAndFailedSaysWhy() {
        XCTAssertEqual(
            RemoteProgramFailure(exitStatus: 1, stderr: "\nremux-ready:1\nherdr: something went wrong\n"),
            .failed("herdr: something went wrong")
        )
        XCTAssertEqual(RemoteProgramFailure(exitStatus: 1, stderr: "\nremux-ready:1\n"), .failed(""))
    }

    /// A program that ran can exit 126 or 127 itself, here a wrapper whose own command is missing: it ran, so
    /// its path isn't what failed.
    func testAProgramThatExits127ItselfRan() {
        XCTAssertEqual(
            RemoteProgramFailure(
                exitStatus: 127,
                stderr: "\nremux-ready:1\n/opt/tools/tmux: line 2: exec: tmux-real: not found\n"
            ),
            .failed("/opt/tools/tmux: line 2: exec: tmux-real: not found")
        )
    }

    /// On a pty, the startup files' output, both copies of the marker and the shell's error arrive in one
    /// stream, with carriage returns.
    func testAPtyStreamIsReadAfterTheMarker() {
        let output = "Last login: Sat Oct 25\r\nwarning: no ~/.cargo/env\r\n\r\nremux-ready:1\r\n\r\nremux-ready:1\r\n"
            + "sh: 1: exec: /opt/tools/tmux: Exec format error\r\n"
        XCTAssertEqual(
            RemoteProgramFailure(exitStatus: 126, stderr: output),
            .couldNotStart("sh: 1: exec: /opt/tools/tmux: Exec format error")
        )
    }

    /// Until the marker, the end of the messages is kept: the not-found line comes last, after any amount of
    /// startup output.
    func testMessagesKeepTheEndBeforeTheMarker() {
        var messages = RemoteProgramMessages()
        messages.append(Data(String(repeating: "welcome to the server\r\n", count: 1_000).utf8))
        messages.append(Data("remux: not found: tmux\r\n".utf8))

        XCTAssertLessThanOrEqual(messages.text.utf8.count, 8 * 1024)
        XCTAssertEqual(RemoteProgramFailure(exitStatus: 127, stderr: messages.text), .notFound)
    }

    /// From the marker on, what follows it is kept, however much the program prints after its first line and
    /// however the stream is split.
    func testMessagesKeepWhatFollowsTheMarker() {
        let stream = Data((
            String(repeating: "welcome to the server\r\n", count: 1_000)
                + "\r\nremux-ready:1\r\n\r\nremux-ready:1\r\nsh: 1: exec: /opt/tools/tmux: Exec format error\r\n"
                + String(repeating: "more output from the wrapper\r\n", count: 1_000)
        ).utf8)
        for split in [7, 1_000, stream.count] {
            var messages = RemoteProgramMessages()
            for start in stride(from: 0, to: stream.count, by: split) {
                messages.append(stream[start..<min(start + split, stream.count)])
            }
            XCTAssertEqual(
                RemoteProgramFailure(exitStatus: 126, stderr: messages.text),
                .couldNotStart("sh: 1: exec: /opt/tools/tmux: Exec format error"),
                "split \(split)"
            )
            XCTAssertLessThanOrEqual(messages.text.utf8.count, 8 * 1024 + 32)
        }
    }

    /// Without the marker the run never got to the program: the login shell or the startup files failed.
    func testARunThatNeverGotToTheProgramIsNotItsFailure() {
        XCTAssertNil(RemoteProgramFailure(exitStatus: 1, stderr: "This account is currently not available.\n"))
        XCTAssertNil(RemoteProgramFailure(exitStatus: 127, stderr: "bash: /nonexistent: No such file or directory\n"))
    }
}
