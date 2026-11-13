import XCTest
@testable import BookCore

@MainActor final class PositionEditionTests: XCTestCase {
    private func fixture() throws -> (URL, ReadingStore, AppModel, PreparedBook) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let content = root.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let document = content.appendingPathComponent("chapter.xhtml")
        try Data("<html><body><p>A synthetic replacement edition.</p></body></html>".utf8).write(to: document)
        let reading = try ReadingStore(namespace: "source-account", baseDirectory: root.appendingPathComponent("state"))
        let model = AppModel(restoreLogin: false)
        model.store = reading
        let book = Book(id: "book", title: "Synthetic", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        model.readerLaunchBook = book
        return (root, reading, model, PreparedBook(book: book, directory: content, document: document, images: [], position: .init()))
    }
    private func earlier(fingerprint: String? = nil) -> ReadingRecord {
        ReadingRecord(position: .init(fraction: 0.45, cfi: "epubcfi(/6/2!/4/2/1:8)"), acknowledgedTicks: 4_500_000,
                      dirty: false, updated: Date(timeIntervalSince1970: 100), title: "Synthetic", format: .epub, contentFingerprint: fingerprint)
    }

    func testChangedEditionDoesNotConstructReaderOrOverwriteSavedPlaceBeforeChoice() async throws {
        let (root, reading, model, prepared) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = earlier(fingerprint: String(repeating: "a", count: 64))
        try reading.set(old, id: prepared.id)
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        let review = try XCTUnwrap(model.positionEditionReview)
        XCTAssertNil(model.reader)
        XCTAssertEqual(reading.records[prepared.id]?.position, old.position)
        XCTAssertEqual(reading.records[prepared.id]?.contentFingerprint, old.contentFingerprint)
        XCTAssertEqual(reading.records[prepared.id]?.syncBlock, .edition)
        model.savePosition(.init(), book: prepared.book)
        XCTAssertEqual(reading.records[prepared.id]?.position, old.position)
        model.resolvePositionEditionReview(review.id, choice: .saved)
        let fingerprint = try await BookFingerprint.prepared(prepared)
        XCTAssertEqual(model.reader?.position, old.position)
        XCTAssertEqual(reading.records[prepared.id]?.contentFingerprint, fingerprint)
        XCTAssertNil(reading.records[prepared.id]?.syncBlock)
        let backup = try XCTUnwrap(reading.bookmarks[prepared.id]?.first)
        XCTAssertEqual(backup.position, old.position)
        XCTAssertEqual(backup.contentFingerprint, old.contentFingerprint)
        let reopened = try ReadingStore(namespace: "source-account", baseDirectory: root.appendingPathComponent("state"))
        XCTAssertEqual(reopened.records[prepared.id]?.contentFingerprint, fingerprint)
        XCTAssertEqual(reopened.bookmarks[prepared.id]?.first?.id, backup.id)
    }

    func testLegacyPlaceIsPreservedWhenStartingReplacementAndSameEditionResumesWithoutReview() async throws {
        let (root, reading, model, prepared) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = earlier()
        try reading.set(old, id: prepared.id)
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        let review = try XCTUnwrap(model.positionEditionReview)
        model.resolvePositionEditionReview(review.id, choice: .beginning)
        XCTAssertEqual(reading.records[prepared.id]?.position, ReadingPosition())
        XCTAssertEqual(reading.bookmarks[prepared.id]?.first?.position, old.position)
        XCTAssertNil(reading.bookmarks[prepared.id]?.first?.contentFingerprint)
        let latest = ReadingPosition(fraction: 0.7, cfi: "epubcfi(/6/2!/4/2/1:20)")
        model.savePosition(latest, book: prepared.book)
        let accepted = try XCTUnwrap(reading.records[prepared.id]?.contentFingerprint)
        model.closeReader()
        model.readerLaunchBook = prepared.book
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        XCTAssertNil(model.positionEditionReview)
        XCTAssertEqual(model.reader?.position, latest)
        XCTAssertEqual(model.reader?.contentFingerprint, accepted)
        XCTAssertEqual(model.currentReaderPreparation(try XCTUnwrap(model.reader)).position, latest)
        XCTAssertEqual(reading.bookmarks[prepared.id]?.count, 1)
    }

    func testCancelKeepsEditionHoldAcrossRelaunchAndStaleChoiceCannotChangeAnotherSource() async throws {
        let (root, reading, model, prepared) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = earlier(fingerprint: String(repeating: "a", count: 64))
        try reading.set(old, id: prepared.id)
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        let review = try XCTUnwrap(model.positionEditionReview)
        model.cancelOpen()
        model.resolvePositionEditionReview(review.id, choice: .beginning)
        XCTAssertEqual(reading.records[prepared.id]?.position, old.position)
        XCTAssertTrue(reading.bookmarks.isEmpty)
        let reopened = try ReadingStore(namespace: "source-account", baseDirectory: root.appendingPathComponent("state"))
        XCTAssertEqual(reopened.records[prepared.id]?.syncBlock, .edition)
        model.readerLaunchBook = prepared.book
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        let secondReview = try XCTUnwrap(model.positionEditionReview)
        let other = try ReadingStore(namespace: "other-source", baseDirectory: root.appendingPathComponent("state"))
        model.store = other
        model.resolvePositionEditionReview(secondReview.id, choice: .saved)
        XCTAssertTrue(other.records.isEmpty)
        XCTAssertTrue(other.bookmarks.isEmpty)
        XCTAssertEqual(reading.records[prepared.id]?.position, old.position)
    }

    func testChangedSavedRecordOrFailedBackupCannotBeOverwrittenByReview() async throws {
        let (root, reading, model, prepared) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try reading.set(earlier(), id: prepared.id)
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        let review = try XCTUnwrap(model.positionEditionReview)
        var concurrent = try XCTUnwrap(reading.records[prepared.id]); concurrent.position.fraction = 0.8
        try reading.set(concurrent, id: prepared.id)
        model.resolvePositionEditionReview(review.id, choice: .beginning)
        XCTAssertEqual(reading.records[prepared.id]?.position, concurrent.position)
        XCTAssertNil(model.reader)
        XCTAssertTrue(reading.bookmarks.isEmpty)
        model.cancelOpen(); model.readerLaunchBook = prepared.book
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        let fresh = try XCTUnwrap(model.positionEditionReview)
        let file = reading.root.appendingPathComponent("bookmarks.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        model.resolvePositionEditionReview(fresh.id, choice: .beginning)
        XCTAssertEqual(reading.records[prepared.id]?.position, concurrent.position)
        XCTAssertNil(model.reader)
        XCTAssertTrue(reading.bookmarks.isEmpty)
        try FileManager.default.removeItem(at: file)
        model.resolvePositionEditionReview(fresh.id, choice: .beginning)
        XCTAssertEqual(reading.records[prepared.id]?.position, ReadingPosition())
        XCTAssertEqual(reading.bookmarks[prepared.id]?.count, 1)
    }

    func testFirstServerPositionIsBoundOnlyAfterActualContentHash() async throws {
        let (root, reading, model, candidate) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var prepared = candidate; prepared.position = .init(fraction: 0.3)
        let seed = ReadingRecord(position: prepared.position, acknowledgedTicks: 3_000_000, dirty: false, updated: Date(), title: "Synthetic", format: .epub)
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID, serverSeed: seed)
        XCTAssertNil(model.positionEditionReview)
        XCTAssertEqual(reading.records[prepared.id]?.position, seed.position)
        let fingerprint = try await BookFingerprint.prepared(prepared)
        XCTAssertEqual(reading.records[prepared.id]?.contentFingerprint, fingerprint)
    }

    func testCorruptKnownEditionPlaceCanOnlyStartSafelyAndPreservesOriginal() async throws {
        let (root, reading, model, prepared) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = try await BookFingerprint.prepared(prepared)
        var old = earlier(fingerprint: fingerprint); old.position.page = Int.max
        try reading.set(old, id: prepared.id)
        try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
        let review = try XCTUnwrap(model.positionEditionReview)
        XCTAssertFalse(review.canTrySaved)
        model.resolvePositionEditionReview(review.id, choice: .saved)
        XCTAssertNil(model.reader)
        model.resolvePositionEditionReview(review.id, choice: .beginning)
        XCTAssertEqual(model.reader?.position, ReadingPosition())
        XCTAssertEqual(reading.bookmarks[prepared.id]?.first?.position.page, Int.max)
    }

    func testLegacyRecordDecodesWithoutLosingItsPlace() throws {
        let old = earlier()
        let encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "contentFingerprint")
        let decoded = try JSONDecoder().decode(ReadingRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.position, old.position)
        XCTAssertNil(decoded.contentFingerprint)
        XCTAssertEqual(decoded.acknowledgedTicks, old.acknowledgedTicks)
    }

    func testPositionFingerprintSurvivesRecoveryAndFingerprintOnlyEditQueuesChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let cloud = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let originalFileDigest = String(repeating: "a", count: 64)
        let nativeContentDigest = String(repeating: "b", count: 64)
        try cloud.setVerifiedEdition(localBookID: "book", fingerprint: originalFileDigest)
        var record = ReadingRecord(position: .init(page: 2), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Synthetic", format: .pdf, contentFingerprint: nativeContentDigest)
        try cloud.replace(records: ["book": record], bookmarks: [:], annotations: [:])
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let first = try XCTUnwrap(cloud.outbox[key.recordName]?.entry.current.revision)
        record.contentFingerprint = String(repeating: "c", count: 64)
        try cloud.replace(records: ["book": record], bookmarks: [:], annotations: [:])
        let version = try XCTUnwrap(cloud.outbox[key.recordName]?.entry.current)
        XCTAssertNotEqual(version.revision, first)
        XCTAssertEqual(version.editionFingerprint, originalFileDigest, "Original-asset and renderer fingerprints have separate purposes")
        if case .position(let position) = version.payload { XCTAssertEqual(position.contentFingerprint, record.contentFingerprint) }
        else { XCTFail("Expected precise position payload") }
        let receiver = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root.appendingPathComponent("receiver"))
        try receiver.setVerifiedEdition(localBookID: "book", fingerprint: originalFileDigest)
        try receiver.observe(key, bookID: "book", remote: version)
        let book = Book(id: "book", title: "Synthetic", author: "", summary: "", format: .pdf, isFolder: false, ticks: 0)
        try receiver.applyObserved(key, book: book, verifiedEditionFingerprint: originalFileDigest, expectedRevision: version.revision)
        XCTAssertEqual(receiver.records[book.id]?.contentFingerprint, record.contentFingerprint)
        XCTAssertEqual(receiver.records[book.id]?.position, record.position)
    }

    func testPDFAndComicOutOfRangePlacesRequireReviewEvenForMatchingEdition() async throws {
        for format in [BookFormat.pdf, .cbz] {
            let (root, reading, model, candidate) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var prepared = candidate; prepared.book.format = format
            if format == .pdf {
                let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Harbor.pdf")
                prepared.document = prepared.directory.appendingPathComponent("book.pdf")
                try FileManager.default.copyItem(at: original, to: prepared.document)
            } else {
                let image = prepared.directory.appendingPathComponent("page.png")
                try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jx1sAAAAASUVORK5CYII=")).write(to: image)
                prepared.images = [image]
            }
            model.readerLaunchBook = prepared.book
            let fingerprint = try await BookFingerprint.prepared(prepared)
            let old = ReadingRecord(position: .init(page: 9999), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Synthetic", format: format, contentFingerprint: fingerprint)
            try reading.set(old, id: prepared.id)
            try await model.finishPreparingReader(prepared, sessionID: model.sessionID)
            let review = try XCTUnwrap(model.positionEditionReview)
            XCTAssertFalse(review.canTrySaved)
            XCTAssertNil(model.reader)
            model.resolvePositionEditionReview(review.id, choice: .beginning)
            XCTAssertEqual(model.reader?.position.page, 0)
            XCTAssertEqual(reading.bookmarks[prepared.id]?.first?.position.page, 9999)
        }
    }
}
