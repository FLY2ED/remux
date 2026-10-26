import NIO
import XCTest
@testable import Remux

/// The panel over a session that couldn't open or stopped, for each way that happens, from the reason the
/// session reports.
final class GhosttyRepairPanelContentTests: XCTestCase {
    private static let server = SavedServer(displayName: "Lab", host: "lab.example.test", username: "builder")

    private func panel(_ reason: TerminalDisconnectReason?) -> GhosttyRepairPanelContent {
        GhosttyRepairPanelContent(reason: reason, serverName: Self.server.displayName)
    }

    private func titles(_ content: GhosttyRepairPanelContent) -> [String] {
        content.actions.map(\.title)
    }

    func testAServerSeenForTheFirstTimeShowsItsKey() {
        let challenge = hostKeyChallenge(.unknown, key: Self.validKey)
        let content = panel(TerminalDisconnectReason(kind: .hostKey, message: "trust required", hostKeyChallenge: challenge))

        XCTAssertEqual(content.title, "Verify Server")
        XCTAssertEqual(
            content.message,
            "First connection to lab.example.test. Trust it only if this fingerprint matches the server."
        )
        XCTAssertEqual(content.hostKey, "ssh-ed25519 \(challenge.receivedKeyFingerprint!)")
        XCTAssertEqual(titles(content), ["Cancel", "Trust Server"])
        XCTAssertEqual(content.actions.last?.isPrimary, true)
    }

    func testAChangedKeyIsTrustedAsANewKey() {
        let content = panel(TerminalDisconnectReason(
            kind: .hostKey,
            message: "trust required",
            hostKeyChallenge: hostKeyChallenge(.changed, key: Self.validKey)
        ))

        XCTAssertEqual(content.title, "Host Key Changed")
        XCTAssertEqual(
            content.message,
            "lab.example.test has a different key than last time. Trust it only if you expected this."
        )
        XCTAssertEqual(titles(content), ["Cancel", "Trust New Key"])
    }

    func testAKeyRemuxCannotReadCannotBeTrusted() {
        let content = panel(TerminalDisconnectReason(
            kind: .hostKey,
            message: "trust required",
            hostKeyChallenge: hostKeyChallenge(.unknown, key: "not-a-key")
        ))

        XCTAssertEqual(content.message, "Remux couldn't read the key lab.example.test offered, so it can't be trusted.")
        XCTAssertNil(content.hostKey)
        XCTAssertEqual(titles(content), ["Cancel"])
    }

    func testRejectedCredentialsNameTheServer() {
        let content = panel(GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(Failure("Permission denied")))

        XCTAssertEqual(content.title, "Authentication Failed")
        XCTAssertEqual(content.message, "Lab rejected the saved password or key.")
        XCTAssertEqual(titles(content), ["Update Credentials"])
    }

    /// Tailscale's check ran out of time: retrying gets a new one, and the credentials aren't the problem.
    func testAnExpiredTailscaleVerificationOffersARetry() {
        let content = panel(GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            TailscaleSSHCheckError.verificationTimedOut
        ))

        XCTAssertEqual(content.title, "Verification Expired")
        XCTAssertEqual(content.message, "Tailscale verification wasn't completed in time.")
        XCTAssertEqual(titles(content), ["Retry"])
        XCTAssertEqual(content.actions.first?.accessibilityIdentifier, "terminal.status.verificationExpired.retry")
    }

    func testAnUnreachableServerSaysWhatToCheck() {
        let content = panel(GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            ChannelError.connectTimeout(.seconds(30))
        ))

        XCTAssertEqual(content.title, "Server Unreachable")
        XCTAssertEqual(content.message, "Check the address, port, network, or VPN.")
        XCTAssertEqual(titles(content), ["Retry", "Edit Server"])
    }

    func testAMissingBackendShowsItsOwnPanel() {
        let content = panel(BackendProblem.notFound.disconnectReason(for: .herdr))

        XCTAssertEqual(content.title, "Herdr Unavailable")
        XCTAssertEqual(
            content.message,
            "Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."
        )
        XCTAssertEqual(titles(content), ["Retry", "Edit Server"])
        XCTAssertEqual(content.actions.map(\.accessibilityIdentifier), [
            "terminal.status.herdr.retry",
            "terminal.status.herdr.editServer",
        ])
    }

    /// The terminal library closes a session on a tmux older than it supports; a reconnect would fail the
    /// same way, and a path to a newer tmux fixes it.
    func testATmuxTooOldIsTmuxUnavailable() {
        let content = panel(TmuxSessionController.CloseReason.unsupportedVersion("3.0a").terminalDisconnectReason)

        XCTAssertEqual(content.title, "tmux Unavailable")
        XCTAssertEqual(content.message, "tmux 3.0a on this server is too old. Remux needs 3.1 or later.")
        XCTAssertEqual(titles(content), ["Retry", "Edit Server"])
    }

    func testALoginShellThatFailsShowsTheServersWords() {
        let content = panel(GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(
            SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics("This account is currently not available.\n")),
            tmuxPath: nil
        ))

        XCTAssertEqual(content.title, "Disconnected")
        XCTAssertEqual(content.message, "The server closed the connection before tmux started.")
        XCTAssertEqual(content.detail, "This account is currently not available.")
        XCTAssertEqual(titles(content), ["Reconnect"])
    }

    /// Herdr says why it stopped; a live update's reason says to reconnect.
    func testHerdrStoppingNamesTheServerAndKeepsHerdrsReason() {
        let reason = "live update in progress; reconnect after handoff completes"
        let content = panel(HerdrConnectionError.serverShutdown(reason: reason).terminalDisconnectReason(on: Self.server))

        XCTAssertEqual(content.title, "Disconnected")
        XCTAssertEqual(content.message, "Herdr stopped on Lab.")
        XCTAssertEqual(content.detail, reason)
        XCTAssertEqual(titles(content), ["Reconnect"])

        XCTAssertNil(panel(HerdrConnectionError.serverShutdown(reason: nil).terminalDisconnectReason(on: Self.server)).detail)
    }

    func testALostConnectionSaysSo() {
        let content = panel(TmuxSessionController.DetachReason.transportClosed.terminalDisconnectReason)

        XCTAssertEqual(content.message, "The connection was lost.")
        XCTAssertEqual(titles(content), ["Reconnect"])
    }

    /// What Remux knows about its own failures goes to its diagnostics, not the screen.
    func testRemuxsOwnFailuresDoNotShowTheirInternals() {
        let reasons: [TerminalDisconnectReason?] = [
            TmuxSessionController.DetachReason.channelAborted.terminalDisconnectReason,
            TmuxSessionController.DetachReason.outOfMemory.terminalDisconnectReason,
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.controlSessionNoResponse(.seconds(15))
            ),
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(Failure("connection fizzled")),
            HerdrConnectionError.incompatible("it uses other codecs").terminalDisconnectReason(on: Self.server),
            nil,
        ]
        for reason in reasons {
            let content = panel(reason)
            XCTAssertEqual(content.title, "Disconnected", String(describing: reason))
            XCTAssertEqual(content.message, "Something went wrong with this session.", String(describing: reason))
            XCTAssertNil(content.detail)
            XCTAssertEqual(titles(content), ["Reconnect"])
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let validKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"

    private func hostKeyChallenge(_ kind: SSHHostKeyTrustChallenge.Kind, key: String) -> SSHHostKeyTrustChallenge {
        SSHHostKeyTrustChallenge(
            kind: kind,
            serverID: Self.server.id,
            host: "lab.example.test",
            trustedKeyType: nil,
            trustedOpenSSHPublicKey: nil,
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: key
        )
    }

    private func diagnostics(_ messages: String) -> SSHTmuxStartupDiagnostics {
        SSHTmuxStartupDiagnostics(
            stdoutByteCount: messages.utf8.count,
            stderrByteCount: 0,
            extendedDataByteCount: 0,
            stderrPreview: nil,
            extendedDataPreview: nil,
            startupOutputPreview: nil,
            messages: messages
        )
    }
}
