import CoreGraphics
import Foundation
import GhosttyKit

enum GhosttyTerminalActionOutcome: Equatable, Sendable {
    case queued
    case missingTarget(GhosttyTerminalActionMissingTarget)

    var isHandled: Bool {
        switch self {
        case .queued:
            true
        case .missingTarget:
            false
        }
    }

    var isQueued: Bool {
        self == .queued
    }
}

struct GhosttyTerminalCommandFailureEvent: Equatable {
    let token: UInt64
    let message: String
}

/// A failed command: an event the screen reacts to once, and a message the status overlay shows for a
/// few seconds, until a newer failure replaces it.
@MainActor
final class GhosttyTerminalCommandFailureNotice {
    /// How long a notice stays on screen.
    nonisolated static let duration: Duration = .seconds(4)

    private(set) var event: GhosttyTerminalCommandFailureEvent?
    private(set) var message: String?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func present(_ message: String) {
        let token = (event?.token ?? 0) &+ 1
        event = GhosttyTerminalCommandFailureEvent(token: token, message: message)
        self.message = message
        onChange()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard let self, self.event?.token == token else { return }
            self.message = nil
            self.onChange()
        }
    }
}

enum GhosttyAppLifecyclePhase: Equatable {
    case active
    case inactive
    case background
}

@MainActor
protocol GhosttyTerminalRenderingModeling: ObservableObject {
    var terminalScreenPresentationProjection: GhosttyTerminalScreenPresentationProjection { get }
    var terminalInteractionProjection: GhosttyTerminalInteractionProjection { get }
    var terminalManagedSurfaceLookup: GhosttyManagedSurfaceLookup { get }
    var commandFailureEvent: GhosttyTerminalCommandFailureEvent? { get }
    var stateTraceLabel: String { get }

    func prepareInitialViewport(
        size: CGSize,
        scale: CGFloat,
        claimActiveViewport: Bool
    )

    /// Host hint that the terminal viewport is (not) in its settled
    /// shape — false while a transient overlay (software keyboard) is
    /// changing the layout. Engines use it to decide which reported
    /// viewport is safe to carry into a reconnect.
    func setViewportStabilityHint(stable: Bool)
}

extension GhosttyTerminalRenderingModeling {
    func prepareInitialViewport(size: CGSize, scale: CGFloat) {
        prepareInitialViewport(
            size: size,
            scale: scale,
            claimActiveViewport: false
        )
    }
}

@MainActor
protocol GhosttyTerminalInputModeling: ObservableObject {
    /// tmux's prefix key (Ctrl+B) is held briefly so Ctrl+B [ can open tmux's copy mode.
    var holdsTmuxPrefixKey: Bool { get }

    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult

    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult

    @discardableResult
    func sendPaste(_ text: String, to surfaceID: UUID) -> FocusedTerminalInputSubmissionResult

    func sendPasteAwaitingCommandCompletion(_ text: String, to surfaceID: UUID) async -> Bool

    @discardableResult
    func sendKeyEvent(
        _ event: GhosttySurfaceKeyEvent,
        to surfaceID: UUID
    ) -> FocusedTerminalInputSubmissionResult

    func sendKeyEventAwaitingCommandCompletion(
        _ event: GhosttySurfaceKeyEvent,
        to surfaceID: UUID
    ) async -> Bool

    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult

    func isMouseCaptured(for surfaceID: UUID) -> Bool

    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome

    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods
    ) -> GhosttyMouseInputSubmissionOutcome

    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome

}

@MainActor
protocol GhosttyTerminalActionModeling: ObservableObject {
    func reclaimActiveTmuxViewport()

    func claimActiveTmuxViewportIfNeeded()

    func refreshPaneMetadata(inTopLevel id: UUID)

    @discardableResult
    func focusPane(_ id: UUID) -> GhosttyTerminalActionOutcome

    @discardableResult
    func focusTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome

    @discardableResult
    func focusAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTerminalActionOutcome

    /// `group`, when the backend groups its top-levels, is the group the window sheet shows.
    @discardableResult
    func createTopLevel(inGroup group: UUID?) -> GhosttyTerminalActionOutcome

    /// A new group, as a Herdr workspace, made from `group`, the group the window sheet shows.
    @discardableResult
    func createTopLevelGroup(from group: UUID?) -> GhosttyTerminalActionOutcome

    @discardableResult
    func splitFocusedPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTerminalActionOutcome

    @discardableResult
    func setFocusedPaneZoomed(_ zoomed: Bool) -> GhosttyTerminalActionOutcome

    @discardableResult
    func closePane(_ id: UUID) -> GhosttyTerminalActionOutcome

    @discardableResult
    func closeTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome

    @discardableResult
    func enterFocusedTmuxCopyMode() -> GhosttyTerminalActionOutcome

    // MARK: Topology action interaction effects

    func createTopLevelInteractionEffect() -> GhosttyTopologyActionInteractionEffect
    func splitFocusedPaneInteractionEffect() -> GhosttyTopologyActionInteractionEffect
    func closeTopLevelInteractionEffect(_ id: UUID) -> GhosttyTopologyActionInteractionEffect
    func closePaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTopologyActionInteractionEffect
}

/// What a backend calls its top-level groups of panes, as the screen shows it:
/// a tmux window, a Herdr tab.
struct GhosttyTopLevelNoun: Equatable, Sendable {
    let singular: String
    let plural: String

    static let window = GhosttyTopLevelNoun(singular: "Window", plural: "Windows")
}

@MainActor
protocol GhosttyTerminalSelectionModeling: ObservableObject {
    var topLevelNoun: GhosttyTopLevelNoun { get }

    func makePanePreviewSession(
        leafIDs: [UUID],
        pixelBudget: GhosttyPanePreviewSession.PixelBudget
    ) -> GhosttyPanePreviewSession

    // MARK: Selection sheets

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection?
    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection?
    func paneCount(topLevelID: UUID) -> Int
    func paneSelectionSheetTopologyProjection(
        topLevelID: UUID?
    ) -> GhosttyPaneSelectionSheetTopologyProjection
    /// The windows of `group`, or of the group on screen, for a backend that groups its top-levels.
    func windowSelectionSheetRenderProjection(group: UUID?) -> GhosttyWindowSelectionSheetRenderProjection
    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection
}

/// The model surface `GhosttySurfaceScreen` renders against: projections of
/// terminal readiness/topology, focused-surface input routing, tmux topology
/// actions, and the selection-sheet/preview plumbing.
///
/// The tmux session stack implements it (`TmuxTerminalScreenAdapter`). The
/// screen owns presentation behavior only; everything engine-specific flows
/// through this boundary.
@MainActor
protocol GhosttyTerminalScreenModeling:
    GhosttyTerminalRenderingModeling,
    GhosttyTerminalInputModeling,
    GhosttyTerminalActionModeling,
    GhosttyTerminalSelectionModeling
{}
