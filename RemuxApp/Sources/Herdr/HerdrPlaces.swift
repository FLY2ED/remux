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

/// A tab or workspace Remux asks Herdr to make, focused as Herdr's client makes them (`tab.create`,
/// `workspace.create`). Each starts with one pane.
enum HerdrCreation: Equatable, Sendable {
    /// A tab in the workspace.
    case tab(workspaceID: String)
    /// A workspace whose pane starts in a directory Herdr's settings take from `source`'s focused pane.
    case workspace(source: String?)

    var method: String {
        switch self {
        case .tab: "tab.create"
        case .workspace: "workspace.create"
        }
    }

    var params: Params {
        switch self {
        case .tab(let workspaceID): Params(workspaceID: workspaceID, sourceWorkspaceID: nil)
        case .workspace(let source): Params(workspaceID: nil, sourceWorkspaceID: source)
        }
    }

    var failureLabel: String {
        switch self {
        case .tab: "new tab"
        case .workspace: "new workspace"
        }
    }

    struct Params: Encodable, Sendable {
        let workspaceID: String?
        let sourceWorkspaceID: String?
        let focus = true

        private enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case sourceWorkspaceID = "source_workspace_id"
            case focus
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
