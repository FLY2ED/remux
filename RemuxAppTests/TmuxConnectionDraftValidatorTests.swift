import XCTest
@testable import Remux

final class TmuxConnectionDraftValidatorTests: XCTestCase {
    func testNewDraftKeepsServerIDAcrossValidation() {
        var draft = validServerDraft()
        let expectedID = draft.serverID

        let first = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )
        draft.displayName = "Renamed"
        let second = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .valid(let firstServer) = first,
              case .valid(let secondServer) = second else {
            return XCTFail("expected valid server drafts")
        }
        XCTAssertEqual(firstServer.serverID, expectedID)
        XCTAssertEqual(secondServer.serverID, expectedID)
    }

    func testTmuxExecutablePathProblem() {
        XCTAssertNil(TmuxConnectionDraftValidator.executablePathProblem(""))
        XCTAssertNil(TmuxConnectionDraftValidator.executablePathProblem("   "))
        XCTAssertNil(TmuxConnectionDraftValidator.executablePathProblem(" /opt/homebrew/bin/tmux "))
        XCTAssertEqual(
            TmuxConnectionDraftValidator.executablePathProblem("tmux"),
            "Enter an absolute path beginning with /."
        )
        XCTAssertEqual(
            TmuxConnectionDraftValidator.executablePathProblem("~/bin/tmux"),
            "Enter an absolute path beginning with /."
        )
        XCTAssertEqual(
            TmuxConnectionDraftValidator.executablePathProblem("/usr/bin/\ntmux"),
            "Executable path contains invalid characters."
        )

        var draft = validServerDraft()
        draft.tmuxExecutablePath = "~/bin/tmux"
        guard case .invalid(let validation) = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        ) else {
            return XCTFail("expected an invalid server draft")
        }
        XCTAssertEqual(validation.tmuxExecutablePath, "Enter an absolute path beginning with /.")
    }

    /// Herdr's own rule (`session::validate_name`), with its rejected cases from `invalid_names_are_rejected`.
    func testHerdrSessionNameProblem() {
        for name in ["default", "work.2_x-Y", String(repeating: "a", count: 64)] {
            XCTAssertNil(TmuxConnectionDraftValidator.herdrSessionNameProblem(name), name)
        }
        XCTAssertEqual(TmuxConnectionDraftValidator.herdrSessionNameProblem(""), "Herdr session name is required.")
        XCTAssertEqual(
            TmuxConnectionDraftValidator.herdrSessionNameProblem(String(repeating: "a", count: 65)),
            "Use 64 characters or fewer."
        )
        for name in [".", ".."] {
            XCTAssertEqual(
                TmuxConnectionDraftValidator.herdrSessionNameProblem(name),
                "A Herdr session can't be named . or ..",
                name
            )
        }
        for name in ["../prod", "work session", "café", "a/b"] {
            XCTAssertEqual(
                TmuxConnectionDraftValidator.herdrSessionNameProblem(name),
                "Use only letters, numbers, ., _ and -.",
                name
            )
        }
    }

    /// A Herdr session is checked by Herdr's rule; a tmux one only needs a name.
    func testWorkspaceNameIsCheckedByItsKindsRule() {
        let serverID = UUID()
        var draft = validServerDraft()
        draft.sessionName = "work session"
        guard case .valid = TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: nil
        ) else {
            return XCTFail("a tmux name with a space should be valid")
        }

        draft.backend = .herdr
        guard case .invalid(let validation) = TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: nil
        ) else {
            return XCTFail("a Herdr name with a space should be invalid")
        }
        XCTAssertEqual(validation.sessionName, "Use only letters, numbers, ., _ and -.")

        draft.sessionName = "default"
        guard case .valid(let submission) = TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: nil
        ) else {
            return XCTFail("Herdr's default name should be valid")
        }
        XCTAssertEqual(submission.workspace.backend, .herdr)
    }

    /// The Herdr path follows the tmux path's rule, and empty means automatic.
    func testHerdrExecutablePathIsCheckedAndTrimmed() {
        var draft = validServerDraft()
        draft.herdrExecutablePath = "~/.cargo/bin/herdr"
        guard case .invalid(let validation) = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        ) else {
            return XCTFail("a relative Herdr path should be invalid")
        }
        XCTAssertEqual(validation.herdrExecutablePath, "Enter an absolute path beginning with /.")

        draft.herdrExecutablePath = "  /home/demo/.cargo/bin/herdr  "
        guard case .valid(let server) = TmuxConnectionDraftValidator.validateServer(draft, existingServerID: nil) else {
            return XCTFail("an absolute Herdr path should be valid")
        }
        XCTAssertEqual(server.herdrExecutablePath, "/home/demo/.cargo/bin/herdr")

        draft.herdrExecutablePath = "   "
        guard case .valid(let automatic) = TmuxConnectionDraftValidator.validateServer(draft, existingServerID: nil) else {
            return XCTFail("an empty Herdr path should be valid")
        }
        XCTAssertNil(automatic.herdrExecutablePath)
    }

    func testDraftFromSavedServerUsesSavedServerID() {
        let server = SavedServer(
            displayName: "Host",
            host: "host.example",
            username: "demo",
            identityID: UUID()
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "main")

        let draft = TmuxConnectionDraft(server: server, workspace: workspace)

        XCTAssertEqual(draft.serverID, server.id)
    }

    func testValidDraftProducesServerDraftWorkspaceAndPassword() {
        var draft = TmuxConnectionDraft()
        draft.displayName = "Example Server"
        draft.host = "server.example.com"
        draft.port = "22"
        draft.username = "demo"
        draft.password = "demo-password"
        draft.tmuxExecutablePath = "  /home/demo/.local/share/mise/shims/tmux  "
        draft.sessionName = "base"

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: nil,
            existingWorkspaceID: nil
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid submission")
            return
        }

        XCTAssertEqual(submission.server.displayName, "Example Server")
        XCTAssertEqual(submission.server.host, "server.example.com")
        XCTAssertEqual(submission.server.port, 22)
        XCTAssertEqual(submission.server.username, "demo")
        XCTAssertEqual(
            submission.server.tmuxExecutablePath,
            "/home/demo/.local/share/mise/shims/tmux"
        )
        XCTAssertEqual(
            submission.server.savedServer(identityID: UUID()).tmuxExecutablePath,
            "/home/demo/.local/share/mise/shims/tmux"
        )
        XCTAssertEqual(submission.workspace.serverID, submission.server.serverID)
        XCTAssertEqual(submission.workspace.sessionName, "base")
        XCTAssertEqual(submission.server.credential, .password("demo-password"))
    }

    func testValidDraftReusesExistingIDs() throws {
        let serverID = UUID()
        let workspaceID = UUID()
        var draft = TmuxConnectionDraft()
        draft.displayName = "Build Host"
        draft.host = "build.example.test"
        draft.port = "2222"
        draft.username = "builder"
        draft.password = "demo-password"
        draft.sessionName = "work"

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: serverID,
            existingWorkspaceID: workspaceID
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid submission")
            return
        }

        XCTAssertEqual(submission.server.serverID, serverID)
        XCTAssertEqual(submission.workspace.id, workspaceID)
        XCTAssertEqual(submission.workspace.serverID, serverID)
    }

    func testInvalidDraftReportsFieldFailures() {
        let result = TmuxConnectionDraftValidator.validate(
            TmuxConnectionDraft(),
            existingServerID: nil,
            existingWorkspaceID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid submission")
            return
        }

        XCTAssertNotNil(validation.displayName)
        XCTAssertNotNil(validation.host)
        XCTAssertNotNil(validation.username)
        XCTAssertNotNil(validation.password)
        XCTAssertNotNil(validation.sessionName)
    }

    func testInvalidConnectionDraftReportsServerAndSessionFailuresTogether() {
        var draft = TmuxConnectionDraft()
        draft.sessionName = ""

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: nil,
            existingWorkspaceID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid submission")
            return
        }

        XCTAssertNotNil(validation.displayName)
        XCTAssertNotNil(validation.host)
        XCTAssertNotNil(validation.username)
        XCTAssertNotNil(validation.password)
        XCTAssertNotNil(validation.sessionName)
    }

    func testServerDraftValidationDoesNotRequireSessionName() {
        let serverID = UUID()
        var draft = TmuxConnectionDraft()
        draft.displayName = "Laptop"
        draft.host = "laptop.example.com"
        draft.port = "22"
        draft.username = "demo"
        draft.password = "demo-password"
        draft.sessionName = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: serverID
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid server submission")
            return
        }

        XCTAssertEqual(submission.serverID, serverID)
        XCTAssertEqual(submission.displayName, "Laptop")
        XCTAssertNil(submission.tmuxExecutablePath)
        XCTAssertEqual(submission.credential, .password("demo-password"))
    }

    func testServerDraftRejectsInvalidTmuxExecutablePaths() {
        for path in [
            "~/.local/share/mise/shims/tmux",
            "/usr/local/bin/tmux\nwhoami",
            "/usr/local/bin/tmux\0",
        ] {
            var draft = validServerDraft()
            draft.tmuxExecutablePath = path

            let result = TmuxConnectionDraftValidator.validateServer(
                draft,
                existingServerID: nil
            )

            guard case .invalid(let validation) = result else {
                XCTFail("expected invalid server submission for \(path.debugDescription)")
                continue
            }

            XCTAssertNotNil(validation.tmuxExecutablePath)
        }
    }

    func testConnectionDraftLoadsSavedTmuxExecutablePathForEditing() {
        let server = SavedServer(
            displayName: "Laptop",
            host: "laptop.example.com",
            username: "demo",
            identityID: UUID(),
            tmuxExecutablePath: "/opt/tmux/bin/tmux"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "ops")

        let draft = TmuxConnectionDraft(server: server, workspace: workspace)

        XCTAssertEqual(draft.tmuxExecutablePath, "/opt/tmux/bin/tmux")
    }

    func testEditingKeepsWorkspaceBackendAndHerdrExecutablePath() {
        let identityID = UUID()
        let server = SavedServer(
            displayName: "Laptop",
            host: "laptop.example.com",
            username: "demo",
            identityID: identityID,
            herdrExecutablePath: "/opt/herdr/bin/herdr"
        )
        let workspace = SavedWorkspace(serverID: server.id, backend: .herdr, sessionName: "ops")
        var draft = TmuxConnectionDraft(server: server, workspace: workspace)
        draft.password = "demo-password"

        let result = TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: server.id,
            existingWorkspaceID: workspace.id
        )

        guard case .valid(let submission) = result else {
            return XCTFail("expected valid submission")
        }
        XCTAssertEqual(submission.workspace.backend, .herdr)
        XCTAssertEqual(
            submission.server.savedServer(identityID: identityID).herdrExecutablePath,
            "/opt/herdr/bin/herdr"
        )
    }

    func testValidPrivateKeyDraftProducesPrivateKeyCredential() {
        var draft = validServerDraft()
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = Self.ed25519Key
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid server submission")
            return
        }

        XCTAssertEqual(
            submission.credential,
            .privateKey(SSHPrivateKeyCredential(privateKeyPEM: Self.ed25519Key))
        )
    }

    func testValidNoneDraftProducesNoneCredentialWithoutPasswordOrKey() {
        var draft = validServerDraft()
        draft.authenticationKind = .none
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid server submission")
            return
        }

        XCTAssertEqual(submission.credential, .none)
    }

    func testPrivateKeyDraftRejectsInvalidKeyText() {
        var draft = validServerDraft()
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = "not a private key"
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid server submission")
            return
        }

        XCTAssertEqual(validation.privateKey, "Import an OpenSSH private key.")
    }

    func testEncryptedPrivateKeyDraftRequiresPassphrase() {
        var draft = validServerDraft()
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = Self.encryptedEd25519Key
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .invalid(let validation) = result else {
            XCTFail("expected invalid server submission")
            return
        }

        XCTAssertEqual(validation.privateKeyPassphrase, "Passphrase is required for encrypted private keys.")
    }

    func testEncryptedPrivateKeyDraftAcceptsPassphrase() {
        var draft = validServerDraft()
        draft.authenticationKind = .privateKey
        draft.privateKeyPEM = Self.encryptedEd25519Key
        draft.privateKeyPassphrase = "secret"
        draft.password = ""

        let result = TmuxConnectionDraftValidator.validateServer(
            draft,
            existingServerID: nil
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid server submission")
            return
        }

        XCTAssertEqual(
            submission.credential,
            .privateKey(
                SSHPrivateKeyCredential(
                    privateKeyPEM: Self.encryptedEd25519Key,
                    passphrase: "secret"
                )
            )
        )
    }

    func testWorkspaceDraftValidationOnlyRequiresSessionName() {
        let serverID = UUID()
        let workspaceID = UUID()
        var draft = TmuxConnectionDraft()
        draft.sessionName = "ops"

        let result = TmuxConnectionDraftValidator.validateWorkspace(
            draft,
            serverID: serverID,
            existingWorkspaceID: workspaceID
        )

        guard case .valid(let submission) = result else {
            XCTFail("expected valid workspace submission")
            return
        }

        XCTAssertEqual(submission.workspace.id, workspaceID)
        XCTAssertEqual(submission.workspace.serverID, serverID)
        XCTAssertEqual(submission.workspace.sessionName, "ops")
    }

    private func validServerDraft() -> TmuxConnectionDraft {
        var draft = TmuxConnectionDraft()
        draft.displayName = "Laptop"
        draft.host = "laptop.example.com"
        draft.port = "22"
        draft.username = "demo"
        draft.password = "demo-password"
        return draft
    }

    private static let encryptedEd25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD87oA8AF
    9fpLEAQtTWMZZwAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIuwDbwcjxPpUNPA
    PkZgyQ9jnCXaboZMHs+AWOqtGxO0AAAAoA9no2kroZ7q7MIpSQ6+Gs5N/KMrm/eFRfWf4K
    iLGRTczk+WQycDp1YidTw8kH9IwJle5ulywHf+5iLCVaolx8vYErJfKsJ1DRRx0qMzZObI
    AHd8pT6MnuDISadNzI+lZgn1dbCZ6/aWPVFO3pFpmREscRgolzFcvSOtLiT/5U1wWUhwPo
    KGvU4Tmf5I5hGQCbKhx4g4z7aJfILg2ErdGPQ=
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let ed25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACA6y4Nl6dWkC0PdxZrJ6S7aYcmBpy9RytK9V0Xz7eIwVQAAAJj3zGE298xh
    NgAAAAtzc2gtZWQyNTUxOQAAACA6y4Nl6dWkC0PdxZrJ6S7aYcmBpy9RytK9V0Xz7eIwVQ
    AAAEB6gaBHbjL56VCVbX8Es1jVLdoaQnikXUxM3SAV105ghzrLg2Xp1aQLQ93FmsnpLtph
    yYGnL1HK0r1XRfPt4jBVAAAAEnJlbXV4LXRlc3QtZml4dHVyZQECAw==
    -----END OPENSSH PRIVATE KEY-----
    """
}
