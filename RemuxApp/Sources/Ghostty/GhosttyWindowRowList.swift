import SwiftUI
import UIKit

/// The windows as a plain list, as the Sessions sheet lists sessions, for a backend that says what each window
/// holds. A row has its panes' marks, its name if the user gave it one and what its focused pane is doing, a
/// spinner while an agent in it works, and the checkmark on the window on screen. Its most urgent agent's
/// other states show as the dot on its front mark. A long press offers Close.
struct GhosttyWindowRowList: View {
    /// A row's content, without the list's insets above and below it.
    private static let contentHeight: CGFloat = 44
    private static let verticalInsets: CGFloat = 16

    @ScaledMetric(relativeTo: .body) private var contentHeight = GhosttyWindowRowList.contentHeight

    let windows: [GhosttyWindowSelectionSheetRenderProjection.Window]
    let topLevelNoun: GhosttyTopLevelNoun
    let onSelect: (GhosttyWindowSelectionSheetRenderProjection.Window) -> Void
    let onClose: (GhosttyWindowSelectionSheetRenderProjection.Window) -> Void

    /// The rows' height, as tall as `rowCount` rows at the user's text size, up to `maximumContentHeight`.
    @MainActor
    static func idealHeight(rowCount: Int, maximumContentHeight: CGFloat) -> CGFloat {
        let rowHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: contentHeight) + verticalInsets
        return min(CGFloat(rowCount) * rowHeight, maximumContentHeight)
    }

    var body: some View {
        List {
            ForEach(windows) { window in
                Button {
                    onSelect(window)
                } label: {
                    GhosttyWindowRow(window: window, topLevelNoun: topLevelNoun)
                        .frame(minHeight: contentHeight)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        onClose(window)
                    } label: {
                        Label("Close \(topLevelNoun.singular)", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("terminal.window.remove.\(window.displayIndex)")
                }
                .accessibilityAction(named: Text("Close \(topLevelNoun.singular)")) {
                    onClose(window)
                }
                .sessionSwitcherListRow(accessibilityIdentifier: "terminal.window.tile.\(window.displayIndex)")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct GhosttyWindowRow: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let window: GhosttyWindowSelectionSheetRenderProjection.Window
    let topLevelNoun: GhosttyTopLevelNoun

    var body: some View {
        HStack(spacing: 12) {
            TerminalProgramStack(
                programs: window.contents?.programs ?? [],
                paneCount: window.paneCount,
                dot: window.rowAgentMark?.dot
            )

            text
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if window.rowAgentMark == .spinner {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }

            if window.isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(chromeStyle.accent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.rowAccessibilityLabel(topLevelNoun: topLevelNoun))
        .accessibilityValue(window.contents?.activity ?? "")
        .accessibilityAddTraits(window.isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// The name, then what the focused pane is doing; either alone when the other is missing.
    private var text: Text {
        let activity = window.contents?.activity ?? ""
        switch (window.rowName, activity.isEmpty) {
        case (let name?, false):
            return Text(name).fontWeight(.medium).foregroundStyle(TerminalSelectionSheetPalette.primary)
                + Text(" · \(activity)").foregroundStyle(TerminalSelectionSheetPalette.secondary)
        case (let name?, true):
            return Text(name).fontWeight(.medium).foregroundStyle(TerminalSelectionSheetPalette.primary)
        case (nil, false):
            return Text(activity).foregroundStyle(TerminalSelectionSheetPalette.primary)
        case (nil, true):
            return Text("\(topLevelNoun.singular) \(window.displayIndex)")
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
        }
    }
}

/// How a window's row shows its most urgent agent.
enum GhosttyWindowRowAgentMark: Equatable {
    /// An agent in it is working.
    case spinner
    /// The state's dot on the front mark.
    case dot(TerminalAgentStatus)

    var dot: TerminalAgentStatus? {
        guard case .dot(let status) = self else { return nil }
        return status
    }
}

extension GhosttyWindowSelectionSheetRenderProjection.Window {
    /// A spinner while an agent in it works, else its most urgent agent's dot; nothing without agents, or
    /// before their state is known.
    var rowAgentMark: GhosttyWindowRowAgentMark? {
        switch agentStatus {
        case .working: .spinner
        case let status? where status != .unknown: .dot(status)
        default: nil
        }
    }

    /// The name its row shows: the user's, from what it holds, or its own name without that.
    var rowName: String? {
        guard let contents else { return displayName.isEmpty ? nil : displayName }
        return contents.name
    }

    /// What VoiceOver reads for its row: where it is, its name, its panes, its agent's state and whether it
    /// is on screen; what its focused pane is doing is the row's value.
    func rowAccessibilityLabel(topLevelNoun: GhosttyTopLevelNoun) -> String {
        var parts = ["\(topLevelNoun.singular) \(displayIndex) of \(totalCount)"]
        if let rowName { parts.append(rowName) }
        parts.append(paneCount == 1 ? "1 pane" : "\(paneCount) panes")
        if rowAgentMark != nil, let agentStatus { parts.append("agent \(agentStatus.word)") }
        if isSelected { parts.append("active") }
        return parts.joined(separator: ", ")
    }
}
