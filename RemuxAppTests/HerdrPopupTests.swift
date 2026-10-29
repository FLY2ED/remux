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
    /// The pixels the tests give the popup's terminal.
    private static let area = (widthPx: UInt32(1170), heightPx: UInt32(1800))

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
        let grid = Self.grid(cell)

        adapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: Self.area.heightPx)
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
    }

    /// The screen learns when the popup's renderer has drawn, as it does for a pane's: what it reads on its
    /// last change says the session is ready, not still opening.
    func testTheScreenLearnsWhenThePopupHasDrawn() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        adapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: Self.area.heightPx)
        let cell = try XCTUnwrap(harness.model.measurement?.cellMetrics)
        let attach = try await harness.bridge(1)
        await attach.serve(DirectServer.welcome() + DirectServer.frame(1, Self.grid(cell), "$ "))
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

    /// The keyboard or a rotation changes the area; once it settles one resize goes, for its newest grid,
    /// and the renderer follows the grid of Herdr's next frame, at the same font.
    func testTheAreaSettlingResizesThePopupOnce() async throws {
        let harness = await makeHarness()
        let (_, attach, cell) = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        let before = await attach.writtenCount

        adapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: 1400)
        adapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: 1100)
        let shorter = HerdrPopupGrid(widthPx: Self.area.widthPx, heightPx: 1100, cell: cell)!
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
        adapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: Self.area.heightPx)
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
    /// for another reason than another device holding the popup; the popup is drawn from the frame Herdr
    /// sends this client, without saying another device has it.
    func testAnAttachThatFailsDrawsThePopupAsHerdrSendsIt() async throws {
        var unknown = HerdrWireWriter()
        unknown.variant(21)
        let cases: [(String, (HerdrPopupGrid) -> [UInt8])] = [
            ("an unknown message type", { DirectServer.frame(1, $0, "$ ") + HerdrWire.frame(unknown.bytes) }),
            ("a truncated frame", { HerdrWire.frame(Array(DirectServer.frame(1, $0, "$ ").dropFirst(4).dropLast(2))) }),
            ("a frame of a size not asked for", { DirectServer.frame(1, HerdrPopupGrid(columns: $0.columns + 1, rows: $0.rows), "$ ") }),
            ("a refusal while an agent reads the popup", { _ in
                DirectServer.shutdown("terminal attach failed: terminal \(Self.popupID) has a read in progress; retry")
            }),
        ]
        for (name, stream) in cases {
            let harness = await makeHarness()
            let session = try await shownSession(harness)
            let adapter = harness.model.terminalScreenAdapter
            await session.bridge.serve(popupSurface(revision: 3, lines: ["abcd", "efgh"]))
            try await harness.waitUntil("\(name): the popup wasn't laid out") { harness.model.layout?.popup != nil }
            adapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: Self.area.heightPx)
            let grid = Self.grid(try XCTUnwrap(harness.model.measurement?.cellMetrics))
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

    /// Typing, pastes and keys go through the attach, as the terminal encodes them; none goes to a pane.
    func testTypingPastesAndKeysGoThroughTheAttach() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        let before = await attach.writtenCount
        let mainBefore = await session.bridge.writtenCount

        XCTAssertTrue(adapter.sendInputToFocusedSurface("ls").isAccepted)
        XCTAssertTrue(adapter.sendPasteToFocusedSurface("echo hi").isAccepted)
        XCTAssertTrue(adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .enter)).isAccepted)
        var bytes: [UInt8] = []
        var index = before
        while !String(decoding: bytes, as: UTF8.self).hasSuffix("\r") {
            for message in try await DirectClient.messages(attach, at: index) {
                guard case .input(let input) = message else { return XCTFail("\(message)") }
                bytes += input
            }
            index += 1
        }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "ls\u{1b}[200~echo hi\u{1b}[201~\r")
        let mainAfter = await session.bridge.writtenCount
        for write in mainBefore..<mainAfter {
            var reader = HerdrWireReader(Array(try await session.bridge.written(write).dropFirst(4)))
            XCTAssertFalse([13, 14].contains(try reader.variant()), "input went over the session's connection")
        }
    }

    /// The composer's message and its Enter go to the popup it was written in, each sent once written.
    func testTheComposersMessageGoesToItsPopup() async throws {
        let harness = await makeHarness()
        let (_, attach, _) = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let before = await attach.writtenCount

        let pasted = await adapter.sendPasteAwaitingCommandCompletion("fix it", to: target)
        XCTAssertTrue(pasted)
        let entered = await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: target)
        XCTAssertTrue(entered)
        let paste = try await DirectClient.messages(attach, at: before)
        XCTAssertEqual(paste, [.input(Array("\u{1b}[200~fix it\u{1b}[201~".utf8))])
        let enter = try await DirectClient.messages(attach, at: before + 1)
        XCTAssertEqual(enter, [.input([0x0d])])
    }

    /// A popup that closes after the composer's paste, as one that exits on its input does, takes the rest
    /// of the message with it: the Enter goes nowhere, not to the pane under it.
    func testTheComposersEnterIsDroppedWhenItsPopupClosesAfterThePaste() async throws {
        let harness = await makeHarness()
        let (session, attach, _) = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let pasted = await adapter.sendPasteAwaitingCommandCompletion("y", to: target)
        XCTAssertTrue(pasted)
        let attachWrites = await attach.writtenCount

        await session.bridge.serve(HerdrServerScript.surface(projection: 1, revision: 9, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the popup didn't close") { harness.model.layout?.popup == nil }
        let mainWrites = await session.bridge.writtenCount
        let entered = await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: target)
        XCTAssertFalse(entered)
        try await Task.sleep(for: .milliseconds(100))
        try await assertNoInput(session.bridge, from: mainWrites)
        let after = await attach.writtenCount
        XCTAssertEqual(after, attachWrites + 1, "only the detach went after the paste")
    }

    /// A popup replacing the one the message was written in doesn't take its Enter.
    func testTheComposersEnterDoesntGoToAPopupThatReplacedItsOwn() async throws {
        let harness = await makeHarness()
        let (session, _, _) = try await attachedPopup(harness)
        let adapter = harness.model.terminalScreenAdapter
        let target = try XCTUnwrap(popup(harness)?.id)
        let pasted = await adapter.sendPasteAwaitingCommandCompletion("y", to: target)
        XCTAssertTrue(pasted)

        await session.bridge.serve(popupSurface(revision: 9, terminalID: "another-popup"))
        try await harness.waitUntil("the popup wasn't replaced") { harness.model.layout?.popup?.terminalID == "another-popup" }
        let mainWrites = await session.bridge.writtenCount
        let entered = await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: target)
        XCTAssertFalse(entered)
        XCTAssertNotEqual(popup(harness)?.id, target)
        try await assertNoInput(session.bridge, from: mainWrites)
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
        adapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: Self.area.heightPx)
        let cell = try XCTUnwrap(harness.model.measurement?.cellMetrics)
        let attach = try await harness.bridge(1)
        await attach.serve(DirectServer.welcome() + DirectServer.frame(1, Self.grid(cell), "$ "))
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
        XCTAssertEqual(popup(harness)?.ink, HerdrTerminalScreenAdapter.popupInk(HerdrPopupAccent.herdrDefault, colors: colors))

        await session.bridge.serve(Self.borderedSurface(revision: 10, accent: 0x02_F3_8B_A8, popup: true))
        try await harness.waitUntil("the frame didn't take the accent") {
            self.popup(harness)?.ink == .color(red: 0xF3, green: 0x8B, blue: 0xA8)
        }
        await session.bridge.serve(Self.borderedSurface(revision: 11, accent: 0x02_A6_E3_A1, popup: true))
        try await harness.waitUntil("the frame didn't follow the accent") {
            self.popup(harness)?.ink == .color(red: 0xA6, green: 0xE3, blue: 0xA1)
        }
        // A single pane draws no lines; the frame keeps the accent the session showed.
        await session.bridge.serve(popupSurface(revision: 12))
        try await harness.waitUntil("the single pane's layout wasn't laid out") { harness.model.layout?.borders.isEmpty == true }
        XCTAssertEqual(popup(harness)?.ink, .color(red: 0xA6, green: 0xE3, blue: 0xA1))
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

    func testTheGridIsTheWholeCellsAnAreaHolds() throws {
        let cell = GhosttyTerminalCellDisplayMetrics(pixelWidth: 24, pixelHeight: 53, contentScale: 3)
        XCTAssertEqual(HerdrPopupGrid(widthPx: 1170, heightPx: 1800, cell: cell), HerdrPopupGrid(columns: 48, rows: 33))
        XCTAssertEqual(HerdrPopupGrid(widthPx: 1176, heightPx: 1802, cell: cell), HerdrPopupGrid(columns: 49, rows: 34))
        XCTAssertNil(HerdrPopupGrid(widthPx: 23, heightPx: 1800, cell: cell))
        let grid = HerdrPopupGrid(columns: 48, rows: 33)
        let drawable = grid.displayMetrics(cell: cell)
        XCTAssertEqual([drawable.pixelWidth, drawable.pixelHeight], [1152, 1749])
        XCTAssertEqual(drawable.contentScale, 3)
    }

    /// The host reports the whole pixels inside its bounds, its edges rounded inward, and draws the grid at
    /// its cells' size on whole pixels inside them.
    func testTheHostReportsWholePixelsAndDrawsTheGridInsideThem() throws {
        let host = GhosttyTerminalPopupHostView(frame: CGRect(x: 10.2, y: 20.5, width: 300.4, height: 200.3))
        var reported: [(UInt32, UInt32)] = []
        host.onArea = { reported.append(($0, $1)) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.addSubview(host)
        window.isHidden = false
        windows.append(window)
        host.layoutIfNeeded()
        let scale = window.screen.scale
        let area = try XCTUnwrap(reported.last)
        XCTAssertEqual(CGFloat(area.0), ((10.2 + 300.4) * scale).rounded(.down) - (10.2 * scale).rounded(.up))
        XCTAssertEqual(CGFloat(area.1), ((20.5 + 200.3) * scale).rounded(.down) - (20.5 * scale).rounded(.up))
    }

    /// The grid is drawn on whole pixels with the area's leftover split on both sides, and a grid of more or
    /// fewer cells, as while Herdr's frames catch up with the keyboard, is drawn where the area's will be.
    func testTheGridKeepsItsPlaceWhileHerdrsFramesCatchUp() throws {
        let cell = GhosttyTerminalCellDisplayMetrics(pixelWidth: 24, pixelHeight: 53, contentScale: 3)
        let origin = CGPoint(x: 0, y: 0)
        func placed(rows: UInt32) -> CGRect {
            GhosttyTerminalPopupHostView.placement(
                areaOrigin: origin,
                widthPx: 1137,
                heightPx: 2096,
                grid: GhosttyTerminalGridSize(columns: 47, rows: rows),
                cell: cell,
                scale: 3
            )
        }
        let settled = placed(rows: 39)
        XCTAssertEqual(settled, CGRect(x: 4.0 / 3, y: 14.0 / 3, width: 1128.0 / 3, height: 2067.0 / 3))
        XCTAssertEqual(placed(rows: 24).origin, settled.origin, "a grid from before the keyboard went down moved")
        XCTAssertEqual(placed(rows: 50).origin, settled.origin, "a grid from before the keyboard came up moved")
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
        let renderer = try await makeRenderer(engine: engine, terminal: try XCTUnwrap(terminal), columns: 4, rows: 2)
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

    private static func grid(_ cell: GhosttyTerminalCellDisplayMetrics) -> HerdrPopupGrid {
        HerdrPopupGrid(widthPx: area.widthPx, heightPx: area.heightPx, cell: cell)!
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
        harness.model.terminalScreenAdapter.preparePopupArea(widthPx: Self.area.widthPx, heightPx: Self.area.heightPx)
        let cell = try XCTUnwrap(harness.model.measurement?.cellMetrics)
        let attach = try await harness.bridge(1)
        await attach.serve(DirectServer.welcome() + DirectServer.frame(1, Self.grid(cell), "$ "))
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
        revision: UInt64,
        title: String = "popup",
        lines: [String] = ["ab", "cd"],
        terminalID: String = popupID
    ) -> [UInt8] {
        HerdrServerScript.surface(
            projection: 1,
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
        engine: HerdrTerminalEngine,
        terminal: HerdrRetainedTerminal,
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
                fence: HerdrPaneRendererFence(engine: engine, target: .popup(Self.popupID), terminal: terminal),
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
    case scroll(up: Bool, lines: UInt16)

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
                messages.append(.scroll(up: try reader.variant() == 0, lines: try reader.u16()))
            case let tag:
                XCTFail("unexpected client message \(tag)")
            }
        }
        return messages
    }
}
