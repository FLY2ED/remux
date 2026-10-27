import CoreGraphics
import Foundation
import GhosttyKit

extension GhosttyTopLevelNoun {
    static let tab = GhosttyTopLevelNoun(singular: "Tab", plural: "Tabs")
    static let workspace = GhosttyTopLevelNoun(singular: "Workspace", plural: "Workspaces")
}

/// Presents a `HerdrScreenModel`'s tab through the `GhosttyTerminalScreenModeling` boundary so
/// `GhosttySurfaceScreen` renders it: a top-level for each tab of the workspace on screen, with one leaf
/// for each pane of the tab on screen that has a text area, laid out on the tab's cell grid, and while
/// the tab is zoomed a leaf for each of its panes. The Tabs sheet offers the other workspaces as groups.
/// The model owns all state; this maps it to the screen's projections and stable ids, and passes typing,
/// moves, zoom and New Tab and New Workspace to it. Other topology actions aren't offered.
@MainActor
final class HerdrTerminalScreenAdapter: ObservableObject {
    private weak var model: HerdrScreenModel?
    private lazy var commandFailure = GhosttyTerminalCommandFailureNotice { [weak self] in
        self?.objectWillChange.send()
    }
    /// One id per Herdr pane and tab id for the model's life, as tmux's are per pane. A pane's screen
    /// surface takes its id when its renderer is admitted, so a pane whose terminal is replaced, by a
    /// renderer failure or a new server boot, stays the same leaf with a new surface.
    private var paneSurfaceIDs: [String: UUID] = [:]
    private var paneIDsBySurfaceID: [UUID: String] = [:]
    private var tabSurfaceIDs: [String: UUID] = [:]
    private var tabIDsBySurfaceID: [UUID: String] = [:]
    private var workspaceGroupIDs: [String: UUID] = [:]
    private var workspaceIDsByGroupID: [UUID: String] = [:]

    func attach(to model: HerdrScreenModel) {
        self.model = model
    }

    func presentFailure(_ label: String) {
        commandFailure.present("Herdr: \(label) failed")
    }

    func invalidate() {
        model = nil
        paneSurfaceIDs.removeAll()
        paneIDsBySurfaceID.removeAll()
        tabSurfaceIDs.removeAll()
        tabIDsBySurfaceID.removeAll()
        workspaceGroupIDs.removeAll()
        workspaceIDsByGroupID.removeAll()
        objectWillChange.send()
    }

    // MARK: Identity

    private func surfaceID(forPane paneID: String) -> UUID {
        if let id = paneSurfaceIDs[paneID] { return id }
        let id = UUID()
        paneSurfaceIDs[paneID] = id
        paneIDsBySurfaceID[id] = paneID
        return id
    }

    private func topLevelID(for layout: HerdrPaneLayout) -> UUID {
        topLevelID(forTab: layout.tab?.tabID ?? "")
    }

    private func topLevelID(forTab tabID: String) -> UUID {
        if let id = tabSurfaceIDs[tabID] { return id }
        let id = UUID()
        tabSurfaceIDs[tabID] = id
        tabIDsBySurfaceID[id] = tabID
        return id
    }

    private func groupID(forWorkspace workspaceID: String) -> UUID {
        if let id = workspaceGroupIDs[workspaceID] { return id }
        let id = UUID()
        workspaceGroupIDs[workspaceID] = id
        workspaceIDsByGroupID[id] = workspaceID
        return id
    }

    private func paneID(for surfaceID: UUID) -> String? {
        guard let paneID = paneIDsBySurfaceID[surfaceID],
              listedPanes.contains(where: { $0.paneID == paneID })
        else { return nil }
        return paneID
    }

    // MARK: Projections

    /// The panes the screen lists: those the frame draws, and while the tab is zoomed every pane of it,
    /// so the pane sheet shows them all and can unzoom the tab. Only drawn panes have a surface.
    private var listedPanes: [HerdrPaneLayout.Pane] {
        guard let layout = model?.layout else { return [] }
        return layout.tab?.zoomed == true ? layout.panes : layout.panes.filter(\.hasTextArea)
    }

    /// The model's focused pane, once it is laid out.
    private var focusedPaneID: String? {
        guard let paneID = model?.focusedPaneID, listedPanes.contains(where: { $0.paneID == paneID }) else {
            return nil
        }
        return paneID
    }

    /// The focused pane, once its renderer exists.
    private var presentedSurfaceID: UUID? {
        guard let model, let paneID = focusedPaneID, model.paneSurface(paneID) != nil else { return nil }
        return surfaceID(forPane: paneID)
    }

    /// The tab the frame on screen draws, and the other tabs of its workspace from the newest snapshot,
    /// in Herdr's order.
    private var topologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        guard let layout = model?.layout else { return .empty }
        let id = topLevelID(for: layout)
        let shown = GhosttyTopLevelSurface(
            id: id,
            name: layout.tab?.label ?? "",
            leafIDs: listedPanes.map { surfaceID(forPane: $0.paneID) },
            focusedLeafID: focusedPaneID.map { surfaceID(forPane: $0) }
        )
        guard let workspace = workspaceOnScreen else {
            return GhosttyRuntimeSurfaceTopologySnapshot(topLevels: [shown], selectedTopLevelID: id)
        }
        let tabs = workspace.tabs.map { $0.id == layout.tab?.tabID ? shown : topLevel(for: $0) }
        return GhosttyRuntimeSurfaceTopologySnapshot(topLevels: tabs, selectedTopLevelID: id)
    }

    /// The workspace of the tab the frame on screen draws.
    private var workspaceOnScreen: HerdrSessionOutline.Workspace? {
        guard let layout = model?.layout, let tabID = layout.tab?.tabID, let outline = model?.places.outline,
              outline.bootID == layout.bootID
        else { return nil }
        return outline.workspace(containingTab: tabID)
    }

    /// A tab that isn't on screen: its panes are the snapshot's, and none has a surface.
    private func topLevel(for tab: HerdrSessionOutline.Tab) -> GhosttyTopLevelSurface {
        GhosttyTopLevelSurface(
            id: topLevelID(forTab: tab.id),
            name: tab.label,
            leafIDs: tab.paneIDs.map(surfaceID(forPane:))
        )
    }

    private var viewportProjection: GhosttyTerminalViewportPresentationProjection {
        guard let model, let layout = model.layout else {
            return GhosttyTerminalViewportPresentationProjection(
                windowGrid: nil,
                cellMetrics: model?.measurement?.cellMetrics,
                panes: [],
                paneLines: [],
                focusedSurfaceID: nil,
                isServerZoomed: false,
                windowCount: 0
            )
        }
        func gridRect(_ rect: HerdrSurfaceRect) -> GhosttyTerminalGridRect {
            GhosttyTerminalGridRect(
                x: UInt32(rect.x),
                y: UInt32(rect.y),
                columns: UInt32(rect.width),
                rows: UInt32(rect.height)
            )
        }
        let zoomed = layout.tab?.zoomed == true
        // The pane sheet's map shows where each pane sits. A zoomed tab's frame draws one pane, so the
        // places come from the newest full layout of the tab; a pane without one leaves the map out.
        let panes = listedPanes.compactMap { pane -> GhosttyTerminalViewportPresentationProjection.Pane? in
            let drawn = pane.hasTextArea ? pane.innerRect.map(gridRect) : nil
            guard let place = (zoomed ? model.mapRect(ofPane: pane.paneID).map(gridRect) : nil) ?? drawn else {
                return nil
            }
            return GhosttyTerminalViewportPresentationProjection.Pane(
                id: surfaceID(forPane: pane.paneID),
                normalFrame: place,
                visibleFrame: drawn,
                isFocused: pane.paneID == focusedPaneID,
                currentCommand: pane.name,
                currentPath: pane.path
            )
        }
        return GhosttyTerminalViewportPresentationProjection(
            windowGrid: GhosttyTerminalGridSize(columns: UInt32(layout.columns), rows: UInt32(layout.rows)),
            cellMetrics: model.measurement?.cellMetrics,
            panes: panes,
            paneLines: layout.borders.map { Self.paneLine($0, colors: model.terminalColors) },
            focusedSurfaceID: presentedSurfaceID,
            isServerZoomed: zoomed,
            windowCount: workspaceOnScreen?.tabs.count ?? 1
        )
    }

    /// As thin as Herdr's box-drawing glyphs show in a terminal.
    static let borderWidth: CGFloat = 1

    /// Herdr's border line where its glyphs are, in the colour Herdr gave it. Ends in the middle of a
    /// cell reach on, as the glyphs' strokes meet in a corner.
    static func paneLine(_ border: HerdrBorderLine, colors: GhosttyTerminalColors?) -> GhosttyPaneLine {
        let ink = border.color.foregroundRGB(in: colors).map {
            GhosttyPaneLine.Ink.color(red: $0.red, green: $0.green, blue: $0.blue)
        }
        return GhosttyPaneLine(
            orientation: border.axis == .horizontal ? .horizontal : .vertical,
            position: CGFloat(border.track) + 0.5,
            start: CGFloat(border.start) / 2,
            end: CGFloat(border.end) / 2,
            ink: ink ?? .separator,
            width: borderWidth,
            cap: .square
        )
    }

    private var runtimePhase: GhosttyTerminalRuntimePhase {
        model?.runtimePhase ?? .failed(message: "terminal session unavailable", reason: nil)
    }

    // MARK: Screen surfaces

    /// The model makes a pane's screen surface when it admits the pane's renderer, so a lookup only
    /// reads.
    func makeScreenSurface(for surface: HerdrPaneSurface) {
        _ = surface.screenSurface(id: surfaceID(forPane: surface.paneID))
    }

    private func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        guard let paneID = paneID(for: id) else { return nil }
        return model?.paneSurface(paneID)?.renderer.managedSurface
    }
}

// MARK: - GhosttyTerminalScreenModeling

extension HerdrTerminalScreenAdapter: GhosttyTerminalScreenModeling {
    func prepareInitialViewport(size: CGSize, scale: CGFloat, claimActiveViewport: Bool) {
        model?.prepareViewport(size: size, scale: scale)
    }

    func setViewportStabilityHint(stable: Bool) {}

    /// The session reads as ready once its connection is ready and its focused pane is presented, so the
    /// root sees it connect.
    var terminalScreenPresentationProjection: GhosttyTerminalScreenPresentationProjection {
        let projection = GhosttyTerminalPresentationProjector.terminalScreenPresentationProjection(
            phase: runtimePhase,
            transportWritable: model?.isConnectionReady ?? false,
            commandFailureMessage: commandFailure.message,
            debugStatus: stateTraceLabel,
            registryDebugSummary: "herdr session",
            presentedSurfaceID: presentedSurfaceID,
            snapshot: topologySnapshot,
            viewportProjection: viewportProjection,
            selectedPanePresentation: model?.presentation(ofPane: focusedPaneID) ?? .pending,
            isShown: model?.isSelected ?? false
        )
        return GhosttyTerminalScreenPresentationProjection(
            readiness: projection.readiness,
            interaction: interaction,
            viewport: projection.viewport,
            statusOverlay: projection.statusOverlay
        )
    }

    var terminalInteractionProjection: GhosttyTerminalInteractionProjection {
        interaction
    }

    /// What the screen may do with the session, for both projections it reads.
    private var interaction: GhosttyTerminalInteractionProjection {
        let projection = GhosttyTerminalPresentationProjector.terminalInteractionProjection(
            phase: runtimePhase,
            presentedSurfaceID: presentedSurfaceID,
            snapshot: topologySnapshot,
            selectedPanePresentation: model?.presentation(ofPane: focusedPaneID) ?? .pending
        )
        return GhosttyTerminalInteractionProjection(
            isInputAvailable: model?.isInputAvailable ?? false,
            hasFocusedSurface: projection.hasFocusedSurface,
            selectedActiveLeafID: projection.selectedActiveLeafID,
            selectedWindowIndex: projection.selectedWindowIndex,
            windowCount: projection.windowCount,
            paneCount: projection.paneCount,
            isWaitingForPanes: projection.isWaitingForPanes
        )
    }

    var terminalManagedSurfaceLookup: GhosttyManagedSurfaceLookup {
        GhosttyManagedSurfaceLookup { [weak self] id in
            self?.managedSurface(for: id)
        }
    }

    var commandFailureEvent: GhosttyTerminalCommandFailureEvent? {
        commandFailure.event
    }

    var stateTraceLabel: String {
        model?.stateTraceLabel ?? "released"
    }

    // MARK: Input

    /// Herdr panes get Ctrl+B at once; Herdr's own keybindings aren't offered on the phone.
    var holdsTmuxPrefixKey: Bool { false }

    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        model?.sendText(text) ?? .transportUnavailable
    }

    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        model?.sendPaste(text) ?? .transportUnavailable
    }

    /// Herdr's client sends input only to the focused pane.
    func sendPaste(_ text: String, to surfaceID: UUID) -> FocusedTerminalInputSubmissionResult {
        guard isFocusedPane(surfaceID) else { return .noFocusedSurface }
        return sendPasteToFocusedSurface(text)
    }

    /// The composer's paste and Enter go to the pane its message was written in, which may no longer be
    /// focused.
    func sendPasteAwaitingCommandCompletion(_ text: String, to surfaceID: UUID) async -> Bool {
        guard let model, let paneID = paneID(for: surfaceID) else { return false }
        return await model.sendPasteAwaitingDelivery(text, toPane: paneID)
    }

    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent, to surfaceID: UUID) -> FocusedTerminalInputSubmissionResult {
        guard isFocusedPane(surfaceID) else { return .noFocusedSurface }
        return sendKeyEventToFocusedSurface(event)
    }

    func sendKeyEventAwaitingCommandCompletion(_ event: GhosttySurfaceKeyEvent, to surfaceID: UUID) async -> Bool {
        guard let model, let paneID = paneID(for: surfaceID) else { return false }
        return await model.sendKeyAwaitingDelivery(event, toPane: paneID)
    }

    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        model?.sendKey(event) ?? .transportUnavailable
    }

    private func isFocusedPane(_ surfaceID: UUID) -> Bool {
        guard let paneID = paneID(for: surfaceID) else { return false }
        return paneID == focusedPaneID
    }

    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        false
    }

    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        .surfaceRejected
    }

    /// The screen moves the pointer only where a scroll gesture over the pane is.
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let model, let paneID = paneID(for: surfaceID) else { return .missingTarget(surfaceID) }
        model.setScrollPointer(position, inPane: paneID)
        return .sent
    }

    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let model, let paneID = paneID(for: surfaceID) else { return .missingTarget(surfaceID) }
        return model.scroll(event, inPane: paneID) ? .sent : .surfaceRejected
    }

    // MARK: Topology actions

    func reclaimActiveTmuxViewport() {}

    func claimActiveTmuxViewportIfNeeded() {}

    /// The pane sheet is opening over the tab: a zoomed tab's map may lack places Herdr can report.
    func refreshPaneMetadata(inTopLevel id: UUID) {
        guard let model, let layout = model.layout, topLevelID(for: layout) == id else { return }
        model.fillTabMapIfNeeded()
    }

    func focusPane(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let paneID = paneID(for: id), model?.focusPane(paneID) == true else {
            return .missingTarget(.pane(id))
        }
        return .queued
    }

    func focusTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let tabID = tabIDsBySurfaceID[id], model?.focusTab(tabID) == true else {
            return .missingTarget(.topLevel(id))
        }
        return .queued
    }

    func focusAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTerminalActionOutcome {
        let topology = topologySnapshot
        guard let index = topology.selectedTopLevelIndex else { return .missingTarget(.adjacentTopLevel) }
        let target = direction.advancedIndex(from: index, count: topology.topLevels.count)
        guard target != index else { return .missingTarget(.adjacentTopLevel) }
        return focusTopLevel(topology.topLevels[target].id)
    }

    /// New Tab goes in the workspace the Tabs sheet shows.
    func createTopLevel(inGroup group: UUID?) -> GhosttyTerminalActionOutcome {
        guard let workspaceID = workspaceID(shownFor: group),
              model?.create(.tab(workspaceID: workspaceID)) == true
        else { return .missingTarget(.host) }
        return .queued
    }

    /// New Workspace starts from the workspace the Tabs sheet shows, as Herdr's client starts one from the
    /// workspace it has picked.
    func createTopLevelGroup(from group: UUID?) -> GhosttyTerminalActionOutcome {
        model?.create(.workspace(source: workspaceID(shownFor: group))) == true ? .queued : .missingTarget(.host)
    }

    /// The workspace `group` names, or without one the workspace on screen.
    private func workspaceID(shownFor group: UUID?) -> String? {
        group.flatMap { workspaceIDsByGroupID[$0] } ?? workspaceOnScreen?.id
    }

    func splitFocusedPane(_ direction: ghostty_action_split_direction_e) -> GhosttyTerminalActionOutcome {
        .missingTarget(.focusedPane)
    }

    func setFocusedPaneZoomed(_ zoomed: Bool) -> GhosttyTerminalActionOutcome {
        model?.setFocusedPaneZoomed(zoomed) == true ? .queued : .missingTarget(.focusedPane)
    }

    func closePane(_ id: UUID) -> GhosttyTerminalActionOutcome {
        .missingTarget(.pane(id))
    }

    func closeTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome {
        .missingTarget(.topLevel(id))
    }

    func enterFocusedTmuxCopyMode() -> GhosttyTerminalActionOutcome {
        .missingTarget(.focusedPane)
    }

    func createTopLevelInteractionEffect() -> GhosttyTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.createTopLevelInteractionEffect()
    }

    func splitFocusedPaneInteractionEffect() -> GhosttyTopologyActionInteractionEffect {
        .none
    }

    func closeTopLevelInteractionEffect(_ id: UUID) -> GhosttyTopologyActionInteractionEffect {
        .none
    }

    func closePaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTopologyActionInteractionEffect {
        .none
    }

    // MARK: Selection sheets and previews

    var topLevelNoun: GhosttyTopLevelNoun { .tab }

    func makePanePreviewSession(
        leafIDs: [UUID],
        pixelBudget: GhosttyPanePreviewSession.PixelBudget
    ) -> GhosttyPanePreviewSession {
        GhosttyPanePreviewSession(
            leafIDs: leafIDs,
            pixelBudget: pixelBudget,
            client: GhosttyPanePreviewSession.PreviewClient(
                capture: { [weak self] leafID, budget in
                    guard let self,
                          let paneID = self.paneID(for: leafID),
                          let surface = self.model?.paneSurface(paneID),
                          let area = self.model?.layout?.panes.first(where: { $0.paneID == paneID })?.innerRect,
                          !surface.renderer.isClosing
                    else { return nil }
                    return await surface.renderer.capturePickerPreview(
                        columns: UInt32(area.width),
                        rows: UInt32(area.height),
                        budget: budget
                    )
                },
                cancelCapture: { [weak self] leafID in
                    guard let self, let paneID = self.paneID(for: leafID) else { return }
                    self.model?.paneSurface(paneID)?.renderer.cancelPickerCaptureForPresentation()
                }
            )
        )
    }

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection? {
        guard let projection = GhosttyTerminalPresentationProjector.windowSheetPresentationProjection(
            snapshot: topologySnapshot
        ) else { return nil }
        return GhosttyWindowSheetPresentationProjection(
            previewLeafIDs: capturablePreviewLeafIDs(projection.previewLeafIDs)
        )
    }

    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.selectedPaneSheetPresentationProjection(snapshot: topologySnapshot)
    }

    func paneCount(topLevelID: UUID) -> Int {
        GhosttyTerminalPresentationProjector.paneCount(topLevelID: topLevelID, snapshot: topologySnapshot)
    }

    func paneSelectionSheetTopologyProjection(topLevelID: UUID?) -> GhosttyPaneSelectionSheetTopologyProjection {
        GhosttyTerminalPresentationProjector.paneSelectionSheetTopologyProjection(
            topLevelID: topLevelID,
            snapshot: topologySnapshot
        )
    }

    /// The tabs of the workspace `group` names, or of the workspace on screen, with the workspaces most
    /// recent first. Only the tab on screen has a preview: the frame Remux already has.
    func windowSelectionSheetRenderProjection(group: UUID?) -> GhosttyWindowSelectionSheetRenderProjection {
        let topology = topologySnapshot
        let onScreen = GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(snapshot: topology)
        let previewLeafIDs = capturablePreviewLeafIDs(onScreen.previewLeafIDs)
        guard let outline = model?.places.outline, let workspaceOnScreen else {
            return GhosttyWindowSelectionSheetRenderProjection(
                windows: onScreen.windows,
                selectedWindowID: onScreen.selectedWindowID,
                previewLeafIDs: previewLeafIDs
            )
        }
        let shown = group.flatMap { workspaceIDsByGroupID[$0] }.flatMap { outline.workspace($0) } ?? workspaceOnScreen
        let windows = shown.id == workspaceOnScreen.id
            ? onScreen.windows
            : GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(
                snapshot: GhosttyRuntimeSurfaceTopologySnapshot(
                    topLevels: shown.tabs.map(topLevel(for:)),
                    selectedTopLevelID: nil
                )
            ).windows
        return GhosttyWindowSelectionSheetRenderProjection(
            windows: windows,
            selectedWindowID: onScreen.selectedWindowID,
            previewLeafIDs: previewLeafIDs,
            grouping: GhosttyWindowSelectionSheetRenderProjection.Grouping(
                noun: .workspace,
                groups: outline.workspacesByRecency.map {
                    .init(id: groupID(forWorkspace: $0.id), name: $0.label)
                },
                shownGroupID: groupID(forWorkspace: shown.id),
                largestWindowCount: outline.workspaces.map(\.tabs.count).max() ?? 0
            )
        )
    }

    func paneSelectionSheetRenderProjection(topLevelID: UUID) -> GhosttyPaneSelectionSheetRenderProjection {
        GhosttyTerminalPresentationProjector.paneSelectionSheetRenderProjection(
            topLevelID: topLevelID,
            snapshot: topologySnapshot,
            viewport: topologySnapshot.selectedTopLevelID == topLevelID ? viewportProjection : nil
        )
    }

    private func capturablePreviewLeafIDs(_ prioritizedLeafIDs: [UUID]) -> [UUID] {
        prioritizedLeafIDs.filter { leafID in
            guard let paneID = paneID(for: leafID) else { return false }
            return model?.paneSurface(paneID) != nil
        }
    }
}
