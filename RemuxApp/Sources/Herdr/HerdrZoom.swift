import Foundation

/// Herdr's answer to `pane.zoom` (`api/schema/panes.rs`, `PaneZoomResult`): whether the zoom changed,
/// the tab's zoom after it, the pane focused there, and where every pane of the tab sits, also while the tab
/// is zoomed. The
/// rects are in the area of Herdr's foreground client, which the command makes this one; only their
/// proportions count here.
struct HerdrPaneZoomResult: Equatable, Sendable {
    struct Layout: Equatable, Sendable, Decodable {
        struct Pane: Equatable, Sendable, Decodable {
            let paneID: String
            let rect: HerdrSurfaceRect

            private enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case rect
            }
        }

        let tabID: String
        let panes: [Pane]

        private enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case panes
        }
    }

    let zoomChanged: Bool
    let zoomed: Bool
    /// The pane Herdr has focused on the tab after the command, which a zoom focuses.
    let focusedPaneID: String
    let layout: Layout

    /// Reads the result from the reply `{"id", "result": {"type": "pane_zoom", "zoom": {...}}}`.
    init(reply: Data) throws {
        struct Reply: Decodable {
            struct Result: Decodable {
                let zoom: Zoom
            }

            struct Zoom: Decodable {
                let zoomChanged: Bool
                let zoomed: Bool
                let focusedPaneID: String
                let layout: Layout

                private enum CodingKeys: String, CodingKey {
                    case zoomChanged = "zoom_changed"
                    case focusedPaneID = "focused_pane_id"
                    case zoomed, layout
                }
            }

            let result: Result
        }
        let zoom = try JSONDecoder().decode(Reply.self, from: reply).result.zoom
        zoomChanged = zoom.zoomChanged
        zoomed = zoom.zoomed
        focusedPaneID = zoom.focusedPaneID
        layout = zoom.layout
    }
}

/// The zooms Remux made on a Herdr session. Herdr's zoom is a flag on the tab with no owner
/// (`api/schema/panes.rs`), so Remux remembers each tab it zoomed, from Herdr's answers saying a zoom changed
/// to on, until a snapshot shows the tab unzoomed or gone, or Herdr's answer to Remux's own unzoom says so.
/// Remux keeps its zooms while the session moves between tabs and leaves the screen, as it keeps tmux's, and
/// takes them off as the session ends.
///
/// The phone keeps them (`HerdrOwnedZoomStore`), so an attachment after the app ended without ending the
/// session takes them over, also across a restart of Herdr's server: Herdr restores a tab's zoom with the
/// session (`persist/restore.rs`, `zoomed: snap.zoomed`), while each server process has a boot of its own
/// (`server/headless.rs`, the process id and its start time). Herdr 0.9.5 keeps tab and pane ids through a
/// restart and doesn't reuse them after a close. As a guard, a record holds the tab's panes too, and a tab
/// is Remux's only while it is zoomed and still has one of them; the record follows the tab's panes as they
/// change.
struct HerdrOwnedZooms: Equatable, Codable, Sendable {
    /// The panes of each tab Remux zoomed, by tab id.
    private(set) var panesByTab: [String: Set<String>] = [:]

    var tabIDs: Set<String> { Set(panesByTab.keys) }

    mutating func record(_ answer: HerdrPaneZoomResult) {
        guard answer.zoomChanged else { return }
        if answer.zoomed {
            panesByTab[answer.layout.tabID] = Set(answer.layout.panes.map(\.paneID))
        } else {
            panesByTab[answer.layout.tabID] = nil
        }
    }

    /// Keeps the tabs `snapshot` has zoomed that still have one of their recorded panes, with their panes now.
    mutating func reconcile(with snapshot: HerdrSnapshot) {
        guard !panesByTab.isEmpty else { return }
        var reconciled: [String: Set<String>] = [:]
        for (tab, panes) in panesByTab where snapshot.tabs.contains(where: { $0.tabID == tab && $0.zoomed }) {
            let current = Set(snapshot.panes.lazy.filter { $0.tabID == tab }.map(\.paneID))
            if !current.isDisjoint(with: panes) { reconciled[tab] = current }
        }
        panesByTab = reconciled
    }

    /// The tabs to take Remux's zoom off as the session ends, as `snapshot` has them: those off screen
    /// first, then the tab on screen, so the session ends where it was when it can.
    func tabsToRelease(in snapshot: HerdrSnapshot) -> [String] {
        var owned = self
        owned.reconcile(with: snapshot)
        let zoomed = snapshot.tabs.lazy.map(\.tabID).filter { owned.panesByTab[$0] != nil }
        return zoomed.filter { $0 != snapshot.focusedTabID } + zoomed.filter { $0 == snapshot.focusedTabID }
    }
}

/// A tab of a Herdr server; tab ids belong to one server boot.
struct HerdrTabKey: Hashable {
    let bootID: String
    let tabID: String
}

/// Where each pane of a tab sits, from the newest full layout Herdr reported for it: a frame that drew
/// every pane, or the answer to a zoom. A zoomed tab's frame draws one pane, so the pane sheet's map
/// takes the others from here; it shows proportions only, which either source gives.
struct HerdrTabMap: Equatable {
    let bootID: String
    let tabID: String
    let rects: [String: HerdrSurfaceRect]
}

/// The panes of a zoomed tab that its map has no place for.
struct HerdrTabMapGap: Equatable {
    let tab: HerdrTabKey
    let paneIDs: Set<String>
}
