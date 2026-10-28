import UIKit

/// What `TerminalClipboard` needs of a pasteboard.
protocol TerminalPasteboard: AnyObject {
    var changeCount: Int { get }
    var string: String? { get set }
}

extension UIPasteboard: TerminalPasteboard {}

/// The iPhone clipboard as programs in a session's panes write it (OSC 52), one for the app, as the
/// clipboard is. As Herdr's client skips a write the clipboard already holds, a write of the text the last
/// one left there, untouched since, isn't written again. The pasteboard's change count tells that without
/// reading the pasteboard, which iOS asks the user to allow when another app wrote it.
@MainActor
final class TerminalClipboard {
    static let general = TerminalClipboard(pasteboard: UIPasteboard.general)

    private let pasteboard: any TerminalPasteboard
    private var lastWrite: (text: String, changeCount: Int)?

    init(pasteboard: any TerminalPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Puts `text` on the clipboard. False when the clipboard already held it from the last write, or
    /// the pasteboard didn't take it.
    func write(_ text: String) -> Bool {
        if let lastWrite, lastWrite.text == text, lastWrite.changeCount == pasteboard.changeCount {
            return false
        }
        let before = pasteboard.changeCount
        pasteboard.string = text
        guard pasteboard.changeCount != before else { return false }
        lastWrite = (text, pasteboard.changeCount)
        return true
    }
}
