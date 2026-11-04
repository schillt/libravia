import XCTest
@testable import BookCore

final class ReaderBookmarkTests: XCTestCase {
    @MainActor func testOriginalFormattingIsPerBookAndNamespaceAndPersists() throws {
        let first = "formatting-\(UUID())", second = "formatting-\(UUID())"
        let store = try ReadingStore(namespace: first), other = try ReadingStore(namespace: second)
        defer { try? store.delete(); try? other.delete() }
        XCTAssertFalse(store.usesOriginalFormatting(bookID: "book"))
        try store.setOriginalFormatting(true, bookID: "book")
        XCTAssertFalse(store.usesOriginalFormatting(bookID: "another"))
        XCTAssertFalse(other.usesOriginalFormatting(bookID: "book"))
        let restored = try ReadingStore(namespace: first)
        XCTAssertTrue(restored.usesOriginalFormatting(bookID: "book"))
        try restored.setOriginalFormatting(false, bookID: "book")
        XCTAssertFalse(try ReadingStore(namespace: first).usesOriginalFormatting(bookID: "book"))
    }

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

    @MainActor func testRenamePersistsWithoutChangingIdentityOrPosition() throws {
        let namespace = "bookmark-test-\(UUID())"
        let store = try ReadingStore(namespace: namespace)
        defer { try? store.delete() }
        let bookmark = Bookmark(name: "Page 6", position: ReadingPosition(page: 5))
        try store.add(bookmark, id: "book")
        XCTAssertThrowsError(try store.renameBookmark(bookmark, id: "other", name: "Missing"))
        XCTAssertThrowsError(try store.renameBookmark(bookmark, id: "book", name: "  \n"))
        try store.renameBookmark(bookmark, id: "book", name: "  Favorite passage  ")
        let restored = try ReadingStore(namespace: namespace).bookmarks["book"]?.first
        XCTAssertEqual(restored?.id, bookmark.id)
        XCTAssertEqual(restored?.position, bookmark.position)
        XCTAssertEqual(restored?.name, "Favorite passage")
    }

    @MainActor func testAnnotationsAreAccountAndBookScopedAndSurviveReload() throws {
        let namespace = "annotation-test-\(UUID())"
        let otherNamespace = "annotation-test-\(UUID())"
        let store = try ReadingStore(namespace: namespace)
        let other = try ReadingStore(namespace: otherNamespace)
        defer { try? store.delete(); try? other.delete() }
        let anchor = AnnotationAnchor.epub(cfi: "epubcfi(/6/2!/4/2:0,/1:0,/1:9)")
        var annotation = ReadingAnnotation(anchor: anchor, selectedText: "A passage", context: "A passage in a book", note: "First note", color: "yellow")
        try store.saveAnnotation(annotation, id: "book")
        annotation.note = "Revised note"
        try store.saveAnnotation(annotation, id: "book")
        let page = ReadingAnnotation(anchor: .page(3), selectedText: nil, context: nil, note: "Page note", color: nil)
        try store.saveAnnotation(page, id: "other-book")
        let highlight = ReadingAnnotation(anchor: .pdf(page: 1, selections: [.init(x: 12, y: 34, width: 56, height: 8)]), selectedText: "Selected passage", context: nil, note: "My thought", color: "yellow", contentFingerprint: "edition")
        try store.saveAnnotation(highlight, id: "pdf-book")
        let restored = try ReadingStore(namespace: namespace)
        XCTAssertEqual(restored.annotations["book"], [annotation])
        XCTAssertEqual(restored.annotations["other-book"], [page])
        XCTAssertEqual(restored.annotations["pdf-book"], [highlight])
        XCTAssertTrue(other.annotations.isEmpty)
        try restored.removeAnnotation(annotation, id: "book")
        let reopened = try ReadingStore(namespace: namespace)
        XCTAssertTrue(reopened.annotations["book"]?.isEmpty == true)
        XCTAssertEqual(reopened.annotations["other-book"], [page])
    }

    @MainActor func testAnnotationsPreventAutomaticRematching() throws {
        let store = try ReadingStore(namespace: "annotation-test-\(UUID())")
        defer { try? store.delete() }
        let position = ReadingPosition(page: 3)
        let record = ReadingRecord(position: position, acknowledgedTicks: 0, dirty: true, updated: Date(), title: "Original", format: .pdf)
        try store.set(record, id: "old")
        let note = ReadingAnnotation(anchor: .page(3), selectedText: nil, context: nil, note: "Keep me", color: nil)
        try store.saveAnnotation(note, id: "old")
        let replacement = Book(id: "new", title: "Replacement", author: "", summary: "", format: .pdf, isFolder: false, ticks: 0)
        XCTAssertThrowsError(try store.movePosition(from: "old", to: replacement, record: record))
        XCTAssertNotNil(store.records["old"])
        XCTAssertNil(store.records["new"])
        XCTAssertEqual(store.annotations["old"], [note])
    }

    @MainActor func testAnnotationWriteFailureDoesNotPublishUnsavedData() throws {
        let store = try ReadingStore(namespace: "annotation-test-\(UUID())")
        defer { try? store.delete() }
        let target = store.root.appendingPathComponent("annotations.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let note = ReadingAnnotation(anchor: .page(2), selectedText: nil, context: nil, note: "Not yet saved", color: nil)
        XCTAssertThrowsError(try store.saveAnnotation(note, id: "book"))
        XCTAssertNil(store.annotations["book"])
    }

    @MainActor func testCorruptAnnotationsAreNotSilentlyOverwritten() throws {
        let namespace = "annotation-test-\(UUID())"
        let store = try ReadingStore(namespace: namespace)
        defer { try? store.delete() }
        let file = store.root.appendingPathComponent("annotations.json")
        let data = Data("not valid json".utf8)
        try data.write(to: file)
        XCTAssertThrowsError(try ReadingStore(namespace: namespace))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testPageNoteOnlyJumpsForMatchingContentAndValidPage() {
        let note = ReadingAnnotation(anchor: .page(3), selectedText: nil, context: nil, note: "A note", color: nil, contentFingerprint: "original")
        XCTAssertEqual(note.availablePage(fingerprint: "original", pageCount: 4), 3)
        XCTAssertNil(note.availablePage(fingerprint: nil, pageCount: 4))
        XCTAssertNil(note.availablePage(fingerprint: "replacement", pageCount: 4))
        XCTAssertNil(note.availablePage(fingerprint: "original", pageCount: 3))
        let legacy = ReadingAnnotation(anchor: .page(3), selectedText: nil, context: nil, note: "Unverified", color: nil)
        XCTAssertNil(legacy.availablePage(fingerprint: "original", pageCount: 4))
    }

    func testAnnotationExportPreservesTextAndLocation() throws {
        let note = ReadingAnnotation(anchor: .page(2), selectedText: "Selected passage", context: nil, note: "First line\nSecond line", color: nil, contentFingerprint: "fixture")
        let bookmark = Bookmark(name: "Place", position: .init(page: 4))
        let data = try AnnotationExport.json(title: "Book", format: .pdf, annotations: [note], bookmarks: [bookmark])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Book")
        XCTAssertEqual((object["annotations"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["bookmarks"] as? [[String: Any]])?.count, 1)
        let markdown = String(decoding: AnnotationExport.markdown(title: "Book", format: .pdf, annotations: [note], bookmarks: [bookmark]), as: UTF8.self)
        XCTAssertTrue(markdown.contains("> Page 3"))
        XCTAssertTrue(markdown.contains("> Selected passage"))
        XCTAssertTrue(markdown.contains("> First line\n> Second line"))
        XCTAssertTrue(markdown.contains("> Place"))
        XCTAssertTrue(markdown.contains("> Page 5"))
    }

    func testEPUBExportRetainsNotesBookmarksAndInvalidAnchors() throws {
        struct Envelope: Decodable { let annotations: [ReadingAnnotation]; let bookmarks: [Bookmark] }
        let selected = "A passage\nwith a second line"
        let cfi = "epubcfi(/6/2!/4/2,/1:0,/1:4)"
        let note = ReadingAnnotation(anchor: .epub(cfi: cfi), selectedText: selected, context: "Context", note: "My note", color: "yellow", contentFingerprint: "edition")
        let unresolved = ReadingAnnotation(anchor: .epub(cfi: "invalid"), selectedText: "Recovery", context: nil, note: "Keep this", color: nil)
        let bookmark = Bookmark(name: "My place", position: .init(fraction: 0.6, cfi: cfi))
        let data = try AnnotationExport.json(title: "Book", format: .epub, annotations: [note, unresolved], bookmarks: [bookmark])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Envelope.self, from: data)
        XCTAssertEqual(archive.annotations.map(\.id), [note.id, unresolved.id])
        XCTAssertEqual(archive.annotations.map(\.anchor), [note.anchor, unresolved.anchor])
        XCTAssertEqual(archive.annotations.map(\.note), ["My note", "Keep this"])
        XCTAssertEqual(archive.annotations[0].selectedText, selected)
        XCTAssertEqual(archive.annotations[0].contentFingerprint, "edition")
        XCTAssertEqual(archive.bookmarks.first?.id, bookmark.id)
        XCTAssertEqual(archive.bookmarks.first?.position, bookmark.position)
        let markdown = String(decoding: AnnotationExport.markdown(title: "Book", format: .epub, annotations: [note, unresolved], bookmarks: [bookmark]), as: UTF8.self)
        for text in [cfi, "My note", "Keep this", "invalid", "My place", "Context"] { XCTAssertTrue(markdown.contains(text)) }
        XCTAssertTrue(markdown.contains("> A passage\n> with a second line"))
    }

    func testMarkdownExportKeepsInvalidPageDataWithoutOverflow() {
        let note = ReadingAnnotation(anchor: .page(Int.max), selectedText: nil, context: nil, note: "Keep this", color: nil)
        let bookmark = Bookmark(name: "Keep bookmark", position: .init(page: Int.max))
        let markdown = String(decoding: AnnotationExport.markdown(title: "Book", format: .pdf, annotations: [note], bookmarks: [bookmark]), as: UTF8.self)
        XCTAssertEqual(markdown.components(separatedBy: "Invalid page index: \(Int.max)").count, 3)
        XCTAssertTrue(markdown.contains("Keep this"))
        XCTAssertTrue(markdown.contains("Keep bookmark"))
    }

    func testPDFHighlightRequiresMatchingFingerprintValidPageAndRectangles() {
        let rect = PDFAnnotationRect(x: 20, y: 30, width: 140, height: 12)
        var highlight = ReadingAnnotation(anchor: .pdf(page: 2, selections: [rect]), selectedText: "A passage", context: nil, note: "A thought", color: "yellow", contentFingerprint: "edition")
        XCTAssertEqual(highlight.availablePage(fingerprint: "edition", pageCount: 3), 2)
        XCTAssertNil(highlight.availablePage(fingerprint: "other", pageCount: 3))
        XCTAssertNil(highlight.availablePage(fingerprint: nil, pageCount: 3))
        XCTAssertNil(highlight.availablePage(fingerprint: "edition", pageCount: 2))
        highlight.anchor = .pdf(page: 2, selections: [])
        XCTAssertNil(highlight.availablePage(fingerprint: "edition", pageCount: 3))
        highlight.anchor = .pdf(page: 2, selections: [.init(x: 0, y: 0, width: .nan, height: 12)])
        XCTAssertNil(highlight.availablePage(fingerprint: "edition", pageCount: 3))
    }

    func testBookFingerprintDetectsChangedContentAndComicOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
        let original = try await BookFingerprint.compute(files: [first, second])
        let same = try await BookFingerprint.compute(files: [first, second])
        let reversed = try await BookFingerprint.compute(files: [second, first])
        XCTAssertEqual(original, same)
        XCTAssertNotEqual(original, reversed)
        try Data("different".utf8).write(to: second)
        let changed = try await BookFingerprint.compute(files: [first, second])
        XCTAssertNotEqual(original, changed)
        do { _ = try await BookFingerprint.compute(files: [root.appendingPathComponent("missing")]); XCTFail("Missing content must not verify") } catch { }
    }

    func testEPUBFingerprintIncludesPathsAndContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chapter = root.appendingPathComponent("chapter.xhtml")
        try Data("original".utf8).write(to: chapter)
        try Data().write(to: root.appendingPathComponent("complete"))
        let original = try await BookFingerprint.epub(directory: root)
        try Data("metadata".utf8).write(to: root.appendingPathComponent(".libravia-metadata.json"))
        try Data("cover".utf8).write(to: root.appendingPathComponent(".libravia-cover"))
        let savedCopy = try await BookFingerprint.epub(directory: root, hasDurableSidecars: true)
        XCTAssertEqual(original, savedCopy, "App-owned offline metadata must not change the book identity")
        let cachedWithNames = try await BookFingerprint.epub(directory: root)
        XCTAssertNotEqual(original, cachedWithNames, "Same-named files in a cache remain publication content")
        try Data("changed publication content".utf8).write(to: root.appendingPathComponent(".libravia-cover"))
        let changedCachedFile = try await BookFingerprint.epub(directory: root)
        XCTAssertNotEqual(cachedWithNames, changedCachedFile)
        try FileManager.default.moveItem(at: chapter, to: root.appendingPathComponent("renamed.xhtml"))
        let renamed = try await BookFingerprint.epub(directory: root, hasDurableSidecars: true)
        XCTAssertNotEqual(original, renamed)
        let note = ReadingAnnotation(anchor: .epub(cfi: "epubcfi(/6/2!/4/2,/1:0,/1:4)"), selectedText: "text", context: nil, note: "", color: "yellow", contentFingerprint: original)
        XCTAssertNotNil(note.availableEPUB(fingerprint: original))
        XCTAssertNil(note.availableEPUB(fingerprint: renamed))
        XCTAssertNil(note.availableEPUB(fingerprint: nil))
    }
}

final class ReaderDictionaryTests: XCTestCase {
    func testOnlySingleWordsOfferDictionary() {
        XCTAssertEqual(ReaderDictionary.term("  reader! "), "reader")
        XCTAssertNil(ReaderDictionary.term("two words"))
        XCTAssertNil(ReaderDictionary.term("..."))
        XCTAssertNil(ReaderDictionary.term(String(repeating: "a", count: 257)))
    }
}

final class ReadingAnnotationStyleTests: XCTestCase {
    func testStylesRoundTripAndLegacyAnnotationsRemainReadable() throws {
        var annotation = ReadingAnnotation(anchor: .epub(cfi: "epubcfi(/6/2!/4/2,/1:0,/1:4)"), selectedText: "word", context: nil, note: "A note", color: "green", contentFingerprint: "edition")
        annotation.style = "underline"
        let data = try JSONEncoder().encode(annotation)
        XCTAssertEqual(try JSONDecoder().decode(ReadingAnnotation.self, from: data), annotation)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "style")
        let restored = try JSONDecoder().decode(ReadingAnnotation.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.style)
        XCTAssertEqual(restored.id, annotation.id)
        XCTAssertEqual(restored.anchor, annotation.anchor)
        XCTAssertEqual(restored.note, annotation.note)
        XCTAssertEqual(restored.color, annotation.color)
    }
}
