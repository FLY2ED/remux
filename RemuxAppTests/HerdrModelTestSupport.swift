import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Reads a renderer's terminal back as text through Ghostty's own selection, and Herdr's cells as the
/// same text.
@MainActor
enum RendererText {
    /// The first `rows` rows of `columns` cells, each as Ghostty selects it (a word in the row,
    /// stretched across the row), without surrounding blanks.
    static func rows(of renderer: TerminalPaneRenderer, columns: Int, rows: Int) -> [String] {
        guard let surface = renderer.rawSurface else {
            XCTFail("renderer has no surface")
            return []
        }
        var size = ghostty_surface_size_s()
        guard ghostty_terminal_surface_size(surface, &size) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            XCTFail("renderer has no size")
            return []
        }
        let cellWidth = Double(size.cell_width_px)
        let cellHeight = Double(size.cell_height_px)
        var snapshot = ghostty_terminal_surface_selection_snapshot_s()
        defer { _ = ghostty_terminal_surface_clear_selection(surface, &snapshot) }
        return (0..<rows).map { row in
            let y = (Double(row) + 0.5) * cellHeight
            var anchored = false
            for column in 0..<columns where !anchored {
                _ = ghostty_terminal_surface_select_word(surface, (Double(column) + 0.5) * cellWidth, y, &snapshot)
                anchored = snapshot.active
            }
            guard anchored else { return "" }
            _ = ghostty_terminal_surface_set_selection_endpoint(
                surface, GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START, 0.5 * cellWidth, y, &snapshot
            )
            _ = ghostty_terminal_surface_set_selection_endpoint(
                surface, GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END, (Double(columns) - 0.5) * cellWidth, y, &snapshot
            )
            var text = ghostty_text_s()
            guard ghostty_terminal_surface_read_selection(surface, &text) == GHOSTTY_TERMINAL_SURFACE_INPUT_SENT else {
                return ""
            }
            defer { _ = ghostty_terminal_surface_free_text(surface, &text) }
            let bytes = UnsafeRawBufferPointer(start: text.text, count: Int(text.text_len))
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    /// The area's rows as Herdr sent them: each cell's symbol, a covered cell adding nothing, without
    /// surrounding blanks.
    static func rows(of frame: HerdrFrame, in area: HerdrSurfaceRect) -> [String] {
        (0..<Int(area.height)).map { y in
            let start = (Int(area.y) + y) * Int(frame.width) + Int(area.x)
            return frame.cells[start..<(start + Int(area.width))]
                .map(\.symbol)
                .joined()
                .trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Server messages for a scripted Herdr session.
enum HerdrServerScript {
    struct Pane {
        let id: String
        let x: UInt16
        let width: UInt16
        let height: UInt16
        var focused = false
    }

    /// A recorded v0.9.3 welcome.
    static func welcome() throws -> [UInt8] {
        HerdrWire.frame(try HerdrConnectionTests.frames(HerdrConnectionTests.recording("herdr-01-handshake-all-caps-A"))[0])
    }

    static func snapshot(revision: UInt64, boot: String = "boot", tabLabel: String = "main") -> [UInt8] {
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":"w1","focused_tab_id":"t1",
         "focused_pane_id":null,"workspaces":[],"tabs":[{"tab_id":"t1","workspace_id":"w1","number":1,
         "label":"\(tabLabel)","custom_label":true,"zoomed":false,"focused":true,"agent_status":"idle"}],
         "panes":[],"agents":[]}
        """
        var writer = HerdrWireWriter()
        writer.variant(20)
        writer.string(HerdrControlKind.snapshot)
        writer.string(json)
        return HerdrWire.frame(writer.bytes)
    }

    /// A full surface of the given lines, all of one width, with every pane's text area on row 0 down.
    static func surface(
        boot: String = "boot",
        projection: UInt64,
        revision: UInt64,
        lines: [String],
        panes: [Pane]
    ) -> [UInt8] {
        let width = lines.first?.count ?? 0
        precondition(lines.allSatisfy { $0.count == width })
        var writer = HerdrWireWriter()
        writer.variant(13)
        writer.string(boot)
        writer.u64(projection)
        writer.u64(revision)
        writer.array(Array(lines.joined())) { writer, character in
            writer.string(String(character))
            writer.u32(0)
            writer.u32(0)
            writer.u16(0)
            writer.bool(false)
            writer.optional(nil as UInt32?) { $0.u32($1) }
        }
        writer.u16(UInt16(width))
        writer.u16(UInt16(lines.count))
        writer.optional(nil as UInt8?) { $0.u8($1) }
        writer.array([String]()) { $0.string($1) }
        writer.byteArray([])
        writer.array(panes) { writer, pane in
            writer.string(pane.id)
            writer.u64(1)
            for _ in 0..<2 {
                writer.u16(pane.x)
                writer.u16(0)
                writer.u16(pane.width)
                writer.u16(pane.height)
            }
            writer.optional(nil as UInt8?) { $0.u8($1) }
            writer.optional(nil as UInt8?) { $0.u8($1) }
            writer.bool(pane.focused)
            writer.bool(false)
            writer.bool(false)
            writer.bool(false)
            writer.u32(0)
            writer.u32(0)
        }
        writer.array([UInt8]()) { $0.u8($1) }
        writer.optional(nil as UInt8?) { $0.u8($1) }
        for _ in 0..<3 {
            writer.array([UInt8]()) { $0.u8($1) }
        }
        return HerdrWire.frame(writer.bytes)
    }

    static func surfaceSetReply(id: String, active: Bool) -> [UInt8] {
        HerdrConnectionTests.reply(
            id: id,
            json: #"{"type":"client_shell_surface_set","active":\#(active),"projection_revision":1}"#
        )
    }
}

/// What Remux wrote, decoded.
enum ClientWrite: Equatable {
    case hello(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int, surfaceActive: Bool)
    case resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    case surfaceSet(id: String, active: Bool)
    case theme(HerdrHostThemeUpdate)
    case focus(Bool)
    case other(tag: UInt32, kind: String)

    var isSurfaceSet: Bool {
        if case .surfaceSet = self { true } else { false }
    }

    static func decode(_ frame: [UInt8]) throws -> ClientWrite {
        var reader = HerdrWireReader(Array(frame.dropFirst(4)))
        let tag = try reader.variant()
        switch tag {
        case 20:
            let kind = try reader.string()
            let data = try reader.string()
            guard kind == HerdrControlKind.hello else { return .other(tag: tag, kind: kind) }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
            let size = try XCTUnwrap(json["surface_size"] as? [String: Int])
            return .hello(
                cols: try XCTUnwrap(size["cols"]),
                rows: try XCTUnwrap(size["rows"]),
                cellWidth: try XCTUnwrap(json["cell_width_px"] as? Int),
                cellHeight: try XCTUnwrap(json["cell_height_px"] as? Int),
                surfaceActive: try XCTUnwrap(json["surface_active"] as? Bool)
            )
        case 12:
            let cellWidth = try reader.u32()
            let cellHeight = try reader.u32()
            return .resize(cols: try reader.u16(), rows: try reader.u16(), cellWidth: cellWidth, cellHeight: cellHeight)
        case 15:
            let request = try HerdrConnectionTests.request(frame)
            guard request.method == HerdrConnection.surfaceSetMethod else {
                return .other(tag: tag, kind: request.method)
            }
            return .surfaceSet(id: request.id, active: try XCTUnwrap(request.params?["active"]))
        case 17:
            func rgb() throws -> HerdrRGB {
                HerdrRGB(red: try reader.u8(), green: try reader.u8(), blue: try reader.u8())
            }
            switch try reader.variant() {
            case 0:
                let kind: HerdrHostThemeUpdate.DefaultColorKind = try reader.variant() == 0 ? .foreground : .background
                return .theme(.defaultColor(kind, try rgb()))
            case 1:
                var colors: [UInt8: HerdrRGB] = [:]
                for _ in 0..<(try reader.u64()) {
                    let index = try reader.u8()
                    colors[index] = try rgb()
                }
                return .theme(.paletteColors(colors))
            default:
                return .theme(.appearance(try reader.variant() == 0 ? .dark : .light))
            }
        case 18:
            return .focus(try reader.bool())
        default:
            return .other(tag: tag, kind: "")
        }
    }
}

/// A `HerdrScreenModel` over scripted bridges: each bridge the model opens is a new
/// `FakeBridgeTransport`, and every state the model reports is kept.
@MainActor
final class HerdrModelHarness {
    actor Bridges {
        private(set) var opened: [FakeBridgeTransport] = []
        private var failure: Error?

        func failNextOpen(with error: Error) {
            failure = error
        }

        func open() throws -> FakeBridgeTransport {
            if let failure {
                self.failure = nil
                throw failure
            }
            let transport = FakeBridgeTransport()
            opened.append(transport)
            return transport
        }
    }

    final class StateLog {
        var updates: [TerminalRuntimeStateUpdate] = []
    }

    let bridges: Bridges
    let stateLog: StateLog
    let model: HerdrScreenModel

    init(
        settings: TerminalSettings = .default,
        timing: HerdrConnection.Timing = HerdrConnection.Timing(),
        failingOpenWith openError: Error? = nil
    ) async {
        let bridges = Bridges()
        let stateLog = StateLog()
        if let openError { await bridges.failNextOpen(with: openError) }
        let server = SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "main")
        let target = SessionTarget(
            server: server,
            workspace: workspace,
            sshAuth: .password(
                username: server.username,
                password: "secret",
                identityID: server.identityID,
                displayLabel: server.displayName
            ),
            terminalSettings: settings
        )
        self.bridges = bridges
        self.stateLog = stateLog
        model = HerdrScreenModel(
            target: target,
            sessionInstanceID: UUID(),
            openBridge: { try await bridges.open() },
            onRuntimeStateChange: { stateLog.updates.append($0) },
            connectionTiming: timing
        )
    }

    var states: [TerminalRuntimeState] { stateLog.updates.map(\.state) }

    /// The bridge the model opened `index`th, waiting up to two seconds for it.
    func bridge(_ index: Int = 0) async throws -> FakeBridgeTransport {
        try await waitUntil("bridge \(index) wasn't opened") { await self.bridges.opened.count > index }
        return await bridges.opened[index]
    }

    func setScreenSize() {
        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 844), scale: 3)
    }

    /// The bridge's writes from `index` on, decoded, once there are `count` of them.
    func writes(
        _ bridge: FakeBridgeTransport,
        from index: Int = 0,
        count: Int
    ) async throws -> [ClientWrite] {
        var writes: [ClientWrite] = []
        for position in index..<(index + count) {
            writes.append(try ClientWrite.decode(try await bridge.written(position)))
        }
        return writes
    }

    /// The next `surface.set` from `index` on, waiting for it; `index` moves past it.
    func nextSurfaceSet(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> (id: String, active: Bool) {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            if case .surfaceSet(let id, let active) = write { return (id, active) }
        }
    }

    func waitUntil(
        _ failure: String,
        timeout: Duration = .seconds(3),
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(failure)
        throw HarnessTimeout()
    }

    struct HarnessTimeout: Error {}

    /// Each shown pane's rows, as its renderer shows them, by pane id.
    func shownRows() -> [String: [String]] {
        var shown: [String: [String]] = [:]
        for pane in model.layout?.panes ?? [] where pane.hasTextArea {
            guard let surface = model.paneSurface(pane.paneID) else { continue }
            shown[pane.paneID] = RendererText.rows(
                of: surface.renderer,
                columns: Int(pane.innerRect.width),
                rows: Int(pane.innerRect.height)
            )
        }
        return shown
    }
}
