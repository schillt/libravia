import XCTest
@testable import BookCore

final class StoragePrivacyTests: XCTestCase {
    @MainActor func testDeviceRemovalPreservesReadingStateAndProtectsOpenBook() async throws {
        let namespace = "device-copy-test-\(UUID())"
        let cache = try BookCache(namespace: namespace)
        let store = try ReadingStore(namespace: namespace)
        let root = await cache.root
        defer { try? FileManager.default.removeItem(at: root); try? store.delete() }
        let book = Book(id: "fixture", title: "Fixture", author: "", summary: "", format: .pdf, isFolder: false, ticks: 0)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("%PDF-fixture".utf8).write(to: source)
        _ = try await cache.install(source, book: book)
        try store.add(Bookmark(name: "Saved", position: .init(page: 2)), id: book.id)
        let keys = try await cache.availableKeys()
        XCTAssertTrue(keys.contains(stableKey(book.id)))
        do { try await cache.remove(book); XCTFail("Open book must remain protected") } catch {}
        await cache.protect(nil)
        try await cache.remove(book)
        let remaining = try await cache.availableKeys()
        XCTAssertFalse(remaining.contains(stableKey(book.id)))
        XCTAssertEqual(store.bookmarks[book.id]?.count, 1)
        try await cache.remove(book)
    }
    func testSignedOutCacheRejectsNewInstallAndDisposesOwnedDownload() async throws {
        let cache = try BookCache(namespace: "privacy-test-\(UUID())")
        let root = await cache.root
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("%PDF-fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
        try await cache.delete()
        try await cache.delete()
        let book = Book(id: "fixture", title: "Fixture", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        do {
            _ = try await cache.install(source, book: book)
            XCTFail("A retired account cache must reject installs")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDownloadedCacheIsExcludedFromBackup() async throws {
        let cache = try BookCache(namespace: "privacy-test-\(UUID())")
        let root = await cache.root
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    @MainActor func testReadingStateDeletionIsIdempotent() throws {
        let store = try ReadingStore(namespace: "privacy-test-\(UUID())")
        try store.add(Bookmark(name: "Fixture", position: ReadingPosition()), id: "fixture")
        try store.delete()
        try store.delete()
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }
}
