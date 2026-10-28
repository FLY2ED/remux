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
    private lazy var notice = GhosttyTerminalNotice { [weak self] in
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
        notice.presentFailure("Herdr: \(label) failed")
    }

    func presentInformation(_ message: String, for duration: Duration) {
        notice.presentInformation(message, for: duration)
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
        guard let model, let layout = model.layout else { return .empty }
        let id = topLevelID(for: layout)
        let shown = GhosttyTopLevelSurface(
            id: id,
            name: layout.tab?.label ?? "",
            leafIDs: listedPanes.map { surfaceID(forPane: $0.paneID) },
            focusedLeafID: focusedPaneID.map { surfaceID(forPane: $0) },
            agentStatus: layout.tab.flatMap { model.agents.status(ofTab: $0.tabID) }
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

    /// A tab that isn't on screen: its panes are the snapshot's, and none has a surface. It shows its most
    /// urgent agent as the tab on screen does.
    private func topLevel(for tab: HerdrSessionOutline.Tab) -> GhosttyTopLevelSurface {
        GhosttyTopLevelSurface(
            id: topLevelID(forTab: tab.id),
            name: tab.label,
            leafIDs: tab.paneIDs.map(surfaceID(forPane:)),
            agentStatus: model?.agents.status(ofTab: tab.id)
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
                currentPath: pane.path,
                agent: model.agents.state(ofPane: pane.paneID)
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
            commandFailureMessage: notice.failureMessage,
            noticeMessage: notice.informationMessage,
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
        notice.event
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
        guard let model, let paneID = paneID(for: surfaceID) else { return false }
        return model.reportsMouse(inPane: paneID)
    }

    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let model, let paneID = paneID(for: surfaceID) else { return .missingTarget(surfaceID) }
        return model.sendMouseButton(event, inPane: paneID) ? .sent : .surfaceRejected
    }

    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let model, let paneID = paneID(for: surfaceID) else { return .missingTarget(surfaceID) }
        model.movePointer(to: position, inPane: paneID, mods: mods)
        return .sent
    }

    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let model, let paneID = paneID(for: surfaceID) else { return .missingTarget(surfaceID) }
        return model.scroll(event, inPane: paneID) ? .sent : .surfaceRejected
    }

    /// Herdr keeps the pane's history and knows where its lines wrap, so it reads the selection.
    func selectedText(in surfaceID: UUID) async -> String? {
        guard let model, let paneID = paneID(for: surfaceID),
              let selection = managedSurface(for: surfaceID)?.historySelection
        else { return nil }
        return await model.readSelection(selection, inPane: paneID)
    }

    /// Herdr's frames don't say where lines wrap, so the pane's terminal cuts a link the pane wraps at the
    /// row's edge. A link or word reaching a row's edge may be part of one, and Herdr finds the whole link,
    /// as its client asks it for a plain-text link's cells; an OSC 8 link, or one inside a row, is whole.
    func completeLinkSelection(
        in surfaceID: UUID,
        at point: CGPoint,
        selected: GhosttyLongPressSelection
    ) async -> Bool {
        guard selected != .explicitLink, let model, let paneID = paneID(for: surfaceID),
              let surface = managedSurface(for: surfaceID),
              let selection = surface.historySelection,
              selection.reachesRowEdge(columns: surface.controlSurface.viewportSize.columns),
              let pressed = surface.historyCell(at: point)
        else { return false }
        guard let link = await model.resolveLink(at: pressed, inPane: paneID), link != selection,
              // A selection changed meanwhile is the user's.
              surface.historySelection == selection,
              case .snapshot(let snapshot) = surface.select(link)
        else { return false }
        return snapshot.isActive
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
        guard let paneID = paneID(for: id), ask(.go(.place(.pane(paneID)))) else { return .missingTarget(.pane(id)) }
        return .queued
    }

    func focusTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let tabID = tabIDsBySurfaceID[id], ask(.go(.place(.tab(tabID)))) else { return .missingTarget(.topLevel(id)) }
        return .queued
    }

    /// The screen's tiles, swipes and sheet buttons pick from what it draws: the layout on screen, and the
    /// session's outline only while it has the layout's server boot (`workspaceOnScreen`). So each pick goes
    /// only on that boot, through the model's one way to ask something of the session.
    private func ask(_ request: HerdrRequest) -> Bool {
        guard let model, let layout = model.layout else { return false }
        return model.ask(request, bootID: layout.bootID)
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
        guard let workspaceID = workspaceID(shownFor: group), ask(.go(.creation(.tab(workspaceID: workspaceID)))) else {
            return .missingTarget(.host)
        }
        return .queued
    }

    /// New Workspace starts from the workspace the Tabs sheet shows, as Herdr's client starts one from the
    /// workspace it has picked.
    func createTopLevelGroup(from group: UUID?) -> GhosttyTerminalActionOutcome {
        ask(.go(.creation(.workspace(source: workspaceID(shownFor: group))))) ? .queued : .missingTarget(.host)
    }

    private func workspaceID(shownFor group: UUID?) -> String? {
        shownWorkspace(for: group)?.id
    }

    /// The workspace `group` names while it is still there, else the workspace on screen: the one the
    /// Tabs sheet lists, and where its New Tab and New Workspace go.
    private func shownWorkspace(for group: UUID?) -> HerdrSessionOutline.Workspace? {
        group.flatMap { workspaceIDsByGroupID[$0] }.flatMap { model?.places.outline?.workspace($0) } ?? workspaceOnScreen
    }

    /// The Panes sheet's Split → and Split ↓ split the focused pane, in the workspace on screen, as Herdr's
    /// client splits; Herdr splits only to the right and down.
    func splitFocusedPane(_ direction: ghostty_action_split_direction_e) -> GhosttyTerminalActionOutcome {
        let herdrDirection: HerdrCreation.SplitDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: herdrDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN: herdrDirection = .down
        default: return .missingTarget(.focusedPane)
        }
        guard let paneID = focusedPaneID,
              ask(.go(.creation(.split(pane: paneID, workspaceID: workspaceOnScreen?.id, direction: herdrDirection))))
        else { return .missingTarget(.focusedPane) }
        return .queued
    }

    func setFocusedPaneZoomed(_ zoomed: Bool) -> GhosttyTerminalActionOutcome {
        model?.setFocusedPaneZoomed(zoomed) == true ? .queued : .missingTarget(.focusedPane)
    }

    func closePane(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let paneID = paneID(for: id), ask(.close(.pane(paneID), group: false)) else { return .missingTarget(.pane(id)) }
        return .queued
    }

    func closeTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let tabID = tabIDsBySurfaceID[id], ask(.close(.tab(tabID), group: false)) else {
            return .missingTarget(.topLevel(id))
        }
        return .queued
    }

    // MARK: Close and rename

    /// What closing a tab tile asks first, if anything, as Herdr's client asks: closing a workspace's only
    /// tab closes the workspace.
    func closeConfirmation(forTopLevel id: UUID) -> HerdrCloseConfirmation? {
        tabIDsBySurfaceID[id].flatMap { drawnOutline?.closeConfirmation(before: .tab($0)) }
    }

    /// What closing a pane tile asks first, if anything: the only pane of a workspace's only tab closes the
    /// workspace.
    func closeConfirmation(forPane id: UUID) -> HerdrCloseConfirmation? {
        paneID(for: id).flatMap { drawnOutline?.closeConfirmation(before: .pane($0)) }
    }

    /// The close the user agreed to, checked as any close is when it goes.
    @discardableResult
    func close(confirmed confirmation: HerdrCloseConfirmation) -> Bool {
        model?.ask(confirmation.request, bootID: confirmation.bootID) == true
    }

    /// The workspace close Herdr's server asked to confirm, as for a tab or pane whose close would close a
    /// worktree group, until the user answers (`answerAskedCloseConfirmation(agreed:)`).
    var askedCloseConfirmation: HerdrCloseConfirmation? {
        model?.askedCloseConfirmation
    }

    func answerAskedCloseConfirmation(agreed: Bool) {
        model?.answerAskedCloseConfirmation(agreed: agreed)
    }

    func renameField(forTopLevel id: UUID) -> HerdrRenameField? {
        tabIDsBySurfaceID[id].flatMap { model?.renameField(for: .tab($0)) }
    }

    func renameField(forPane id: UUID) -> HerdrRenameField? {
        paneID(for: id).flatMap { model?.renameField(for: .pane($0)) }
    }

    @discardableResult
    func renameTopLevel(_ id: UUID, to name: String) -> Bool {
        guard let tabID = tabIDsBySurfaceID[id] else { return false }
        return ask(.rename(.tab(tabID), name: name))
    }

    @discardableResult
    func renamePane(_ id: UUID, to name: String) -> Bool {
        guard let paneID = paneID(for: id) else { return false }
        return ask(.rename(.pane(paneID), name: name))
    }

    /// The session's outline while it has the server boot of the layout on screen, which the tiles are
    /// drawn from.
    private var drawnOutline: HerdrSessionOutline? {
        guard let outline = model?.places.outline, outline.bootID == model?.layout?.bootID else { return nil }
        return outline
    }

    func enterFocusedTmuxCopyMode() -> GhosttyTerminalActionOutcome {
        .missingTarget(.focusedPane)
    }

    func createTopLevelInteractionEffect() -> GhosttyTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.createTopLevelInteractionEffect()
    }

    func splitFocusedPaneInteractionEffect() -> GhosttyTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.splitFocusedPaneInteractionEffect()
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
        guard let outline = model?.places.outline, let workspaceOnScreen, let shown = shownWorkspace(for: group) else {
            return GhosttyWindowSelectionSheetRenderProjection(
                windows: onScreen.windows,
                selectedWindowID: onScreen.selectedWindowID,
                previewLeafIDs: previewLeafIDs
            )
        }
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
