import XCTest
@testable import BookCore

final class ReaderBookmarkTests: XCTestCase {
    @MainActor func testEPUBDeduplicatesExactCFIButKeepsNearbyLocations() throws {
        let store = try ReadingStore(namespace: "bookmark-test-\(UUID())")
        defer { try? store.delete() }
        let first = Bookmark(name: "First", position: ReadingPosition(fraction: 0.4, cfi: "epubcfi(/6/2!/4/2:0)"))
        XCTAssertTrue(try store.addIfAbsent(first, id: "book", format: .epub))
        let sameLocation = Bookmark(name: "Different name", position: ReadingPosition(fraction: 0.41, cfi: first.position.cfi))
        XCTAssertFalse(try store.addIfAbsent(sameLocation, id: "book", format: .epub))
        let nearby = Bookmark(name: "Nearby", position: ReadingPosition(fraction: 0.4, cfi: "epubcfi(/6/2!/4/2:5)"))
        XCTAssertTrue(try store.addIfAbsent(nearby, id: "book", format: .epub))
        XCTAssertEqual(store.bookmarks["book"]?.count, 2)
    }

    @MainActor func testPageBookmarksIgnoreFractionAndRemainBookScoped() throws {
        let namespace = "bookmark-test-\(UUID())"
        let store = try ReadingStore(namespace: namespace)
        defer { try? store.delete() }
        let first = Bookmark(name: "Page 6", position: ReadingPosition(fraction: 0.1, page: 5))
        XCTAssertTrue(try store.addIfAbsent(first, id: "pdf", format: .pdf))
        XCTAssertFalse(try store.addIfAbsent(Bookmark(name: "Again", position: ReadingPosition(fraction: 0.2, page: 5)), id: "pdf", format: .pdf))
        XCTAssertTrue(try store.addIfAbsent(first, id: "cbz", format: .cbz))
        let restored = try ReadingStore(namespace: namespace)
        XCTAssertEqual(restored.bookmarks["pdf"]?.count, 1)
        XCTAssertEqual(restored.bookmarks["cbz"]?.count, 1)
    }
}
