import CoreGraphics
import Foundation
import GhosttyKit

extension GhosttyTopLevelNoun {
    static let tab = GhosttyTopLevelNoun(singular: "Tab", plural: "Tabs")
}

/// Presents a `HerdrScreenModel`'s tab through the `GhosttyTerminalScreenModeling` boundary so
/// `GhosttySurfaceScreen` renders it: one top-level for the tab, one leaf for each pane with a text
/// area, laid out on the tab's cell grid. The model owns all state; this maps it to the screen's
/// projections and stable ids, and passes typing and pane focus to it. Other topology actions aren't
/// offered.
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
        let tabID = layout.tab?.tabID ?? ""
        if let id = tabSurfaceIDs[tabID] { return id }
        let id = UUID()
        tabSurfaceIDs[tabID] = id
        return id
    }

    private func paneID(for surfaceID: UUID) -> String? {
        guard let paneID = paneIDsBySurfaceID[surfaceID],
              model?.layout?.panes.contains(where: { $0.paneID == paneID && $0.hasTextArea }) == true
        else { return nil }
        return paneID
    }

    // MARK: Projections

    private var shownPanes: [HerdrPaneLayout.Pane] {
        model?.layout?.panes.filter(\.hasTextArea) ?? []
    }

    /// The model's focused pane, once it is laid out.
    private var focusedPaneID: String? {
        guard let paneID = model?.focusedPaneID, shownPanes.contains(where: { $0.paneID == paneID }) else {
            return nil
        }
        return paneID
    }

    /// The focused pane, once its renderer exists.
    private var presentedSurfaceID: UUID? {
        guard let model, let paneID = focusedPaneID, model.paneSurface(paneID) != nil else { return nil }
        return surfaceID(forPane: paneID)
    }

    private var topologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        guard let layout = model?.layout else { return .empty }
        let id = topLevelID(for: layout)
        let tab = GhosttyTopLevelSurface(
            id: id,
            name: layout.tab?.label ?? "",
            leafIDs: shownPanes.map { surfaceID(forPane: $0.paneID) },
            focusedLeafID: focusedPaneID.map { surfaceID(forPane: $0) }
        )
        return GhosttyRuntimeSurfaceTopologySnapshot(topLevels: [tab], selectedTopLevelID: id)
    }

    private var viewportProjection: GhosttyTerminalViewportPresentationProjection {
        guard let model, let layout = model.layout else {
            return GhosttyTerminalViewportPresentationProjection(
                windowGrid: nil,
                cellMetrics: model?.measurement?.cellMetrics,
                panes: [],
                focusedSurfaceID: nil,
                isServerZoomed: false,
                windowCount: 0
            )
        }
        let panes = shownPanes.map { pane in
            let frame = GhosttyTerminalGridRect(
                x: UInt32(pane.innerRect.x),
                y: UInt32(pane.innerRect.y),
                columns: UInt32(pane.innerRect.width),
                rows: UInt32(pane.innerRect.height)
            )
            return GhosttyTerminalViewportPresentationProjection.Pane(
                id: surfaceID(forPane: pane.paneID),
                normalFrame: frame,
                visibleFrame: frame,
                isFocused: pane.paneID == focusedPaneID,
                currentCommand: pane.name,
                currentPath: pane.path
            )
        }
        return GhosttyTerminalViewportPresentationProjection(
            windowGrid: GhosttyTerminalGridSize(columns: UInt32(layout.columns), rows: UInt32(layout.rows)),
            cellMetrics: model.measurement?.cellMetrics,
            panes: panes,
            focusedSurfaceID: presentedSurfaceID,
            isServerZoomed: false,
            windowCount: 1
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

    /// The session reads as ready once its focused pane is presented, so the root sees it connect.
    var terminalScreenPresentationProjection: GhosttyTerminalScreenPresentationProjection {
        let projection = GhosttyTerminalPresentationProjector.terminalScreenPresentationProjection(
            phase: runtimePhase,
            transportWritable: model?.isConnectionOpen ?? false,
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

    func refreshPaneMetadata(inTopLevel id: UUID) {}

    func focusPane(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let paneID = paneID(for: id), model?.focusPane(paneID) == true else {
            return .missingTarget(.pane(id))
        }
        return .queued
    }

    func focusTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome {
        .missingTarget(.topLevel(id))
    }

    func focusAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTerminalActionOutcome {
        .missingTarget(.adjacentTopLevel)
    }

    func createTopLevel() -> GhosttyTerminalActionOutcome {
        .missingTarget(.host)
    }

    func splitFocusedPane(_ direction: ghostty_action_split_direction_e) -> GhosttyTerminalActionOutcome {
        .missingTarget(.focusedPane)
    }

    func setFocusedPaneZoomed(_ zoomed: Bool) -> GhosttyTerminalActionOutcome {
        .missingTarget(.focusedPane)
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
        .none
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
                          let pane = self.model?.layout?.panes.first(where: { $0.paneID == paneID }),
                          !surface.renderer.isClosing
                    else { return nil }
                    return await surface.renderer.capturePickerPreview(
                        columns: UInt32(pane.innerRect.width),
                        rows: UInt32(pane.innerRect.height),
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

    func windowSelectionSheetRenderProjection() -> GhosttyWindowSelectionSheetRenderProjection {
        let projection = GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(
            snapshot: topologySnapshot
        )
        return GhosttyWindowSelectionSheetRenderProjection(
            windows: projection.windows,
            selectedWindowID: projection.selectedWindowID,
            previewLeafIDs: capturablePreviewLeafIDs(projection.previewLeafIDs)
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
