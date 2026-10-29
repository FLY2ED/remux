import Foundation

/// The zooms Remux made on each Herdr session, by the session as Remux reaches it (`HerdrSessionAddress`), kept
/// on the phone since Herdr's zoom has no owner
/// (`HerdrOwnedZooms`). Reads and writes are synchronous, for the engine, which owns the zooms and
/// changes them as Herdr's answers and snapshots come; a write that fails loses only what a later attachment
/// would take over.
protocol HerdrOwnedZoomStore: Sendable {
    func zooms(of session: HerdrSessionAddress) -> HerdrOwnedZooms
    func save(_ zooms: HerdrOwnedZooms, of session: HerdrSessionAddress)
}

final class FileBackedHerdrOwnedZoomStore: HerdrOwnedZoomStore, @unchecked Sendable {
    private struct Entry: Codable {
        let session: HerdrSessionAddress
        let zooms: HerdrOwnedZooms
    }

    private let fileURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent("herdr-owned-zooms.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func zooms(of session: HerdrSessionAddress) -> HerdrOwnedZooms {
        lock.withLock { loadLocked().first { $0.session == session }?.zooms ?? HerdrOwnedZooms() }
    }

    /// A session without zooms has no entry.
    func save(_ zooms: HerdrOwnedZooms, of session: HerdrSessionAddress) {
        lock.withLock {
            var entries = loadLocked().filter { $0.session != session }
            if !zooms.tabIDs.isEmpty { entries.append(Entry(session: session, zooms: zooms)) }
            guard let data = try? encoder.encode(entries) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }
}

final class InMemoryHerdrOwnedZoomStore: HerdrOwnedZoomStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [HerdrSessionAddress: HerdrOwnedZooms] = [:]

    func zooms(of session: HerdrSessionAddress) -> HerdrOwnedZooms {
        lock.withLock { entries[session] ?? HerdrOwnedZooms() }
    }

    func save(_ zooms: HerdrOwnedZooms, of session: HerdrSessionAddress) {
        lock.withLock { entries[session] = zooms.tabIDs.isEmpty ? nil : zooms }
    }
}
