import Foundation

/// Which failures of a Herdr session's actions become a notice, by Herdr's client's rules
/// (`client/shell/actions.rs`, `push_endpoint_notice` and the answers to its requests). A target or
/// content that changed meanwhile says nothing; a server that doesn't answer, or isn't available, says so
/// once, and a timeout again only after that action has worked; a refusal isn't repeated while the same
/// one is on screen. What was shown is remembered per server boot.
struct HerdrNoticePolicy {
    private enum Kind: Hashable {
        case rejected
        case timeout
        case unavailable
        case unsupported
    }

    private struct Key: Hashable {
        let bootID: String
        let kind: Kind
        let code: String
    }

    /// Herdr's answers to an action that is no longer wanted, or no longer applies.
    private static let silentCodes: Set<String> = ["confirmation_required", "stale_content", "stale_target"]

    private let visibleFor: Duration
    private var seen: Set<Key> = []
    private var visible: (key: Key, detail: String, until: ContinuousClock.Instant)?

    /// - Parameter visibleFor: how long a notice stays on screen.
    init(visibleFor: Duration) {
        self.visibleFor = visibleFor
    }

    /// Whether `method`'s failure is shown. A connection that ended says nothing here: the session
    /// reconnects.
    mutating func shows(_ method: String, failedWith error: HerdrCommandError, bootID: String?) -> Bool {
        let boot = bootID ?? Self.noBoot
        switch error {
        case .connectionEnded:
            return false
        case .failed(let code, _) where Self.silentCodes.contains(code):
            return false
        case .timedOut, .failed("endpoint_timeout", _):
            return firstTime(Key(bootID: boot, kind: .timeout, code: method))
        case .failed("endpoint_cancelled", _):
            return firstTime(Key(bootID: boot, kind: .unavailable, code: "cancelled"))
        case .failed("server_unavailable", _), .noSnapshot:
            return firstTime(Key(bootID: boot, kind: .unavailable, code: "server"))
        case .unsupported:
            return firstTime(Key(bootID: boot, kind: .unsupported, code: method))
        case .failed(let code, let message):
            return unlessOnScreen(Key(bootID: boot, kind: .rejected, code: "\(method):\(code)"), detail: message)
        case .notAcknowledged:
            return unlessOnScreen(Key(bootID: boot, kind: .rejected, code: "\(method):not_acknowledged"), detail: "")
        }
    }

    /// `method` worked, so its next timeout is shown again.
    mutating func succeeded(_ method: String, bootID: String?) {
        seen.remove(Key(bootID: bootID ?? Self.noBoot, kind: .timeout, code: method))
    }

    /// Whether Herdr's refusal of typed or pasted input, with its reason, is shown.
    mutating func showsRefusedInput(_ message: String, bootID: String?) -> Bool {
        unlessOnScreen(Key(bootID: bootID ?? Self.noBoot, kind: .rejected, code: "paste_rejected"), detail: message)
    }

    /// Herdr's key for failures that come before any snapshot.
    private static let noBoot = "disconnected"

    private mutating func firstTime(_ key: Key) -> Bool {
        guard seen.insert(key).inserted else { return false }
        visible = (key, "", .now + visibleFor)
        return true
    }

    private mutating func unlessOnScreen(_ key: Key, detail: String) -> Bool {
        let now = ContinuousClock.now
        if let visible, visible.key == key, visible.detail == detail, now < visible.until { return false }
        visible = (key, detail, now + visibleFor)
        return true
    }
}
