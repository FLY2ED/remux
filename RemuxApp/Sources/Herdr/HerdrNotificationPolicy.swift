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
/// the oldest dropped first. An agent's notification waits Herdr's default toast delay. A notification
/// takes the screen, when due or when its turn comes after waiting, only if its agent is still in the
/// state it reports and its tab isn't on screen; otherwise it is dropped. Herdr's client checks only when
/// a notification falls due, so one that waited could show for a tab already on screen. A newer
/// notification for a pane replaces that pane's earlier one wherever it is.
///
/// A notification that comes with a bell keeps that pairing until its banner shows, whatever rings
/// after: the bell's vibration stood for both.
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
        /// When the notification came, which can be well before the banner shows.
        let arrived: ContinuousClock.Instant
        /// A bell rang with the notification (`HapticRules.cameTogether`).
        var cameWithBell = false

        /// The vibration the banner plays when it shows: only an agent that needs the user or finished.
        var alert: HapticAlert? {
            switch notification.kind {
            case .needsAttention: .agentNeedsYou(cameWithBell: cameWithBell)
            case .finished: .agentFinished(cameWithBell: cameWithBell)
            case .updateInstalled, .custom: nil
            }
        }
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
        var banner: Banner
        var due: ContinuousClock.Instant
        let expires: ContinuousClock.Instant
    }

    private var pending: [Pending] = []
    private var queued: [Banner] = []
    private(set) var visible: (banner: Banner, until: ContinuousClock.Instant)?
    private var nextID: UInt64 = 0
    private var lastBell: ContinuousClock.Instant?

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
                promoteQueued(at: now, sessions: sessions)
            }
        }
        nextID += 1
        pending.append(Pending(
            banner: Banner(
                id: nextID,
                origin: origin,
                notification: notification,
                arrived: now,
                cameWithBell: lastBell.map { HapticRules.cameTogether($0, now) } ?? false
            ),
            due: now + delay,
            expires: now + Self.completionEvidenceGrace
        ))
        advance(to: now, sessions: sessions)
    }

    /// A program rang the bell: each notification that came with it is paired with it. An agent's
    /// notification is still waiting out its delay then, so only those are looked at.
    mutating func ringBell(at now: ContinuousClock.Instant) {
        lastBell = now
        for index in pending.indices where HapticRules.cameTogether(now, pending[index].banner.arrived) {
            pending[index].banner.cameWithBell = true
        }
    }

    /// Ends the banner on screen when its time is up, and shows or drops each notification that is due.
    mutating func advance(to now: ContinuousClock.Instant, sessions: Sessions) {
        if let visible, now >= visible.until {
            self.visible = nil
            promoteQueued(at: now, sessions: sessions)
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
            // Herdr's word that an agent finished is a hint: one that still reads as working gets a moment
            // for the snapshot that says otherwise.
            if now < entry.expires, Self.validation(of: notification, in: session) == .awaitingSnapshot {
                entry.due = min(now + Self.completionRecheck, entry.expires)
                pending.append(entry)
                continue
            }
            if Self.mayShow(notification, in: session) {
                show(entry.banner, at: now)
            }
        }
    }

    /// The banner on screen goes, as when it is tapped, and the next one shows.
    mutating func dismiss(_ id: Banner.ID, at now: ContinuousClock.Instant, sessions: Sessions) {
        guard visible?.banner.id == id else { return }
        visible = nil
        promoteQueued(at: now, sessions: sessions)
    }

    /// Drops every notification of a session that closed or whose server restarted: its panes are gone.
    mutating func retire(_ workspaceID: SavedWorkspace.ID, at now: ContinuousClock.Instant, sessions: Sessions) {
        pending.removeAll { $0.banner.origin.workspaceID == workspaceID }
        queued.removeAll { $0.origin.workspaceID == workspaceID }
        if visible?.banner.origin.workspaceID == workspaceID {
            visible = nil
            promoteQueued(at: now, sessions: sessions)
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

    /// The first waiting banner that may still take the screen shows; those that may not are dropped.
    private mutating func promoteQueued(at now: ContinuousClock.Instant, sessions: Sessions) {
        while !queued.isEmpty {
            let banner = queued.removeFirst()
            guard Self.mayShow(banner.notification, in: sessions(banner.origin.workspaceID)) else { continue }
            visible = (banner, now + Self.displayTime(of: banner.notification.kind))
            return
        }
    }

    /// Whether a notification may take the screen now: its agent is still in the state it reports, and
    /// its tab isn't the one on screen. A finished agent that reads as working again has resumed.
    private static func mayShow(
        _ notification: HerdrSemanticNotification,
        in session: HerdrNotificationSessionState?
    ) -> Bool {
        validation(of: notification, in: session) == .current && !targetIsShown(notification, in: session)
    }

    /// Whether the agent is still in the state the notification reports. Only an agent's notifications
    /// report a state; one with no pane can't be checked, so a finished one without a pane isn't shown.
    private static func validation(
        of notification: HerdrSemanticNotification,
        in session: HerdrNotificationSessionState?
    ) -> Validation {
        switch notification.kind {
        case .updateInstalled, .custom:
            return .current
        case .needsAttention, .finished:
            break
        }
        guard let paneID = notification.paneID else {
            return notification.kind == .finished ? .stale : .current
        }
        guard let status = session?.agentStatuses[paneID] else { return .awaitingSnapshot }
        switch (notification.kind, status) {
        case (.needsAttention, .blocked), (.finished, .done):
            return .current
        case (.finished, .working):
            return .awaitingSnapshot
        default:
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

/// Runs `HerdrNotificationPolicy` for the app: Herdr sessions hand it their notifications and bells, the
/// banner on screen is published for the view that draws it, and a banner vibrates when it shows. A timer
/// runs only while something is due.
@MainActor
final class HerdrNotificationCenter: ObservableObject {
    @Published private(set) var banner: HerdrNotificationPolicy.Banner?

    /// Reads an open Herdr session's state; set by whoever owns the sessions.
    var sessions: @MainActor (SavedWorkspace.ID) -> HerdrNotificationSessionState? = { _ in nil }
    /// Plays an alert's vibration, as the user's Haptics settings allow.
    var vibrate: @MainActor (HapticAlert) -> Void = { Haptic.alert($0) }

    private var policy = HerdrNotificationPolicy()
    private var timer: Task<Void, Never>?

    /// A program in the session on screen rang the bell.
    func ringBell() {
        policy.ringBell(at: .now)
        vibrate(.bell)
    }

    func receive(_ notification: HerdrSemanticNotification, from origin: HerdrNotificationPolicy.Origin) {
        policy.receive(notification, from: origin, at: .now) { self.sessions($0) }
        update()
    }

    func dismiss(_ id: HerdrNotificationPolicy.Banner.ID) {
        policy.dismiss(id, at: .now) { self.sessions($0) }
        update()
    }

    func retire(_ workspaceID: SavedWorkspace.ID) {
        policy.retire(workspaceID, at: .now) { self.sessions($0) }
        update()
    }

    private func advance() {
        policy.advance(to: .now) { self.sessions($0) }
        update()
    }

    private func update() {
        let shown = policy.visible?.banner
        if banner != shown {
            banner = shown
            if let alert = shown?.alert { vibrate(alert) }
        }
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
