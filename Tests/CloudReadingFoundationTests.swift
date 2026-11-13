import XCTest
import CloudKit
@testable import BookCore

final class CloudReadingFoundationTests: XCTestCase {
    @MainActor func testReadingStoreMigrationWiresMutationsAndRejectsMissingSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let store = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        let stale = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        let record = ReadingRecord(position: ReadingPosition(page: 3), acknowledgedTicks: 7, dirty: true, updated: Date(), title: "Test", format: .pdf)
        let mark = Bookmark(name: "Legacy", position: ReadingPosition(page: 2))
        try store.set(record, id: "book"); try store.add(mark, id: "book")
        try store.prepareAtomicReading(scope: scope)
        XCTAssertThrowsError(try stale.add(Bookmark(name: "Stale", position: ReadingPosition(page: 4)), id: "book"))
        XCTAssertThrowsError(try stale.delete())
        try store.renameBookmark(mark, id: "book", name: "Renamed")
        try store.saveAnnotation(ReadingAnnotation(anchor: .page(1), selectedText: nil, context: nil, note: "Note", color: nil), id: "book")
        let reopened = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        XCTAssertEqual(reopened.records["book"]?.position.page, 3)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Renamed")
        XCTAssertEqual(reopened.annotations["book"]?.first?.note, "Note")
        XCTAssertTrue(reopened.hasUnsyncedCloudChanges)
        XCTAssertThrowsError(try reopened.delete())
        let atomic = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(atomic.outbox.count, 3)
        try FileManager.default.removeItem(at: atomic.file)
        XCTAssertThrowsError(try ReadingStore(namespace: "synthetic", baseDirectory: root))
    }

    @MainActor func testInterruptedMigrationDoesNotReplaceNewLegacyData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let store = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        _ = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        try store.add(Bookmark(name: "New", position: ReadingPosition(page: 2)), id: "book")
        XCTAssertThrowsError(try store.prepareAtomicReading(scope: scope))
        XCTAssertEqual(try ReadingStore(namespace: "synthetic", baseDirectory: root).bookmarks["book"]?.first?.name, "New")
    }

    @MainActor func testAtomicMigrationAndMutationSurviveRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let record = ReadingRecord(position: ReadingPosition(page: 3), acknowledgedTicks: 7, dirty: true, updated: Date(), title: "Test", format: .pdf)
        let mark = Bookmark(name: "Old", position: ReadingPosition(page: 2))
        let annotation = ReadingAnnotation(anchor: .page(3), selectedText: nil, context: nil, note: "Note", color: nil)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: ["book": record], legacyBookmarks: ["book": [mark]], legacyAnnotations: ["book": [annotation]], baseDirectory: root)
        XCTAssertEqual(store.outbox.count, 3)
        try store.remove(mark, bookID: "book")
        let markKey = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: mark.id)
        XCTAssertNil(store.outbox[markKey.recordName]?.entry.current.payload)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        XCTAssertEqual(reopened.records["book"]?.position.page, 3)
        XCTAssertEqual(reopened.annotations["book"]?.first?.note, "Note")
        XCTAssertEqual(reopened.bookmarks["book"]?.count, 0)
        XCTAssertEqual(reopened.outbox[markKey.recordName]?.bookID, "book")
        XCTAssertTrue(reopened.outbox[markKey.recordName]?.entry.pending == true)
        let other = try CloudReadingScope(cloudUserRecordName: "other", source: .imported)
        XCTAssertTrue(try CloudAtomicReadingStore(scope: other, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root).records.isEmpty)
    }

    @MainActor func testFailedAtomicMutationDoesNotChangeDurableOrInMemoryState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let bookmark = Bookmark(name: "Original", position: ReadingPosition(page: 1))
        try store.set(bookmark, bookID: "book")
        var invalid = bookmark; invalid.position.fraction = .nan
        XCTAssertThrowsError(try store.set(invalid, bookID: "book"))
        XCTAssertEqual(store.bookmarks["book"]?.first?.name, "Original")
        XCTAssertEqual(store.bookmarks["book"]?.first?.position.fraction, 0)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.position.fraction, 0)
        XCTAssertEqual(reopened.outbox.count, 1)
    }

    @MainActor func testStaleStoreCannotOverwriteNewerState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let first = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let stale = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        try first.set(Bookmark(name: "Saved", position: ReadingPosition(page: 1)), bookID: "book")
        XCTAssertThrowsError(try stale.set(Bookmark(name: "Stale", position: ReadingPosition(page: 2)), bookID: "book"))
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Saved")
    }

    @MainActor final class FakeTransport: CloudReadingTransport {
        var value: CloudReadingVersion?
        var afterUpload: (() throws -> Void)?
        var uploadCount = 0
        func fetch(_ key: CloudReadingKey) async throws -> CloudReadingVersion? { value }
        func upload(_ entry: CloudReadingEntry, expected: UUID?) async throws -> CloudReadingUploadResult {
            uploadCount += 1
            if let value, value.revision != expected { return .conflict(value) }
            value = entry.current
            try afterUpload?()
            return .saved
        }
    }

    @MainActor func testSyntheticSyncKeepsNewEditsAndFencesAccountChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic-account", source: .imported)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let journal = try CloudReadingJournal(scope: scope, baseDirectory: root)
        try journal.edit(key, payload: nil)
        let transport = FakeTransport()
        transport.afterUpload = { try journal.edit(key, payload: nil) }
        let coordinator = CloudReadingSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: { true })
        await coordinator.sync(key)
        XCTAssertEqual(journal.entries[key.recordName]?.pending, true)
        XCTAssertEqual(journal.entries[key.recordName]?.baseRevision, transport.value?.revision)
        transport.afterUpload = nil
        var valid = true
        let switched = CloudReadingSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: { valid })
        transport.afterUpload = { valid = false }
        await switched.sync(key)
        XCTAssertEqual(switched.status, .accountChanged)
        XCTAssertEqual(journal.entries[key.recordName]?.pending, true)
        XCTAssertEqual(try CloudReadingJournal(scope: scope, baseDirectory: root).entries[key.recordName]?.pending, true)
    }

    @MainActor func testSyntheticRemoteConflictPreservesBothVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic-account", source: .imported)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let journal = try CloudReadingJournal(scope: scope, baseDirectory: root)
        try journal.edit(key, payload: nil)
        let local = try XCTUnwrap(journal.entries[key.recordName]?.current.revision)
        let transport = FakeTransport()
        transport.value = CloudReadingVersion(revision: UUID(), payload: nil)
        let coordinator = CloudReadingSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: { true })
        await coordinator.sync(key)
        XCTAssertEqual(coordinator.status, .conflict)
        XCTAssertEqual(transport.uploadCount, 0)
        XCTAssertEqual(journal.entries[key.recordName]?.current.revision, local)
        XCTAssertEqual(journal.entries[key.recordName]?.conflicts.first?.revision, transport.value?.revision)
    }

    @MainActor func testPendingChangesAndTombstoneSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic-account", source: .imported)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let journal = try CloudReadingJournal(scope: scope, baseDirectory: root)
        func payload(_ page: Int) -> CloudReadingPayload { .position(CloudPrecisePosition(position: ReadingPosition(page: page), contentFingerprint: nil, acknowledgedServerTicks: nil)) }
        try journal.edit(key, payload: payload(1))
        let first = try XCTUnwrap(journal.entries[key.recordName]?.current.revision)
        try journal.edit(key, payload: payload(2))
        let second = try XCTUnwrap(journal.entries[key.recordName]?.current.revision)
        try journal.acknowledge(key, revision: first)
        let reopened = try CloudReadingJournal(scope: scope, baseDirectory: root)
        XCTAssertEqual(reopened.entries[key.recordName]?.baseRevision, first)
        XCTAssertEqual(reopened.entries[key.recordName]?.current.revision, second)
        XCTAssertEqual(reopened.entries[key.recordName]?.pending, true)
        try reopened.edit(key, payload: nil)
        let tombstone = try CloudReadingJournal(scope: scope, baseDirectory: root).entries[key.recordName]
        XCTAssertNil(tombstone?.current.payload)
        XCTAssertEqual(tombstone?.pending, true)
    }

    @MainActor func testConflictsAndScopesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic-a", source: .imported)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let journal = try CloudReadingJournal(scope: scope, baseDirectory: root)
        try journal.edit(key, payload: nil)
        let first = CloudReadingVersion(revision: UUID(), payload: nil)
        let second = CloudReadingVersion(revision: UUID(), payload: nil)
        try journal.observe(key, remote: first)
        try journal.observe(key, remote: second)
        try journal.resolve(key, against: first.revision, payload: nil)
        let reopened = try CloudReadingJournal(scope: scope, baseDirectory: root)
        XCTAssertEqual(reopened.entries[key.recordName]?.conflicts.map(\.revision), [second.revision])
        XCTAssertThrowsError(try reopened.edit(key, payload: nil))
        let other = try CloudReadingScope(cloudUserRecordName: "synthetic-b", source: .imported)
        XCTAssertTrue(try CloudReadingJournal(scope: other, baseDirectory: root).entries.isEmpty)
        let otherSource = try CloudReadingScope(cloudUserRecordName: "synthetic-a", source: .jellyfin(serverID: "server", userID: "user"))
        XCTAssertTrue(try CloudReadingJournal(scope: otherSource, baseDirectory: root).entries.isEmpty)
        XCTAssertThrowsError(try CloudReadingJournal(scope: otherSource, baseDirectory: root).edit(key, payload: nil))
    }

    @MainActor func testSyntheticCloudRecordRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let bookmark = Bookmark(name: "Example", position: ReadingPosition(page: 4))
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: bookmark.id)
        let journal = try CloudReadingJournal(scope: scope, baseDirectory: root)
        try journal.edit(key, payload: .bookmark(bookmark))
        let entry = try XCTUnwrap(journal.entries[key.recordName])
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let record = try CloudReadingRecordCodec.record(entry: entry, bookID: "book", zoneID: zone)
        XCTAssertThrowsError(try CloudReadingRecordCodec.record(entry: entry, bookID: "different", zoneID: zone))
        XCTAssertNotNil(record.encryptedValues["readingData"])
        let (decodedKey, decodedBookID, decoded) = try CloudReadingRecordCodec.decode(record, expectedSource: scope.sourceKey)
        XCTAssertEqual(decodedKey, key)
        XCTAssertEqual(decodedBookID, "book")
        XCTAssertEqual(decoded.revision, entry.current.revision)
        XCTAssertThrowsError(try CloudReadingRecordCodec.decode(record, expectedSource: "other"))
    }
}
