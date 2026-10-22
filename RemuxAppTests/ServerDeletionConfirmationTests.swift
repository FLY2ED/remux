import XCTest
@testable import Remux

final class ServerDeletionConfirmationTests: XCTestCase {
    func testPrivateKeyOnlyThisServerUsesIsCalledOutWithItsSessions() {
        let key = SSHIdentity(name: "GPU box", authenticationKind: .privateKey)
        let server = SavedServer(displayName: "GPU box", host: "gpu-01", username: "ml", identityID: key.id)
        let other = SavedServer(displayName: "Mac mini", host: "mini.local", username: "me", identityID: UUID())
        let snapshot = ConnectionLibrarySnapshot(
            servers: [server, other],
            workspaces: [
                SavedWorkspace(serverID: server.id, sessionName: "train-run"),
                SavedWorkspace(serverID: server.id, sessionName: "eval"),
                SavedWorkspace(serverID: other.id, sessionName: "notes"),
            ],
            identities: [key]
        )

        let confirmation = ServerDeletionConfirmation(server: server, snapshot: snapshot)

        XCTAssertEqual(confirmation.title, "Delete \u{201C}GPU box\u{201D}?")
        XCTAssertEqual(
            confirmation.message,
            "Its 2 saved sessions are removed from Remux. "
                + "Its private key is deleted from this device. If Remux generated it, there is no other copy. "
                + "Sessions on the server keep running."
        )
    }

    func testPasswordOnlyThisServerUsesIsCalledOut() {
        let password = SSHIdentity(name: "Mac mini", authenticationKind: .password)
        let server = SavedServer(displayName: "Mac mini", host: "mini.local", username: "me", identityID: password.id)
        let snapshot = ConnectionLibrarySnapshot(
            servers: [server],
            workspaces: [SavedWorkspace(serverID: server.id, sessionName: "main")],
            identities: [password]
        )

        XCTAssertEqual(
            ServerDeletionConfirmation(server: server, snapshot: snapshot).message,
            "Its saved session is removed from Remux. Its saved password is deleted. "
                + "Sessions on the server keep running."
        )
    }

    func testSignInSharedWithAnotherServerIsKept() {
        let key = SSHIdentity(name: "Shared", authenticationKind: .privateKey)
        let server = SavedServer(displayName: "GPU box", host: "gpu-01", username: "ml", identityID: key.id)
        let other = SavedServer(displayName: "GPU box 2", host: "gpu-02", username: "ml", identityID: key.id)
        let snapshot = ConnectionLibrarySnapshot(servers: [server, other], workspaces: [], identities: [key])

        XCTAssertEqual(
            ServerDeletionConfirmation(server: server, snapshot: snapshot).message,
            "Sessions on the server keep running."
        )
    }

    func testTailscaleServerHasNoStoredSecretToMention() {
        let tailscale = SSHIdentity(name: "Studio", authenticationKind: .none)
        let server = SavedServer(displayName: "Studio", host: "studio", username: "me", identityID: tailscale.id)
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [tailscale])

        XCTAssertEqual(
            ServerDeletionConfirmation(server: server, snapshot: snapshot).message,
            "Sessions on the server keep running."
        )
    }
}
