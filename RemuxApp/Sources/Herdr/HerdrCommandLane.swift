import Foundation

/// The one command lane of a Herdr connection. Herdr runs one endpoint command at a time for a client and
/// refuses another while one is in flight (`server/headless/endpoint_requests.rs` `endpoint_busy`), so
/// every command Remux sends waits here, and the engine, which owns the lane, decides what goes next in
/// the same turn as the answer or snapshot that frees it.
///
/// The order is one rule: the current view request's steps first, in order; then every other command (a
/// selection read, a link question, the zoom button, the pane sheet's layout question) in the order asked;
/// then the finale, as the session leaves the screen or closes. A request that replaces another drops only
/// the steps that one hadn't sent; the other commands still go. A hide or a close ends the current request
/// and fails the commands waiting, so its finale is the last thing sent. A step or finale waiting for the
/// snapshot that shows where the step before it took the session holds the lane.
/// `client_shell.surface.set` isn't a command here: Herdr answers it even while a command is in flight
/// (`endpoint_requests.rs` checks for it before `endpoint_busy`).
struct HerdrCommandLane {
    /// A step of the current view request. The engine decides what each sends, if anything, as it goes.
    enum Step: Equatable, Sendable {
        /// Remux's zoom off the tab it zoomed, when the session leaves that tab for the pane's: an unzoom
        /// of the tab's focused pane, which Herdr's unzoom focuses. Decided as it goes, since the answer to
        /// a request this one replaced can change what Remux zoomed.
        case leave(to: String)
        /// The setting's zoom of the pane's tab. `navigates` for a move's, which takes the session to the
        /// pane: Herdr's zoom focuses its target (`actions.rs` `apply_pane_zoom`). A show's zooms the pane
        /// already focused.
        case zoom(String, navigates: Bool)
        /// The pane focused, which also marks its tab's agents seen (`api/panes.rs` `handle_pane_focus`),
        /// as Herdr's client goes to a pane.
        case focus(String)

        var method: String {
            switch self {
            case .leave, .zoom: HerdrScreenModel.paneZoomMethod
            case .focus: HerdrScreenModel.paneFocusMethod
            }
        }
    }

    /// A command other than a view request's step, and what it is for.
    struct Command: Sendable {
        enum Purpose {
            /// A zoom of `pane` outside a request: the zoom button's, which reports a failure, or the pane
            /// sheet's question for a tab's layout, which doesn't. Each goes only while no request is in
            /// progress and `pane` is focused, since a zoom focuses its pane.
            case zoom(pane: String, zoomed: Bool, reportsFailure: Bool)
            /// The finale's zoom off the tab on screen; `closed` once it is answered or fails.
            case unzoom(pane: String, closed: (@Sendable () -> Void)?)
            /// Anything else, whose caller gets its answer; it goes only while the session is shown.
            case other(answered: @Sendable (Result<HerdrCommandReply, HerdrCommandError>) -> Void)
        }

        let method: String
        let params: any Encodable & Sendable
        let purpose: Purpose
    }

    enum Item {
        case step(request: UInt64, Step)
        case command(Command)

        var method: String {
            switch self {
            case .step(_, let step): step.method
            case .command(let command): command.method
            }
        }
    }

    /// How the session leaves: Remux's zoom off the tab on screen, if it made one, then the hide view
    /// request `request` sends, or the connection's close once the unzoom is answered.
    enum Finale {
        case hide(request: UInt64)
        case close(done: @Sendable () -> Void)
    }

    /// The command Herdr is answering, and the reply's chunks so far.
    struct InFlight {
        let id: String
        let item: Item
        /// The newest snapshot's revision when it went out.
        let sentAfter: UInt64
        var data: [UInt8] = []
        /// The snapshots that came while it was in flight.
        var snapshots: [HerdrSnapshot] = []
    }

    /// The current view request's steps not yet sent.
    private(set) var steps: [Step] = []
    private var stepsRequest: UInt64?
    private var waiting: [Command] = []
    /// The finale, once the session leaves; it goes when nothing else waits.
    var finale: Finale?
    private(set) var inFlight: InFlight?

    var isIdle: Bool { inFlight == nil }

    /// Whether `request` has a step waiting or in flight.
    func hasWork(for request: UInt64) -> Bool {
        if stepsRequest == request, !steps.isEmpty { return true }
        if case .step(request, _)? = inFlight?.item { return true }
        return false
    }

    /// The steps of a new current request; the previous request's unsent steps don't go.
    mutating func replaceSteps(_ steps: [Step], for request: UInt64) {
        self.steps = steps
        stepsRequest = request
    }

    /// The current request sends nothing more.
    mutating func dropSteps() {
        steps.removeAll()
    }

    mutating func append(_ command: Command) {
        waiting.append(command)
    }

    /// The other commands waiting, which won't go: Herdr refuses commands from a hidden session.
    mutating func takeWaiting() -> [Command] {
        defer { waiting.removeAll() }
        return waiting
    }

    /// The next item in the lane's order; nil when nothing waits.
    var next: Item? {
        if let request = stepsRequest, let step = steps.first { return .step(request: request, step) }
        return waiting.first.map(Item.command)
    }

    /// Takes the next item out of line.
    mutating func removeNext() {
        if stepsRequest != nil, !steps.isEmpty {
            steps.removeFirst()
        } else if !waiting.isEmpty {
            waiting.removeFirst()
        }
    }

    mutating func sent(_ item: Item, id: String, after revision: UInt64) {
        inFlight = InFlight(id: id, item: item, sentAfter: revision)
    }

    mutating func record(_ snapshot: HerdrSnapshot) {
        inFlight?.snapshots.append(snapshot)
    }

    /// A chunk of the reply to the command in flight; the whole reply once its last chunk is in, which
    /// frees the lane. A chunk of any other request is dropped, as a late reply to a command that timed
    /// out.
    mutating func receive(_ chunk: HerdrResponseChunk) -> (InFlight, [UInt8])? {
        guard var current = inFlight, current.id == chunk.requestID else { return nil }
        current.data += chunk.data
        guard chunk.isFinal else {
            inFlight = current
            return nil
        }
        inFlight = nil
        return (current, current.data)
    }

    /// The command in flight, retired when it times out; nil when it was answered first.
    mutating func expire(_ id: String) -> InFlight? {
        guard let current = inFlight, current.id == id else { return nil }
        inFlight = nil
        return current
    }

    /// A reply as Herdr sends it (`{"id", "result"}`), or the failure it carries.
    static func result(of data: [UInt8]) -> Result<Data, HerdrCommandError> {
        struct Failure: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
            }

            let error: Body?
        }
        let json = Data(data)
        if let failure = try? JSONDecoder().decode(Failure.self, from: json), let error = failure.error {
            return .failure(.failed(code: error.code, message: error.message))
        }
        return .success(json)
    }

    /// Everything in the lane, emptied when the connection ends.
    mutating func takeAll() -> (inFlight: InFlight?, waiting: [Command], finale: Finale?) {
        defer {
            inFlight = nil
            steps.removeAll()
            stepsRequest = nil
            waiting.removeAll()
            finale = nil
        }
        return (inFlight, waiting, finale)
    }
}
