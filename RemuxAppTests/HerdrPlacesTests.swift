import Combine
import XCTest
@testable import Remux

/// The places Remux lists and moves to in a Herdr session, from Herdr's snapshot.
final class HerdrPlacesTests: XCTestCase {
    /// The outline lists the snapshot's workspaces in Herdr's order, each with its tabs and their panes.
    func testTheOutlineListsWorkspacesWithTheirTabsInHerdrsOrder() throws {
        let outline = HerdrSessionOutline(try snapshot(workspaces: ["api", "web"], focusedWorkspace: "web"), after: nil)

        XCTAssertEqual(outline.workspaces.map(\.label), ["api", "web"])
        XCTAssertEqual(outline.workspaces[0].tabs.map(\.id), ["api-t1", "api-t2"])
        XCTAssertEqual(outline.workspaces[0].tabs[1].paneIDs, ["api-t2-p1", "api-t2-p2"])
        XCTAssertEqual(outline.focusedWorkspaceID, "web")
        XCTAssertEqual(outline.workspace(containingTab: "web-t2")?.id, "web")
    }

    /// The Tabs sheet offers the workspaces this phone was in, the newest first, then the rest in Herdr's
    /// order, so its first three capsules follow the user and More holds the rest.
    func testWorkspacesComeByRecencyThenInHerdrsOrder() throws {
        let names = ["a", "b", "c", "d", "e", "f", "g", "h"]
        var outline: HerdrSessionOutline?
        for visit in ["c", "f", "a", "f"] {
            outline = HerdrSessionOutline(try snapshot(workspaces: names, focusedWorkspace: visit), after: outline)
        }
        XCTAssertEqual(outline?.workspacesByRecency.map(\.id), ["f", "a", "c", "b", "d", "e", "g", "h"])

        // The same rule at four workspaces.
        var four: HerdrSessionOutline?
        for visit in ["d", "b"] {
            four = HerdrSessionOutline(try snapshot(workspaces: Array(names.prefix(4)), focusedWorkspace: visit), after: four)
        }
        XCTAssertEqual(four?.workspacesByRecency.map(\.id), ["b", "d", "a", "c"])
    }

    /// A workspace that closes leaves the order; a new server boot has new workspaces, so it starts over.
    func testRecencyDropsClosedWorkspacesAndStartsOverOnANewBoot() throws {
        var outline = HerdrSessionOutline(try snapshot(workspaces: ["a", "b", "c"], focusedWorkspace: "c"), after: nil)
        outline = HerdrSessionOutline(try snapshot(workspaces: ["a", "b", "c"], focusedWorkspace: "b"), after: outline)
        outline = HerdrSessionOutline(try snapshot(workspaces: ["a", "b"], focusedWorkspace: "b"), after: outline)
        XCTAssertEqual(outline.workspacesByRecency.map(\.id), ["b", "a"])

        let restarted = HerdrSessionOutline(
            try snapshot(boot: "new", workspaces: ["a", "b", "c"], focusedWorkspace: "a"),
            after: outline
        )
        XCTAssertEqual(restarted.workspacesByRecency.map(\.id), ["a", "b", "c"])
    }

    /// The places publish only when the outline changes, not with each snapshot.
    @MainActor
    func testThePlacesPublishOnlyWhenTheOutlineChanges() throws {
        let places = HerdrSessionPlaces()
        var published = 0
        let subscription = places.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        XCTAssertTrue(places.update(with: try snapshot(workspaces: ["a", "b"], focusedWorkspace: "a")))
        XCTAssertFalse(places.update(with: try snapshot(revision: 2, workspaces: ["a", "b"], focusedWorkspace: "a")))
        XCTAssertTrue(places.update(with: try snapshot(revision: 3, workspaces: ["a", "b"], focusedWorkspace: "b")))
        XCTAssertEqual(published, 2)
    }

    /// Each place is reached with the command Herdr's client sends for it, and shows its tab.
    func testEachPlaceHasHerdrsFocusCommandAndReachesItsTab() throws {
        let snapshot = try snapshot(workspaces: ["a", "b"], focusedWorkspace: "a", activeTabs: ["b": "b-t2"])
        XCTAssertEqual(HerdrPlace.pane("b-t2-p2").focusMethod, "pane.focus")
        XCTAssertEqual(HerdrPlace.tab("b-t1").focusParams, ["tab_id": "b-t1"])
        XCTAssertEqual(HerdrPlace.workspace("b").focusMethod, "workspace.focus")
        XCTAssertEqual(HerdrPlace.workspace("b").focusParams, ["workspace_id": "b"])

        XCTAssertEqual(snapshot.tabID(reachedBy: .pane("b-t2-p2")), "b-t2")
        XCTAssertEqual(snapshot.tabID(reachedBy: .tab("b-t1")), "b-t1")
        XCTAssertEqual(snapshot.tabID(reachedBy: .workspace("b")), "b-t2", "a workspace shows this phone's tab there")
        XCTAssertNil(snapshot.tabID(reachedBy: .tab("gone")))
        XCTAssertTrue(snapshot.isAt(.workspace("a")))
        XCTAssertTrue(snapshot.isAt(.tab("a-t1")))
        XCTAssertFalse(snapshot.isAt(.tab("b-t1")))
    }

    /// New Tab and New Workspace ask for what they make to be focused, as Herdr's client does.
    func testCreationsAskHerdrToFocusWhatTheyMake() throws {
        func encoded(_ creation: HerdrCreation) throws -> [String: AnyHashable] {
            let data = try JSONEncoder().encode(creation.params)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
        }
        XCTAssertEqual(HerdrCreation.tab(workspaceID: "w2").method, "tab.create")
        XCTAssertEqual(try encoded(.tab(workspaceID: "w2")), ["workspace_id": "w2", "focus": true])
        XCTAssertEqual(HerdrCreation.workspace(source: "w1").method, "workspace.create")
        XCTAssertEqual(try encoded(.workspace(source: "w1")), ["source_workspace_id": "w1", "focus": true])
    }

    /// Workspaces named by `workspaces`, each with tabs `<name>-t1` (one pane) and `<name>-t2` (two
    /// panes), this phone in `focusedWorkspace` at its tab from `activeTabs`, else its first.
    private func snapshot(
        boot: String = "boot",
        revision: UInt64 = 1,
        workspaces: [String],
        focusedWorkspace: String,
        activeTabs: [String: String] = [:]
    ) throws -> HerdrSnapshot {
        let focusedTab = activeTabs[focusedWorkspace] ?? "\(focusedWorkspace)-t1"
        let entries = workspaces.enumerated().map { index, name in
            #"{"workspace_id":"\#(name)","active_tab_id":"\#(activeTabs[name] ?? "\(name)-t1")","number":\#(index + 1),"label":"\#(name)","custom_label":true,"focused":\#(name == focusedWorkspace),"agent_status":"idle"}"#
        }
        let tabs = workspaces.flatMap { name in
            ["t1", "t2"].enumerated().map { index, tab in
                #"{"tab_id":"\#(name)-\#(tab)","workspace_id":"\#(name)","number":\#(index + 1),"label":"\#(tab)","custom_label":false,"zoomed":false,"focused":\#("\(name)-\(tab)" == focusedTab),"agent_status":"idle"}"#
            }
        }
        let panes = workspaces.flatMap { name in
            [("t1", 1), ("t2", 2)].flatMap { tab, count in
                (1...count).map { pane in
                    #"{"pane_id":"\#(name)-\#(tab)-p\#(pane)","workspace_id":"\#(name)","tab_id":"\#(name)-\#(tab)","label":null,"cwd":null,"foreground_cwd":null,"focused":false}"#
                }
            }
        }
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":"\(focusedWorkspace)","focused_tab_id":"\(focusedTab)",
         "focused_pane_id":null,"workspaces":[\(entries.joined(separator: ","))],"tabs":[\(tabs.joined(separator: ","))],
         "panes":[\(panes.joined(separator: ","))],"agents":[]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }
}
