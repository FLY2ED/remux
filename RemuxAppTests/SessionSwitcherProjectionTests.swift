import Foundation
import XCTest
@testable import Remux

final class SessionSwitcherProjectionTests: XCTestCase {
    func testAvailableSessionsFollowServerOrderWithNamesSortedWithinEachServer() {
        let zulu = makeServer(name: "Zulu")
        let alpha = makeServer(name: "Alpha")
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [zulu, alpha], workspaces: []),
            activeSessions: [],
            discoveries: [
                zulu.id: loadedDiscovery(["z", "a"]),
                alpha.id: loadedDiscovery(["b"]),
            ],
            selectedSessionID: nil
        )
        XCTAssertEqual(projection.availableSessions.map(\.id.serverID), [zulu.id, zulu.id, alpha.id])
        XCTAssertEqual(projection.availableSessions.map(\.id.locator.name), ["a", "z", "b"])
    }

    /// Herdr's sessions join tmux's in one list sorted by name. A tmux and a Herdr session with the same
    /// name are different sessions, and Herdr's stopped sessions are listed too.
    func testAvailableSessionsMixBothBackendsByName() {
        let server = makeServer(name: "Mini")
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: []),
            activeSessions: [],
            discoveries: [
                server.id: loadedDiscovery(["main", "default"], herdr: [
                    DiscoveredSession(name: "default", isRunning: true),
                    DiscoveredSession(name: "agents", isRunning: false),
                ]),
            ],
            selectedSessionID: nil
        )
        XCTAssertEqual(projection.availableSessions.map(\.id.locator), [
            SessionLocator(backend: .herdr, name: "agents"),
            SessionLocator(backend: .tmux, name: "default"),
            SessionLocator(backend: .herdr, name: "default"),
            SessionLocator(backend: .tmux, name: "main"),
        ])
        XCTAssertEqual(projection.availableSessions.map(\.isRunning), [false, true, true, true])
    }

    /// The switcher names a server only when none of its sessions could be listed. A missing Herdr, even
    /// where a Herdr session is saved, leaves the server's tmux sessions listed.
    func testOnlyAServerNoneOfWhoseSessionsCouldBeListedIsUnchecked() {
        let herdrMissing = makeServer(name: "Herdr Missing")
        let unreachable = makeServer(name: "Unreachable")
        let saved = SavedWorkspace(serverID: herdrMissing.id, backend: .herdr, sessionName: "default")
        var missing = loadedDiscovery(["main"])
        missing.herdr = SessionDiscoveryState.idle.failingRefresh(problem: .notFound)
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [herdrMissing, unreachable], workspaces: [saved]),
            activeSessions: [],
            discoveries: [
                herdrMissing.id: missing,
                unreachable.id: ServerSessionDiscovery.idle.mapping { $0.failingRefresh() },
            ],
            selectedSessionID: nil
        )
        XCTAssertEqual(projection.uncheckedServerIDs, [unreachable.id])
    }

    @MainActor
    func testLastOpenedPresentationUsesJustNowForRecentDates() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            SessionLastOpenedText.value(
                for: referenceDate.addingTimeInterval(-30),
                relativeTo: referenceDate
            ),
            "Opened just now"
        )
    }

    func testProjectionPreservesCanonicalActiveOrderAndMarksSelection() {
        let production = makeServer(name: "Production")
        let macMini = makeServer(name: "Mac Mini")
        let newest = makeWorkspace(
            server: production,
            name: "api",
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )
        let selected = makeWorkspace(
            server: macMini,
            name: "codex",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [production, macMini],
                workspaces: [newest, selected]
            ),
            activeSessions: [
                makeSession(server: production, workspace: newest),
                makeSession(server: macMini, workspace: selected),
            ],
            selectedSessionID: selected.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [newest.id, selected.id])
        XCTAssertEqual(projection.activeSessions.map(\.sessionName), ["api", "codex"])
        XCTAssertEqual(projection.activeSessions.map(\.serverName), ["Production", "Mac Mini"])
        XCTAssertEqual(projection.activeSessions.map(\.isSelected), [false, true])
    }

    func testProjectionKeepsEveryActiveRuntimeWhenNamesMatch() {
        let server = makeServer(name: "Production")
        let first = makeWorkspace(
            server: server,
            name: "shared",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let second = makeWorkspace(
            server: server,
            name: "shared",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: [first, second]),
            activeSessions: [
                makeSession(server: server, workspace: first),
                makeSession(server: server, workspace: second),
            ],
            discoveries: [server.id: loadedDiscovery(["shared"])],
            selectedSessionID: second.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(projection.activeSessions.map(\.isSelected), [false, true])
        XCTAssertTrue(projection.availableSessions.isEmpty)
    }

    func testProjectionSeparatesConfirmedRecentFromGlobalAvailableSessions() {
        let production = makeServer(name: "Production")
        let staging = makeServer(name: "Staging")
        let active = makeWorkspace(
            server: production,
            name: "active",
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )
        let recent = makeWorkspace(
            server: production,
            name: "recent",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let missing = makeWorkspace(
            server: production,
            name: "gone",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [production, staging],
                workspaces: [active, recent, missing]
            ),
            activeSessions: [makeSession(server: production, workspace: active)],
            discoveries: [
                production.id: loadedDiscovery(["active", "recent", "remote"]),
                staging.id: loadedDiscovery(["logs"]),
            ],
            selectedSessionID: active.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [active.id])
        XCTAssertEqual(projection.recentSessions.map(\.id), [recent.id])
        XCTAssertEqual(
            projection.availableSessions.map(\.id),
            [
                RemoteSessionIdentity(serverID: production.id, locator: SessionLocator(backend: .tmux, name: "remote")),
                RemoteSessionIdentity(serverID: staging.id, locator: SessionLocator(backend: .tmux, name: "logs")),
            ]
        )
        XCTAssertFalse(projection.recentSessions.contains { $0.id == missing.id })
        XCTAssertFalse(
            projection.availableSessions.contains { $0.id.locator.name == "recent" }
        )
        XCTAssertEqual(projection.availableSessions(on: production.id).map(\.id.locator.name), ["remote"])
        XCTAssertEqual(projection.availableSessions(on: staging.id).map(\.id.locator.name), ["logs"])
    }

    func testSameNamedTmuxAndHerdrSessionsStayDistinct() {
        let server = makeServer(name: "Production")
        let herdrOps = SavedWorkspace(
            serverID: server.id,
            backend: .herdr,
            sessionName: "ops",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let herdrAgents = SavedWorkspace(
            serverID: server.id,
            backend: .herdr,
            sessionName: "agents",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: [herdrOps, herdrAgents]),
            activeSessions: [],
            discoveries: [server.id: loadedDiscovery(["ops"])],
            selectedSessionID: nil
        )

        // tmux discovery neither hides Herdr sessions it doesn't list nor
        // treats a Herdr "ops" as the tmux "ops" it does list.
        XCTAssertEqual(projection.recentSessions.map(\.id), [herdrOps.id, herdrAgents.id])
        XCTAssertEqual(
            projection.availableSessions.map(\.id),
            [RemoteSessionIdentity(serverID: server.id, locator: SessionLocator(backend: .tmux, name: "ops"))]
        )
    }

    func testProjectionKeepsLargeAvailableInventoryOutOfQuickSheet() {
        let server = makeServer(name: "Production")
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: []),
            activeSessions: [],
            discoveries: [
                server.id: loadedDiscovery(["one", "two", "three", "four", "five"]),
            ],
            selectedSessionID: nil
        )

        XCTAssertEqual(projection.availableSessions.count, 5)
        XCTAssertEqual(projection.inlineAvailableSessions.count, 3)
        XCTAssertEqual(projection.hiddenAvailableSessionCount, 2)
        XCTAssertEqual(
            projection.availableSessions(on: server.id),
            projection.availableSessions
        )
        XCTAssertEqual(
            projection.inlineAvailableSessions.map(\.id.locator.name),
            Array(projection.availableSessions.prefix(3)).map(\.id.locator.name)
        )
    }

    func testProjectionIncludesEveryInactiveWorkspaceInRecentOrder() {
        let server = makeServer(name: "Mac Mini")
        let workspaces = (0..<7).map { index in
            makeWorkspace(
                server: server,
                name: "session-\(index)",
                lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: workspaces),
            activeSessions: [],
            selectedSessionID: nil
        )

        XCTAssertEqual(projection.recentSessions.count, 7)
        XCTAssertEqual(
            projection.recentSessions.map(\.sessionName),
            (0..<7).reversed().map { "session-\($0)" }
        )
        XCTAssertEqual(projection.recentSessions.map(\.serverName), Array(repeating: "Mac Mini", count: 7))
    }

    func testProjectionExcludesActiveWorkspaceFromRecentSessionsByIdentity() {
        let server = makeServer(name: "Production")
        let persistedActive = makeWorkspace(
            server: server,
            name: "api",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        var runtimeActive = persistedActive
        runtimeActive.lastOpenedAt = Date(timeIntervalSince1970: 300)
        let recent = makeWorkspace(
            server: server,
            name: "logs",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [server],
                workspaces: [persistedActive, recent]
            ),
            activeSessions: [makeSession(server: server, workspace: runtimeActive)],
            selectedSessionID: runtimeActive.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [runtimeActive.id])
        XCTAssertEqual(projection.recentSessions.map(\.id), [recent.id])
    }

    func testProjectionOmitsWorkspaceWhoseServerIsUnavailable() {
        let savedServer = makeServer(name: "Production")
        let missingServer = makeServer(name: "Removed")
        let available = makeWorkspace(
            server: savedServer,
            name: "api",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let orphan = makeWorkspace(
            server: missingServer,
            name: "orphan",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [savedServer],
                workspaces: [available, orphan]
            ),
            activeSessions: [],
            selectedSessionID: nil
        )

        XCTAssertEqual(projection.recentSessions.map(\.id), [available.id])
    }

    func testOrderedServersPlacesCurrentServerFirstAndPreservesLibraryOrder() {
        let production = makeServer(name: "Production")
        let macMini = makeServer(name: "Mac Mini")
        let staging = makeServer(name: "Staging")

        let ordered = SessionSwitcherProjection.orderedServers(
            [production, staging, macMini],
            currentServerID: staging.id
        )

        XCTAssertEqual(ordered.map(\.id), [staging.id, production.id, macMini.id])
        XCTAssertEqual(
            SessionSwitcherProjection.orderedServers([production, macMini], currentServerID: nil),
            [production, macMini]
        )
    }

    private func snapshot(
        servers: [SavedServer],
        workspaces: [SavedWorkspace]
    ) -> ConnectionLibrarySnapshot {
        ConnectionLibrarySnapshot(servers: servers, workspaces: workspaces)
    }

    private func makeWorkspace(
        server: SavedServer,
        name: String,
        lastOpenedAt: Date
    ) -> SavedWorkspace {
        SavedWorkspace(
            serverID: server.id,
            sessionName: name,
            lastOpenedAt: lastOpenedAt
        )
    }

    private func makeSession(
        server: SavedServer,
        workspace: SavedWorkspace
    ) -> ActiveTerminalSession {
        let auth = ResolvedSSHAuth.password(
            username: server.username,
            password: "test-password",
            identityID: server.identityID,
            displayLabel: server.displayName
        )
        return ActiveTerminalSession(
            target: SessionTarget(
                server: server,
                workspace: workspace,
                sshAuth: auth
            ),
            runtimeState: .connected
        )
    }

    private func loadedDiscovery(
        _ tmuxNames: [String],
        herdr: [DiscoveredSession]? = nil
    ) -> ServerSessionDiscovery {
        ServerSessionDiscovery(
            tmux: SessionDiscoveryState.idle.finishingRefresh(
                with: tmuxNames.map { DiscoveredSession(name: $0, isRunning: true) }
            ),
            herdr: herdr.map { SessionDiscoveryState.idle.finishingRefresh(with: $0) } ?? .idle
        )
    }

    private func makeServer(name: String) -> SavedServer {
        SavedServer(
            displayName: name,
            host: "\(name.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
            username: "tester",
            identityID: UUID()
        )
    }
}
