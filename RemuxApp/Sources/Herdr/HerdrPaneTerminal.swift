import Foundation
import GhosttyKit

/// One reference to a Herdr pane's terminal, for the renderer that draws it. The engine's producer
/// writes the terminal; producer, this reference and the renderer's surface may be freed in any order
/// (ghostty.h), so a renderer can outlive the pane it showed.
final class HerdrRetainedTerminal: RetainedGhosttyTerminal, @unchecked Sendable {
    /// Immutable, and released exactly once, when the last holder lets go.
    let handle: ghostty_terminal_t

    fileprivate init(handle: ghostty_terminal_t) {
        self.handle = handle
    }

    deinit {
        ghostty_terminal_release(handle)
    }
}

/// A renderer surface registered with the engine. GhosttyKit lets `terminal_changed` run on the
/// engine's thread; the registration fence guarantees no call is in progress once the surface is
/// unregistered, before the main thread frees it.
struct HerdrRendererSurface: Equatable, @unchecked Sendable {
    let handle: ghostty_terminal_surface_t
}

/// One Herdr pane's terminal producer. Its only caller is the engine, which serializes every call as
/// GhosttyKit requires.
final class HerdrPaneProducer {
    enum Failure: Error, Equatable {
        case create(ghostty_terminal_producer_result_e)
        case retain(ghostty_terminal_producer_result_e)
    }

    private let producer: ghostty_terminal_producer_t

    /// A terminal of `columns` × `rows` with no scrollback: Herdr keeps a pane's history on the server
    /// and sends only what is on screen.
    init(columns: UInt16, rows: UInt16) throws(Failure) {
        var config = ghostty_terminal_producer_config_new()
        config.columns = columns
        config.rows = rows
        config.max_scrollback = 0
        var created: ghostty_terminal_producer_t?
        let result = ghostty_terminal_producer_new(&config, &created)
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK, let created else {
            throw .create(result)
        }
        producer = created
    }

    deinit {
        ghostty_terminal_producer_free(producer)
    }

    func retainTerminal() throws(Failure) -> HerdrRetainedTerminal {
        var terminal: ghostty_terminal_t?
        let result = ghostty_terminal_producer_retain_terminal(producer, &terminal)
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK, let terminal else {
            throw .retain(result)
        }
        return HerdrRetainedTerminal(handle: terminal)
    }

    func feed(_ bytes: [UInt8]) -> ghostty_terminal_producer_result_e {
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_terminal_producer_feed(producer, buffer.baseAddress, buffer.count)
        }
    }

    /// The new size and the content written for it, under one hold of the terminal lock, so a
    /// renderer never draws the resized terminal before its repaint.
    func resizeAndFeed(
        columns: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        bytes: [UInt8]
    ) -> ghostty_terminal_producer_result_e {
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_terminal_producer_resize_and_feed(
                producer, columns, rows, cellWidthPx, cellHeightPx, buffer.baseAddress, buffer.count
            )
        }
    }

    func resize(
        columns: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32
    ) -> ghostty_terminal_producer_result_e {
        ghostty_terminal_producer_resize(producer, columns, rows, cellWidthPx, cellHeightPx)
    }
}
