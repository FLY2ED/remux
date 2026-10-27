import Combine
import Foundation

/// What Herdr's notification rules read of one open Herdr session when a notification falls due.
struct HerdrNotificationSessionState: Equatable {
    /// The session the app shows, as Herdr's client's active machine: a sheet over it or the app's
    /// background doesn't change it.
    var isShown: Bool
    var focusedWorkspaceID: String?
    var focusedTabID: String?
    /// Each agent pane's status as this phone shows it (`HerdrAgentPresentation`).
    var agentStatuses: [String: HerdrAgentStatus]
}

/// The workspace and tab a notification is about, by the names Herdr gives them in the session's snapshot
/// when it arrived; a tab without a label of its own is named after its number, as Herdr names it.
struct HerdrNotificationPlace: Equatable, Sendable {
    var workspace: String?
    var tab: String?

    init(workspace: String? = nil, tab: String? = nil) {
        self.workspace = workspace
        self.tab = tab
    }

    init(_ notification: HerdrSemanticNotification, in snapshot: HerdrSnapshot?) {
        let tab = snapshot?.tabs.first { $0.tabID == notification.tabID }
        let workspaceID = notification.workspaceID ?? tab?.workspaceID
        self.workspace = snapshot?.workspaces.first { $0.workspaceID == workspaceID }.map(\.label)
        self.tab = tab?.label
    }
}

/// Herdr's client's rules for its in-app notifications (`client/shell/notification_policy.rs`), across
/// every open Herdr session as Herdr's client applies them across its machines.
///
/// One notification is on screen at a time, for a time set by its kind, and up to eight wait behind it,
/// the oldest dropped first. An agent's notification waits Herdr's default toast delay, then shows only
/// if the agent is still in the state it reports, and never for the tab on screen. A newer notification
/// for a pane replaces that pane's earlier one wherever it is.
struct HerdrNotificationPolicy {
    /// Where a notification came from, as the banner names it and its tap needs it.
    struct Origin: Equatable, Sendable {
        let workspaceID: SavedWorkspace.ID
        let sessionName: String
        let serverName: String
        /// The server boot the session was on, whose pane ids the notification uses.
        let bootID: String?
        let place: HerdrNotificationPlace
    }

    struct Banner: Identifiable, Equatable {
        let id: UInt64
        let origin: Origin
        let notification: HerdrSemanticNotification
    }

    typealias Sessions = (SavedWorkspace.ID) -> HerdrNotificationSessionState?

    /// Herdr's default `toast.delay_seconds`.
    static let delay: Duration = .seconds(1)
    /// How long a finished agent that still reads as working gets for the snapshot that says otherwise.
    static let completionEvidenceGrace: Duration = .seconds(1)
    static let completionRecheck: Duration = .milliseconds(50)
    static let maxQueued = 8

    static func displayTime(of kind: HerdrSemanticNotification.Kind) -> Duration {
        switch kind {
        case .needsAttention: .seconds(8)
        case .finished: .seconds(5)
        case .updateInstalled: .seconds(3)
        case .custom: .seconds(5)
        }
    }

    private enum Validation {
        case current
        case awaitingSnapshot
        case stale
    }

    private struct Pending {
        let banner: Banner
        var due: ContinuousClock.Instant
        let expires: ContinuousClock.Instant
        let checksState: Bool
    }

    private var pending: [Pending] = []
    private var queued: [Banner] = []
    private(set) var visible: (banner: Banner, until: ContinuousClock.Instant)?
    private var nextID: UInt64 = 0

    /// When something is next due: a waiting notification, or the end of the one on screen.
    var nextDeadline: ContinuousClock.Instant? {
        ([visible?.until].compactMap { $0 } + pending.map(\.due)).min()
    }

    mutating func receive(
        _ notification: HerdrSemanticNotification,
        from origin: Origin,
        at now: ContinuousClock.Instant,
        sessions: Sessions
    ) {
        let delay: Duration = notification.kind == .custom ? .zero : Self.delay
        if let paneID = notification.paneID {
            let samePane = { (banner: Banner) in
                banner.origin.workspaceID == origin.workspaceID && banner.notification.paneID == paneID
            }
            pending.removeAll { samePane($0.banner) }
            queued.removeAll(where: samePane)
            if let visible, samePane(visible.banner) {
                self.visible = nil
                promoteQueued(at: now)
            }
        }
        nextID += 1
        pending.append(Pending(
            banner: Banner(id: nextID, origin: origin, notification: notification),
            due: now + delay,
            expires: now + Self.completionEvidenceGrace,
            // A finished agent is checked even without a delay: Herdr's word that it finished is a hint.
            checksState: delay > .zero || notification.kind == .finished
        ))
        advance(to: now, sessions: sessions)
    }

    /// Ends the banner on screen when its time is up, and shows or drops each notification that is due.
    mutating func advance(to now: ContinuousClock.Instant, sessions: Sessions) {
        if let visible, now >= visible.until {
            self.visible = nil
            promoteQueued(at: now)
        }
        let waiting = pending
        pending.removeAll()
        for var entry in waiting {
            guard entry.due <= now else {
                pending.append(entry)
                continue
            }
            let notification = entry.banner.notification
            let session = sessions(entry.banner.origin.workspaceID)
            if entry.checksState {
                switch Self.validation(of: notification, in: session) {
                case .current:
                    break
                case .awaitingSnapshot where now < entry.expires:
                    entry.due = min(now + Self.completionRecheck, entry.expires)
                    pending.append(entry)
                    continue
                case .awaitingSnapshot, .stale:
                    continue
                }
            }
            if !Self.targetIsShown(notification, in: session) {
                show(entry.banner, at: now)
            }
        }
    }

    /// The banner on screen goes, as when it is tapped, and the next one shows.
    mutating func dismiss(_ id: Banner.ID, at now: ContinuousClock.Instant) {
        guard visible?.banner.id == id else { return }
        visible = nil
        promoteQueued(at: now)
    }

    /// Drops every notification of a session that closed or whose server restarted: its panes are gone.
    mutating func retire(_ workspaceID: SavedWorkspace.ID, at now: ContinuousClock.Instant) {
        pending.removeAll { $0.banner.origin.workspaceID == workspaceID }
        queued.removeAll { $0.origin.workspaceID == workspaceID }
        if visible?.banner.origin.workspaceID == workspaceID {
            visible = nil
            promoteQueued(at: now)
        }
    }

    private mutating func show(_ banner: Banner, at now: ContinuousClock.Instant) {
        guard visible != nil else {
            visible = (banner, now + Self.displayTime(of: banner.notification.kind))
            return
        }
        if queued.count == Self.maxQueued { queued.removeFirst() }
        queued.append(banner)
    }

    private mutating func promoteQueued(at now: ContinuousClock.Instant) {
        guard !queued.isEmpty else { return }
        let banner = queued.removeFirst()
        visible = (banner, now + Self.displayTime(of: banner.notification.kind))
    }

    /// Whether the agent is still in the state the notification reports. A notification with no pane
    /// can't be checked, so a finished one without a pane isn't shown.
    private static func validation(
        of notification: HerdrSemanticNotification,
        in session: HerdrNotificationSessionState?
    ) -> Validation {
        guard let paneID = notification.paneID else {
            return notification.kind == .finished ? .stale : .current
        }
        guard let status = session?.agentStatuses[paneID] else { return .awaitingSnapshot }
        switch (notification.kind, status) {
        case (.needsAttention, .blocked), (.finished, .done), (.updateInstalled, _), (.custom, _):
            return .current
        case (.finished, .working):
            return .awaitingSnapshot
        case (.needsAttention, _), (.finished, _):
            return .stale
        }
    }

    /// The tab the notification is about is the one on screen; with no tab, its workspace.
    private static func targetIsShown(
        _ notification: HerdrSemanticNotification,
        in session: HerdrNotificationSessionState?
    ) -> Bool {
        guard let session, session.isShown else { return false }
        if let tabID = notification.tabID { return session.focusedTabID == tabID }
        guard let workspaceID = notification.workspaceID else { return false }
        return session.focusedWorkspaceID == workspaceID
    }
}

/// Runs `HerdrNotificationPolicy` for the app: Herdr sessions hand it their notifications, and the
/// banner on screen is published for the view that draws it. A timer runs only while something is due.
@MainActor
final class HerdrNotificationCenter: ObservableObject {
    @Published private(set) var banner: HerdrNotificationPolicy.Banner?

    /// Reads an open Herdr session's state; set by whoever owns the sessions.
    var sessions: @MainActor (SavedWorkspace.ID) -> HerdrNotificationSessionState? = { _ in nil }

    private var policy = HerdrNotificationPolicy()
    private var timer: Task<Void, Never>?

    func receive(_ notification: HerdrSemanticNotification, from origin: HerdrNotificationPolicy.Origin) {
        policy.receive(notification, from: origin, at: .now) { self.sessions($0) }
        update()
    }

    func dismiss(_ id: HerdrNotificationPolicy.Banner.ID) {
        policy.dismiss(id, at: .now)
        update()
    }

    func retire(_ workspaceID: SavedWorkspace.ID) {
        policy.retire(workspaceID, at: .now)
        update()
    }

    private func advance() {
        policy.advance(to: .now) { self.sessions($0) }
        update()
    }

    private func update() {
        let shown = policy.visible?.banner
        if banner != shown { banner = shown }
        timer?.cancel()
        timer = nil
        guard let due = policy.nextDeadline else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
