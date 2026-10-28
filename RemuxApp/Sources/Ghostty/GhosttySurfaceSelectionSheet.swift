import SwiftUI

enum GhosttySurfaceSelectionSheet: Identifiable {
    case windows(GhosttyPanePreviewSession)
    case panes(topLevelID: UUID)

    var id: String {
        switch self {
        case .windows:
            "windows"
        case .panes(let topLevelID):
            "panes-\(topLevelID.uuidString)"
        }
    }

    var paneTopLevelIDForTopologyValidation: UUID? {
        switch self {
        case .windows:
            nil
        case .panes(let topLevelID):
            topLevelID
        }
    }
}

struct GhosttyWindowSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var removal = GhosttyTileRemoval<GhosttyWindowSelectionSheetRenderProjection.Window>()

    let projection: GhosttyWindowSelectionSheetRenderProjection
    let topLevelNoun: GhosttyTopLevelNoun
    let sessionName: String
    let layout: PanePreviewLayout.Metrics
    let contentHeight: CGFloat
    let commandFailureMessage: String?
    /// The close the backend's server asked about, which the sheet asks while it is open.
    let askedCloseQuestion: GhosttyCloseQuestion?
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemoveWindow: (UUID) -> Void
    /// Picking a group changes only which windows the sheet lists.
    let onShowGroup: (UUID) -> Void
    let onCreateGroup: () -> Void

    var body: some View {
        NavigationStack {
            TerminalSelectionSheetContent {
                if let grouping = projection.grouping {
                    GhosttyWindowGroupPicker(grouping: grouping, onShow: onShowGroup)
                } else {
                    TerminalSelectionSheetContextLabel(
                        text: "\(sessionName) · \(projection.windows.count) \((projection.windows.count == 1 ? topLevelNoun.singular : topLevelNoun.plural).lowercased())"
                    )
                }
            } content: {
                ScrollView(showsIndicators: false) {
                    windowGrid(
                        windows: projection.windows,
                        layout: layout
                    )
                }
                .frame(height: contentHeight)
                .accessibilityIdentifier("terminal.windows.scroll")
                .contentMargins(
                    .horizontal,
                    TerminalSelectionSheetLayout.horizontalContentPadding,
                    for: .scrollContent
                )
            } actions: {
                HStack(spacing: 12) {
                    TerminalSelectionSheetActionButton(
                        title: "New \(topLevelNoun.singular)",
                        systemName: "plus",
                        accessibilityIdentifier: "terminal.window.new",
                        action: onCreateWindow
                    )

                    if let grouping = projection.grouping {
                        TerminalSelectionSheetActionButton(
                            title: "New \(grouping.noun.singular)",
                            systemName: "plus",
                            accessibilityIdentifier: "terminal.windows.group.new",
                            action: onCreateGroup
                        )
                    }
                }
            }
            .navigationTitle(topLevelNoun.plural)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptic.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close \(topLevelNoun.plural)")
                    .accessibilityIdentifier("terminal.windows.close")
                }
            }
        }
        .onAppear {
            session.reconcile(leafIDs: projection.previewLeafIDs)
            GhosttyRuntimeTrace.perf("panePreview.presentation activate kind=windows")
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
        }
        .onChange(of: projection.windows.map(\.id)) { _, newValue in
            removal.keepBubble(among: newValue)
        }
        .ghosttyCloseConfirmationDialog(closeQuestion)
        .overlay(alignment: .bottom) {
            if let commandFailureMessage {
                GhosttySelectionSheetFailureBanner(message: commandFailureMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, TerminalSelectionSheetLayout.actionBarHeight + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: commandFailureMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.windows.sheet")
    }

    private func windowGrid(
        windows: [GhosttyWindowSelectionSheetRenderProjection.Window],
        layout: PanePreviewLayout.Metrics
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(windows) { window in
                ZStack(alignment: .topTrailing) {
                    Button {
                        removal.end()
                        Haptic.selection()
                        onSelect(window.id)
                    } label: {
                        GhosttyWindowSelectionTile(
                            topLevelNoun: topLevelNoun,
                            displayIndex: window.displayIndex,
                            displayName: window.displayName,
                            totalCount: window.totalCount,
                            paneCount: window.paneCount,
                            isSelected: window.isSelected,
                            agentStatus: window.agentStatus,
                            previewState: window.focusedPreviewPaneID.flatMap { pane in
                                // A pane the sheet doesn't capture has no preview coming.
                                projection.previewLeafIDs.contains(pane) ? session.imagesByPaneID[pane] : .failed
                            },
                            chromeStyle: chromeStyle,
                            layout: layout
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("terminal.window.tile.\(window.displayIndex)")
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                            .onEnded { _ in
                                Haptic.warning()
                                removal.showBubble(on: window)
                            }
                    )
                    .allowsHitTesting(removal.bubbleTileID != window.id)

                    if removal.bubbleTileID == window.id {
                        GhosttySelectionContextActionButton(
                            title: "Remove \(topLevelNoun.singular) \(window.displayIndex)",
                            accessibilityIdentifier: "terminal.window.remove.\(window.displayIndex)"
                        ) {
                            if let window = removal.bubbleTapped(among: projection.windows) {
                                onRemoveWindow(window.id)
                            }
                        }
                        .padding(4)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .frame(width: layout.tilePointSize.width, height: layout.tilePointSize.height)
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: removal.bubbleTileID)
                .accessibilityAction(named: Text("Remove \(topLevelNoun.singular) \(window.displayIndex)")) {
                    Haptic.warning()
                    if let window = removal.remove(window) {
                        onRemoveWindow(window.id)
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The window's removal asked about, else the close the backend's server asked about.
    private var closeQuestion: GhosttyCloseQuestion? {
        guard let window = removal.asked, let confirmation = window.closeConfirmation else { return askedCloseQuestion }
        return GhosttyCloseQuestion(
            confirmation: confirmation,
            confirmIdentifier: "terminal.window.remove.confirm.\(window.displayIndex)"
        ) { agreed in
            if agreed { onRemoveWindow(window.id) }
            removal.end()
        }
    }
}

struct GhosttyPaneSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @State private var removal = GhosttyTileRemoval<GhosttyPaneSelectionSheetRenderProjection.Pane>()

    let projection: GhosttyPaneSelectionSheetRenderProjection
    let topologySize: CGSize
    let commandFailureMessage: String?
    /// The close the backend's server asked about, which the sheet asks while it is open.
    let askedCloseQuestion: GhosttyCloseQuestion?
    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSetZoomed: (Bool) -> Void
    let onSelect: (UUID) -> Void
    let onRemovePane: (UUID) -> Void

    var body: some View {
        NavigationStack {
            TerminalSelectionSheetContent(
                context: "\(projection.paneCount) \(projection.paneCount == 1 ? "pane" : "panes")"
            ) {
                panePicker
                    .padding(
                        .horizontal,
                        TerminalSelectionSheetLayout.horizontalContentPadding
                    )
            } actions: {
                HStack(spacing: 0) {
                    GhosttyPaneSheetActionButton(
                        title: "Split",
                        systemName: "arrow.right",
                        accessibilityLabel: "Split right",
                        accessibilityIdentifier: "terminal.pane.split.right",
                        action: onSplitPane
                    )

                    GhosttyPaneSheetControlDivider()

                    GhosttyPaneSheetActionButton(
                        title: "Split",
                        systemName: "arrow.down",
                        accessibilityLabel: "Split down",
                        accessibilityIdentifier: "terminal.pane.split.down",
                        action: onStackPane
                    )

                    if projection.paneCount > 1 {
                        GhosttyPaneSheetControlDivider()

                        GhosttyPaneSheetZoomControl(
                            isOn: Binding(
                                get: { projection.isServerZoomed },
                                set: { zoomed in onSetZoomed(zoomed) }
                            ),
                            accent: chromeStyle.accent
                        )
                    }
                }
                .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
                .terminalSelectionSheetControlGroupSurface()
            }
            .navigationTitle("Panes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptic.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Panes")
                    .accessibilityIdentifier("terminal.panes.close")
                }
            }
        }
        .onChange(of: projection.panes.map(\.id)) { _, newValue in
            removal.keepBubble(among: newValue)
        }
        .ghosttyCloseConfirmationDialog(closeQuestion)
        .overlay(alignment: .bottom) {
            if let commandFailureMessage {
                GhosttySelectionSheetFailureBanner(message: commandFailureMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, TerminalSelectionSheetLayout.actionBarHeight + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: commandFailureMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.panes.sheet")
    }

    private var panePicker: some View {
        GhosttyPaneTopologyDiagram(
            panes: projection.panes,
            selectedPaneID: projection.selectedPaneID,
            size: topologySize,
            accent: chromeStyle.selectedStroke,
            pendingRemovalPaneID: removal.bubbleTileID,
            onSelect: { paneID in
                Haptic.selection()
                removal.end()
                onSelect(paneID)
            },
            onLongPress: { pane in
                Haptic.warning()
                removal.showBubble(on: pane)
            },
            onRemove: { _ in
                if let pane = removal.bubbleTapped(among: projection.panes) {
                    onRemovePane(pane.id)
                }
            }
        )
        .frame(height: topologySize.height, alignment: .top)
    }

    /// The pane's removal asked about, else the close the backend's server asked about.
    private var closeQuestion: GhosttyCloseQuestion? {
        guard let pane = removal.asked, let confirmation = pane.closeConfirmation else { return askedCloseQuestion }
        return GhosttyCloseQuestion(confirmation: confirmation, confirmIdentifier: "terminal.pane.remove.confirm") { agreed in
            if agreed { onRemovePane(pane.id) }
            removal.end()
        }
    }
}

/// A tile that a selection sheet's long-press can remove.
protocol GhosttyRemovableTile: Identifiable where ID == UUID {
    /// What closing the tile asks the user first; nil when it closes at once.
    var closeConfirmation: GhosttyCloseConfirmation? { get }
}

extension GhosttyWindowSelectionSheetRenderProjection.Window: GhosttyRemovableTile {}
extension GhosttyPaneSelectionSheetRenderProjection.Pane: GhosttyRemovableTile {}

/// A selection sheet's removal of a tile: the long-press bubble on it, then the question its backend asks
/// first, if any. What closing the tile asks is read from the sheet's tiles when the bubble is tapped, not at
/// the long-press, since it can change meanwhile, as when another client closes the tile's last sibling.
struct GhosttyTileRemoval<Tile: GhosttyRemovableTile> {
    /// The tile the bubble is on.
    private(set) var bubbleTileID: UUID?
    /// The tile whose removal the dialog asks about, as the sheet listed it then.
    private(set) var asked: Tile?

    mutating func showBubble(on tile: Tile) {
        bubbleTileID = tile.id
    }

    /// The bubble was tapped: removes its tile as `tiles`, the sheet's tiles now, list it. Returns the tile
    /// when it goes at once; nil when its backend asks first, or when the sheet no longer lists it.
    mutating func bubbleTapped(among tiles: [Tile]) -> Tile? {
        guard let tile = tiles.first(where: { $0.id == bubbleTileID }) else {
            bubbleTileID = nil
            return nil
        }
        return remove(tile)
    }

    /// Removes `tile`, after asking when its backend asks first. Returns the tile when it goes at once.
    mutating func remove(_ tile: Tile) -> Tile? {
        bubbleTileID = nil
        guard tile.closeConfirmation != nil else { return tile }
        asked = tile
        return nil
    }

    /// The tiles the sheet lists changed: a bubble on one no longer listed goes.
    mutating func keepBubble(among ids: [UUID]) {
        if let id = bubbleTileID, !ids.contains(id) { bubbleTileID = nil }
    }

    /// The question was answered, or the bubble set aside.
    mutating func end() {
        bubbleTileID = nil
        asked = nil
    }
}

/// A close the user is asked to confirm, and what their answer does.
struct GhosttyCloseQuestion {
    let confirmation: GhosttyCloseConfirmation
    let confirmIdentifier: String
    /// The dialog answers no as it goes, after any button, so a no after a yes must change nothing.
    let answer: (Bool) -> Void
}

extension View {
    /// The selection sheets' dialog before a close, in its backend's words.
    func ghosttyCloseConfirmationDialog(_ question: GhosttyCloseQuestion?) -> some View {
        confirmationDialog(
            question?.confirmation.title ?? "",
            isPresented: Binding(
                get: { question != nil },
                set: { isPresented in
                    if !isPresented { question?.answer(false) }
                }
            ),
            titleVisibility: .visible,
            presenting: question
        ) { question in
            Button(question.confirmation.action, role: .destructive) {
                question.answer(true)
            }
            .accessibilityIdentifier(question.confirmIdentifier)
        } message: { question in
            Text(question.confirmation.message)
        }
    }
}

/// A backend's groups of windows, as Herdr's workspaces: the most recent as capsules, and the rest behind
/// More, which shows the group it lists when that one is picked. The order follows the backend's recency,
/// so it holds as groups are added. Each group shows its most urgent agent's dot before its name.
private struct GhosttyWindowGroupPicker: View {
    @Environment(\.colorScheme) private var colorScheme

    let grouping: GhosttyWindowSelectionSheetRenderProjection.Grouping
    let onShow: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(grouping.capsules.enumerated()), id: \.element.id) { index, group in
                let isShown = group.id == grouping.shownGroupID
                Button {
                    Haptic.selection()
                    onShow(group.id)
                } label: {
                    GhosttyWindowGroupCapsule(title: group.name, agentStatus: group.agentStatus, isShown: isShown)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityName(of: group))
                .accessibilityAddTraits(isShown ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("terminal.windows.group.\(index + 1)")
            }

            if !grouping.overflow.isEmpty {
                more
            }

            Spacer(minLength: 0)
        }
        .frame(height: TerminalSelectionSheetLayout.groupPickerHeight)
    }

    private var more: some View {
        let shownInMore = grouping.overflow.first { $0.id == grouping.shownGroupID }
        return Menu {
            // A toggle for each group, which a menu draws as a checkmark, not a picker: the group shown may be
            // a capsule, which the menu doesn't list.
            ForEach(grouping.overflow) { group in
                Toggle(
                    isOn: Binding(
                        get: { group.id == grouping.shownGroupID },
                        set: { isOn in if isOn { onShow(group.id) } }
                    )
                ) {
                    if let status = group.agentStatus {
                        Label {
                            Text(group.name)
                        } icon: {
                            Image(uiImage: status.dotImage(for: colorScheme))
                        }
                        .accessibilityLabel("\(group.name), agent \(status.word)")
                    } else {
                        Text(group.name)
                    }
                }
            }
        } label: {
            GhosttyWindowGroupCapsule(
                title: shownInMore?.name ?? "More",
                agentStatus: shownInMore?.agentStatus,
                isShown: shownInMore != nil,
                showsMenuIndicator: true
            )
        }
        // Top to bottom in the groups' order, as the Sessions list has them, whichever way the menu opens.
        .menuOrder(.fixed)
        .accessibilityLabel(
            shownInMore.map { "\(accessibilityName(of: $0)), more \(grouping.noun.plural.lowercased())" }
                ?? "More \(grouping.noun.plural.lowercased())"
        )
        .accessibilityIdentifier("terminal.windows.group.more")
    }

    private func accessibilityName(of group: GhosttyWindowSelectionSheetRenderProjection.Grouping.Group) -> String {
        let agent = group.agentStatus.map { ", agent \($0.word)" } ?? ""
        return "\(grouping.noun.singular) \(group.name)\(agent)"
    }
}

private struct GhosttyWindowGroupCapsule: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let agentStatus: TerminalAgentStatus?
    let isShown: Bool
    var showsMenuIndicator = false

    var body: some View {
        HStack(spacing: 5) {
            if let agentStatus {
                TerminalAgentDot(status: agentStatus)
                    // A shown capsule is filled in the opposite appearance's colours.
                    .environment(\.colorScheme, isShown ? (colorScheme == .dark ? .light : .dark) : colorScheme)
            }

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isShown ? Color(uiColor: .systemBackground) : TerminalSelectionSheetPalette.primary)
        .padding(.horizontal, 14)
        .frame(height: TerminalSelectionSheetLayout.groupPickerHeight)
        .background(
            isShown ? TerminalSelectionSheetPalette.primary : TerminalSelectionSheetPalette.controlFill,
            in: Capsule()
        )
        .contentShape(Capsule())
    }
}

private struct GhosttySelectionSheetFailureBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemRed))
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 7)
        .accessibilityIdentifier("terminal.selection.failure")
    }
}

private struct GhosttySelectionContextActionButton: View {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(GhosttySelectionContextActionPalette.destructiveText)
                .frame(width: 44, height: 44)
                .ghosttySelectionContextActionSurface()
        }
        .buttonStyle(GhosttySelectionContextActionButtonStyle())
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(title)
    }
}

private struct GhosttySelectionContextActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum GhosttySelectionContextActionPalette {
    static let fallbackFill = Color(uiColor: .secondarySystemBackground).opacity(0.92)
    static let glassTint = Color.primary.opacity(0.055)
    static let destructiveText = Color(uiColor: .systemRed)
    static let stroke = Color.primary.opacity(0.11)
    static let shadow = Color.black.opacity(0.20)
}

private struct GhosttyRenderedPreviewSurface: View {
    let image: CGImage
    let size: CGSize

    var body: some View {
        Image(decorative: image, scale: PanePreviewLayout.currentScale())
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .background(Color.black.opacity(0.30))
            .clipped()
    }

}

private struct GhosttyWindowSelectionTile: View {
    let topLevelNoun: GhosttyTopLevelNoun
    let displayIndex: Int
    let displayName: String
    let totalCount: Int
    let paneCount: Int
    let isSelected: Bool
    let agentStatus: TerminalAgentStatus?
    let previewState: GhosttyPanePreviewSession.PreviewState?
    let chromeStyle: GhosttyTerminalChromeStyle
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            previewSurface

            metadata
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color.black.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .padding(8)
        }
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .terminalSelectionTileChrome(isSelected: isSelected, chromeStyle: chromeStyle)
        .overlay(alignment: .topLeading) {
            GhosttyPreviewIndexBadge(
                displayIndex: displayIndex,
                isSelected: isSelected,
                chromeStyle: chromeStyle
            )
            .padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(previewState.accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch previewState {
        case .ready(let image):
            GhosttyRenderedPreviewSurface(
                image: image,
                size: layout.tilePointSize
            )

        case .pending, .none, .failed:
            Color.black.opacity(0.30)
                .frame(width: layout.tilePointSize.width, height: layout.tilePointSize.height)
        }
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            if let agentStatus {
                TerminalAgentDot(status: agentStatus)
                    // The label sits on a dark plate in either appearance.
                    .environment(\.colorScheme, .dark)
            }

            Text(displayName.isEmpty ? "\(topLevelNoun.singular) \(displayIndex)" : displayName)
                .fontWeight(.semibold)

            Text("·")

            Text("\(paneCount) \(paneCount == 1 ? "pane" : "panes")")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.white.opacity(0.94))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var accessibilityLabel: String {
        let paneText = "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
        let positional = "\(topLevelNoun.singular) \(displayIndex) of \(totalCount)"
        let named = displayName.isEmpty ? positional : "\(positional), \(displayName)"
        let agent = agentStatus.map { ", agent \($0.word)" } ?? ""
        if isSelected {
            return "\(named), \(paneText)\(agent), active"
        }
        return "\(named), \(paneText)\(agent)"
    }
}

private struct GhosttyPreviewIndexBadge: View {
    let displayIndex: Int
    let isSelected: Bool
    let chromeStyle: GhosttyTerminalChromeStyle

    var body: some View {
        Text("\(displayIndex)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(
                isSelected
                    ? chromeStyle.accentForeground
                    : TerminalSelectionSheetPalette.primary
            )
            .frame(width: 28, height: 28)
            .background(
                isSelected
                    ? chromeStyle.accent
                    : Color(uiColor: .secondarySystemBackground).opacity(0.84),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 0.75)
                }
            }
    }
}

private struct GhosttyPaneTopologyDiagram: View {
    static let contentInset: CGFloat = 6
    private static let outerCornerRadius: CGFloat = 12
    private static let tileInset: CGFloat = 2

    let panes: [GhosttyPaneSelectionSheetRenderProjection.Pane]
    let selectedPaneID: UUID?
    let size: CGSize
    let accent: Color
    let pendingRemovalPaneID: UUID?
    let onSelect: (UUID) -> Void
    let onLongPress: (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void
    let onRemove: (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void

    static func contentSize(for outerSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, outerSize.width - contentInset * 2),
            height: max(1, outerSize.height - contentInset * 2)
        )
    }

    private var layout: PaneTopologyLayout.Frames? {
        let topologyPanes = panes.compactMap { pane in
            pane.frame.map { PaneTopologyLayout.Pane(id: pane.id, frame: $0) }
        }
        guard topologyPanes.count == panes.count else { return nil }
        return PaneTopologyLayout.frames(
            panes: topologyPanes,
            size: Self.contentSize(for: size)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let layout {
                ForEach(panes) { pane in
                    if let frame = layout.frame(for: pane.id) {
                        let tile = frame.insetBy(dx: Self.tileInset, dy: Self.tileInset)
                        paneTile(for: pane, size: tile.size)
                            .position(x: tile.midX, y: tile.midY)
                    }
                }
            }
        }
        .frame(width: Self.contentSize(for: size).width, height: Self.contentSize(for: size).height)
        .padding(Self.contentInset)
        .frame(width: size.width, height: size.height)
        .background(
            Color.black.opacity(0.18),
            in: RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous)
                .strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 1)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: pendingRemovalPaneID)
    }

    private func paneTile(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane,
        size: CGSize
    ) -> some View {
        let selected = pane.id == selectedPaneID
        let radius = max(1, min(6, min(size.width, size.height) * 0.18))

        return ZStack(alignment: .topTrailing) {
            Button {
                onSelect(pane.id)
            } label: {
                paneLabel(for: pane, size: size)
            }
            .buttonStyle(.plain)
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                    .onEnded { _ in onLongPress(pane) }
            )
            .allowsHitTesting(pendingRemovalPaneID != pane.id)
            .accessibilityIdentifier("terminal.pane.tile.\(pane.id.uuidString)")
            .accessibilityLabel(accessibilityLabel(for: pane))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: Text("Remove Pane")) {
                onLongPress(pane)
            }

            if pendingRemovalPaneID == pane.id {
                GhosttySelectionContextActionButton(
                    title: "Remove Pane",
                    accessibilityIdentifier: "terminal.pane.remove.\(pane.id.uuidString)",
                    action: { onRemove(pane) }
                )
                .padding(4)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            selected
                ? accent.opacity(0.24)
                : TerminalSelectionSheetPalette.row.opacity(0.84),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    selected ? accent : TerminalSelectionSheetPalette.stroke,
                    lineWidth: selected ? 2 : 1
                )
        }
    }

    private func directoryName(
        _ pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> String {
        guard !pane.currentPath.isEmpty else { return "—" }
        let name = (pane.currentPath as NSString).lastPathComponent
        return name.isEmpty ? pane.currentPath : name
    }

    private func paneLabel(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane,
        size: CGSize
    ) -> some View {
        VStack(spacing: 2) {
            Text(directoryName(pane))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    pane.id == selectedPaneID
                        ? accent
                        : TerminalSelectionSheetPalette.primary
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Text(commandName(for: pane))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let agent = pane.agent {
                TerminalAgentStateLine(state: agent)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: max(0, size.width - 16))
        .frame(width: size.width, height: size.height, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }

    private func commandName(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> String {
        pane.currentCommand.isEmpty ? "—" : pane.currentCommand
    }

    private func accessibilityLabel(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> String {
        let label = "\(directoryName(pane)), \(commandName(for: pane))"
        guard let agent = pane.agent else { return label }
        return "\(label), \(agent.word)"
    }
}

private struct GhosttyPaneSheetActionButton: View {
    let title: String
    let systemName: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: (() -> Void)?

    var body: some View {
        Button {
            Haptic.tap()
            action?()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: systemName)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(GhosttyPaneSheetActionButtonStyle(isEnabled: action != nil))
        .frame(maxWidth: .infinity)
        .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
        .contentShape(Rectangle())
        .disabled(action == nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct GhosttyPaneSheetActionButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed && isEnabled
                    ? TerminalSelectionSheetPalette.controlPressedFill
                    : Color.clear
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct GhosttyPaneSheetZoomControl: View {
    @Binding var isOn: Bool
    let accent: Color

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("Zoom")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                .lineLimit(1)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent)
        .padding(.horizontal, 11)
        .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityLabel("Zoom")
        .accessibilityIdentifier("terminal.pane.zoom")
    }
}

private struct GhosttyPaneSheetControlDivider: View {
    var body: some View {
        Rectangle()
            .fill(TerminalSelectionSheetPalette.stroke)
            .frame(width: 0.75, height: 24)
            .accessibilityHidden(true)
    }
}

private extension Optional where Wrapped == GhosttyPanePreviewSession.PreviewState {
    var accessibilityValue: String {
        switch self {
        case .ready:
            "Preview ready"
        case .failed:
            "Preview unavailable"
        case .pending, .none:
            "Preview loading"
        }
    }
}

private extension View {
    @ViewBuilder
    func ghosttySelectionContextActionSurface() -> some View {
        let shape = Circle()

        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.tint(GhosttySelectionContextActionPalette.glassTint).interactive(), in: shape)
                .overlay {
                    shape.strokeBorder(GhosttySelectionContextActionPalette.stroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttySelectionContextActionPalette.shadow, radius: 18, y: 9)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(GhosttySelectionContextActionPalette.fallbackFill)
                }
                .overlay {
                    shape.strokeBorder(GhosttySelectionContextActionPalette.stroke, lineWidth: 1)
                }
                .shadow(color: GhosttySelectionContextActionPalette.shadow, radius: 18, y: 10)
        }
    }

}
