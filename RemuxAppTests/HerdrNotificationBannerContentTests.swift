import XCTest
@testable import Remux

/// What a Herdr banner says: the title in Herdr's mobile wording (`client/shell/notifications.rs`), the
/// place by name, and the server and session when the banner comes from a session not on screen, as in
/// the design picked on 26 October.
final class HerdrNotificationBannerContentTests: XCTestCase {
    private func banner(
        _ kind: HerdrSemanticNotification.Kind,
        _ title: String,
        body: String? = nil,
        session: String = "default",
        server: String = "gpu-box",
        place: HerdrNotificationPlace = HerdrNotificationPlace()
    ) throws -> HerdrNotificationPolicy.Banner {
        let frame = HerdrServerScript.notification(kind, title: title, body: body, workspace: "w1", tab: "w1:t2", pane: "w1:p3")
        guard case .semanticNotification(let notification) = try HerdrServerMessage.decode(Array(frame.dropFirst(4)))
        else { throw CancellationError() }
        return HerdrNotificationPolicy.Banner(
            id: 1,
            origin: HerdrNotificationPolicy.Origin(
                workspaceID: UUID(),
                sessionName: session,
                serverName: server,
                bootID: "boot",
                place: place
            ),
            notification: notification,
            arrived: .now
        )
    }

    private func content(_ banner: HerdrNotificationPolicy.Banner, shown: Bool) -> HerdrNotificationBannerContent {
        HerdrNotificationBannerContent(banner, fromShownSession: shown)
    }

    func testTitlesAreWordedAsHerdrsMobileLayout() throws {
        XCTAssertEqual(content(try banner(.needsAttention, "codex needs attention"), shown: true).title, "codex waiting")
        XCTAssertEqual(content(try banner(.finished, "claude finished"), shown: true).title, "claude done")
        XCTAssertEqual(content(try banner(.updateInstalled, "herdr updated"), shown: true).title, "update ready")
        XCTAssertEqual(content(try banner(.custom, "build passed"), shown: true).title, "build passed")
        XCTAssertEqual(content(try banner(.needsAttention, "odd title"), shown: true).title, "odd title")
    }

    /// An agent's dot is its state's, an update's or a custom one's Herdr's accent.
    func testTheDotIsTheAgentsState() throws {
        XCTAssertEqual(content(try banner(.needsAttention, "a needs attention"), shown: true).dot, .status(.waiting))
        XCTAssertEqual(content(try banner(.finished, "a finished"), shown: true).dot, .status(.done))
        XCTAssertEqual(content(try banner(.custom, "c"), shown: true).dot, .accent)
    }

    /// On the session on screen the place is the workspace and tab; from another session the server
    /// comes first, and the session only when it isn't Herdr's default one.
    func testThePlaceNamesTheServerAndSessionOnlyFromElsewhere() throws {
        let place = HerdrNotificationPlace(workspace: "train", tab: "main")
        XCTAssertEqual(content(try banner(.needsAttention, "codex needs attention", place: place), shown: true).place, "train › main")
        XCTAssertEqual(
            content(try banner(.needsAttention, "claude needs attention", place: place), shown: false).place,
            "gpu-box · train › main"
        )
        XCTAssertEqual(
            content(try banner(.needsAttention, "claude needs attention", session: "agents", place: place), shown: false).place,
            "gpu-box · agents · train › main"
        )
        XCTAssertEqual(
            content(try banner(.finished, "claude finished", place: HerdrNotificationPlace(workspace: "remux", tab: "2")), shown: true).place,
            "remux › 2"
        )
        XCTAssertEqual(
            content(try banner(.finished, "claude finished", place: HerdrNotificationPlace(workspace: "web")), shown: true).place,
            "web"
        )
    }

    /// An agent's own context line numbers its workspace, so it is never shown; a custom notification's
    /// body is its message.
    func testNumbersNeverShowAndACustomBodyIsItsMessage() throws {
        let numbered = try banner(.needsAttention, "claude needs attention", body: "web · 2 · 1")
        XCTAssertNil(content(numbered, shown: true).place)
        XCTAssertEqual(content(numbered, shown: false).place, "gpu-box")
        XCTAssertEqual(content(try banner(.custom, "build", body: "all green"), shown: true).place, "all green")
        XCTAssertEqual(content(try banner(.custom, "build", body: "all green"), shown: false).place, "gpu-box · all green")
    }

    /// The names come from the snapshot, as Herdr gives them: the workspace's label and the tab's, which for
    /// a tab without a label of its own is its number.
    func testThePlaceIsNamedFromTheSnapshot() throws {
        let json = """
        {"boot_id":"b","revision":1,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":null,
         "workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","number":1,"label":"web","custom_label":false,
           "focused":true,"agent_status":"idle"}],
         "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","custom_label":false,"zoomed":false,
           "focused":true,"agent_status":"idle"},
          {"tab_id":"w1:t2","workspace_id":"w1","number":2,"label":"review","custom_label":true,"zoomed":false,
           "focused":false,"agent_status":"idle"}],
         "panes":[],"agents":[]}
        """
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
        func notification(tab: String?, workspace: String?) throws -> HerdrSemanticNotification {
            let frame = HerdrServerScript.notification(.needsAttention, title: "t", workspace: workspace, tab: tab)
            guard case .semanticNotification(let notification) = try HerdrServerMessage.decode(Array(frame.dropFirst(4)))
            else { throw CancellationError() }
            return notification
        }
        XCTAssertEqual(
            HerdrNotificationPlace(try notification(tab: "w1:t2", workspace: "w1"), in: snapshot),
            HerdrNotificationPlace(workspace: "web", tab: "review")
        )
        XCTAssertEqual(
            HerdrNotificationPlace(try notification(tab: "w1:t1", workspace: nil), in: snapshot),
            HerdrNotificationPlace(workspace: "web", tab: "1")
        )
        XCTAssertEqual(
            HerdrNotificationPlace(try notification(tab: nil, workspace: "w1"), in: snapshot),
            HerdrNotificationPlace(workspace: "web")
        )
        XCTAssertEqual(HerdrNotificationPlace(try notification(tab: "w1:t2", workspace: "w1"), in: nil), HerdrNotificationPlace())
    }
}
