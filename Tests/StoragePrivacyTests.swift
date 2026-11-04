import XCTest
@testable import BookCore

final class StoragePrivacyTests: XCTestCase {
    @MainActor func testReadingWritesRollBackMemoryWhenPersistenceFails() throws {
        let store = try ReadingStore(namespace: "reading-write-test-\(UUID())")
        defer { try? store.delete() }
        let id = "book"
        let original = ReadingRecord(position: .init(page: 1), acknowledgedTicks: 0, dirty: true, updated: Date(), title: "Book", format: .pdf)
        try store.set(original, id: id)
        let bookmark = Bookmark(name: "Original", position: .init(page: 1))
        try store.add(bookmark, id: id)
        for name in ["positions.json", "bookmarks.json"] {
            let path = store.root.appendingPathComponent(name)
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        var changed = original; changed.position.page = 7
        XCTAssertThrowsError(try store.set(changed, id: id))
        XCTAssertEqual(store.records[id]?.position.page, 1)
        XCTAssertThrowsError(try store.add(Bookmark(name: "New", position: .init(page: 7)), id: id))
        XCTAssertEqual(store.bookmarks[id]?.map(\.id), [bookmark.id])
    }

    @MainActor func testUnreadableReadingFilesAreNotTreatedAsEmpty() throws {
        let namespace = "unreadable-reading-test-\(UUID())"
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyfinBooks/\(stableKey(namespace))")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["positions.json", "bookmarks.json"] {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertThrowsError(try ReadingStore(namespace: namespace))
            try FileManager.default.removeItem(at: file)
        }
    }
    func testStorageUsageCountsBookFilesAndSkipsStagingAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-usage-\(UUID())")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("storage-outside-\(UUID())")
        let outsideDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("storage-external-dir-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside); try? FileManager.default.removeItem(at: outsideDirectory) }
        let book = root.appendingPathComponent("book/nested"), staging = root.appendingPathComponent("staging-partial")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 17).write(to: book.appendingPathComponent("page"))
        try Data(repeating: 2, count: 11).write(to: root.appendingPathComponent("book/metadata"))
        try Data(repeating: 3, count: 100).write(to: staging.appendingPathComponent("partial"))
        try Data(repeating: 4, count: 200).write(to: outside)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 300).write(to: outsideDirectory.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("book/link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("book/directory-link"), withDestinationURL: outsideDirectory)
        XCTAssertEqual(try ManagedStorageUsage.bookBytes(in: root), 28)
    }

    func testClearCacheKeepsProtectedBookAndInProgressStaging() async throws {
        let cache = try BookCache(namespace: "clear-cache-test-\(UUID())")
        let root = await cache.root
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appendingPathComponent(stableKey("reading"))
        let staging = root.appendingPathComponent("staging-\(UUID())")
        let disposable = root.appendingPathComponent("disposable")
        for directory in [protected, staging, disposable] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        await cache.protect("reading")
        try await cache.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disposable.path))
        try await cache.delete()
        do { try await cache.clear(); XCTFail("A retired cache must reject clearing") } catch is CancellationError {}
    }
    @MainActor func testDurableCopySurvivesCacheEvictionAndRemovalKeepsReadingData() async throws {
        let namespace = "durable-test-\(UUID())"
        let saved = try DurableBookStore(namespace: namespace)
        let cache = try BookCache(namespace: namespace, budget: 0)
        let reading = try ReadingStore(namespace: namespace)
        let root = await saved.root, cacheRoot = await cache.root
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cacheRoot); try? reading.delete() }
        let book = Book(id: "fixture", title: "Fixture", author: "", summary: "", format: .pdf, isFolder: false, ticks: 0)
        try Data(contentsOf: durableFixturePDF).write(to: source)
        let directory = try await saved.install(source, book: book)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try reading.add(Bookmark(name: "Saved", position: .init(page: 2)), id: book.id)
        try await cache.evict()
        let reopened = try DurableBookStore(namespace: namespace)
        let restored = await reopened.saved(book)
        XCTAssertEqual(restored?.standardizedFileURL.path, directory.standardizedFileURL.path)
        try await reopened.remove(book)
        XCTAssertEqual(reading.bookmarks[book.id]?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDurableCopyRejectsInvalidAndIsolatesNamespaces() async throws {
        let saved = try DurableBookStore(namespace: "durable-test-\(UUID())")
        let other = try DurableBookStore(namespace: "durable-test-\(UUID())")
        let root = await saved.root, otherRoot = await other.root
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        let book = Book(id: "fixture", title: "Fixture", author: "", summary: "", format: .pdf, isFolder: false, ticks: 0)
        try Data("invalid".utf8).write(to: source)
        do { _ = try await saved.install(source, book: book); XCTFail("Invalid input must not become available") } catch {}
        let keys = try await saved.availableKeys()
        XCTAssertTrue(keys.isEmpty)
        try Data("%PDF-truncated".utf8).write(to: source)
        do { _ = try await saved.install(source, book: book); XCTFail("A PDF header alone is not a valid book") } catch {}
        let afterTruncated = try await saved.availableKeys()
        XCTAssertTrue(afterTruncated.isEmpty)
        try Data(contentsOf: durableFixturePDF).write(to: source)
        _ = try await saved.install(source, book: book)
        let otherCopy = await other.saved(book)
        XCTAssertNil(otherCopy)
        try await saved.delete()
        do { _ = try await saved.install(source, book: book); XCTFail("Retired store must reject installs") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRetiringAccountStoreKeepsSavedCopiesForLaterSignIn() async throws {
        let namespace = "durable-retire-\(UUID())"
        let saved = try DurableBookStore(namespace: namespace)
        let root = await saved.root
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
        let book = Book(id: "fixture", title: "Fixture", author: "", summary: "", format: .pdf, isFolder: false, ticks: 0)
        try Data(contentsOf: durableFixturePDF).write(to: source)
        _ = try await saved.install(source, book: book)
        await saved.retire()
        do { _ = try await saved.install(source, book: book); XCTFail("Retired store must reject installs") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let reopened = try DurableBookStore(namespace: namespace)
        let restored = await reopened.saved(book)
        XCTAssertNotNil(restored)
    }

    func testSavedCatalogAndCoverSurviveReopening() async throws {
        let namespace = "durable-catalog-\(UUID())"
        let saved = try DurableBookStore(namespace: namespace)
        let root = await saved.root
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
        let book = Book(id: "fixture", title: "Saved title", author: "Author", summary: "Description", format: .pdf, isFolder: false, imageTag: "art", ticks: 100)
        let cover = Data("cover-fixture".utf8)
        try Data(contentsOf: durableFixturePDF).write(to: source)
        _ = try await saved.install(source, book: book, cover: cover)
        let reopened = try DurableBookStore(namespace: namespace)
        let catalog = try await reopened.catalog()
        let restoredCover = await reopened.cover(book)
        XCTAssertEqual(catalog.map(\.title), ["Saved title"])
        XCTAssertEqual(catalog.first?.id, book.id)
        XCTAssertEqual(catalog.first?.author, book.author)
        XCTAssertEqual(restoredCover, cover)
        let storedDirectory = await reopened.saved(book)
        let directory = try XCTUnwrap(storedDirectory)
        try Data("%PDF-truncated".utf8).write(to: directory.appendingPathComponent("book.pdf"))
        let damagedCatalog = try await reopened.catalog()
        let damagedCopy = await reopened.saved(book)
        let available = try await reopened.availableKeys()
        XCTAssertEqual(damagedCatalog.map(\.id), [book.id], "A damaged copy stays visible for recovery")
        XCTAssertNil(damagedCopy)
        XCTAssertFalse(available.contains(stableKey(book.id)))
    }

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

private var durableFixturePDF: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Harbor.pdf")
}
