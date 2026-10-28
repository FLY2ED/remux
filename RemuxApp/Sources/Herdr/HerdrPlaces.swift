import Foundation

/// A place in a Herdr session that Remux takes this phone to, with the command Herdr's client sends for
/// it: a pane (`pane.focus`), a tab (`tab.focus`), or a workspace, which shows the tab this phone last
/// had there (`workspace.focus`).
enum HerdrPlace: Hashable, Sendable {
    case pane(String)
    case tab(String)
    case workspace(String)

    var focusMethod: String {
        switch self {
        case .pane: HerdrScreenModel.paneFocusMethod
        case .tab: "tab.focus"
        case .workspace: "workspace.focus"
        }
    }

    var focusParams: [String: String] {
        switch self {
        case .pane(let id): ["pane_id": id]
        case .tab(let id): ["tab_id": id]
        case .workspace(let id): ["workspace_id": id]
        }
    }

    /// What a failed move says it couldn't do.
    var focusFailureLabel: String {
        switch self {
        case .pane: "select pane"
        case .tab: "select tab"
        case .workspace: "select workspace"
        }
    }
}

/// A pane Remux asks Herdr to make, in a new tab, a new workspace or beside a pane, focused as Herdr's
/// client makes them (`tab.create`, `workspace.create`, `pane.split`). Herdr's answer names the pane.
enum HerdrCreation: Equatable, Sendable {
    /// A tab in the workspace.
    case tab(workspaceID: String)
    /// A workspace whose pane starts in a directory Herdr's settings take from `source`'s focused pane.
    case workspace(source: String?)
    /// A pane beside `pane` in its tab, as Herdr's client splits the focused pane of its workspace.
    case split(pane: String, workspaceID: String?, direction: SplitDirection)

    enum SplitDirection: String, Encodable, Sendable {
        case right
        case down
    }

    var method: String {
        switch self {
        case .tab: "tab.create"
        case .workspace: "workspace.create"
        case .split: "pane.split"
        }
    }

    var params: Params {
        switch self {
        case .tab(let workspaceID):
            Params(workspaceID: workspaceID)
        case .workspace(let source):
            Params(sourceWorkspaceID: source)
        case .split(let pane, let workspaceID, let direction):
            Params(workspaceID: workspaceID, targetPaneID: pane, direction: direction)
        }
    }

    var failureLabel: String {
        switch self {
        case .tab: "new tab"
        case .workspace: "new workspace"
        case .split: "split pane"
        }
    }

    /// The place on the tab the new pane goes in, when that tab is there already: a split's pane. New
    /// Tab and New Workspace make their tab.
    var tabPlace: HerdrPlace? {
        guard case .split(let pane, _, _) = self else { return nil }
        return .pane(pane)
    }

    /// The pane Herdr made, from its answer (`api/schema/response.rs`): the first pane of a new tab or
    /// workspace (`root_pane`), or a split's (`pane`).
    static func pane(madeIn reply: Data) -> String? {
        struct Reply: Decodable {
            struct Result: Decodable {
                let rootPane: Pane?
                let pane: Pane?

                private enum CodingKeys: String, CodingKey {
                    case rootPane = "root_pane"
                    case pane
                }
            }

            struct Pane: Decodable {
                let paneID: String

                private enum CodingKeys: String, CodingKey {
                    case paneID = "pane_id"
                }
            }

            let result: Result
        }
        guard let result = try? JSONDecoder().decode(Reply.self, from: reply).result else { return nil }
        return (result.rootPane ?? result.pane)?.paneID
    }

    struct Params: Encodable, Sendable {
        var workspaceID: String?
        var sourceWorkspaceID: String?
        var targetPaneID: String?
        var direction: SplitDirection?
        let focus = true

        private enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case sourceWorkspaceID = "source_workspace_id"
            case targetPaneID = "target_pane_id"
            case direction
            case focus
        }
    }
}

/// Where Remux takes a Herdr session: a place there already, or the pane a creation makes.
enum HerdrDestination: Equatable, Sendable {
    case place(HerdrPlace)
    case creation(HerdrCreation)

    /// The place it names, which must still be on the server for it to go: the place, or the workspace
    /// or pane a creation starts from.
    var origin: HerdrPlace? {
        switch self {
        case .place(let place): place
        case .creation(.tab(let workspaceID)): .workspace(workspaceID)
        case .creation(.workspace(let source)): source.map(HerdrPlace.workspace)
        case .creation(.split(let pane, _, _)): .pane(pane)
        }
    }
}

extension HerdrSnapshot {
    /// The tab a move to `place` shows: a pane's tab, the tab, or the tab this phone has in the workspace.
    func tabID(reachedBy place: HerdrPlace) -> String? {
        switch place {
        case .pane(let id): panes.first { $0.paneID == id }?.tabID
        case .tab(let id): tabs.contains { $0.tabID == id } ? id : nil
        case .workspace(let id): workspaces.first { $0.workspaceID == id }?.activeTabID
        }
    }

    /// Whether this phone is at `place` already.
    func isAt(_ place: HerdrPlace) -> Bool {
        switch place {
        case .pane(let id): focusedPaneID == id
        case .tab(let id): focusedTabID == id
        case .workspace(let id): focusedWorkspaceID == id
        }
    }

    /// Whether `place` is still on the server.
    func contains(_ place: HerdrPlace) -> Bool {
        switch place {
        case .pane(let id): panes.contains { $0.paneID == id }
        case .tab(let id): tabs.contains { $0.tabID == id }
        case .workspace(let id): workspaces.contains { $0.workspaceID == id }
        }
    }
}

/// A Herdr session's workspaces and their tabs as Remux lists them, from its newest snapshot, in Herdr's
/// order. It also remembers the workspaces this phone was in, which the Tabs sheet offers first.
struct HerdrSessionOutline: Equatable, Sendable {
    struct Workspace: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let tabs: [Tab]
    }

    struct Tab: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let paneIDs: [String]
    }

    let bootID: String
    let workspaces: [Workspace]
    let focusedWorkspaceID: String?
    /// The workspaces this phone was in, the newest first. Workspace ids belong to a server boot, so a new
    /// boot starts over.
    private let visited: [String]

    init(_ snapshot: HerdrSnapshot, after previous: HerdrSessionOutline?) {
        bootID = snapshot.bootID
        let tabs = Dictionary(grouping: snapshot.tabs, by: \.workspaceID)
        let panes = Dictionary(grouping: snapshot.panes, by: \.tabID)
        workspaces = snapshot.workspaces.map { workspace in
            Workspace(
                id: workspace.workspaceID,
                label: workspace.label,
                tabs: (tabs[workspace.workspaceID] ?? []).map { tab in
                    Tab(id: tab.tabID, label: tab.label, paneIDs: (panes[tab.tabID] ?? []).map(\.paneID))
                }
            )
        }
        focusedWorkspaceID = snapshot.focusedWorkspaceID
        let earlier = previous?.bootID == snapshot.bootID ? previous?.visited ?? [] : []
        let existing = Set(snapshot.workspaces.map(\.workspaceID))
        visited = ([snapshot.focusedWorkspaceID].compactMap { $0 } + earlier.filter { $0 != snapshot.focusedWorkspaceID })
            .filter(existing.contains)
    }

    /// The workspaces this phone was in, the newest first, then the rest in Herdr's order.
    var workspacesByRecency: [Workspace] {
        visited.compactMap { workspace($0) } + workspaces.filter { !visited.contains($0.id) }
    }

    func workspace(_ id: String) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func workspace(containingTab tabID: String) -> Workspace? {
        workspaces.first { $0.tabs.contains { $0.id == tabID } }
    }
}

/// A session's outline for the views that list its places, such as the Sessions sheet. It publishes
/// only when the outline changes, not with every snapshot.
@MainActor
final class HerdrSessionPlaces: ObservableObject {
    @Published private(set) var outline: HerdrSessionOutline?

    /// Returns whether the outline changed.
    func update(with snapshot: HerdrSnapshot) -> Bool {
        let next = HerdrSessionOutline(snapshot, after: outline)
        guard next != outline else { return false }
        outline = next
        return true
    }
}
