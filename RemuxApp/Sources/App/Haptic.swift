import AudioToolbox
import UIKit

/// What Remux vibrates for, by the Settings switch that covers it.
enum HapticCategory: Hashable, Sendable {
    /// A program ringing the bell, and an agent that needs the user or finished.
    case bellsAndAgents
    /// Toolbar keys and Remux's own buttons and controls.
    case keysAndButtons
}

/// An alert that vibrates.
enum HapticAlert: Equatable, Sendable {
    /// A program in the session on screen rang the bell.
    case bell
    /// An agent's banner appeared; `arrived` is when its notification came, which can be well before.
    case agentNeedsYou(arrived: ContinuousClock.Instant)
    case agentFinished(arrived: ContinuousClock.Instant)
}

/// Which vibrations play. Each belongs to a category the user can turn off, and alerts are spaced so a
/// burst of bells vibrates once, and so does a bell with an agent's notification that came with it, even
/// though its banner appears later.
struct HapticRules: Sendable {
    static let alertSpacing: Duration = .milliseconds(100)

    private(set) var allowed: Set<HapticCategory>
    private var lastAlert: ContinuousClock.Instant?
    private var lastBell: ContinuousClock.Instant?

    init(_ settings: TerminalSettings = .default) {
        allowed = Self.allowed(by: settings)
    }

    mutating func follow(_ settings: TerminalSettings) {
        allowed = Self.allowed(by: settings)
    }

    func allows(_ category: HapticCategory) -> Bool {
        allowed.contains(category)
    }

    /// The vibration `alert` plays at `now`, if any: a warning for a bell or an agent that needs the
    /// user, and success for an agent that finished.
    mutating func feedback(
        for alert: HapticAlert,
        at now: ContinuousClock.Instant
    ) -> UINotificationFeedbackGenerator.FeedbackType? {
        guard allows(.bellsAndAgents) else { return nil }
        let feedback: UINotificationFeedbackGenerator.FeedbackType
        switch alert {
        case .bell:
            lastBell = now
            feedback = .warning
        case .agentNeedsYou(let arrived):
            guard !Self.isNear(arrived, lastBell) else { return nil }
            feedback = .warning
        case .agentFinished(let arrived):
            guard !Self.isNear(arrived, lastBell) else { return nil }
            feedback = .success
        }
        if let lastAlert, now - lastAlert < Self.alertSpacing { return nil }
        lastAlert = now
        return feedback
    }

    private static func isNear(_ instant: ContinuousClock.Instant, _ other: ContinuousClock.Instant?) -> Bool {
        guard let other else { return false }
        let gap = instant < other ? other - instant : instant - other
        return gap < alertSpacing
    }

    private static func allowed(by settings: TerminalSettings) -> Set<HapticCategory> {
        var allowed: Set<HapticCategory> = []
        if settings.vibratesForBellsAndAgents { allowed.insert(.bellsAndAgents) }
        if settings.vibratesForKeysAndButtons { allowed.insert(.keysAndButtons) }
        return allowed
    }
}

/// Remux's haptics, each played only while the user allows its category.
@MainActor
enum Haptic {
    private(set) static var rules = HapticRules()

    /// Follows the user's Haptics settings.
    static func follow(_ settings: TerminalSettings) {
        rules.follow(settings)
    }

    static func alert(_ alert: HapticAlert) {
        guard let feedback = rules.feedback(for: alert, at: .now) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(feedback)
    }

    static func selection() {
        guard rules.allows(.keysAndButtons) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard rules.allows(.keysAndButtons) else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func warning() {
        guard rules.allows(.keysAndButtons) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func success() {
        guard rules.allows(.keysAndButtons) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard rules.allows(.keysAndButtons) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    // MARK: - Chrome press feedback (long-lived prepared generators)

    private static var keyboardImpact: UIImpactFeedbackGenerator?
    private static var chromeSelection: UISelectionFeedbackGenerator?

    /// Warm both keyboard-chrome generators so the first key/dock press has no
    /// cold-start latency. Idempotent.
    static func prewarmChromeFeedback() {
        guard rules.allows(.keysAndButtons) else { return }
        if keyboardImpact == nil {
            keyboardImpact = UIImpactFeedbackGenerator(style: .light)
        }
        if chromeSelection == nil {
            chromeSelection = UISelectionFeedbackGenerator()
        }
        keyboardImpact?.prepare()
        chromeSelection?.prepare()
    }

    /// Touch-down feedback for an accessory key (ctrl / esc / tab).
    /// Audio defaults to OFF: a normal-app view cannot honor iOS Settings >
    /// Keyboard Feedback > Sound, so we ship visual + haptic only and leave
    /// the audio click as an explicit caller opt-in.
    static func keyboardPress(playsAudio: Bool = false) {
        if rules.allows(.keysAndButtons) {
            if keyboardImpact == nil {
                keyboardImpact = UIImpactFeedbackGenerator(style: .light)
            }
            keyboardImpact?.impactOccurred()
            keyboardImpact?.prepare()
        }

        if playsAudio {
            // Public-API approximation of the iOS keyboard click; not exact
            // parity. Plays via the ringer/silent path.
            AudioServicesPlaySystemSound(1104)
        }
    }

    /// Touch-down feedback for chrome navigation/toggle controls (home,
    /// windows, panes, keyboard toggle). Selection tic - canonical for
    /// nav/toggle controls and materially quieter than the key impact.
    static func chromeControlPress() {
        guard rules.allows(.keysAndButtons) else { return }
        if chromeSelection == nil {
            chromeSelection = UISelectionFeedbackGenerator()
        }
        chromeSelection?.selectionChanged()
        chromeSelection?.prepare()
    }
}
