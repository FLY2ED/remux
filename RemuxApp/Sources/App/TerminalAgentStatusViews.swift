import SwiftUI
import UIKit

extension TerminalAgentStatus {
    /// Herdr's colours for the states (`client/shell.rs` `status_color`), from the themes Herdr pairs by
    /// default (`config/theme.rs`): Catppuccin Mocha in dark appearance and Latte in light
    /// (`app/state.rs`). An unknown state takes the themes' muted grey, as do agents whose session isn't
    /// connected, since their state may be out of date.
    var color: Color {
        let (dark, light): (UIColor, UIColor) = switch self {
        case .working: (Self.rgb(249, 226, 175), Self.rgb(223, 142, 29))
        case .blocked: (Self.rgb(243, 139, 168), Self.rgb(210, 15, 57))
        case .done: (Self.rgb(148, 226, 213), Self.rgb(23, 146, 153))
        case .idle: (Self.rgb(166, 227, 161), Self.rgb(64, 160, 43))
        case .unknown: (Self.rgb(108, 112, 134), Self.rgb(156, 160, 176))
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}

/// An agent's dot: a session's, workspace's or tab's most urgent agent, or one agent's state. It says
/// nothing to VoiceOver; the row or tile it is on names the state.
struct TerminalAgentDot: View {
    let status: TerminalAgentStatus
    var size: CGFloat = 8
    /// The agent's session isn't connected, so the state may be out of date.
    var isStale = false

    var body: some View {
        Circle()
            .fill(isStale ? TerminalAgentStatus.unknown.color : status.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// An agent's state as a pane tile adds it: the dot and the word, in the state's colour.
struct TerminalAgentStateLine: View {
    let state: TerminalAgentState

    var body: some View {
        HStack(spacing: 4) {
            TerminalAgentDot(status: state.status, size: 7)
            Text(state.word)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(state.status.color)
        .lineLimit(1)
    }
}
