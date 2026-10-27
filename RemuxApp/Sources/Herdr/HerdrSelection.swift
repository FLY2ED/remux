import Foundation

/// `pane.selection.read`: the plain text between two cells of a pane, read by Herdr from the pane's
/// terminal, history included. Rows count from the top of the history, the viewport's top row being
/// `max_offset_from_bottom - offset_from_bottom`, as Herdr's client counts them (`selection.rs`); soft-
/// wrapped rows come back as one line.
///
/// As Herdr's client copies an explicit selection (`request_selection_copy` with `live`), no content
/// revision goes with it: rows counted from the top of the history stay with their lines as output
/// arrives, so Herdr reads the live terminal instead of refusing a copy over output that came after the
/// frame on screen.
struct HerdrSelectionRead: Encodable, Sendable {
    struct Point: Encodable, Sendable {
        let row: UInt32
        let col: UInt16
    }

    let paneID: String
    let anchor: Point
    let cursor: Point

    /// `selection`'s cells in reading order, as Herdr's client sends them.
    init(paneID: String, selection: GhosttyHistorySelection) {
        func point(_ cell: GhosttyTerminalCell) -> Point {
            Point(row: UInt32(clamping: cell.row), col: cell.column)
        }
        let (first, last) = selection.ordered
        self.paneID = paneID
        anchor = point(first)
        cursor = point(last)
    }

    /// Reads the text from the reply `{"id", "result": {"type": "pane_selection", "pane_id", "text"}}`.
    static func text(fromReply reply: Data) throws -> String {
        struct Reply: Decodable {
            struct Result: Decodable {
                let text: String
            }

            let result: Result
        }
        return try JSONDecoder().decode(Reply.self, from: reply).result.text
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case anchor, cursor
    }
}
