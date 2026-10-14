import CoreGraphics
import Foundation
import GhosttyKit
import SwiftUI
import UIKit

enum TerminalThemePreviewSample {
    static func output(for theme: TerminalTheme) -> Data {
        Data(sample(for: theme).utf8)
    }

    private static let esc = "\u{1B}["
    private static let reset = "\(esc)0m"

    private static func sample(for _: TerminalTheme) -> String {
        [
            "\(esc)2J\(esc)H\(esc)?25h",
            codeLine(number: 1, segments: [
                Run("#include ", "\(esc)34m"),
                Run("<iostream>", "\(esc)32m"),
            ]),
            codeLine(number: 2, segments: []),
            codeLine(number: 3, segments: [
                Run("int", "\(esc)33m"),
                Run(" main() {", reset),
            ]),
            codeLine(number: 4, segments: [
                Run("    std::cout << ", reset),
                Run("\"remux\"", "\(esc)32m"),
                Run(";", reset),
            ]),
            codeLine(number: 5, segments: [Run("}", reset)], terminator: ""),
            "\(esc)6;1H\(esc)44;30m NORMAL \(esc)48;5;8;37m test.cpp \(esc)K\(reset)",
            "\(esc)4;28H",
        ].joined()
    }

    private struct Run {
        let text: String
        let sgr: String

        init(_ text: String, _ sgr: String) {
            self.text = text
            self.sgr = sgr
        }
    }

    private static func codeLine(
        number: Int,
        segments: [Run],
        terminator: String = "\r\n"
    ) -> String {
        var line = "\(reset)\(esc)K\(esc)38;5;8m\(number) "
        for segment in segments { line += "\(segment.sgr)\(segment.text)" }
        return "\(line)\(reset)\(terminator)"
    }
}

struct TerminalThemePreviewRenderRequest: Equatable {
    let settings: TerminalSettings
    let pointSize: CGSize
    let scale: CGFloat
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    init?(settings: TerminalSettings, pointSize: CGSize, scale: CGFloat) {
        let safeWidth = pointSize.width.rounded(.down)
        let safeHeight = pointSize.height.rounded(.down)
        guard safeWidth.isFinite, safeWidth > 0,
              safeHeight.isFinite, safeHeight > 0
        else { return nil }

        let safeScale = max(scale.isFinite && scale > 0 ? scale : 1, 1)
        let metrics = GhosttySurfaceDisplayMetrics(
            size: CGSize(width: safeWidth, height: safeHeight),
            scale: safeScale
        )
        self.settings = settings
        self.pointSize = CGSize(width: safeWidth, height: safeHeight)
        self.scale = safeScale
        pixelWidth = metrics.pixelWidth
        pixelHeight = metrics.pixelHeight
    }
}

/// Owns one producer, its retained terminal, and one renderer surface.
/// SwiftUI mounts the Ghostty renderer view directly.
@MainActor
final class TerminalThemePreviewContent {
    enum CreationError: Error {
        case invalidGrid
        case producer(ghostty_terminal_producer_result_e)
        case terminal(ghostty_terminal_producer_result_e)
        case feed(ghostty_terminal_producer_result_e)
        case surface(ghostty_terminal_surface_result_e)
    }

    let view: GhosttyKitSurfaceView

    private let runtime: GhosttyKitRuntime
    private let producer: ghostty_terminal_producer_t
    private let terminal: ghostty_terminal_t
    private let surface: ghostty_terminal_surface_t

    init(request: TerminalThemePreviewRenderRequest) throws {
        let runtime = try GhosttyKitRuntime(terminalSettings: request.settings)
        guard let viewport = try runtime.measureTmuxViewport(
            size: request.pointSize,
            scale: request.scale
        ) else { throw CreationError.invalidGrid }

        var producerConfig = ghostty_terminal_producer_config_new()
        producerConfig.columns = viewport.columns
        producerConfig.rows = viewport.rows
        producerConfig.max_scrollback = 0

        var createdProducer: ghostty_terminal_producer_t?
        let producerResult = ghostty_terminal_producer_new(&producerConfig, &createdProducer)
        guard producerResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK,
              let createdProducer
        else { throw CreationError.producer(producerResult) }

        var createdTerminal: ghostty_terminal_t?
        let terminalResult = ghostty_terminal_producer_retain_terminal(
            createdProducer,
            &createdTerminal
        )
        guard terminalResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK,
              let createdTerminal
        else {
            ghostty_terminal_producer_free(createdProducer)
            throw CreationError.terminal(terminalResult)
        }

        let output = TerminalThemePreviewSample.output(for: request.settings.theme)
        let feedResult = output.withUnsafeBytes { bytes in
            ghostty_terminal_producer_feed(
                createdProducer,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard feedResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            ghostty_terminal_release(createdTerminal)
            ghostty_terminal_producer_free(createdProducer)
            throw CreationError.feed(feedResult)
        }

        let view = GhosttyKitSurfaceView(frame: CGRect(origin: .zero, size: request.pointSize))
        view.contentScaleFactor = request.scale
        view.applyTerminalTheme(request.settings.theme)
        var surfaceConfig = runtime.makeTmuxBaseSurfaceConfig()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        surfaceConfig.scale_factor = request.scale
        surfaceConfig.width_px = request.pixelWidth
        surfaceConfig.height_px = request.pixelHeight
        surfaceConfig.visible = false
        // Focused so the sample shows the cursor. The view never becomes first
        // responder, so this does not make it interactive.
        surfaceConfig.focused = true

        var createdSurface: ghostty_terminal_surface_t?
        let surfaceResult = ghostty_terminal_surface_new(
            runtime.appHandle,
            createdTerminal,
            &surfaceConfig,
            &createdSurface
        )
        guard surfaceResult == GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
              let createdSurface
        else {
            ghostty_terminal_release(createdTerminal)
            ghostty_terminal_producer_free(createdProducer)
            throw CreationError.surface(surfaceResult)
        }

        self.runtime = runtime
        producer = createdProducer
        terminal = createdTerminal
        surface = createdSurface
        self.view = view
        view.alignGhosttyRendererSublayers()
        let visibleResult = ghostty_terminal_surface_set_visible(createdSurface, true)
        guard visibleResult == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw CreationError.surface(visibleResult)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            ghostty_terminal_surface_free(surface)
            ghostty_terminal_release(terminal)
            ghostty_terminal_producer_free(producer)
            _ = runtime
        }
    }
}

@MainActor
final class TerminalThemePreviewRenderer: ObservableObject {
    enum State {
        case idle
        case ready(TerminalThemePreviewContent)
        case failed
    }

    @Published private(set) var state: State = .idle
    private var currentRequest: TerminalThemePreviewRenderRequest?

    func render(settings: TerminalSettings, pointSize: CGSize, scale: CGFloat) {
        guard let request = TerminalThemePreviewRenderRequest(
            settings: settings,
            pointSize: pointSize,
            scale: scale
        ) else {
            currentRequest = nil
            state = .idle
            return
        }
        guard request != currentRequest else { return }
        currentRequest = request
        do {
            state = .ready(try TerminalThemePreviewContent(request: request))
        } catch {
            GhosttyRuntimeTrace.diagnostics(
                "themePreview.create failed error=\(String(describing: error))"
            )
            state = .failed
        }
    }
}

struct TerminalThemePreviewContentView: UIViewRepresentable {
    /// Strong ownership is intentional: the native producer/terminal/surface
    /// must outlive the UIKit renderer view returned from makeUIView.
    let content: TerminalThemePreviewContent

    func makeUIView(context: Context) -> GhosttyKitSurfaceView {
        content.view
    }

    func updateUIView(_ uiView: GhosttyKitSurfaceView, context: Context) {}
}
