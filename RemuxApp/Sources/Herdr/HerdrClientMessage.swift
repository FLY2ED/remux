import Foundation

/// The client messages Remux sends (`ClientMessage`, Herdr v0.9.3 `wire.rs:482-640`; variant order is
/// the tag).
enum HerdrClientMessage: Equatable, Sendable {
    /// Must be the first message.
    case hello(HerdrHello)
    case shellResize(HerdrSurfaceGeometry)
    case paneInput(paneID: String, events: [HerdrInputEvent])
    case popupInput(terminalID: String, events: [HerdrInputEvent])
    /// `request` is the JSON `{"id", "method", "params"}`.
    case endpointRequest(bootID: String, request: String)
    case hostTheme(HerdrHostThemeUpdate)
    case focus(Bool)
    case healthPing(data: String)
    case detach

    /// An endpoint command; `bootID` must be the current snapshot's.
    static func endpointRequest<Params: Encodable>(
        bootID: String,
        id: String,
        method: String,
        params: Params
    ) throws -> HerdrClientMessage {
        let request = HerdrEndpointRequest(id: id, method: method, params: params)
        let json = try JSONEncoder().encode(request)
        return .endpointRequest(bootID: bootID, request: String(decoding: json, as: UTF8.self))
    }

    var frame: [UInt8] {
        HerdrWire.frame(payload)
    }

    var payload: [UInt8] {
        var writer = HerdrWireWriter()
        switch self {
        case .hello(let hello):
            writer.variant(20)
            writer.string(HerdrControlKind.hello)
            writer.string(hello.json)
        case .shellResize(let geometry):
            writer.variant(12)
            writer.u32(geometry.cellWidthPx)
            writer.u32(geometry.cellHeightPx)
            writer.u16(geometry.cols)
            writer.u16(geometry.rows)
            writer.bool(geometry.pixelMouse)
        case .paneInput(let paneID, let events):
            writer.variant(13)
            writer.string(paneID)
            writer.array(events) { $1.write(to: &$0) }
        case .popupInput(let terminalID, let events):
            writer.variant(14)
            writer.string(terminalID)
            writer.array(events) { $1.write(to: &$0) }
        case .endpointRequest(let bootID, let request):
            writer.variant(15)
            writer.string(bootID)
            writer.string(request)
        case .hostTheme(let update):
            writer.variant(17)
            update.write(to: &writer)
        case .focus(let focused):
            writer.variant(18)
            writer.bool(focused)
        case .healthPing(let data):
            writer.variant(20)
            writer.string(HerdrControlKind.healthPing)
            writer.string(data)
        case .detach:
            writer.variant(4)
        }
        return writer.bytes
    }
}

/// `endpoint.hello.v1` (`protocol/endpoint.rs:47-75`).
struct HerdrHello: Equatable, Sendable, Codable {
    struct SurfaceSize: Equatable, Sendable, Codable {
        let cols: UInt16
        let rows: UInt16
    }

    let generation: UInt32
    let cellWidthPx: UInt32
    let cellHeightPx: UInt32
    let surfaceSize: SurfaceSize
    let pixelMouse: Bool
    let directGraphics: Bool
    let endpointKeybindings: Bool
    let mouseCapture: Bool
    let surfaceActive: Bool
    let surfaceReuse: Bool?
    let surfaceDelta: Bool?
    let surfaceScroll: Bool?
    let snapshotCodecs: [String]?
    let surfaceCodecs: [String]?
    let inputCodecs: [String]?
    let blobCodecs: [String]?

    /// Remux's hello: every surface encoding, the four v1 codecs, and no pixel mouse, direct
    /// graphics, endpoint keybindings or client mouse capture. Cell size 0 means unknown.
    init(cellWidthPx: UInt32, cellHeightPx: UInt32, cols: UInt16, rows: UInt16, surfaceActive: Bool) {
        self.init(
            generation: 1,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            surfaceSize: SurfaceSize(cols: cols, rows: rows),
            pixelMouse: false,
            directGraphics: false,
            endpointKeybindings: false,
            mouseCapture: false,
            surfaceActive: surfaceActive,
            surfaceReuse: true,
            surfaceDelta: true,
            surfaceScroll: true,
            snapshotCodecs: [HerdrControlKind.snapshot],
            surfaceCodecs: ["shell.surface.v1"],
            inputCodecs: ["shell.input.semantic.v1"],
            blobCodecs: ["shell.blob.v1"]
        )
    }

    init(
        generation: UInt32,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        surfaceSize: SurfaceSize,
        pixelMouse: Bool,
        directGraphics: Bool,
        endpointKeybindings: Bool,
        mouseCapture: Bool,
        surfaceActive: Bool,
        surfaceReuse: Bool?,
        surfaceDelta: Bool?,
        surfaceScroll: Bool?,
        snapshotCodecs: [String]?,
        surfaceCodecs: [String]?,
        inputCodecs: [String]?,
        blobCodecs: [String]?
    ) {
        self.generation = generation
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.surfaceSize = surfaceSize
        self.pixelMouse = pixelMouse
        self.directGraphics = directGraphics
        self.endpointKeybindings = endpointKeybindings
        self.mouseCapture = mouseCapture
        self.surfaceActive = surfaceActive
        self.surfaceReuse = surfaceReuse
        self.surfaceDelta = surfaceDelta
        self.surfaceScroll = surfaceScroll
        self.snapshotCodecs = snapshotCodecs
        self.surfaceCodecs = surfaceCodecs
        self.inputCodecs = inputCodecs
        self.blobCodecs = blobCodecs
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Only strings, integers, booleans and arrays: encoding cannot fail.
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case cellWidthPx = "cell_width_px"
        case cellHeightPx = "cell_height_px"
        case surfaceSize = "surface_size"
        case pixelMouse = "pixel_mouse"
        case directGraphics = "direct_graphics"
        case endpointKeybindings = "endpoint_keybindings"
        case mouseCapture = "mouse_capture"
        case surfaceActive = "surface_active"
        case surfaceReuse = "surface_reuse"
        case surfaceDelta = "surface_delta"
        case surfaceScroll = "surface_scroll"
        case snapshotCodecs = "snapshot_codecs"
        case surfaceCodecs = "surface_codecs"
        case inputCodecs = "input_codecs"
        case blobCodecs = "blob_codecs"
    }
}

struct HerdrSurfaceGeometry: Equatable, Sendable {
    let cellWidthPx: UInt32
    let cellHeightPx: UInt32
    let cols: UInt16
    let rows: UInt16
    let pixelMouse: Bool
}

private struct HerdrEndpointRequest<Params: Encodable>: Encodable {
    let id: String
    let method: String
    let params: Params
}

// MARK: - Semantic input (`shell.input.semantic.v1`, `wire.rs:64-182`)

enum HerdrInputEvent: Equatable, Sendable {
    case key(HerdrKeyEvent)
    /// Written to the program as is.
    case text(String)
    case mouse(HerdrMouseEvent)
    /// Bracketed when the program enabled bracketed paste.
    case paste(String)

    func write(to writer: inout HerdrWireWriter) {
        switch self {
        case .key(let key):
            writer.variant(0)
            key.write(to: &writer)
        case .text(let text):
            writer.variant(1)
            writer.string(text)
        case .mouse(let mouse):
            writer.variant(2)
            mouse.write(to: &writer)
        case .paste(let text):
            writer.variant(3)
            writer.string(text)
        }
    }
}

enum HerdrKeyCode: Equatable, Sendable {
    case backspace, enter, left, right, up, down, home, end, pageUp, pageDown
    case tab, backTab, delete, insert, escape
    /// serde `char`: exactly one Unicode scalar. A multi-scalar grapheme goes as `.text`.
    case character(Unicode.Scalar)
    case function(UInt8)
    case null
}

/// crossterm 0.29 `KeyModifiers` bits.
struct HerdrKeyModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let shift = HerdrKeyModifiers(rawValue: 1)
    static let control = HerdrKeyModifiers(rawValue: 2)
    static let alt = HerdrKeyModifiers(rawValue: 4)
    static let `super` = HerdrKeyModifiers(rawValue: 8)
    static let hyper = HerdrKeyModifiers(rawValue: 16)
    static let meta = HerdrKeyModifiers(rawValue: 32)
}

struct HerdrKeyEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case press, `repeat`, release
    }

    let code: HerdrKeyCode
    let modifiers: HerdrKeyModifiers
    let kind: Kind
    let repeatCount: UInt16
    let shiftedCodepoint: UInt32?
    /// The text the key produces. With `tracksRelease` false it is written as plain text.
    let generatedText: String?
    /// Herdr holds the press until its release and releases it itself if the surface deactivates.
    let tracksRelease: Bool
    let physicalKeyID: UInt32?

    init(
        code: HerdrKeyCode,
        modifiers: HerdrKeyModifiers = [],
        kind: Kind = .press,
        repeatCount: UInt16 = 1,
        shiftedCodepoint: UInt32? = nil,
        generatedText: String? = nil,
        tracksRelease: Bool = false,
        physicalKeyID: UInt32? = nil
    ) {
        self.code = code
        self.modifiers = modifiers
        self.kind = kind
        self.repeatCount = repeatCount
        self.shiftedCodepoint = shiftedCodepoint
        self.generatedText = generatedText
        self.tracksRelease = tracksRelease
        self.physicalKeyID = physicalKeyID
    }

    func write(to writer: inout HerdrWireWriter) {
        switch code {
        case .backspace: writer.variant(0)
        case .enter: writer.variant(1)
        case .left: writer.variant(2)
        case .right: writer.variant(3)
        case .up: writer.variant(4)
        case .down: writer.variant(5)
        case .home: writer.variant(6)
        case .end: writer.variant(7)
        case .pageUp: writer.variant(8)
        case .pageDown: writer.variant(9)
        case .tab: writer.variant(10)
        case .backTab: writer.variant(11)
        case .delete: writer.variant(12)
        case .insert: writer.variant(13)
        case .escape: writer.variant(14)
        case .character(let character):
            writer.variant(15)
            writer.character(character)
        case .function(let number):
            writer.variant(16)
            writer.u8(number)
        case .null: writer.variant(17)
        }
        writer.u8(modifiers.rawValue)
        switch kind {
        case .press: writer.variant(0)
        case .repeat: writer.variant(1)
        case .release: writer.variant(2)
        }
        writer.u16(repeatCount)
        writer.optional(shiftedCodepoint) { $0.u32($1) }
        writer.optional(generatedText) { $0.string($1) }
        writer.bool(tracksRelease)
        writer.optional(physicalKeyID) { $0.u32($1) }
        // windows_record: Windows console input only.
        writer.optional(nil as UInt8?) { $0.u8($1) }
    }
}

struct HerdrMouseEvent: Equatable, Sendable {
    enum Button: UInt32, Equatable, Sendable {
        case left = 0, right, middle
    }

    enum Kind: Equatable, Sendable {
        case down(Button), up(Button), drag(Button)
        case moved, scrollUp, scrollDown, scrollLeft, scrollRight
    }

    /// Relative to the pane's text area.
    enum Position: Equatable, Sendable {
        case cell(column: UInt16, row: UInt16)
        case pixels(x: UInt32, y: UInt32, column: UInt16, row: UInt16)
    }

    struct Geometry: Equatable, Sendable {
        let cols: UInt16
        let rows: UInt16
        let widthPx: UInt32
        let heightPx: UInt32
    }

    let kind: Kind
    let position: Position
    let geometry: Geometry?
    let modifiers: HerdrKeyModifiers
    /// Wheel lines; Herdr uses it only to scroll host history. Program wheel routes send one report
    /// or arrow key per event.
    let lines: UInt16

    init(
        kind: Kind,
        position: Position,
        geometry: Geometry? = nil,
        modifiers: HerdrKeyModifiers = [],
        lines: UInt16 = 1
    ) {
        self.kind = kind
        self.position = position
        self.geometry = geometry
        self.modifiers = modifiers
        self.lines = lines
    }

    func write(to writer: inout HerdrWireWriter) {
        switch kind {
        case .down(let button):
            writer.variant(0)
            writer.variant(button.rawValue)
        case .up(let button):
            writer.variant(1)
            writer.variant(button.rawValue)
        case .drag(let button):
            writer.variant(2)
            writer.variant(button.rawValue)
        case .moved: writer.variant(3)
        case .scrollUp: writer.variant(4)
        case .scrollDown: writer.variant(5)
        case .scrollLeft: writer.variant(6)
        case .scrollRight: writer.variant(7)
        }
        switch position {
        case .cell(let column, let row):
            writer.variant(0)
            writer.u16(column)
            writer.u16(row)
        case .pixels(let x, let y, let column, let row):
            writer.variant(1)
            writer.u32(x)
            writer.u32(y)
            writer.u16(column)
            writer.u16(row)
        }
        writer.optional(geometry) { writer, geometry in
            writer.u16(geometry.cols)
            writer.u16(geometry.rows)
            writer.u32(geometry.widthPx)
            writer.u32(geometry.heightPx)
        }
        writer.u8(modifiers.rawValue)
        writer.u16(lines)
    }
}

// MARK: - Host theme (`wire.rs:643-690`)

struct HerdrRGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// The phone's terminal colours, reported so Herdr answers programs' colour queries and resolves
/// default colours with them.
enum HerdrHostThemeUpdate: Equatable, Sendable {
    enum DefaultColorKind: Equatable, Sendable {
        case foreground, background
    }

    enum Appearance: Equatable, Sendable {
        case dark, light
    }

    case defaultColor(DefaultColorKind, HerdrRGB)
    /// Palette index and colour; at most 256 entries.
    case paletteColors([(index: UInt8, color: HerdrRGB)])
    case appearance(Appearance)

    static func == (lhs: HerdrHostThemeUpdate, rhs: HerdrHostThemeUpdate) -> Bool {
        switch (lhs, rhs) {
        case let (.defaultColor(lhsKind, lhsColor), .defaultColor(rhsKind, rhsColor)):
            return lhsKind == rhsKind && lhsColor == rhsColor
        case let (.paletteColors(lhsColors), .paletteColors(rhsColors)):
            return lhsColors.elementsEqual(rhsColors) { $0.index == $1.index && $0.color == $1.color }
        case let (.appearance(lhsAppearance), .appearance(rhsAppearance)):
            return lhsAppearance == rhsAppearance
        default:
            return false
        }
    }

    func write(to writer: inout HerdrWireWriter) {
        func rgb(_ color: HerdrRGB) {
            writer.u8(color.red)
            writer.u8(color.green)
            writer.u8(color.blue)
        }
        switch self {
        case .defaultColor(let kind, let color):
            writer.variant(0)
            writer.variant(kind == .foreground ? 0 : 1)
            rgb(color)
        case .paletteColors(let colors):
            writer.variant(1)
            writer.u64(UInt64(colors.count))
            for entry in colors {
                writer.u8(entry.index)
                rgb(entry.color)
            }
        case .appearance(let appearance):
            writer.variant(2)
            writer.variant(appearance == .dark ? 0 : 1)
        }
    }
}
