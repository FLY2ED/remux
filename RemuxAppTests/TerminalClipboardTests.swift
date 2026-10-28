import XCTest
@testable import Remux

/// A pasteboard that counts its changes as UIKit's does, without the simulator's clipboard.
final class FakePasteboard: TerminalPasteboard {
    private(set) var changeCount = 0
    /// Every string the pasteboard took, in order.
    private(set) var writes: [String] = []
    /// Whether a write goes in.
    var takesWrites = true
    private var stored: String?

    var string: String? {
        get { stored }
        set {
            guard takesWrites else { return }
            stored = newValue
            if let newValue { writes.append(newValue) }
            changeCount += 1
        }
    }

    /// Another app put something on the clipboard.
    func changeElsewhere() {
        stored = "elsewhere"
        changeCount += 1
    }
}

@MainActor
final class TerminalClipboardTests: XCTestCase {
    func testAWriteGoesInAndRepeatingItIsADuplicateUntilTheClipboardChanges() {
        let pasteboard = FakePasteboard()
        let clipboard = TerminalClipboard(pasteboard: pasteboard)

        XCTAssertTrue(clipboard.write("one"))
        XCTAssertEqual(pasteboard.string, "one")
        XCTAssertFalse(clipboard.write("one"), "the clipboard already held it")
        XCTAssertTrue(clipboard.write("two"))
        XCTAssertTrue(clipboard.write("one"), "the clipboard held other text")

        pasteboard.changeElsewhere()
        XCTAssertTrue(clipboard.write("one"), "another app changed the clipboard since")
        XCTAssertEqual(pasteboard.writes, ["one", "two", "one", "one"])
    }

    func testAWriteThePasteboardDoesntTakeIsntOne() {
        let pasteboard = FakePasteboard()
        pasteboard.takesWrites = false
        let clipboard = TerminalClipboard(pasteboard: pasteboard)

        XCTAssertFalse(clipboard.write("one"))
        pasteboard.takesWrites = true
        XCTAssertTrue(clipboard.write("one"), "a write that didn't go in left nothing to repeat")
    }
}

@MainActor
final class GhosttyTerminalNoticeTests: XCTestCase {
    /// One notice shows at a time; only a failure is an event the screen reacts to, and a newer notice
    /// replaces one on screen without ending early.
    func testTheNewestNoticeShowsForItsTimeAndOnlyAFailureIsAnEvent() async throws {
        var changes = 0
        let notice = GhosttyTerminalNotice { changes += 1 }

        notice.presentFailure("failed")
        XCTAssertEqual(notice.failureMessage, "failed")
        XCTAssertNil(notice.informationMessage)
        let failure = try XCTUnwrap(notice.event)
        XCTAssertEqual(failure.message, "failed")

        notice.presentInformation("copied", for: .milliseconds(150))
        XCTAssertEqual(notice.informationMessage, "copied")
        XCTAssertNil(notice.failureMessage)
        XCTAssertEqual(notice.event, failure, "information isn't a failure event")
        XCTAssertEqual(changes, 2)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(notice.informationMessage)
        XCTAssertEqual(changes, 3)
    }

    func testANoticeIsShownInTheStatusOverlayAfterAFailure() {
        let readiness = TerminalReadinessSnapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 1,
            selectedActiveLeafID: UUID(),
            selectedPanePresentation: .ready,
            isShown: true
        )
        func overlay(failure: String?, notice: String?) -> GhosttyTerminalStatusOverlayProjection {
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: readiness,
                commandFailureMessage: failure,
                noticeMessage: notice,
                debugStatus: "",
                registryDebugSummary: ""
            )
        }

        XCTAssertEqual(overlay(failure: nil, notice: "copied"), .notice("copied"))
        XCTAssertEqual(overlay(failure: "failed", notice: nil), .commandFailure("failed"))
        XCTAssertEqual(overlay(failure: nil, notice: nil), .ready)
    }
}
