import Foundation

/// Herdr's answer to `pane.zoom` (`api/schema/panes.rs`, `PaneZoomResult`): whether the zoom changed,
/// the tab's zoom after it, and where every pane of the tab sits, also while the tab is zoomed. The
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
                let layout: Layout

                private enum CodingKeys: String, CodingKey {
                    case zoomChanged = "zoom_changed"
                    case zoomed, layout
                }
            }

            let result: Result
        }
        let zoom = try JSONDecoder().decode(Reply.self, from: reply).result.zoom
        zoomChanged = zoom.zoomChanged
        zoomed = zoom.zoomed
        layout = zoom.layout
    }
}

/// The zoom Remux made on a Herdr session. Herdr's zoom is a flag on the tab with no owner, so
/// Remux remembers the tab it zoomed, from Herdr's answer saying the zoom changed to on, until a snapshot
/// shows that tab unzoomed or gone, or Herdr's answer to Remux's own unzoom says so. Tabs belong to one
/// server boot, so another boot forgets it; a reconnect to the same boot keeps it.
///
/// Remux zooms only the tab on screen, and takes its zoom off a tab before it moves the session to
/// another, so it records one tab. When another client moves the session, the record stays with the tab
/// left, and Remux undoes that zoom only while its tab is on screen, since an unzoom focuses its target.
struct HerdrOwnedZoom: Equatable {
    private var tab: HerdrTabKey?

    mutating func record(_ answer: HerdrPaneZoomResult, bootID: String) {
        guard answer.zoomChanged else { return }
        let answered = HerdrTabKey(bootID: bootID, tabID: answer.layout.tabID)
        if answer.zoomed {
            tab = answered
        } else if tab == answered {
            tab = nil
        }
    }

    mutating func reconcile(with snapshot: HerdrSnapshot) {
        guard let tab else { return }
        if tab.bootID != snapshot.bootID || !snapshot.tabs.contains(where: { $0.tabID == tab.tabID && $0.zoomed }) {
            self.tab = nil
        }
    }

    /// The pane to unzoom the tab with when the session leaves the screen: the tab's focused pane, since an
    /// unzoom focuses its target. Nil unless the tab Remux zoomed is the one on screen.
    func paneToUnzoom(in snapshot: HerdrSnapshot) -> String? {
        guard let tab, tab.bootID == snapshot.bootID, tab.tabID == snapshot.focusedTabID else { return nil }
        return snapshot.focusedPaneID
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
