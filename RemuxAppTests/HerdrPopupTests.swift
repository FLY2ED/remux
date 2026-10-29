import Combine
import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Herdr's popup in Remux: while it is on the phone's screen the phone attaches straight to its terminal, at
/// the grid the terminal area holds at the panes' font, and shows it in Herdr's frame; the popup takes the
/// tab's input; the phone lets it go when it leaves; when Herdr refuses the attach, the popup is drawn from
/// the frames Herdr sends this client.
@MainActor
final class HerdrPopupTests: XCTestCase {
    private var harnesses: [HerdrModelHarness] = []
    private var windows: [UIWindow] = []
    private var renderers: [TerminalPaneRenderer] = []
    private var runtime: GhosttyKitRuntime?

    private static let popupID = "popup-terminal"
    private static let panes: [HerdrServerScript.Pane] = [
        .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
        .init(id: "w1:p2", x: 4, width: 3, height: 1),
    ]

    override func tearDown() async throws {
        for renderer in renderers {
            await withCheckedContinuation { continuation in renderer.close { continuation.resume() } }
        }
        renderers.removeAll()
        for window in windows {
            window.isHidden = true
        }
        windows.removeAll()
        for harness in harnesses {
            for bridge in await harness.bridges.opened {
                await bridge.finishServing()
            }
            await harness.model.stop()
        }
        harnesses.removeAll()
        runtime = nil
    }

    // MARK: - Holding the popup

    /// The popup on screen is attached at the grid its area holds, and its renderer draws Herdr's frames
    /// at the panes' font, in the frame with the popup's title and its tab.
    func testThePopupOnScreenIsAttachedAtTheGridItsAreaHolds() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        await session.bridge.serve(popupSurface(revision: 3, title: "notes"))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        let cell = try XCTUnwrap(harness.model.measurement?.cellMetrics)
        let grid = try Self.grid(harness)

        let attach = try await harness.bridge(1)
        let opening = try await DirectClient.messages(attach, at: 0)
        XCTAssertEqual(opening, [
            .hello(columns: grid.columns, rows: grid.rows, cellWidthPx: cell.pixelWidth, cellHeightPx: cell.pixelHeight),
            .attach(Self.popupID),
        ])
        await attach.serve(DirectServer.welcome() + DirectServer.frame(1, grid, "$ "))
        try await harness.waitUntil("the popup's renderer wasn't made") { self.popup(harness)?.grid != nil }
        let popup = try XCTUnwrap(self.popup(harness))
        XCTAssertEqual(popup.title, "notes")
        XCTAssertEqual(popup.tabLabel, "main")
        XCTAssertEqual(popup.grid, GhosttyTerminalGridSize(columns: UInt32(grid.columns), rows: UInt32(grid.rows)))
        XCTAssertEqual(popup.cell, cell, "the popup isn't at the panes' font")
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)
        // The attach is quiet while the popup is, so Herdr mustn't end it for that.
        let kinds = await harness.bridges.kinds
        XCTAssertEqual(kinds, [.session, .terminal])
    }

    /// The screen learns when the popup's renderer has drawn, as it does for a pane's: what it reads on its
    /// last change says the session is ready, not still opening.
    func testTheScreenLearnsWhenThePopupHasDrawn() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        let cell = try XCTUnwrap(harness.model.measurement?.cellMetrics)
        let attach = try await harness.bridge(1)
        await attach.serve(DirectServer.welcome() + DirectServer.frame(1, try Self.grid(harness), "$ "))
        try await harness.waitUntil("the popup's renderer wasn't made") { harness.model.popup.surface?.renderer.managedSurface != nil }
        try await Task.sleep(for: .milliseconds(300))

        var read: [GhosttyTerminalStatusOverlayProjection] = []
        let observation = adapter.objectWillChange.sink {
            DispatchQueue.main.async { read.append(adapter.terminalScreenPresentationProjection.statusOverlay) }
        }
        defer { observation.cancel() }
        show(try XCTUnwrap(harness.model.popup.surface?.renderer.view))
        try await harness.waitUntil("the popup wasn't drawn") { harness.model.popupPresentation == .ready }
        try await harness.waitUntil("the screen wasn't told the popup drew") { read.last == .ready }
    }

    /// The keyboard or a rotation changes the screen's grid; once it settles one resize goes, for the newest
    /// grid inside the frame, and the renderer follows the grid of Herdr's next frame, at the same font.
    func testTheScreenSettlingResizesThePopupOnce() async throws {
        let harness = await makeHarness()
        let (_, attach, cell) = try await attachedPopup(harness)
        let before = await attach.writtenCount

        harness.model.prepareViewport(size: CGSize(width: 390, height: 640), scale: 3)
        harness.model.prepareViewport(size: CGSize(width: 390, height: 480), scale: 3)
        let shorter = try Self.grid(harness)
        let resized = try await DirectClient.messages(attach, at: before)
        XCTAssertEqual(resized, [.resize(columns: shorter.columns, rows: shorter.rows)])
        try await Task.sleep(for: .milliseconds(400))
        let writes = await attach.writtenCount
        XCTAssertEqual(writes, before + 1, "a superseded size went too")

        await attach.serve(DirectServer.frame(2, shorter, "$ "))
        try await harness.waitUntil("the renderer didn't follow the new grid") {
            self.popup(harness)?.grid?.rows == UInt32(shorter.rows)
        }
        XCTAssertEqual(popup(harness)?.cell, cell)
    }

    /// Leaving the session lets the popup go, which gives its size back; coming back attaches again.
    func testLeavingDetachesAndComingBackAttachesAgain() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        var index = session.next
        let before = await attach.writtenCount

        harness.model.setSelected(false)
        let left = try await DirectClient.messages(attach, at: before)
        XCTAssertEqual(left, [.detach])
        try await harness.waitUntil("the attach's bridge stayed open") { await attach.isClosed }
        XCTAssertNil(harness.model.popup.surface)

        harness.model.setSelected(true)
        var show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        while !show.active { show = try await harness.nextSurfaceSet(session.bridge, from: &index) }
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await session.bridge.serve(try harness.shownSurface(projection: 1, revision: 20, lines: ["one two"], panes: Self.panes, popup: Self.popupID))
        let again = try await harness.bridge(2)
        let opening = try await DirectClient.messages(again, at: 0)
        XCTAssertEqual(opening.last, .attach(Self.popupID))
    }

    /// A hidden session reads as connected also with a popup open: the phone lets the popup go when the
    /// session leaves the screen, and Home shows the session's state, as it does for its panes.
    func testAHiddenSessionWithAPopupReadsAsConnected() async throws {
        let harness = await makeHarness()
        _ = try await attachedPopup(harness)
        try await harness.waitUntil("the shown session wasn't connected") { harness.states.last == .connected }

        harness.model.setSelected(false)
        try await harness.waitUntil("the popup wasn't let go") { harness.model.popup.surface == nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.states.last, .connected, "the hidden session read as its popup")
    }

    /// The background lets the popup go, as leaving does, and back in front the phone attaches again; an
    /// inactive phase, as under Control Center, keeps it.
    func testTheBackgroundDetachesAndTheFrontAttachesAgain() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        var index = session.next
        let before = await attach.writtenCount

        harness.model.handleAppLifecyclePhase(.inactive)
        try await Task.sleep(for: .milliseconds(200))
        let inactive = await attach.writtenCount
        XCTAssertEqual(inactive, before, "an inactive phase let the popup go")
        harness.model.handleAppLifecyclePhase(.background)
        let left = try await DirectClient.messages(attach, at: before)
        XCTAssertEqual(left, [.detach])
        try await harness.waitUntil("the attach's bridge stayed open") { await attach.isClosed }

        harness.model.handleAppLifecyclePhase(.active)
        var show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        while !show.active { show = try await harness.nextSurfaceSet(session.bridge, from: &index) }
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await session.bridge.serve(try harness.shownSurface(projection: 1, revision: 20, lines: ["one two"], panes: Self.panes, popup: Self.popupID))
        let again = try await harness.bridge(2)
        let opening = try await DirectClient.messages(again, at: 0)
        XCTAssertEqual(opening.last, .attach(Self.popupID))
    }

    /// Another device holds the popup: Herdr refuses the attach, the phone says so, and the popup is drawn
    /// from the frame Herdr sends this client, whose input goes as Herdr's client sends a popup's.
    func testARefusedAttachDrawsThePopupAsHerdrSendsIt() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        await session.bridge.serve(popupSurface(revision: 3, lines: ["abcd", "efgh"]))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        let attach = try await harness.bridge(1)
        await attach.serve(DirectServer.welcome() + DirectServer.shutdown(
            "terminal attach failed: terminal \(Self.popupID) already has an attached client; retry with --takeover"
        ))
        try await harness.waitUntil("the popup wasn't drawn from its frame") { self.popup(harness)?.grid != nil }
        XCTAssertEqual(popup(harness)?.grid, GhosttyTerminalGridSize(columns: 4, rows: 2))
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .notice(HerdrScreenModel.popupHeldElsewhereMessage))

        XCTAssertTrue(adapter.sendInputToFocusedSurface("l").isAccepted)
        let typed = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(typed, popupInput(HerdrInputTranslator.events(forText: "l", reportsAllKeys: false)))
        // The composer's message goes the same way once the popup has drawn, and learns once Herdr has it.
        show(try XCTUnwrap(harness.model.popup.surface?.renderer.view))
        try await harness.waitUntil("the popup wasn't drawn") { harness.model.popupPresentation == .ready }
        let target = try XCTUnwrap(popup(harness)?.id)
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("fix it", to: target) }
        let pasted = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(pasted, popupInput([.paste("fix it")]))
        let ping = try await nextPing(session.bridge, from: &index)
        await session.bridge.serve(HerdrConnectionTests.pong(ping))
        let delivered = await paste.value
        XCTAssertTrue(delivered)
        let opened = await harness.bridges.opened.count
        XCTAssertEqual(opened, 2, "the refused popup was attached again")
    }

    /// Anything on the attach Remux doesn't expect, as a newer Herdr might send, ends it, as does a refusal
    /// for another reason than another device holding the popup or Herdr asking to try again; the popup is
    /// drawn from the frame Herdr sends this client, without saying another device has it.
    func testAnAttachThatFailsDrawsThePopupAsHerdrSendsIt() async throws {
        var unknown = HerdrWireWriter()
        unknown.variant(21)
        let cases: [(String, (HerdrPopupGrid) -> [UInt8])] = [
            ("an unknown message type", { DirectServer.frame(1, $0, "$ ") + HerdrWire.frame(unknown.bytes) }),
            ("a truncated frame", { HerdrWire.frame(Array(DirectServer.frame(1, $0, "$ ").dropFirst(4).dropLast(2))) }),
            ("a frame of a size not asked for", { DirectServer.frame(1, HerdrPopupGrid(columns: $0.columns + 1, rows: $0.rows), "$ ") }),
            ("a refusal for a terminal Herdr doesn't have", { _ in
                DirectServer.shutdown("terminal attach failed: terminal \(Self.popupID) not found")
            }),
        ]
        for (name, stream) in cases {
            let harness = await makeHarness()
            let session = try await shownSession(harness)
            let adapter = harness.model.terminalScreenAdapter
            await session.bridge.serve(popupSurface(revision: 3, lines: ["abcd", "efgh"]))
            try await harness.waitUntil("\(name): the popup wasn't laid out") { harness.model.layout?.popup != nil }
            let grid = try Self.grid(harness)
            let attach = try await harness.bridge(1)
            await attach.serve(DirectServer.welcome() + stream(grid))
            try await harness.waitUntil("\(name): the popup wasn't drawn from its frame") {
                self.popup(harness)?.grid == GhosttyTerminalGridSize(columns: 4, rows: 2)
            }
            try await harness.waitUntil("\(name): the attach's bridge stayed open") { await attach.isClosed }
            XCTAssertNotEqual(
                adapter.terminalScreenPresentationProjection.statusOverlay,
                .notice(HerdrScreenModel.popupHeldElsewhereMessage),
                name
            )
            let opened = await harness.bridges.opened.count
            XCTAssertEqual(opened, 2, "\(name): the popup was attached again")
        }
    }

    /// Herdr asks to try again while an agent reads the popup's terminal: the phone attaches again, once,
    /// after a moment, and a second refusal draws the popup from its frame.
    func testAReadInProgressIsTriedAgainOnce() async throws {
        let busy = DirectServer.shutdown("terminal attach failed: terminal \(Self.popupID) has a read in progress; retry")
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        await session.bridge.serve(popupSurface(revision: 3, lines: ["abcd", "efgh"]))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        let grid = try Self.grid(harness)
        let first = try await harness.bridge(1)
        await first.serve(DirectServer.welcome() + busy)
        let refusedAt = ContinuousClock.now
        let second = try await harness.bridge(2)
        let waited = ContinuousClock.now - refusedAt
        XCTAssertGreaterThanOrEqual(waited, HerdrPopupController.retryDelay - .milliseconds(20), "the attach went again at once")
        await second.serve(DirectServer.welcome() + DirectServer.frame(1, grid, "$ "))
        try await harness.waitUntil("the second attach wasn't drawn") { harness.model.popup.surface?.isAttached == true }

        let again = await makeHarness()
        let other = try await shownSession(again)
        await other.bridge.serve(popupSurface(revision: 3, lines: ["abcd", "efgh"]))
        try await again.waitUntil("the popup wasn't laid out") { again.model.layout?.popup != nil }
        let firstAgain = try await again.bridge(1)
        await firstAgain.serve(DirectServer.welcome() + busy)
        let secondAgain = try await again.bridge(2)
        await secondAgain.serve(DirectServer.welcome() + busy)
        try await again.waitUntil("the popup wasn't drawn from its frame") {
            self.popup(again)?.grid == GhosttyTerminalGridSize(columns: 4, rows: 2)
        }
        try await Task.sleep(for: HerdrPopupController.retryDelay * 2)
        let opened = await again.bridges.opened.count
        XCTAssertEqual(opened, 3, "the popup was attached a third time")
    }

    /// Herdr ends the attach once the popup's program exits; nothing of the popup is drawn after, and the
    /// layout without it brings the panes back.
    func testAPopupWhoseProgramExitsLeavesNothingBehind() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        await attach.serve(DirectServer.shutdown("terminal attach ended: terminal \(Self.popupID) not found"))
        try await harness.waitUntil("the popup's renderer stayed") { harness.model.popup.surface == nil }
        XCTAssertNil(popup(harness)?.grid, "the popup was drawn from its frames")
        await session.bridge.serve(HerdrServerScript.surface(projection: 1, revision: 9, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the popup stayed after it closed") { self.popup(harness) == nil }
        XCTAssertEqual(harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.viewport.panes.count, 2)
    }

    // MARK: - Input

    /// Typing, pastes and keys go as Herdr's client sends a popup's, over the session's connection: Herdr
    /// encodes each for the program's modes, as an arrow for application cursor keys, and makes the phone
    /// the client it sends the program's clipboard writes to. The attach carries none.
    func testTypingPastesAndKeysGoAsHerdrsClientSendsAPopups() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let attachWrites = await attach.writtenCount

        XCTAssertTrue(adapter.sendInputToFocusedSurface("ls").isAccepted)
        XCTAssertTrue(adapter.sendPasteToFocusedSurface("echo hi").isAccepted)
        XCTAssertTrue(adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .arrowUp)).isAccepted)
        let typed = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(typed, popupInput(HerdrInputTranslator.events(forText: "ls", reportsAllKeys: false)))
        let pasted = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(pasted, popupInput([.paste("echo hi")]))
        let key = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(key, popupInput([.key(HerdrKeyEvent(code: .up, tracksRelease: true))]))
        let after = await attach.writtenCount
        XCTAssertEqual(after, attachWrites, "input went over the attach")
    }

    /// Herdr says when the popup's program asks for every key (`ClientShellKeyboardReportAll` follows the
    /// popup), and typing then goes as Herdr's client sends it for such a program.
    func testTypingFollowsHerdrsReportOfEveryKey() async throws {
        let harness = await makeHarness()
        let (session, _, _) = try await attachedPopup(harness)
        var index = session.next
        await session.bridge.serve(HerdrServerScript.keyboardReportAll(true) + popupSurface(revision: 4, title: "every key"))
        try await harness.waitUntil("the popup's title didn't follow") { self.popup(harness)?.title == "every key" }
        XCTAssertNotEqual(
            HerdrInputTranslator.events(forText: "é", reportsAllKeys: true),
            HerdrInputTranslator.events(forText: "é", reportsAllKeys: false)
        )

        XCTAssertTrue(harness.model.terminalScreenAdapter.sendInputToFocusedSurface("é").isAccepted)
        let typed = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(typed, popupInput(HerdrInputTranslator.events(forText: "é", reportsAllKeys: true)))
    }

    /// A swipe over the popup goes as Herdr's client sends a popup's wheel, a step a row at the cell under the
    /// finger, on the same connection and queue as the keys: a key after a swipe comes after all of its steps,
    /// so it can't reset the history before steps that scroll it away again. Nothing goes over the attach.
    func testASwipeAndAKeyGoInOrderAsHerdrsClientSendsThem() async throws {
        let harness = await makeHarness()
        let (session, attach, cell) = try await attachedPopup(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let attachWrites = await attach.writtenCount

        _ = adapter.sendMousePosition(to: target, CGPoint(x: cell.pointWidth * 2.5, y: cell.pointHeight * 3.5), mods: [])
        let swipe = GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: Double(cell.pixelHeight) * 2, mods: .init(precision: true, momentum: .began))
        XCTAssertEqual(adapter.sendMouseScroll(to: target, swipe), .sent)
        XCTAssertTrue(adapter.sendInputToFocusedSurface("k").isAccepted)
        let wheel = HerdrMouseEvent(kind: .scrollUp, column: 2, row: 3, modifiers: [], lines: 1)
        let steps = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(steps, popupInput([.mouse(wheel), .mouse(wheel)]))
        let key = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(key, popupInput(HerdrInputTranslator.events(forText: "k", reportsAllKeys: false)))
        let after = await attach.writtenCount
        XCTAssertEqual(after, attachWrites, "the swipe went over the attach")
    }

    /// Typing, a key, a paste and the composer's message end a selection in the popup, as Herdr's client ends
    /// its own on a key, text or a paste, whatever sends it; a wheel step doesn't.
    func testInputOtherThanTheWheelEndsThePopupsSelection() async throws {
        let harness = await makeHarness()
        let (_, _, cell) = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let surface = try XCTUnwrap(harness.model.popup.surface?.renderer.managedSurface)
        // The popup's first cell holds the frame's "$".
        let point = CGPoint(x: cell.pointWidth / 2, y: cell.pointHeight / 2)
        func selected() -> Bool {
            if case .snapshot(let snapshot) = surface.selectionSnapshot() { snapshot.isActive } else { false }
        }
        func select() {
            _ = surface.selectWord(at: point)
            XCTAssertTrue(selected(), "the popup's text wasn't selected")
        }

        select()
        _ = adapter.sendMousePosition(to: target, point, mods: [])
        let wheel = GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: Double(cell.pixelHeight) * 1.2, mods: .init(precision: true, momentum: .began))
        XCTAssertEqual(adapter.sendMouseScroll(to: target, wheel), .sent)
        XCTAssertTrue(selected(), "a wheel step ended the selection")

        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .accepted)
        XCTAssertFalse(selected(), "typing kept the selection")

        select()
        XCTAssertEqual(adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .escape)), .accepted)
        XCTAssertFalse(selected(), "Escape kept the selection")

        select()
        XCTAssertEqual(adapter.sendPasteToFocusedSurface("pasted"), .accepted)
        XCTAssertFalse(selected(), "a paste kept the selection")

        select()
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("message", to: target) }
        try await harness.waitUntil("the composer's paste kept the selection") { !selected() }
        paste.cancel()
    }

    /// The composer's message and its Enter go to the popup it was written in, each once Herdr has it.
    func testTheComposersMessageGoesToItsPopup() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let attachWrites = await attach.writtenCount

        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("fix it", to: target) }
        let pasted = try await nextDeliveredInput(session.bridge, from: &index)
        XCTAssertEqual(pasted, popupInput([.paste("fix it")]))
        let pasteDelivered = await paste.value
        XCTAssertTrue(pasteDelivered)
        let enter = Task { await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: target) }
        let entered = try await nextDeliveredInput(session.bridge, from: &index)
        XCTAssertEqual(entered, popupInput([.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]))
        let enterDelivered = await enter.value
        XCTAssertTrue(enterDelivered)
        let after = await attach.writtenCount
        XCTAssertEqual(after, attachWrites, "the message went over the attach")
    }

    /// A popup that closes after the composer's paste, as one that exits on its input does, takes the rest
    /// of the message with it: the Enter goes nowhere, not to the pane under it.
    func testTheComposersEnterIsDroppedWhenItsPopupClosesAfterThePaste() async throws {
        let harness = await makeHarness()
        let (session, _, _) = try await attachedPopup(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("y", to: target) }
        _ = try await nextDeliveredInput(session.bridge, from: &index)
        let pasted = await paste.value
        XCTAssertTrue(pasted)

        await session.bridge.serve(HerdrServerScript.surface(projection: 1, revision: 9, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the popup didn't close") { harness.model.layout?.popup == nil }
        let mainWrites = await session.bridge.writtenCount
        let entered = await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: target)
        XCTAssertFalse(entered)
        try await Task.sleep(for: .milliseconds(100))
        try await assertNoInput(session.bridge, from: mainWrites)
    }

    /// A popup replacing the one the message was written in doesn't take its Enter.
    func testTheComposersEnterDoesntGoToAPopupThatReplacedItsOwn() async throws {
        let harness = await makeHarness()
        let (session, _, _) = try await attachedPopup(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("y", to: target) }
        _ = try await nextDeliveredInput(session.bridge, from: &index)
        let pasted = await paste.value
        XCTAssertTrue(pasted)

        await session.bridge.serve(popupSurface(revision: 9, terminalID: "another-popup"))
        try await harness.waitUntil("the popup wasn't replaced") { harness.model.layout?.popup?.terminalID == "another-popup" }
        let mainWrites = await session.bridge.writtenCount
        let entered = await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: target)
        XCTAssertFalse(entered)
        XCTAssertNotEqual(popup(harness)?.id, target)
        try await assertNoInput(session.bridge, from: mainWrites)
    }

    /// A composer message over Herdr's limit doesn't go, and the composer learns it didn't; nothing of it
    /// reaches the popup, which Herdr would refuse.
    func testAComposerMessageOverHerdrsLimitDoesntGo() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let mainWrites = await session.bridge.writtenCount
        let attachWrites = await attach.writtenCount

        let message = String(repeating: "x", count: HerdrConnection.maxInputBytes + 1)
        let pasted = await adapter.sendPasteAwaitingCommandCompletion(message, to: target)
        XCTAssertFalse(pasted)
        try await Task.sleep(for: .milliseconds(100))
        try await assertNoInput(session.bridge, from: mainWrites)
        let after = await attach.writtenCount
        XCTAssertEqual(after, attachWrites)
    }

    /// A popup opening between a message's paste into a pane and its Enter doesn't take the Enter.
    func testAPopupOpeningAfterAPanesPasteDoesntTakeItsEnter() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("fix it", to: pane) }
        _ = try await nextInput(session.bridge, from: &index)
        let ping = try await nextPing(session.bridge, from: &index)
        await session.bridge.serve(HerdrConnectionTests.pong(ping))
        let pasted = await paste.value
        XCTAssertTrue(pasted)

        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        let entered = await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: pane)
        XCTAssertFalse(entered)
    }

    /// A hidden session's popup takes no input.
    func testAHiddenSessionsPopupTakesNoInput() async throws {
        let harness = await makeHarness()
        _ = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        harness.model.setSelected(false)
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("l"), .transportUnavailable)
    }

    // MARK: - Screen

    func testTabsAndPanesAreInertUnderThePopup() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = adapter.terminalScreenPresentationProjection.viewport.panes[1].id
        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }

        XCTAssertFalse(adapter.focusPane(other).isHandled)
        XCTAssertFalse(adapter.createTopLevel(inGroup: nil).isHandled)
        XCTAssertFalse(adapter.createTopLevelGroup(from: nil).isHandled)
        XCTAssertFalse(adapter.splitFocusedPane(GHOSTTY_SPLIT_DIRECTION_RIGHT).isHandled)
        XCTAssertFalse(adapter.setFocusedPaneZoomed(true).isHandled)
        XCTAssertFalse(adapter.closePane(other).isHandled)

        await session.bridge.serve(HerdrServerScript.surface(projection: 1, revision: 4, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the popup didn't close") { harness.model.layout?.popup == nil }
        XCTAssertTrue(adapter.focusPane(other).isHandled)
        let focus = try await nextCommand(session.bridge, from: &index)
        guard case .paneFocus(_, let paneID) = focus else {
            return XCTFail("a command went while the popup was open: \(focus)")
        }
        XCTAssertEqual(paneID, "w1:p2")
    }

    /// A new title for the same popup is shown at once.
    /// The frame names the tab it is over as the user named it, else "tab" and its number, as Herdr's own
    /// name for a tab is its number; a rename shows while the popup is on screen.
    func testTheFrameNamesItsTabAsTheToolbarCountsTabs() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 2, tabLabel: "1", customTabLabel: false, focusedPane: "w1:p1", panes: ["w1:p1", "w1:p2"].map { HerdrServerScript.snapshotPane($0) })
                + popupSurface(projection: 2, revision: 3)
        )
        try await harness.waitUntil("the popup didn't say its tab") { self.popup(harness)?.tabLabel == "tab 1" }
        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 3, tabLabel: "notes", focusedPane: "w1:p1", panes: ["w1:p1", "w1:p2"].map { HerdrServerScript.snapshotPane($0) })
                + popupSurface(projection: 3, revision: 4)
        )
        try await harness.waitUntil("the popup didn't follow the tab's name") { self.popup(harness)?.tabLabel == "notes" }
    }

    func testThePopupsTitleFollowsHerdr() async throws {
        let harness = await makeHarness()
        let (session, _, _) = try await attachedPopup(harness)
        await session.bridge.serve(popupSurface(revision: 9, title: "logs"))
        try await harness.waitUntil("the new title wasn't shown") { self.popup(harness)?.title == "logs" }
        XCTAssertNotNil(popup(harness)?.grid, "a new title let the popup go")
    }

    /// A session opened while a popup is open waits on the popup, not on the panes it covers, which aren't
    /// drawn under it.
    func testASessionOpenedUnderAPopupIsReadyOnceThePopupIsDrawn() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome()
                + HerdrServerScript.snapshot(
                    revision: 1,
                    focusedPane: "w1:p1",
                    panes: ["w1:p1", "w1:p2"].map { HerdrServerScript.snapshotPane($0) }
                )
        )
        await bridge.serve(popupSurface(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let showing = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: showing.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: Self.panes, popup: Self.popupID))
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        let cell = try XCTUnwrap(harness.model.measurement?.cellMetrics)
        let attach = try await harness.bridge(1)
        await attach.serve(DirectServer.welcome() + DirectServer.frame(1, try Self.grid(harness), "$ "))
        try await harness.waitUntil("the popup's renderer wasn't made") { harness.model.popup.surface != nil }
        show(try XCTUnwrap(harness.model.popup.surface?.renderer.view))
        try await harness.waitUntil("the session waited on the panes under the popup", timeout: .seconds(5)) {
            TerminalReadinessProjector.runtimeState(adapter.terminalScreenPresentationProjection.readiness) == .connected
        }
    }

    /// The frame is in Herdr's accent: the colour of the focused pane's border lines, kept for a tab that
    /// draws none, and followed when it changes while the popup is shown.
    func testTheFramesInkIsHerdrsAccentAndFollowsIt() async throws {
        let harness = await makeHarness()
        let (session, _, _) = try await attachedPopup(harness)
        let colors = harness.model.terminalColors
        XCTAssertEqual(
            popup(harness)?.titleInk,
            HerdrTerminalScreenAdapter.ink(HerdrPopupAccent.herdrDefault, colors: colors, minimumContrast: GhosttyTerminalColors.MinimumContrast.text)
        )

        await session.bridge.serve(Self.borderedSurface(revision: 10, accent: 0x02_F3_8B_A8, popup: true))
        try await harness.waitUntil("the frame didn't take the accent") {
            self.popup(harness)?.titleInk == .color(red: 0xF3, green: 0x8B, blue: 0xA8)
        }
        await session.bridge.serve(Self.borderedSurface(revision: 11, accent: 0x02_A6_E3_A1, popup: true))
        try await harness.waitUntil("the frame didn't follow the accent") {
            self.popup(harness)?.titleInk == .color(red: 0xA6, green: 0xE3, blue: 0xA1)
        }
        XCTAssertEqual(popup(harness)?.border.map(\.ink), Array(repeating: .color(red: 0xA6, green: 0xE3, blue: 0xA1), count: 4))
        // A single pane draws no lines; the frame keeps the accent the session showed.
        await session.bridge.serve(popupSurface(revision: 12))
        try await harness.waitUntil("the single pane's layout wasn't laid out") { harness.model.layout?.borders.isEmpty == true }
        XCTAssertEqual(popup(harness)?.titleInk, .color(red: 0xA6, green: 0xE3, blue: 0xA1))
    }

    func testTheAccentIsTheFocusedPanesLines() {
        let accent = HerdrColor(raw: 0x02_89_B4_FA)
        let other = HerdrColor(raw: 0x02_6C_70_86)
        // Two panes side by side, text areas 1...2 and 5...6 on row 1, framed by lines on rows 0 and 2 and
        // columns 0, 3, 4 and 7.
        func layout(focused: String) -> HerdrPaneLayout {
            let leftColor = focused == "a" ? accent : other
            let rightColor = focused == "b" ? accent : other
            return HerdrPaneLayout(
                bootID: "boot",
                tab: nil,
                focusedPaneID: focused,
                columns: 8,
                rows: 3,
                panes: [
                    .init(paneID: "a", innerRect: HerdrSurfaceRect(x: 1, y: 1, width: 2, height: 1), name: "a", path: ""),
                    .init(paneID: "b", innerRect: HerdrSurfaceRect(x: 5, y: 1, width: 2, height: 1), name: "b", path: ""),
                ],
                borders: [
                    HerdrBorderLine(axis: .horizontal, track: 0, start: 1, end: 7, color: leftColor),
                    HerdrBorderLine(axis: .horizontal, track: 0, start: 9, end: 15, color: rightColor),
                    HerdrBorderLine(axis: .vertical, track: 0, start: 1, end: 5, color: leftColor),
                    HerdrBorderLine(axis: .vertical, track: 7, start: 1, end: 5, color: rightColor),
                ],
                popup: nil
            )
        }
        XCTAssertEqual(HerdrPopupAccent.color(in: layout(focused: "a")), accent)
        XCTAssertEqual(HerdrPopupAccent.color(in: layout(focused: "b")), accent)
        let bare = HerdrPaneLayout(bootID: "boot", tab: nil, focusedPaneID: "a", columns: 3, rows: 1, panes: [
            .init(paneID: "a", innerRect: HerdrSurfaceRect(x: 0, y: 0, width: 3, height: 1), name: "a", path: ""),
        ], borders: [], popup: nil)
        XCTAssertNil(HerdrPopupAccent.color(in: bare))
    }

    // MARK: - Grid

    /// The popup takes the cells inside Herdr's frame on the panes' grid, whose lines take the outer cells.
    func testThePopupTakesTheCellsInsideHerdrsFrame() {
        XCTAssertEqual(HerdrPopupGrid(framedIn: 50, rows: 41), HerdrPopupGrid(columns: 48, rows: 39))
        XCTAssertEqual(HerdrPopupGrid(framedIn: 50, rows: 25), HerdrPopupGrid(columns: 48, rows: 23))
        XCTAssertNil(HerdrPopupGrid(framedIn: 2, rows: 41))
        XCTAssertNil(HerdrPopupGrid(framedIn: 50, rows: 2))
        let cell = GhosttyTerminalCellDisplayMetrics(pixelWidth: 24, pixelHeight: 53, contentScale: 3)
        let drawable = HerdrPopupGrid(columns: 48, rows: 39).displayMetrics(cell: cell)
        XCTAssertEqual([drawable.pixelWidth, drawable.pixelHeight], [1152, 2067])
        XCTAssertEqual(drawable.contentScale, 3)
    }

    /// The popup's frame is Herdr's box on the outer cells of the panes' grid, its lines drawn as the panes'
    /// lines are: through the middle of the outer cells, as thin, in the ink of a line in Herdr's accent. Its
    /// terminal takes the cells inside, and its labels are in the panes' cells.
    func testTheFrameIsHerdrsBoxOnThePanesGrid() async throws {
        let harness = await makeHarness()
        let (session, _, _) = try await attachedPopup(harness)
        // Herdr lays out the client's whole grid.
        await session.bridge.serve(try harness.shownSurface(projection: 1, revision: 20, lines: ["one two"], panes: Self.panes, popup: Self.popupID))
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the screen's grid wasn't laid out") {
            (adapter.terminalScreenPresentationProjection.viewport.windowGrid?.rows ?? 0) > 2
        }
        let viewport = adapter.terminalScreenPresentationProjection.viewport
        let popup = try XCTUnwrap(viewport.popup)
        let grid = try XCTUnwrap(viewport.windowGrid)
        let cell = try XCTUnwrap(viewport.cellMetrics)
        let colors = harness.model.terminalColors
        let ink = HerdrTerminalScreenAdapter.ink(HerdrPopupAccent.herdrDefault, colors: colors, minimumContrast: GhosttyTerminalColors.MinimumContrast.line)
        func line(_ orientation: GhosttyPaneLine.Orientation, _ position: CGFloat, _ end: CGFloat) -> GhosttyPaneLine {
            GhosttyPaneLine(orientation: orientation, position: position, start: 0.5, end: end, ink: ink, width: HerdrTerminalScreenAdapter.borderWidth, cap: .square)
        }
        let columns = CGFloat(grid.columns), rows = CGFloat(grid.rows)
        XCTAssertEqual(popup.border, [
            line(.horizontal, 0.5, columns - 0.5), line(.horizontal, rows - 0.5, columns - 0.5),
            line(.vertical, 0.5, rows - 0.5), line(.vertical, columns - 0.5, rows - 0.5),
        ])
        XCTAssertEqual(
            GhosttyTerminalViewportPresentationProjection.Popup.content(in: grid),
            GhosttyTerminalGridRect(x: 1, y: 1, columns: grid.columns - 2, rows: grid.rows - 2)
        )
        let inside = try Self.grid(harness)
        XCTAssertEqual([UInt32(inside.columns), UInt32(inside.rows)], [grid.columns - 2, grid.rows - 2])
        // The labels' characters are a cell wide, at the terminal's font size.
        let font = GhosttyTerminalPopupFrameView.labelFont(cellWidth: cell.pointWidth)
        XCTAssertEqual(("0" as NSString).size(withAttributes: [.font: font]).width, cell.pointWidth, accuracy: 0.01)
    }

    /// Herdr's colours stay readable on the phone's terminal, whose theme Herdr doesn't draw for: a line at
    /// 3:1 and text at 4.5:1 against the background, mixed toward the foreground only as far as that takes,
    /// so Herdr's dark accent reads on a light terminal and is left as it is on a dark one. The tab's label
    /// is the terminal's text made secondary, still readable.
    func testHerdrsInkIsReadableOnTheTerminalsBackground() throws {
        let light = try GhosttyKitRuntime(terminalSettings: TerminalSettings(fontSize: nil, theme: .remuxLight)).terminalColors()
        let dark = try GhosttyKitRuntime(terminalSettings: TerminalSettings(fontSize: nil, theme: .remuxDark)).terminalColors()
        let white = GhosttyTerminalColors.Color(red: 255, green: 255, blue: 255)
        let black = GhosttyTerminalColors.Color(red: 0, green: 0, blue: 0)
        XCTAssertEqual(GhosttyTerminalColors.contrast(black, white), 21, accuracy: 0.001)
        let accent = GhosttyTerminalColors.Color(red: 0x89, green: 0xB4, blue: 0xFA)
        XCTAssertEqual(GhosttyTerminalColors.contrast(accent, light.background), 1.86, accuracy: 0.01)

        for (minimum, name) in [(GhosttyTerminalColors.MinimumContrast.line, "line"), (GhosttyTerminalColors.MinimumContrast.text, "text")] {
            let onLight = light.legible(accent, minimumContrast: minimum)
            XCTAssertGreaterThanOrEqual(GhosttyTerminalColors.contrast(onLight, light.background), minimum, name)
            XCTAssertLessThan(GhosttyTerminalColors.contrast(onLight, light.background), minimum + 0.2, "\(name): mixed further than it needed")
            XCTAssertEqual(dark.legible(accent, minimumContrast: minimum), accent, "\(name): a readable accent changed")
        }
        for colors in [light, dark] {
            let secondary = GhosttyTerminalColors.contrast(colors.secondaryText, colors.background)
            XCTAssertGreaterThanOrEqual(secondary, GhosttyTerminalColors.MinimumContrast.text)
            XCTAssertLessThan(secondary, GhosttyTerminalColors.contrast(colors.foreground, colors.background))
        }

        // The panes' lines take the same rule: Herdr's focus line in its dark accent, on a light terminal.
        let focusLine = HerdrTerminalScreenAdapter.paneLine(
            HerdrBorderLine(axis: .horizontal, track: 0, start: 1, end: 7, color: HerdrPopupAccent.herdrDefault),
            colors: light
        )
        guard case .color(let red, let green, let blue) = focusLine.ink else { return XCTFail("\(focusLine.ink)") }
        XCTAssertGreaterThanOrEqual(
            GhosttyTerminalColors.contrast(GhosttyTerminalColors.Color(red: red, green: green, blue: blue), light.background),
            GhosttyTerminalColors.MinimumContrast.line
        )
    }

    /// Herdr's terminals cluster graphemes, and its frames write a joined emoji as one cell's text for a
    /// terminal that clusters them as Ghostty's do; the attach's terminal does too, so the emoji keeps its
    /// cell and the text after it its own (recorded from Herdr v0.9.5).
    func testAJoinedEmojiKeepsItsCellOnTheAttachsTerminal() async throws {
        let fixture = try DirectTerminalFixture(version: "0.9.5", scenario: "06-grapheme")
        let payloads = try fixture.serverPayloads()
        let bridge = FakeBridgeTransport()
        let attachment = HerdrTerminalAttachment(
            terminalID: fixture.expected.client.compactMap(\.AttachTerminal).first?.terminal_id ?? "term",
            geometry: .init(columns: 40, rows: 12, cellWidthPx: 8, cellHeightPx: 16),
            openBridge: { bridge }
        )
        Task { await attachment.run() }
        // Up to Herdr's end of the attach, which would end the renderer's registration with it.
        let shutdown = try XCTUnwrap(payloads.lastIndex { $0.first == 3 })
        await bridge.serve(payloads[..<shutdown].flatMap(HerdrWire.frame))
        var updates = attachment.updates.makeAsyncIterator()
        var terminal: HerdrRetainedTerminal?
        while terminal == nil {
            guard let event = await updates.next() else { return XCTFail("the attach ended") }
            if case .terminal(let made, _, _) = event { terminal = made }
        }
        let attached = try XCTUnwrap(terminal)
        let renderer = try await makeRenderer(
            terminal: attached,
            fence: HerdrTerminalAttachmentFence(attachment: attachment, terminal: attached),
            columns: 40,
            rows: 2
        )
        XCTAssertEqual(RendererText.rows(of: renderer, columns: 40, rows: 2), ["\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} X", "sh-3.2$"])
        await attachment.detach()
    }

    // MARK: - Engine

    /// The engine paints a popup's frame only while it is drawn from its frames; turned on, it paints the
    /// frame on screen, and a call older than the last applied is ignored.
    func testTheEnginePaintsThePopupOnlyWhileAsked() async throws {
        let engine = HerdrTerminalEngine(cellWidthPx: 18, cellHeightPx: 38)
        var updates = engine.updates.makeAsyncIterator()
        let feed = await engine.beginConnection(1)
        await feed.receive(try HerdrTerminalEngineTests.snapshot(revision: 1))
        await feed.receive(.surface(try Self.engineSurface(revision: 1, popup: (Self.popupID, "notes", ["hi  ", "ok  "]))))
        var layout: HerdrPaneLayout?
        while layout == nil {
            switch await updates.next() {
            case .popupTerminal?:
                return XCTFail("the popup was painted while it wasn't asked for")
            case .drawn(let next, _, _)?:
                layout = next
            case nil:
                return XCTFail("the engine ended")
            default:
                continue
            }
        }
        XCTAssertEqual(layout?.popup, HerdrPaneLayout.Popup(terminalID: Self.popupID, title: "notes", columns: 4, rows: 2))

        await engine.setPaintsPopup(true, revision: 2)
        await engine.setPaintsPopup(false, revision: 1)
        var terminal: HerdrRetainedTerminal?
        while terminal == nil {
            guard case .popupTerminal(let terminalID, let next)? = await updates.next() else { continue }
            XCTAssertEqual(terminalID, Self.popupID)
            terminal = next
        }
        let painted = try XCTUnwrap(terminal)
        let renderer = try await makeRenderer(
            terminal: painted,
            fence: HerdrPaneRendererFence(engine: engine, target: .popup(Self.popupID), terminal: painted),
            columns: 4,
            rows: 2
        )
        XCTAssertEqual(RendererText.rows(of: renderer, columns: 4, rows: 2), ["hi", "ok"])
        await feed.receive(.surface(try Self.engineSurface(revision: 2, popup: (Self.popupID, "notes", ["hi  ", "yes "]))))
        XCTAssertEqual(RendererText.rows(of: renderer, columns: 4, rows: 2), ["hi", "yes"])
        await engine.stop()
    }

    // MARK: - Support

    private func makeHarness() async -> HerdrModelHarness {
        let harness = await HerdrModelHarness()
        harnesses.append(harness)
        return harness
    }

    /// The grid inside the popup's frame on the screen's grid.
    private static func grid(_ harness: HerdrModelHarness) throws -> HerdrPopupGrid {
        let viewport = try XCTUnwrap(harness.model.measurement?.controlViewport)
        return try XCTUnwrap(HerdrPopupGrid(framedIn: viewport.columns, rows: viewport.rows))
    }

    private func popup(_ harness: HerdrModelHarness) -> GhosttyTerminalViewportPresentationProjection.Popup? {
        harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.viewport.popup
    }

    /// A session shown with a popup over its tab, attached at the tests' area and drawn.
    private func attachedPopup(
        _ harness: HerdrModelHarness
    ) async throws -> (session: (bridge: FakeBridgeTransport, next: Int), attach: FakeBridgeTransport, cell: GhosttyTerminalCellDisplayMetrics) {
        let session = try await shownSession(harness)
        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        let cell = try XCTUnwrap(harness.model.measurement?.cellMetrics)
        let attach = try await harness.bridge(1)
        await attach.serve(DirectServer.welcome() + DirectServer.frame(1, try Self.grid(harness), "$ "))
        try await harness.waitUntil("the popup's renderer wasn't made") { harness.model.popup.surface?.renderer.managedSurface != nil }
        show(try XCTUnwrap(harness.model.popup.surface?.renderer.view))
        // The renderer takes input once it has drawn.
        try await harness.waitUntil("the popup wasn't drawn") { harness.model.popupPresentation == .ready }
        return (session, attach, cell)
    }

    /// A session shown with panes `w1:p1` and `w1:p2`, both drawn, `w1:p1` focused; returns its bridge and
    /// the index of the first write after the show.
    private func shownSession(_ harness: HerdrModelHarness) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome()
                + HerdrServerScript.snapshot(
                    revision: 1,
                    focusedPane: "w1:p1",
                    panes: ["w1:p1", "w1:p2"].map { HerdrServerScript.snapshotPane($0) }
                )
        )
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one two"], panes: Self.panes))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the panes' renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        for pane in Self.panes {
            if let view = harness.model.paneSurface(pane.id)?.renderer.view {
                viewController.view.addSubview(view)
            }
        }
        window.isHidden = false
        windows.append(window)
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        return (bridge, index)
    }

    private func show(_ view: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.isHidden = false
        windows.append(window)
    }

    private func popupSurface(
        projection: UInt64 = 1,
        revision: UInt64,
        title: String = "popup",
        lines: [String] = ["ab", "cd"],
        terminalID: String = popupID
    ) -> [UInt8] {
        HerdrServerScript.surface(
            projection: projection,
            revision: revision,
            lines: ["one two"],
            panes: Self.panes,
            popup: terminalID,
            popupTitle: title,
            popupLines: lines
        )
    }

    /// Pane `w1:p1` framed by Herdr's lines, the accent on its horizontal lines, beside `w1:p2`.
    private static func borderedSurface(revision: UInt64, accent: UInt32, popup: Bool) -> [UInt8] {
        HerdrServerScript.surface(
            projection: 1,
            revision: revision,
            lines: ["┌───┐   ", "│one│two", "└───┘   "],
            panes: [
                .init(id: "w1:p1", x: 1, y: 1, width: 3, height: 1, focused: true, rect: (0, 0, 5, 3)),
                .init(id: "w1:p2", x: 5, y: 1, width: 3, height: 1),
            ],
            popup: popup ? popupID : nil,
            foreground: ["┌": accent, "─": accent, "┐": accent, "└": accent, "┘": accent, "│": 0x02_6C_70_86]
        )
    }

    private func popupInput(_ events: [HerdrInputEvent]) -> [UInt8] {
        HerdrClientMessage.popupInput(terminalID: Self.popupID, events: events).frame
    }

    /// The next pane or popup input from `index` on, as framed; `index` moves past it.
    private func nextInput(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> [UInt8] {
        while true {
            let frame = try await bridge.written(index)
            index += 1
            var reader = HerdrWireReader(Array(frame.dropFirst(4)))
            let tag = try reader.variant()
            if tag == 13 || tag == 14 { return frame }
        }
    }

    /// The next pane or popup input from `index` on, then Herdr's answer to the ping after it, which tells
    /// the composer Herdr has it.
    private func nextDeliveredInput(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> [UInt8] {
        let input = try await nextInput(bridge, from: &index)
        let ping = try await nextPing(bridge, from: &index)
        await bridge.serve(HerdrConnectionTests.pong(ping))
        return input
    }

    private func assertNoInput(_ bridge: FakeBridgeTransport, from index: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let count = await bridge.writtenCount
        for write in index..<count {
            var reader = HerdrWireReader(Array(try await bridge.written(write).dropFirst(4)))
            XCTAssertFalse([13, 14].contains(try reader.variant()), "input went over the session's connection", file: file, line: line)
        }
    }

    private func nextPing(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> String {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            if case .ping(let data) = write { return data }
        }
    }

    /// The next command from `index` on; pane input in between fails the test.
    private func nextCommand(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> ClientWrite {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            switch write {
            case .paneFocus, .paneZoom, .command: return write
            default: continue
            }
        }
    }

    /// A frame of pane `P` and, when given, a popup of terminal `id`, titled `title`, of `lines`.
    private static func engineSurface(
        revision: UInt64,
        popup: (id: String, title: String, lines: [String])?
    ) throws -> HerdrPaneSurfaceFrame {
        func frame(_ lines: [String]) -> String {
            let width = lines.first?.count ?? 0
            let cells = lines.joined().map {
                #"{"symbol":"\#($0)","fg":0,"bg":0,"modifier":0,"skip":false,"hyperlink":null}"#
            }
            return #"{"cells":[\#(cells.joined(separator: ","))],"width":\#(width),"height":\#(lines.count),"cursor":null,"hyperlinks":[],"graphics":[]}"#
        }
        let popupJSON = popup.map {
            #"{"terminal_id":"\#($0.id)","title":"\#($0.title)","width":null,"height":null,"frame":\#(frame($0.lines)),"mouse_reporting":false,"sgr_pixel_mouse":false,"pixel_width":0,"pixel_height":0}"#
        } ?? "null"
        let json = """
        {"boot_id":"boot","projection_revision":1,"surface_revision":\(revision),
         "frame":\(frame(["pane    "])),
         "panes":[\(HerdrTerminalEngineTests.pane("P", x: 0, width: 8, height: 1, focused: true))],"splits":[],
         "popup":\(popupJSON),"graphics":{"assets":[],"placements":[],"retained_assets":[]}}
        """
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    private func makeRenderer(
        terminal: HerdrRetainedTerminal,
        fence: any TerminalPaneRendererFence,
        columns: Int,
        rows: Int
    ) async throws -> TerminalPaneRenderer {
        let runtime = try self.runtime ?? GhosttyKitRuntime(terminalSettings: .default)
        self.runtime = runtime
        let measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(size: CGSize(width: 390, height: 844), scale: 3))
        let metrics = try XCTUnwrap(measurement.displayMetrics(columns: UInt32(columns), rows: UInt32(rows)))
        let renderer = try await withCheckedThrowingContinuation { continuation in
            TerminalPaneRenderer.create(
                app: runtime.appHandleForTesting,
                terminal: terminal,
                fence: fence,
                writeInput: nil,
                baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
                metrics: metrics,
                theme: .ghosttyDefault,
                diagnosticName: "test popup",
                onRendererFailure: {}
            ) { result in continuation.resume(with: result) }
        }
        renderers.append(renderer)
        return renderer
    }
}

/// What Herdr sends a direct terminal client, for a scripted attach.
enum DirectServer {
    static func welcome() -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(0)
        writer.u32(22)
        writer.variant(1)
        writer.optional(nil as String?) { $0.string($1) }
        return HerdrWire.frame(writer.bytes)
    }

    /// A full frame of `grid` that clears it and writes `text`.
    static func frame(_ sequence: UInt64, _ grid: HerdrPopupGrid, _ text: String) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(1)
        writer.u64(sequence)
        writer.u16(grid.columns)
        writer.u16(grid.rows)
        writer.bool(true)
        writer.byteArray(Array("\u{1b}[H\u{1b}[2J\(text)".utf8))
        return HerdrWire.frame(writer.bytes)
    }

    static func shutdown(_ reason: String) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(3)
        writer.optional(reason) { $0.string($1) }
        return HerdrWire.frame(writer.bytes)
    }
}

/// What a direct terminal client wrote, read back from a scripted bridge.
enum DirectClient: Equatable {
    case hello(columns: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32)
    case attach(String)
    case input([UInt8])
    case resize(columns: UInt16, rows: UInt16)
    case detach
    case scroll(up: Bool, lines: UInt16, column: UInt16?, row: UInt16?)

    /// The messages of the write at `index`, waiting for it.
    static func messages(_ bridge: FakeBridgeTransport, at index: Int) async throws -> [DirectClient] {
        var splitter = HerdrFrameSplitter()
        splitter.append(try await bridge.written(index))
        var messages: [DirectClient] = []
        while let payload = try splitter.nextPayload() {
            var reader = HerdrWireReader(payload)
            switch try reader.variant() {
            case 0:
                _ = try reader.u32()
                messages.append(.hello(columns: try reader.u16(), rows: try reader.u16(), cellWidthPx: try reader.u32(), cellHeightPx: try reader.u32()))
            case 1:
                messages.append(.input(try reader.byteArray()))
            case 3:
                messages.append(.resize(columns: try reader.u16(), rows: try reader.u16()))
            case 4:
                messages.append(.detach)
            case 5:
                messages.append(.attach(try reader.string()))
            case 6:
                _ = try reader.variant()
                let up = try reader.variant() == 0
                let lines = try reader.u16()
                messages.append(.scroll(up: up, lines: lines, column: try reader.optional { try $0.u16() }, row: try reader.optional { try $0.u16() }))
            case let tag:
                XCTFail("unexpected client message \(tag)")
            }
        }
        return messages
    }
}
