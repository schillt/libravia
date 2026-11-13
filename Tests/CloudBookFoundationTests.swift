import XCTest
import CloudKit
import CryptoKit
import Darwin
import AppKit
import PDFKit
@testable import BookCore

final class CloudBookFoundationTests: XCTestCase {
    @MainActor final class RecoveryPages: CloudRecoveryPageSource {
        var pages: [CloudRecoveryPage]
        var requested: [Data?] = []
        var duringPage: (() -> Void)?
        init(_ pages: [CloudRecoveryPage]) { self.pages = pages }
        func page(after token: Data?) async throws -> CloudRecoveryPage {
            requested.append(token)
            duringPage?()
            guard requested.count <= pages.count else { throw ReaderError.message("Unexpected page") }
            return pages[requested.count - 1]
        }
    }

    @MainActor final class SyntheticRecoveryCloud: CloudReadingRecordDatabase, CloudRecoveryPageSource {
        var records: [CKRecord.ID: CKRecord] = [:]
        var online = true
        var disconnectAfterBookSave = false
        func fetch(_ id: CKRecord.ID) async throws -> CKRecord? {
            guard online else { throw ReaderError.message("Offline") }
            return records[id]?.copy() as? CKRecord
        }
        func saveIfUnchanged(_ record: CKRecord) async throws -> CloudReadingRecordSaveResult {
            guard online else { throw ReaderError.message("Offline") }
            records[record.recordID] = record.copy() as? CKRecord
            if disconnectAfterBookSave && record.recordType == CloudBookRecordCodec.recordType {
                disconnectAfterBookSave = false
                online = false
                throw ReaderError.message("Connection lost after save")
            }
            return .saved
        }
        func page(after token: Data?) async throws -> CloudRecoveryPage {
            guard online else { throw ReaderError.message("Offline") }
            guard token == nil else { throw ReaderError.message("Unexpected page") }
            return CloudRecoveryPage(records: records.values.compactMap { $0.copy() as? CKRecord },
                                     deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)
        }
    }

    @MainActor func testDiscoveryStagesBooksAndReadingBeforeAdvancingAndReplays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let sender = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let staged = try await sender.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let receiverStager = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("receiver"))
        let books = try CloudBookJournal(scope: scope, stager: receiverStager, baseDirectory: root.appendingPathComponent("receiver"))
        let reading = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root.appendingPathComponent("receiver"))
        let journal = try CloudReadingJournal(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let bookmark = Bookmark(name: "Saved", position: ReadingPosition(page: 2))
        let key = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .bookmark, itemID: bookmark.id)
        try journal.edit(key, payload: .bookmark(bookmark))
        var entry = try XCTUnwrap(journal.entries[key.recordName]); entry.current.editionFingerprint = staged.metadata.sha256
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let bookRecord = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone)
        let readingRecord = try CloudReadingRecordCodec.record(entry: entry, bookID: id.readingBookID, zoneID: zone)
        let pages = [CloudRecoveryPage(records: [bookRecord], deletedRecordCount: 0, nextToken: Data([1]), moreComing: true),
                     CloudRecoveryPage(records: [readingRecord], deletedRecordCount: 0, nextToken: Data([2]), moreComing: false)]
        let receiver = try CloudRecoveryRecordReceiver(scope: scope, zoneID: zone, reading: reading, books: books, accountIsCurrent: { true })
        for _ in 0..<2 {
            let source = RecoveryPages(pages)
            let scan = CloudRecoveryDiscovery(source: source, zoneID: zone, accountIsCurrent: { true }, receive: { try await receiver.receive($0) })
            try await scan.scan()
            XCTAssertEqual(source.requested, [nil, Data([1])])
        }
        XCTAssertEqual(books.entry(for: id)?.current.revision, staged.metadata.revision)
        XCTAssertTrue(books.entry(for: id)?.pendingApplication == true)
        XCTAssertTrue(reading.outbox[key.recordName]?.pendingApplication == true)
        let copy = try await receiverStager.reopen(bookID: id, revision: staged.metadata.revision)
        XCTAssertEqual(try Data(contentsOf: copy.assetURL), try Data(contentsOf: fixture))
        do { try await receiverStager.discard(bookID: id, revision: staged.metadata.revision); XCTFail("Recovery asset must remain pinned") } catch {}
    }

    @MainActor func testDiscoveryStopsOnDeletionOrAccountChangeWithoutAdvancing() async throws {
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "Synthetic", recordID: CKRecord.ID(recordName: "item", zoneID: zone))
        let pages = RecoveryPages([CloudRecoveryPage(records: [record], deletedRecordCount: 1, nextToken: Data([1]), moreComing: true)])
        var received = 0
        let scan = CloudRecoveryDiscovery(source: pages, zoneID: zone, accountIsCurrent: { true }, receive: { _ in received += 1 })
        do { try await scan.scan(); XCTFail("Physical deletions require review") } catch {}
        XCTAssertEqual(received, 0); XCTAssertEqual(pages.requested.count, 1)
        var current = true
        let next = RecoveryPages([CloudRecoveryPage(records: [record], deletedRecordCount: 0, nextToken: Data([1]), moreComing: true)])
        let interrupted = CloudRecoveryDiscovery(source: next, zoneID: zone, accountIsCurrent: { current }, receive: { _ in received += 1; current = false })
        do { try await interrupted.scan(); XCTFail("Changed account must stop recovery") } catch {}
        XCTAssertEqual(received, 1); XCTAssertEqual(next.requested.count, 1)
    }

    @MainActor func testLegacyJellyfinMigrationScansAllPagesBeforeSwitchingAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let old = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: account.serverID, userID: account.userID))
        let target = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reading.prepareAtomicReading(scope: old)
        let note = ReadingAnnotation(anchor: .page(1), selectedText: nil, context: nil, note: "Cloud only", color: nil)
        let key = try CloudReadingKey(scope: old, bookID: "book", kind: .annotation, itemID: note.id)
        let version = CloudReadingVersion(revision: UUID(), payload: .annotation(note))
        let entry = CloudReadingEntry(key: key, current: version, baseRevision: nil, pending: false, pendingRevisions: [], conflicts: [])
        let record = try CloudReadingRecordCodec.record(entry: entry, bookID: "book", zoneID: old.recoveryZoneID)
        let first = CloudRecoveryPage(records: [record], deletedRecordCount: 0, nextToken: Data([1]), moreComing: true)
        let last = CloudRecoveryPage(records: [], deletedRecordCount: 0, nextToken: Data([2]), moreComing: false)
        let zones = CloudReadingFoundationTests.FakeZoneDatabase(); zones.value = .present
        let incomplete = RecoveryPages([first])
        let failed = try LegacyJellyfinMigration(account: account, target: target, reading: reading, pages: incomplete, zones: zones, accountIsCurrent: { true }, stillCurrent: { true })
        do { try await failed.runAfterLibraryConfirmation(); XCTFail("An incomplete scan must not switch journals") } catch {}
        try reading.requireRecoveryScope(old)
        XCTAssertEqual(reading.cloudReadingStore?.outbox[key.recordName]?.entry.current.revision, version.revision)
        let oldStore = try XCTUnwrap(reading.cloudReadingStore)
        let stagedPlan = try oldStore.legacyJellyfinMigrationSnapshot(account: account, targetScope: target).makePlan()
        XCTAssertThrowsError(try oldStore.installLegacyJellyfinMigration(stagedPlan, baseDirectory: root) { throw ReaderError.message("interrupted") })
        let pages = RecoveryPages([first, last])
        let retry = try LegacyJellyfinMigration(account: account, target: target, reading: reading, pages: pages, zones: zones, accountIsCurrent: { true }, stillCurrent: { true })
        try await retry.runAfterLibraryConfirmation()
        XCTAssertEqual(pages.requested, [nil, Data([1])])
        try reading.requireRecoveryScope(target)
        let newKey = try CloudReadingKey(scope: target, bookID: "book", kind: .annotation, itemID: note.id)
        let staged = try XCTUnwrap(reading.cloudReadingStore?.outbox[newKey.recordName])
        XCTAssertEqual(staged.legacyConflictRevisions, [version.revision])
        XCTAssertEqual(staged.entry.conflicts.first?.revision, version.revision)
        XCTAssertNil(staged.entry.current.payload)
    }

    @MainActor func testLegacyJellyfinMigrationStopsForMissingZoneOrChangedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let old = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: account.serverID, userID: account.userID))
        let target = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reading.prepareAtomicReading(scope: old)
        let zones = CloudReadingFoundationTests.FakeZoneDatabase()
        let pages = RecoveryPages([CloudRecoveryPage(records: [], deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        var current = true
        let migration = try LegacyJellyfinMigration(account: account, target: target, reading: reading, pages: pages, zones: zones, accountIsCurrent: { current }, stillCurrent: { true })
        do { try await migration.runAfterLibraryConfirmation(); XCTFail("Missing zone requires review") } catch {}
        XCTAssertTrue(pages.requested.isEmpty)
        zones.value = .present; pages.duringPage = { current = false }
        do { try await migration.runAfterLibraryConfirmation(); XCTFail("Changed account must stop migration") } catch {}
        try reading.requireRecoveryScope(old)
    }

    @MainActor func testJellyfinAccountSwitchScansDestinationBeforeChangingMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .scopedJellyfin(account))
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        let mark = Bookmark(name: "Device", position: ReadingPosition(page: 1))
        try reading.add(mark, id: "book")
        try reading.prepareAtomicReading(scope: first)
        var other = mark; other.name = "Destination cloud"
        let key = try CloudReadingKey(scope: second, bookID: "book", kind: .bookmark, itemID: mark.id)
        let remote = CloudReadingVersion(revision: UUID(), payload: .bookmark(other))
        let entry = CloudReadingEntry(key: key, current: remote, baseRevision: nil, pending: false, pendingRevisions: [], conflicts: [])
        let record = try CloudReadingRecordCodec.record(entry: entry, bookID: "book", zoneID: second.recoveryZoneID)
        let note = ReadingAnnotation(anchor: .page(1), selectedText: nil, context: nil, note: "Only in destination", color: nil)
        let noteKey = try CloudReadingKey(scope: second, bookID: "book", kind: .annotation, itemID: note.id)
        let noteVersion = CloudReadingVersion(revision: UUID(), payload: .annotation(note))
        let noteEntry = CloudReadingEntry(key: noteKey, current: noteVersion, baseRevision: nil, pending: false, pendingRevisions: [], conflicts: [])
        let noteRecord = try CloudReadingRecordCodec.record(entry: noteEntry, bookID: "book", zoneID: second.recoveryZoneID)
        let firstPage = CloudRecoveryPage(records: [record, noteRecord], deletedRecordCount: 0, nextToken: Data([1]), moreComing: true)
        let finalPage = CloudRecoveryPage(records: [], deletedRecordCount: 0, nextToken: Data([2]), moreComing: false)
        let zones = CloudReadingFoundationTests.FakeZoneDatabase(); zones.value = .present
        let failed = try JellyfinRecoveryAccountSwitch(account: account, target: second, reading: reading,
            pages: RecoveryPages([firstPage]), zones: zones, accountIsCurrent: { true }, stillCurrent: { true })
        do { try await failed.runAfterConfirmation(); XCTFail("Incomplete discovery must not switch accounts") } catch {}
        try reading.requireRecoveryScope(first)
        XCTAssertEqual(reading.bookmarks["book"]?.first?.name, "Device")
        let retry = try JellyfinRecoveryAccountSwitch(account: account, target: second, reading: reading,
            pages: RecoveryPages([firstPage, finalPage]), zones: zones, accountIsCurrent: { true }, stillCurrent: { true })
        try await retry.runAfterConfirmation()
        try reading.requireRecoveryScope(second)
        let item = try XCTUnwrap(reading.cloudReadingStore?.outbox[key.recordName])
        XCTAssertEqual(item.entry.conflicts.map(\.revision), [remote.revision])
        XCTAssertEqual(item.entry.baseRevision, remote.revision)
        XCTAssertEqual(reading.bookmarks["book"]?.first?.name, "Device")
        let incoming = try XCTUnwrap(reading.cloudReadingStore?.outbox[noteKey.recordName])
        XCTAssertTrue(incoming.pendingApplication == true)
        XCTAssertFalse(incoming.entry.pending)
        XCTAssertEqual(incoming.entry.current.revision, noteVersion.revision)
        XCTAssertTrue(incoming.entry.conflicts.isEmpty)
    }

    @MainActor func testStandaloneAccountSwitchDiscoversBooksWithoutGuessingIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .imported)
        let library = try LocalLibrary(namespace: "switch-discovery-\(UUID().uuidString)")
        let local = try await library.importFile(fixture, folderBookID: "local-book")
        let oldID = try await library.ensureCloudIdentity(for: local, scope: first)
        let reading = try ReadingStore(namespace: "switch-discovery", baseDirectory: root)
        let mark = Bookmark(name: "Local", position: ReadingPosition(page: 1))
        try reading.add(mark, id: local.id)
        try reading.prepareAtomicReading(scope: first, localToCloudBookIDs: [local.id: oldID.readingBookID])
        let stager = try CloudBookStager(scope: second, baseDirectory: root)
        let journal = try CloudBookJournal(scope: second, stager: stager, baseDirectory: root)
        let remoteID = CloudStandaloneBookID()
        let remoteBook = try await stager.stage(source: fixture, bookID: remoteID, title: "Other book", format: .pdf)
        let bookRecord = try await CloudBookRecordCodec.record(remoteBook, scope: second, zoneID: second.recoveryZoneID)
        let remoteMark = Bookmark(name: "Cloud only", position: ReadingPosition(page: 2))
        let key = try CloudReadingKey(scope: second, bookID: remoteID.readingBookID, kind: .bookmark, itemID: remoteMark.id)
        let version = CloudReadingVersion(revision: UUID(), payload: .bookmark(remoteMark))
        let entry = CloudReadingEntry(key: key, current: version, baseRevision: nil, pending: false, pendingRevisions: [], conflicts: [])
        let readingRecord = try CloudReadingRecordCodec.record(entry: entry, bookID: remoteID.readingBookID, zoneID: second.recoveryZoneID)
        let page = CloudRecoveryPage(records: [bookRecord, readingRecord], deletedRecordCount: 0, nextToken: Data([1]), moreComing: true)
        let last = CloudRecoveryPage(records: [], deletedRecordCount: 0, nextToken: Data([2]), moreComing: false)
        let zones = CloudReadingFoundationTests.FakeZoneDatabase(); zones.value = .present
        let failed = try StandaloneRecoveryAccountSwitch(target: second, reading: reading, library: library, journal: journal,
            pages: RecoveryPages([page]), zones: zones, accountIsCurrent: { true }, stillCurrent: { true })
        do { try await failed.runAfterConfirmation(); XCTFail("Incomplete discovery cannot switch accounts") } catch {}
        try reading.requireRecoveryScope(first)
        var current = true
        let changingPages = RecoveryPages([page]); changingPages.duringPage = { current = false }
        let changing = try StandaloneRecoveryAccountSwitch(target: second, reading: reading, library: library, journal: journal,
            pages: changingPages, zones: zones, accountIsCurrent: { current }, stillCurrent: { true })
        do { try await changing.runAfterConfirmation(); XCTFail("An account change must stop the switch") } catch {}
        try reading.requireRecoveryScope(first)
        let beforeRetry = await library.catalog()
        XCTAssertNil(beforeRetry.first?.cloudIdentities?[second.cloudAccountKey])
        let retry = try StandaloneRecoveryAccountSwitch(target: second, reading: reading, library: library, journal: journal,
            pages: RecoveryPages([page, last]), zones: zones, accountIsCurrent: { true }, stillCurrent: { true })
        try await retry.runAfterConfirmation()
        try reading.requireRecoveryScope(second)
        let catalog = await library.catalog()
        let updated = try XCTUnwrap(catalog.first(where: { $0.id == local.id }))
        let newID = try XCTUnwrap(updated.cloudIdentities?[second.cloudAccountKey])
        XCTAssertNotEqual(newID, oldID); XCTAssertNotEqual(newID, remoteID)
        XCTAssertEqual(reading.cloudReadingStore?.localToCloudBookIDs?[local.id], newID.readingBookID)
        XCTAssertEqual(reading.bookmarks[local.id]?.first?.name, "Local")
        XCTAssertTrue(reading.cloudReadingStore?.outbox[key.recordName]?.pendingApplication == true)
        XCTAssertTrue(journal.entry(for: remoteID)?.pendingApplication == true)
        XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: remoteBook.assetURL))
        try await library.remove(updated)
    }

    @MainActor func testStandaloneAccountSwitchPDFRestoresOnSecondDevice() async throws { try await standaloneSwitchJourney(format: .pdf) }
    @MainActor func testStandaloneAccountSwitchEPUBRestoresOnSecondDevice() async throws { try await standaloneSwitchJourney(format: .epub) }
    @MainActor func testStandaloneAccountSwitchCBZRestoresOnSecondDevice() async throws { try await standaloneSwitchJourney(format: .cbz) }
    @MainActor func testStandaloneAccountSwitchImageOnlyPDFRestoresOnSecondDevice() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let image = NSImage(size: NSSize(width: 240, height: 320))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 240, height: 320).fill()
        NSColor.black.setFill()
        for y in stride(from: 30, through: 280, by: 25) { NSRect(x: 20, y: CGFloat(y), width: 190, height: 4).fill() }
        image.unlockFocus()
        let document = PDFDocument()
        for page in 0..<2 { document.insert(try XCTUnwrap(PDFPage(image: image)), at: page) }
        XCTAssertTrue((document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try XCTUnwrap(document.dataRepresentation()).write(to: file)
        try await standaloneSwitchJourney(format: .pdf, sourceOverride: file)
    }

    @MainActor private func standaloneSwitchJourney(format: BookFormat, sourceOverride: URL? = nil) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let sourceFile = sourceOverride ?? project.appendingPathComponent("Fixtures/Harbor.\(format.rawValue)")
        let script = project.appendingPathComponent("App/Resources/Archive/jszip.min.js")
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .imported)
        let cloud = SyntheticRecoveryCloud()
        let sourceLibrary = try LocalLibrary(namespace: "switch-source-\(UUID().uuidString)", archiveScript: script)
        let sourceBook = try await sourceLibrary.importFile(sourceFile, folderBookID: "book")
        let sourceReading = try ReadingStore(namespace: "source", baseDirectory: root.appendingPathComponent("source"))
        let oldStager = try CloudBookStager(scope: first, baseDirectory: root.appendingPathComponent("source"))
        let oldJournal = try CloudBookJournal(scope: first, stager: oldStager, baseDirectory: root.appendingPathComponent("source"))
        let preparation = try StandaloneRecoveryPreparation(scope: first, library: sourceLibrary, reading: sourceReading,
            stager: oldStager, journal: oldJournal, accountIsCurrent: { true })
        try await preparation.prepare()
        _ = try await sourceReading.verifyStandaloneEdition(sourceBook, library: sourceLibrary, scope: first)
        let position = format == .epub ? ReadingPosition(fraction: 0.4, cfi: "epubcfi(/6/2!/4/2:3)") : ReadingPosition(page: 1)
        let anchor: AnnotationAnchor = format == .epub ? .epub(cfi: "epubcfi(/6/2!/4/2:3)") : .page(1)
        let mark = Bookmark(name: "Switch bookmark", position: position)
        let note = ReadingAnnotation(anchor: anchor, selectedText: nil, context: nil, note: "Switch note", color: nil)
        try sourceReading.set(ReadingRecord(position: position, acknowledgedTicks: 0, dirty: false, updated: Date(),
                                            title: sourceBook.title, format: format), id: sourceBook.id)
        try sourceReading.add(mark, id: sourceBook.id)
        try sourceReading.saveAnnotation(note, id: sourceBook.id)
        let newStager = try CloudBookStager(scope: second, baseDirectory: root.appendingPathComponent("source"))
        let newJournal = try CloudBookJournal(scope: second, stager: newStager, baseDirectory: root.appendingPathComponent("source"))
        let zones = CloudReadingFoundationTests.FakeZoneDatabase(); zones.value = .present
        let switcher = try StandaloneRecoveryAccountSwitch(target: second, reading: sourceReading, library: sourceLibrary,
            journal: newJournal, pages: cloud, zones: zones, archiveScript: script, accountIsCurrent: { true }, stillCurrent: { true })
        try await switcher.runAfterConfirmation()
        let firstPass = try StandaloneRecoveryCycle(scope: second, library: sourceLibrary, reading: sourceReading,
            journal: newJournal, zoneID: second.recoveryZoneID, pages: cloud, database: cloud, archiveScript: script, accountIsCurrent: { true })
        let uploaded = try await firstPass.run()
        XCTAssertTrue(uploaded.failures.isEmpty); XCTAssertEqual(uploaded.pendingItems, 0)
        XCTAssertEqual(cloud.records.count, 4)
        let targetLibrary = try LocalLibrary(namespace: "switch-target-\(UUID().uuidString)", archiveScript: script)
        let targetReading = try ReadingStore(namespace: "target", baseDirectory: root.appendingPathComponent("target"))
        let targetStager = try CloudBookStager(scope: second, baseDirectory: root.appendingPathComponent("target"))
        let targetJournal = try CloudBookJournal(scope: second, stager: targetStager, baseDirectory: root.appendingPathComponent("target"))
        let restore = try StandaloneRecoveryCycle(scope: second, library: targetLibrary, reading: targetReading,
            journal: targetJournal, zoneID: second.recoveryZoneID, pages: cloud, database: cloud, archiveScript: script, accountIsCurrent: { true })
        let result = try await restore.run()
        XCTAssertTrue(result.failures.isEmpty); XCTAssertEqual(result.restoredBooks, 1)
        let books = await targetLibrary.catalog()
        let restored = try XCTUnwrap(books.first)
        XCTAssertEqual(targetReading.records[restored.id]?.position, position)
        XCTAssertEqual(targetReading.bookmarks[restored.id]?.first?.name, mark.name)
        XCTAssertEqual(targetReading.annotations[restored.id]?.first?.note, note.note)
        let original = await targetLibrary.originalFile(for: restored)
        XCTAssertEqual(try Data(contentsOf: sourceFile), try Data(contentsOf: try XCTUnwrap(original)))
        try await sourceLibrary.remove(sourceBook)
        try await targetLibrary.remove(restored)
    }

    @MainActor func testAppRecoveryDoesNotStartWhileReaderIsOpen() async throws {
        let model = AppModel(restoreLogin: false)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        model.reader = PreparedBook(book: book, directory: fixture.deletingLastPathComponent(), document: fixture, images: [], position: ReadingPosition())
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let pages = RecoveryPages([]); let database = BookRecordDatabase()
        do { _ = try await model.runStandaloneRecovery(scope: scope, zoneID: zone, pages: pages, database: database, accountIsCurrent: { true }); XCTFail("Recovery must not start over an open reader") } catch {}
        XCTAssertFalse(model.standaloneRecoveryRunning); XCTAssertTrue(pages.requested.isEmpty); XCTAssertEqual(database.attempts, 0)
    }

    @MainActor func testAutomaticJellyfinRecoveryRequiresApprovedSourceAndOpenBook() async throws {
        let suite = "libravia-auto-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(restoreLogin: false)
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        model.account = account
        model.reader = PreparedBook(book: book, directory: fixture.deletingLastPathComponent(), document: fixture, images: [], position: ReadingPosition())
        model.readerLaunchBook = book
        let approved = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        var otherAccount = account; otherAccount.server = URL(string: "https://other.invalid")!
        let other = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(otherAccount))
        var attempts = 0
        let factory: @MainActor () throws -> StandaloneCloudRecoveryService = {
            attempts += 1
            throw ReaderError.message("Synthetic service unavailable")
        }
        model.configureAutomaticJellyfinRecovery(enabled: true, scope: other, defaults: defaults)
        await model.retryAutomaticJellyfinRecovery(defaults: defaults, makeService: factory)
        XCTAssertEqual(attempts, 0)
        model.configureAutomaticJellyfinRecovery(enabled: true, scope: approved, defaults: defaults)
        model.readerLaunchBook = nil
        await model.retryAutomaticJellyfinRecovery(defaults: defaults, makeService: factory)
        XCTAssertEqual(attempts, 0)
        model.readerLaunchBook = book
        await model.retryAutomaticJellyfinRecovery(defaults: defaults, makeService: factory)
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(model.automaticJellyfinRecoveryStatus)
        await model.retryAutomaticJellyfinRecovery(defaults: defaults, makeService: factory)
        XCTAssertEqual(attempts, 1, "Failed attempts should back off")
        model.configureAutomaticJellyfinRecovery(enabled: false, defaults: defaults)
        await model.retryAutomaticJellyfinRecovery(defaults: defaults, makeService: factory)
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(model.automaticJellyfinRecoveryStatus)
    }

    @MainActor func testDestinationPendingPositionRemainsReviewableAfterAccountSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("book.pdf")
        try FileManager.default.copyItem(at: fixture, to: document)
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let source = try CloudReadingSource.scopedJellyfin(account)
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: source)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: source)
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reading.prepareAtomicReading(scope: first)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let digest = try await BookFingerprint.compute(files: [document])
        try target.setVerifiedEdition(localBookID: book.id, fingerprint: digest)
        try target.set(ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false,
                                     updated: Date(), title: book.title, format: .pdf), bookID: book.id)
        let key = try CloudReadingKey(scope: second, bookID: book.id, kind: .position)
        let revision = try XCTUnwrap(target.outbox[key.recordName]?.entry.current.revision)
        try reading.switchJellyfinRecoveryAccount(account: account, targetScope: second)
        let prepared = PreparedBook(book: book, directory: directory, document: document, images: [], position: ReadingPosition())
        let model = AppModel(restoreLogin: false)
        model.account = account; model.provider = JellyfinProvider(account: account); model.store = reading
        model.reader = prepared; model.readerLaunchBook = book
        let candidate = try XCTUnwrap(model.stagedJellyfinPosition(scope: second))
        XCTAssertEqual(candidate.revision, revision)
        do {
            _ = try await model.applyStagedJellyfinPosition(candidate, scope: second, stillReadingSamePosition: { false },
                                                            accountIsCurrent: { true }, refreshBook: { book })
            XCTFail("A moved reader must not be overwritten")
        } catch { }
        XCTAssertNil(reading.records[book.id])
        let position = try await model.applyStagedJellyfinPosition(candidate, scope: second, stillReadingSamePosition: { true },
                                                                    accountIsCurrent: { true }, refreshBook: { book })
        XCTAssertEqual(position.page, 1)
        XCTAssertEqual(reading.records[book.id]?.position.page, 1)
        let applied = try XCTUnwrap(reading.cloudReadingStore?.outbox[key.recordName])
        XCTAssertEqual(applied.entry.current.revision, revision)
        XCTAssertTrue(applied.entry.pending)
        XCTAssertFalse(applied.pendingApplication == true)
        XCTAssertNil(model.stagedJellyfinPosition(scope: second))
    }

    @MainActor func testJellyfinPositionDeletionNeedsExplicitReviewAndStableServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("book.pdf")
        try FileManager.default.copyItem(at: fixture, to: document)
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope)
        let atomic = try XCTUnwrap(reading.cloudReadingStore)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        let prepared = PreparedBook(book: book, directory: directory, document: document, images: [], position: ReadingPosition())
        let digest = try await BookFingerprint.compute(files: [document])
        let key = try CloudReadingKey(scope: scope, bookID: book.id, kind: .position)
        let deletion = CloudReadingVersion(revision: UUID(), payload: nil, editionFingerprint: digest)
        try atomic.observe(key, bookID: book.id, remote: deletion)
        try atomic.setVerifiedEdition(localBookID: book.id, fingerprint: digest)
        XCTAssertThrowsError(try atomic.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: deletion.revision),
                             "A position deletion must never apply without explicit review")
        let model = AppModel(restoreLogin: false)
        model.account = account; model.provider = JellyfinProvider(account: account); model.store = reading
        model.reader = prepared; model.readerLaunchBook = book
        let incoming = try XCTUnwrap(model.pendingJellyfinIncomingReading(scope: scope).first)
        do {
            try await model.confirmJellyfinIncomingReading(incoming, scope: scope, accountIsCurrent: { true },
                                                           stillReadingSamePosition: { false }, refreshBook: { book })
            XCTFail("A changed reader must stop deletion")
        } catch { }
        var changed = book; changed.ticks = 10_000
        do {
            try await model.confirmJellyfinIncomingReading(incoming, scope: scope, accountIsCurrent: { true },
                                                           refreshBook: { changed })
            XCTFail("Changed server progress must stop deletion")
        } catch { }
        XCTAssertTrue(try XCTUnwrap(atomic.outbox[key.recordName]).pendingApplication == true)
        try await model.confirmJellyfinIncomingReading(incoming, scope: scope, accountIsCurrent: { true }, refreshBook: { book })
        XCTAssertFalse(try XCTUnwrap(atomic.outbox[key.recordName]).pendingApplication == true)
        XCTAssertNil(reading.records[book.id])

        try reading.set(ReadingRecord(position: ReadingPosition(page: 0), acknowledgedTicks: 0, dirty: true,
                                      updated: Date(), title: book.title, format: .pdf), id: book.id)
        let competingDeletion = CloudReadingVersion(revision: UUID(), payload: nil, editionFingerprint: digest)
        try atomic.observe(key, bookID: book.id, remote: competingDeletion)
        let conflict = try XCTUnwrap(model.pendingJellyfinReadingReviews(scope: scope).first { $0.remote?.revision == competingDeletion.revision })
        do {
            _ = try await model.reviewJellyfinReadingItem(conflict, scope: scope, choice: .remote, accountIsCurrent: { true },
                                                          stillReadingSamePosition: { true }, refreshBook: { changed })
            XCTFail("Changed server progress must preserve both alternatives")
        } catch { }
        XCTAssertNotNil(reading.records[book.id])
        XCTAssertFalse(try XCTUnwrap(atomic.outbox[key.recordName]).entry.conflicts.isEmpty)
        do {
            _ = try await model.reviewJellyfinReadingItem(conflict, scope: scope, choice: .remote, accountIsCurrent: { true },
                                                          stillReadingSamePosition: { true }, refreshBook: { book })
            XCTFail("Unsynced local progress must not be removed")
        } catch { }
        XCTAssertNotNil(reading.records[book.id])
        try reading.set(ReadingRecord(position: ReadingPosition(page: 0), acknowledgedTicks: 0, dirty: false,
                                      updated: Date(), title: book.title, format: .pdf), id: book.id)
        let updated = try XCTUnwrap(model.pendingJellyfinReadingReviews(scope: scope).first { $0.remote?.revision == competingDeletion.revision })
        let position = try await model.reviewJellyfinReadingItem(updated, scope: scope, choice: .remote, accountIsCurrent: { true },
                                                                 stillReadingSamePosition: { true }, refreshBook: { book })
        XCTAssertNil(position)
        XCTAssertNil(reading.records[book.id])
        let resolved = try XCTUnwrap(atomic.outbox[key.recordName])
        XCTAssertNil(resolved.entry.current.payload)
        XCTAssertTrue(resolved.entry.pending)
        XCTAssertTrue(resolved.entry.conflicts.isEmpty)
    }

    @MainActor func testAppJellyfinRecoveryAppliesBookmarksButStagesOpenReaderPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("book.pdf")
        try FileManager.default.copyItem(at: fixture, to: document)
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let source = try CloudReadingSource.scopedJellyfin(account)
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: source)
        let reading = try ReadingStore(namespace: "server", baseDirectory: root)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        let legacy = Bookmark(name: "Local before sync", position: ReadingPosition(page: 0))
        try reading.add(legacy, id: book.id)
        let prepared = PreparedBook(book: book, directory: directory, document: document, images: [], position: ReadingPosition())
        let digest = try await BookFingerprint.compute(files: [document])
        let remote = try CloudReadingJournal(scope: scope, baseDirectory: root.appendingPathComponent("remote"))
        let mark = Bookmark(name: "Cloud mark", position: ReadingPosition(page: 0))
        let legacyIncoming = Bookmark(name: "Older cloud mark", position: ReadingPosition(page: 0))
        let markKey = try CloudReadingKey(scope: scope, bookID: book.id, kind: .bookmark, itemID: mark.id)
        let legacyIncomingKey = try CloudReadingKey(scope: scope, bookID: book.id, kind: .bookmark, itemID: legacyIncoming.id)
        let positionKey = try CloudReadingKey(scope: scope, bookID: book.id, kind: .position)
        try remote.edit(markKey, payload: .bookmark(mark))
        try remote.edit(legacyIncomingKey, payload: .bookmark(legacyIncoming))
        try remote.edit(positionKey, payload: .position(CloudPrecisePosition(position: ReadingPosition(page: 1), contentFingerprint: nil, acknowledgedServerTicks: 0)))
        var markEntry = try XCTUnwrap(remote.entries[markKey.recordName]); markEntry.current.editionFingerprint = digest
        let positionEntry = try XCTUnwrap(remote.entries[positionKey.recordName])
        let legacyIncomingEntry = try XCTUnwrap(remote.entries[legacyIncomingKey.recordName])
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let records = try [CloudReadingRecordCodec.record(entry: markEntry, bookID: book.id, zoneID: zone),
                           CloudReadingRecordCodec.record(entry: legacyIncomingEntry, bookID: book.id, zoneID: zone),
                           CloudReadingRecordCodec.record(entry: positionEntry, bookID: book.id, zoneID: zone)]
        let pages = RecoveryPages([CloudRecoveryPage(records: records, deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let model = AppModel(restoreLogin: false)
        model.account = account; model.provider = JellyfinProvider(account: account); model.store = reading
        model.reader = prepared; model.readerLaunchBook = book
        let result = try await model.runJellyfinReadingRecovery(scope: scope, zoneID: zone, pages: pages,
                                                                 database: BookRecordDatabase(), accountIsCurrent: { true })
        XCTAssertEqual(result.applied, 1); XCTAssertGreaterThanOrEqual(result.needsReview, 1)
        XCTAssertTrue(reading.bookmarks[book.id]?.contains(where: { $0.name == "Cloud mark" }) == true)
        let incoming = try XCTUnwrap(model.pendingJellyfinIncomingReading(scope: scope).first { $0.key == legacyIncomingKey })
        do { try await model.confirmJellyfinIncomingReading(incoming, scope: scope, accountIsCurrent: { false }); XCTFail("Account changes must stop review") } catch { }
        XCTAssertFalse(reading.bookmarks[book.id]?.contains(where: { $0.id == legacyIncoming.id }) ?? false)
        try await model.confirmJellyfinIncomingReading(incoming, scope: scope, accountIsCurrent: { true })
        XCTAssertTrue(reading.bookmarks[book.id]?.contains(where: { $0.id == legacyIncoming.id }) == true)
        XCTAssertEqual(reading.cloudReadingStore?.outbox[legacyIncomingKey.recordName]?.entry.current.editionFingerprint, digest)
        XCTAssertTrue(reading.cloudReadingStore?.outbox[legacyIncomingKey.recordName]?.entry.pending == true)
        let review = try XCTUnwrap(model.pendingJellyfinReadingReviews(scope: scope).first { $0.key.itemID == legacy.id && $0.remote == nil })
        try await model.reviewJellyfinReadingItem(review, scope: scope, choice: nil, accountIsCurrent: { true })
        XCTAssertEqual(reading.cloudReadingStore?.outbox[review.key.recordName]?.entry.current.editionFingerprint, digest)
        var remoteLegacy = legacy; remoteLegacy.name = "Cloud choice"
        let competing = CloudReadingVersion(revision: UUID(), payload: .bookmark(remoteLegacy), editionFingerprint: digest)
        try XCTUnwrap(reading.cloudReadingStore).observe(review.key, bookID: book.id, remote: competing)
        let conflict = try XCTUnwrap(model.pendingJellyfinReadingReviews(scope: scope).first { $0.remote?.revision == competing.revision })
        try await model.reviewJellyfinReadingItem(conflict, scope: scope, choice: .remote, accountIsCurrent: { true })
        XCTAssertTrue(reading.bookmarks[book.id]?.contains(where: { $0.name == "Cloud choice" }) == true)
        reading.invalidateCloudVerification()
        let chosenBookmark = try XCTUnwrap(reading.bookmarks[book.id]?.first { $0.id == legacy.id })
        try reading.removeBookmark(chosenBookmark, id: book.id)
        let deletionReview = try XCTUnwrap(model.pendingJellyfinReadingReviews(scope: scope).first {
            $0.key.itemID == legacy.id && $0.remote == nil && $0.current.payload == nil
        })
        do {
            try await model.reviewJellyfinReadingItem(deletionReview, scope: scope, choice: nil, accountIsCurrent: { false })
            XCTFail("An account change must not certify a deletion")
        } catch { }
        XCTAssertNil(reading.cloudReadingStore?.outbox[deletionReview.key.recordName]?.entry.current.editionFingerprint)
        try await model.reviewJellyfinReadingItem(deletionReview, scope: scope, choice: nil, accountIsCurrent: { true })
        let deletion = try XCTUnwrap(reading.cloudReadingStore?.outbox[deletionReview.key.recordName])
        XCTAssertNil(deletion.entry.current.payload)
        XCTAssertEqual(deletion.entry.current.editionFingerprint, digest)
        XCTAssertTrue(deletion.entry.pending)
        XCTAssertFalse(reading.bookmarks[book.id]?.contains(where: { $0.id == legacy.id }) ?? false)
        XCTAssertNil(reading.records[book.id])
        XCTAssertTrue(try XCTUnwrap(reading.cloudReadingStore?.outbox[positionKey.recordName]).pendingApplication == true)
        let candidate = try XCTUnwrap(model.stagedJellyfinPosition(scope: scope))
        do { _ = try await model.applyStagedJellyfinPosition(candidate, scope: scope, stillReadingSamePosition: { false }, accountIsCurrent: { true }); XCTFail("A moved reader must not be overwritten") } catch {}
        XCTAssertNil(reading.records[book.id])
        XCTAssertTrue(try XCTUnwrap(reading.cloudReadingStore?.outbox[positionKey.recordName]).pendingApplication == true)
        let invalid = JellyfinPositionCandidate(key: candidate.key, revision: candidate.revision, position: ReadingPosition(page: 999))
        do { _ = try await model.applyStagedJellyfinPosition(invalid, scope: scope, stillReadingSamePosition: { true }, accountIsCurrent: { true }, refreshBook: { book }); XCTFail("An out-of-range page must remain staged") } catch {}
        XCTAssertNil(reading.records[book.id])
        do { _ = try await model.applyStagedJellyfinPosition(candidate, scope: scope, stillReadingSamePosition: { true },
            accountIsCurrent: { true }, refreshBook: { book }); XCTFail("An older position needs explicit edition confirmation") } catch { }
        var newerServerBook = book; newerServerBook.ticks = 10_000
        do { _ = try await model.applyStagedJellyfinPosition(candidate, scope: scope, stillReadingSamePosition: { true },
            accountIsCurrent: { true }, confirmLegacyEdition: true, refreshBook: { newerServerBook }); XCTFail("Changed Jellyfin progress must stop restoration") } catch { }
        XCTAssertNil(reading.records[book.id])
        let selected = try await model.applyStagedJellyfinPosition(candidate, scope: scope, stillReadingSamePosition: { true },
                                                                  accountIsCurrent: { true }, confirmLegacyEdition: true, refreshBook: { book })
        XCTAssertEqual(selected.page, 1); XCTAssertEqual(reading.records[book.id]?.position.page, 1)
        XCTAssertFalse(try XCTUnwrap(reading.cloudReadingStore?.outbox[positionKey.recordName]).pendingApplication == true)
        try reading.set(ReadingRecord(position: ReadingPosition(page: 0), acknowledgedTicks: 0, dirty: false,
                                      updated: Date(), title: book.title, format: .pdf), id: book.id)
        let positionAlternative = CloudReadingVersion(revision: UUID(),
            payload: .position(CloudPrecisePosition(position: ReadingPosition(page: 2), contentFingerprint: nil, acknowledgedServerTicks: 0)),
            editionFingerprint: digest)
        let atomic = try XCTUnwrap(reading.cloudReadingStore)
        try atomic.observe(positionKey, bookID: book.id, remote: positionAlternative)
        let positionConflict = try XCTUnwrap(model.pendingJellyfinReadingReviews(scope: scope).first { $0.remote?.revision == positionAlternative.revision })
        do {
            try await model.reviewJellyfinReadingItem(positionConflict, scope: scope, choice: .remote,
                accountIsCurrent: { true }, stillReadingSamePosition: { false }, refreshBook: { book })
            XCTFail("A moved reader must not be overwritten")
        } catch { }
        var changedBook = book; changedBook.ticks = 10000
        do {
            try await model.reviewJellyfinReadingItem(positionConflict, scope: scope, choice: .remote,
                accountIsCurrent: { true }, stillReadingSamePosition: { true }, refreshBook: { changedBook })
            XCTFail("Changed server progress must preserve the conflict")
        } catch { }
        XCTAssertEqual(reading.records[book.id]?.position.page, 0)
        XCTAssertTrue(try XCTUnwrap(atomic.outbox[positionKey.recordName]).entry.conflicts.contains { $0.revision == positionAlternative.revision })
        let resolved = try await model.reviewJellyfinReadingItem(positionConflict, scope: scope, choice: .remote,
            accountIsCurrent: { true }, stillReadingSamePosition: { true }, refreshBook: { book })
        XCTAssertEqual(resolved?.page, 2)
        XCTAssertEqual(reading.records[book.id]?.position.page, 2)
        XCTAssertTrue(try XCTUnwrap(atomic.outbox[positionKey.recordName]).entry.conflicts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(atomic.outbox[positionKey.recordName]).entry.pending)
        XCTAssertFalse(model.jellyfinRecoveryRunning)
        let otherStore = try ReadingStore(namespace: "other-session", baseDirectory: root.appendingPathComponent("second"))
        let otherModel = AppModel(restoreLogin: false)
        otherModel.account = account; otherModel.provider = JellyfinProvider(account: account); otherModel.store = otherStore
        otherModel.reader = prepared; otherModel.readerLaunchBook = book
        let interruptedPages = RecoveryPages([CloudRecoveryPage(records: records, deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        interruptedPages.duringPage = { otherModel.cancelOpen() }
        do { _ = try await otherModel.runJellyfinReadingRecovery(scope: scope, zoneID: zone, pages: interruptedPages,
                                                                 database: BookRecordDatabase(), accountIsCurrent: { true }); XCTFail("A closed reader must stop recovery") } catch {}
        XCTAssertTrue(otherStore.bookmarks.isEmpty)
        XCTAssertFalse(otherModel.jellyfinRecoveryRunning)
    }

    @MainActor func testJellyfinRecoveryCycleRequiresFreshMatchingServerPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("book.pdf")
        try FileManager.default.copyItem(at: fixture, to: document)
        let source = CloudReadingSource.jellyfin(serverID: "server", userID: "user")
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: source)
        let reading = try ReadingStore(namespace: "server", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 10_000)
        let prepared = PreparedBook(book: book, directory: directory, document: document, images: [], position: ReadingPosition())
        let digest = try await BookFingerprint.compute(files: [document])
        let remote = try CloudReadingJournal(scope: scope, baseDirectory: root.appendingPathComponent("remote"))
        let key = try CloudReadingKey(scope: scope, bookID: book.id, kind: .position)
        try remote.edit(key, payload: .position(CloudPrecisePosition(position: ReadingPosition(page: 3), contentFingerprint: nil, acknowledgedServerTicks: 10_000)))
        var entry = try XCTUnwrap(remote.entries[key.recordName]); entry.current.editionFingerprint = digest
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let record = try CloudReadingRecordCodec.record(entry: entry, bookID: book.id, zoneID: zone)
        let pages = RecoveryPages([CloudRecoveryPage(records: [record], deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let database = BookRecordDatabase()
        var server = book; server.ticks = 20_000
        let cycle = try JellyfinReadingRecoveryCycle(scope: scope, source: source, reading: reading, zoneID: zone,
                                                      pages: pages, database: database, accountIsCurrent: { true },
                                                      stillCurrent: { true }, freshBook: { server })
        let first = try await cycle.run(prepared: prepared)
        XCTAssertEqual(first.applied, 0); XCTAssertFalse(first.failures.isEmpty)
        XCTAssertNil(reading.records[book.id]); XCTAssertEqual(database.saves, 0)
        server.ticks = 10_000; pages.requested.removeAll()
        let second = try await cycle.run(prepared: prepared)
        XCTAssertEqual(second.applied, 1); XCTAssertTrue(second.failures.isEmpty)
        XCTAssertEqual(reading.records[book.id]?.position.page, 3)
        XCTAssertEqual(reading.records[book.id]?.acknowledgedTicks, 10_000)
    }

    @MainActor func testJellyfinEditionVerificationUsesPreparedContentAndSessionFence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("book.pdf")
        try FileManager.default.copyItem(at: fixture, to: document)
        let source = CloudReadingSource.jellyfin(serverID: "server", userID: "user")
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: source)
        let reading = try ReadingStore(namespace: "server", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        let prepared = PreparedBook(book: book, directory: directory, document: document, images: [], position: ReadingPosition())
        let digest = try await reading.verifyJellyfinEdition(prepared, source: source, stillCurrent: { true })
        let expected = try await BookFingerprint.compute(files: [document])
        XCTAssertEqual(digest, expected)
        let wrong = CloudReadingSource.jellyfin(serverID: "different", userID: "user")
        do { _ = try await reading.verifyJellyfinEdition(prepared, source: wrong, stillCurrent: { true }); XCTFail("Wrong source") } catch {}
        do { _ = try await reading.verifyJellyfinEdition(prepared, source: source, stillCurrent: { false }); XCTFail("Ended session") } catch {}
        let replacement = directory.appendingPathComponent("elsewhere.pdf")
        var invalid = prepared; invalid.document = replacement
        do { _ = try await reading.verifyJellyfinEdition(invalid, source: source, stillCurrent: { true }); XCTFail("Changed content") } catch {}
    }

    @MainActor func testRecoveryCycleDiscoversBeforeRestoringBookAndReadingData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let sender = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let staged = try await sender.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let bookRecord = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone)
        let marks = try CloudReadingJournal(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let mark = Bookmark(name: "Recovered", position: ReadingPosition(page: 0))
        let key = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .bookmark, itemID: mark.id)
        try marks.edit(key, payload: .bookmark(mark))
        var entry = try XCTUnwrap(marks.entries[key.recordName]); entry.current.editionFingerprint = staged.metadata.sha256
        let readingRecord = try CloudReadingRecordCodec.record(entry: entry, bookID: id.readingBookID, zoneID: zone)
        let pages = RecoveryPages([CloudRecoveryPage(records: [bookRecord, readingRecord], deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let library = try LocalLibrary(namespace: "recovery-cycle-\(UUID().uuidString)")
        let reading = try ReadingStore(namespace: "cycle", baseDirectory: root)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let database = BookRecordDatabase(); database.value = bookRecord
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zone, pages: pages, database: database, accountIsCurrent: { true })
        let result = try await cycle.run()
        XCTAssertEqual(result.restoredBooks, 1); XCTAssertEqual(result.appliedReadingItems, 1)
        XCTAssertTrue(result.failures.isEmpty); XCTAssertEqual(result.needsReview, 0); XCTAssertEqual(database.saves, 0)
        let books = await library.catalog(); XCTAssertEqual(books.count, 1)
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(reading.bookmarks[book.id]?.map(\.name), ["Recovered"])
        let later = Bookmark(name: "Later", position: ReadingPosition(page: 0))
        let laterKey = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .bookmark, itemID: later.id)
        try marks.edit(laterKey, payload: .bookmark(later))
        var laterEntry = try XCTUnwrap(marks.entries[laterKey.recordName]); laterEntry.current.editionFingerprint = staged.metadata.sha256
        let laterRecord = try CloudReadingRecordCodec.record(entry: laterEntry, bookID: id.readingBookID, zoneID: zone)
        pages.requested.removeAll()
        pages.pages = [CloudRecoveryPage(records: [bookRecord, readingRecord, laterRecord], deletedRecordCount: 0, nextToken: Data([2]), moreComing: false)]
        let second = try await cycle.run()
        XCTAssertEqual(second.restoredBooks, 0); XCTAssertEqual(second.appliedReadingItems, 1)
        XCTAssertEqual(Set(reading.bookmarks[book.id]?.map(\.name) ?? []), Set(["Recovered", "Later"]))
        try await library.remove(book)
    }

    @MainActor func testSyntheticPDFRecoveryAfterOfflineReading() async throws { try await syntheticRecoveryJourney(format: .pdf) }
    @MainActor func testSyntheticEPUBRecoveryAfterOfflineReading() async throws { try await syntheticRecoveryJourney(format: .epub) }
    @MainActor func testSyntheticCBZRecoveryAfterOfflineReading() async throws { try await syntheticRecoveryJourney(format: .cbz) }

    @MainActor private func syntheticRecoveryJourney(format: BookFormat) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let script = project.appendingPathComponent("App/Resources/Archive/jszip.min.js")
        let sourceFile = project.appendingPathComponent("Fixtures/Harbor.\(format.rawValue)")
        let position = format == .epub ? ReadingPosition(fraction: 0.4, cfi: "epubcfi(/6/2!/4/2:3)") : ReadingPosition(page: 1)
        let anchor: AnnotationAnchor = format == .epub ? .epub(cfi: "epubcfi(/6/2!/4/2:3)") : .page(1)
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let cloud = SyntheticRecoveryCloud()
        let source = try LocalLibrary(namespace: "two-device-source-\(UUID().uuidString)", archiveScript: script)
        let sourceBook = try await source.importFile(sourceFile, folderBookID: "book")
        let sourceReading = try ReadingStore(namespace: "source", baseDirectory: root.appendingPathComponent("source"))
        let sourceStager = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("source"))
        let sourceJournal = try CloudBookJournal(scope: scope, stager: sourceStager, baseDirectory: root.appendingPathComponent("source"), archiveScript: script)
        let prep = try StandaloneRecoveryPreparation(scope: scope, library: source, reading: sourceReading,
                                                      stager: sourceStager, journal: sourceJournal, accountIsCurrent: { true })
        try await prep.prepare()
        _ = try await sourceReading.verifyStandaloneEdition(sourceBook, library: source, scope: scope)
        let sourceCycle = try StandaloneRecoveryCycle(scope: scope, library: source, reading: sourceReading,
            journal: sourceJournal, zoneID: zone, pages: cloud, database: cloud, archiveScript: script, accountIsCurrent: { true })
        cloud.online = false
        let bookmark = Bookmark(name: "Offline mark", position: position)
        let note = ReadingAnnotation(anchor: anchor, selectedText: nil, context: nil, note: "Offline note", color: nil)
        try sourceReading.set(ReadingRecord(position: position, acknowledgedTicks: 0, dirty: false,
                                            updated: Date(), title: sourceBook.title, format: format), id: sourceBook.id)
        try sourceReading.add(bookmark, id: sourceBook.id)
        try sourceReading.saveAnnotation(note, id: sourceBook.id)
        do { _ = try await sourceCycle.run(); XCTFail("An offline discovery cannot complete") } catch { }
        XCTAssertTrue(cloud.records.isEmpty)
        XCTAssertEqual(sourceReading.annotations[sourceBook.id]?.first?.note, "Offline note")
        cloud.online = true
        cloud.disconnectAfterBookSave = true
        let interrupted = try await sourceCycle.run()
        XCTAssertFalse(interrupted.failures.isEmpty)
        XCTAssertEqual(cloud.records.count, 1)
        XCTAssertEqual(cloud.records.values.first?.recordType, CloudBookRecordCodec.recordType)
        XCTAssertGreaterThanOrEqual(interrupted.pendingItems, 3)
        XCTAssertTrue(sourceJournal.entries.values.contains { $0.pending })
        XCTAssertEqual(sourceReading.annotations[sourceBook.id]?.first?.note, "Offline note")
        cloud.online = true
        let uploaded = try await sourceCycle.run()
        XCTAssertTrue(uploaded.failures.isEmpty); XCTAssertEqual(uploaded.pendingItems, 0)
        XCTAssertEqual(cloud.records.count, 4)

        let target = try LocalLibrary(namespace: "two-device-target-\(UUID().uuidString)", archiveScript: script)
        let targetReading = try ReadingStore(namespace: "target", baseDirectory: root.appendingPathComponent("target"))
        let targetStager = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("target"))
        let targetJournal = try CloudBookJournal(scope: scope, stager: targetStager, baseDirectory: root.appendingPathComponent("target"), archiveScript: script)
        let targetCycle = try StandaloneRecoveryCycle(scope: scope, library: target, reading: targetReading,
            journal: targetJournal, zoneID: zone, pages: cloud, database: cloud, archiveScript: script, accountIsCurrent: { true })
        let restored = try await targetCycle.run()
        XCTAssertTrue(restored.failures.isEmpty); XCTAssertEqual(restored.restoredBooks, 1)
        XCTAssertEqual(restored.appliedReadingItems, 3); XCTAssertEqual(restored.needsReview, 0)
        let recoveredBooks = await target.catalog()
        let recovered = try XCTUnwrap(recoveredBooks.first)
        XCTAssertEqual(targetReading.records[recovered.id]?.position, position)
        XCTAssertEqual(targetReading.bookmarks[recovered.id]?.first?.name, "Offline mark")
        XCTAssertEqual(targetReading.annotations[recovered.id]?.first?.note, "Offline note")
        let recoveredFile = await target.originalFile(for: recovered)
        let file = try XCTUnwrap(recoveredFile)
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: sourceFile))
        let reinstalled = try LocalLibrary(namespace: "two-device-reinstall-\(UUID().uuidString)", archiveScript: script)
        let freshRoot = root.appendingPathComponent("reinstall")
        let freshReading = try ReadingStore(namespace: "fresh", baseDirectory: freshRoot)
        let freshStager = try CloudBookStager(scope: scope, baseDirectory: freshRoot)
        let freshJournal = try CloudBookJournal(scope: scope, stager: freshStager, baseDirectory: freshRoot, archiveScript: script)
        let freshCycle = try StandaloneRecoveryCycle(scope: scope, library: reinstalled, reading: freshReading,
            journal: freshJournal, zoneID: zone, pages: cloud, database: cloud, archiveScript: script, accountIsCurrent: { true })
        let freshReport = try await freshCycle.run()
        XCTAssertTrue(freshReport.failures.isEmpty); XCTAssertEqual(freshReport.appliedReadingItems, 3)
        let freshBooks = await reinstalled.catalog()
        let freshBook = try XCTUnwrap(freshBooks.first)
        XCTAssertEqual(freshReading.records[freshBook.id]?.position, position)
        XCTAssertEqual(freshReading.bookmarks[freshBook.id]?.first?.id, bookmark.id)
        XCTAssertEqual(freshReading.annotations[freshBook.id]?.first?.id, note.id)
        XCTAssertEqual(freshBook.cloudIdentities?[scope.cloudAccountKey], recovered.cloudIdentities?[scope.cloudAccountKey])

        // Each device edits the same bookmark before seeing the other's edit.
        try sourceReading.renameBookmark(bookmark, id: sourceBook.id, name: "Source edit")
        try targetReading.renameBookmark(bookmark, id: recovered.id, name: "Target edit")
        let firstEdit = try await sourceCycle.run()
        XCTAssertTrue(firstEdit.failures.isEmpty)
        let conflictReport = try await targetCycle.run()
        XCTAssertGreaterThan(conflictReport.needsReview, 0)
        XCTAssertEqual(targetReading.bookmarks[recovered.id]?.first?.name, "Target edit")
        let atomic = try XCTUnwrap(targetReading.cloudReadingStore)
        let cloudID = try XCTUnwrap(atomic.localToCloudBookIDs?[recovered.id])
        let key = try CloudReadingKey(scope: scope, bookID: cloudID, kind: .bookmark, itemID: bookmark.id)
        let conflict = try XCTUnwrap(atomic.outbox[key.recordName])
        let remote = try XCTUnwrap(conflict.entry.conflicts.first)
        guard case .bookmark(let sourceVersion) = remote.payload else { return XCTFail("Expected the source bookmark") }
        XCTAssertEqual(sourceVersion.name, "Source edit")
        let digest = try await targetReading.verifyStandaloneEdition(recovered, library: target, scope: scope)
        try targetReading.resolveCloudConflict(key, book: recovered.book, verifiedEditionFingerprint: digest,
            expectedLocalRevision: conflict.entry.current.revision, remoteRevision: remote.revision, choice: .local)
        let resolved = try await targetCycle.run()
        XCTAssertTrue(resolved.failures.isEmpty); XCTAssertEqual(resolved.needsReview, 0)
        let otherDevice = try await sourceCycle.run()
        XCTAssertTrue(otherDevice.failures.isEmpty)
        XCTAssertEqual(sourceReading.bookmarks[sourceBook.id]?.first?.name, "Target edit")

        let targetMark = try XCTUnwrap(targetReading.bookmarks[recovered.id]?.first)
        try targetReading.removeBookmark(targetMark, id: recovered.id)
        let deleted = try await targetCycle.run()
        XCTAssertTrue(deleted.failures.isEmpty)
        let receivedDeletion = try await sourceCycle.run()
        XCTAssertTrue(receivedDeletion.failures.isEmpty)
        XCTAssertTrue(sourceReading.bookmarks[sourceBook.id]?.isEmpty ?? true)

        // A deletion and an independent edit of the same note must remain
        // reviewable; choosing the edit must restore it on the deleting device.
        try sourceReading.removeAnnotation(note, id: sourceBook.id)
        var editedNote = try XCTUnwrap(targetReading.annotations[recovered.id]?.first { $0.id == note.id })
        editedNote.note = "Edited on target"
        try targetReading.saveAnnotation(editedNote, id: recovered.id)
        let deletionUploaded = try await sourceCycle.run()
        XCTAssertTrue(deletionUploaded.failures.isEmpty)
        let noteConflictReport = try await targetCycle.run()
        XCTAssertGreaterThan(noteConflictReport.needsReview, 0)
        XCTAssertEqual(targetReading.annotations[recovered.id]?.first?.note, "Edited on target")
        let noteKey = try CloudReadingKey(scope: scope, bookID: cloudID, kind: .annotation, itemID: note.id)
        let noteConflict = try XCTUnwrap(atomic.outbox[noteKey.recordName])
        let remoteDeletion = try XCTUnwrap(noteConflict.entry.conflicts.first)
        XCTAssertNil(remoteDeletion.payload)
        let refreshedDigest = try await targetReading.verifyStandaloneEdition(recovered, library: target, scope: scope)
        try targetReading.resolveCloudConflict(noteKey, book: recovered.book, verifiedEditionFingerprint: refreshedDigest,
            expectedLocalRevision: noteConflict.entry.current.revision, remoteRevision: remoteDeletion.revision, choice: .local)
        let noteResolved = try await targetCycle.run()
        XCTAssertTrue(noteResolved.failures.isEmpty); XCTAssertEqual(noteResolved.needsReview, 0)
        let noteRestored = try await sourceCycle.run()
        XCTAssertTrue(noteRestored.failures.isEmpty)
        XCTAssertEqual(sourceReading.annotations[sourceBook.id]?.first?.note, "Edited on target")

        let chosenNote = try XCTUnwrap(sourceReading.annotations[sourceBook.id]?.first { $0.id == note.id })
        try sourceReading.removeAnnotation(chosenNote, id: sourceBook.id)
        let finalSource = try await sourceCycle.run()
        let finalTarget = try await targetCycle.run()
        let finalFresh = try await freshCycle.run()
        XCTAssertTrue(finalSource.failures.isEmpty)
        XCTAssertTrue(finalTarget.failures.isEmpty)
        XCTAssertTrue(finalFresh.failures.isEmpty)
        XCTAssertTrue(targetReading.annotations[recovered.id]?.isEmpty ?? true)
        XCTAssertTrue(freshReading.annotations[freshBook.id]?.isEmpty ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        try await source.remove(sourceBook); try await target.remove(recovered); try await reinstalled.remove(freshBook)
    }

    @MainActor func testRecoveryCycleDoesNotUploadReadingDataWhenBookUploadFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let pages = RecoveryPages([CloudRecoveryPage(records: [], deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let library = try LocalLibrary(namespace: "recovery-upload-fail-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let reading = try ReadingStore(namespace: "cycle", baseDirectory: root)
        try reading.add(Bookmark(name: "Local", position: ReadingPosition(page: 0)), id: book.id)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let database = BookRecordDatabase(); database.duringSave = { throw ReaderError.message("Offline") }
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zone, pages: pages, database: database, accountIsCurrent: { true })
        let result = try await cycle.run()
        XCTAssertEqual(database.attempts, 1); XCTAssertEqual(database.saves, 0)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertTrue(try XCTUnwrap(reading.cloudReadingStore).outbox.values.contains { $0.entry.pending })
        XCTAssertTrue(journal.entries.values.contains { $0.pending })
        try await library.remove(book)
    }

    @MainActor func testRecoveryCycleReportsInvalidItemAndRestoresValidItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let sender = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let staged = try await sender.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let bookRecord = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone)
        let remote = try CloudReadingJournal(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let valid = Bookmark(name: "Valid", position: ReadingPosition(page: 0))
        let invalid = Bookmark(name: "Invalid", position: ReadingPosition(page: -1))
        var records = [bookRecord]
        for bookmark in [valid, invalid] {
            let key = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .bookmark, itemID: bookmark.id)
            try remote.edit(key, payload: .bookmark(bookmark))
            var entry = try XCTUnwrap(remote.entries[key.recordName]); entry.current.editionFingerprint = staged.metadata.sha256
            records.append(try CloudReadingRecordCodec.record(entry: entry, bookID: id.readingBookID, zoneID: zone))
        }
        let pages = RecoveryPages([CloudRecoveryPage(records: records, deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let library = try LocalLibrary(namespace: "recovery-invalid-item-\(UUID().uuidString)")
        let reading = try ReadingStore(namespace: "cycle", baseDirectory: root)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zone, pages: pages, database: BookRecordDatabase(), accountIsCurrent: { true })
        let report = try await cycle.run()
        XCTAssertEqual(report.restoredBooks, 1); XCTAssertEqual(report.appliedReadingItems, 1)
        XCTAssertEqual(report.failures.count, 1); XCTAssertGreaterThanOrEqual(report.needsReview, 1)
        let books = await library.catalog(); let book = try XCTUnwrap(books.first)
        XCTAssertEqual(reading.bookmarks[book.id]?.map(\.name), ["Valid"])
        let invalidKey = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .bookmark, itemID: invalid.id)
        XCTAssertTrue(try XCTUnwrap(reading.cloudReadingStore?.outbox[invalidKey.recordName]).pendingApplication == true)
        try await library.remove(book)
    }

    @MainActor func testRecoveryCycleAcknowledgesBooklessDeletionButRetainsReadingData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        let bookRecord = try CloudBookRecordCodec.record(deletion, scope: scope, zoneID: zone)
        let remote = try CloudReadingJournal(scope: scope, baseDirectory: root.appendingPathComponent("remote"))
        let mark = Bookmark(name: "Keep for review", position: ReadingPosition(page: 0))
        let key = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .bookmark, itemID: mark.id)
        try remote.edit(key, payload: .bookmark(mark))
        var entry = try XCTUnwrap(remote.entries[key.recordName]); entry.current.editionFingerprint = String(repeating: "a", count: 64)
        let readingRecord = try CloudReadingRecordCodec.record(entry: entry, bookID: id.readingBookID, zoneID: zone)
        let pages = RecoveryPages([CloudRecoveryPage(records: [bookRecord, readingRecord], deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let library = try LocalLibrary(namespace: "recovery-deleted-\(UUID().uuidString)")
        let reading = try ReadingStore(namespace: "cycle", baseDirectory: root)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let database = BookRecordDatabase()
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zone, pages: pages, database: database, accountIsCurrent: { true })
        let report = try await cycle.run()
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: id)).pendingApplication)
        XCTAssertTrue(try XCTUnwrap(reading.cloudReadingStore?.outbox[key.recordName]).pendingApplication == true)
        XCTAssertGreaterThanOrEqual(report.needsReview, 1)
        XCTAssertEqual(database.saves, 0)
        let books = await library.catalog()
        XCTAssertTrue(books.isEmpty)
        pages.requested.removeAll()
        _ = try await cycle.run()
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: id)).pendingApplication)
        XCTAssertTrue(try XCTUnwrap(reading.cloudReadingStore?.outbox[key.recordName]).pendingApplication == true)
    }

    @MainActor func testRecoveryCycleKeepsDeviceCopyWhenCloudBookWasDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let library = try LocalLibrary(namespace: "recovery-local-deletion-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let id = try await library.ensureCloudIdentity(for: book, scope: scope)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        let record = try CloudBookRecordCodec.record(deletion, scope: scope, zoneID: zone)
        let pages = RecoveryPages([CloudRecoveryPage(records: [record], deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let reading = try ReadingStore(namespace: "cycle", baseDirectory: root)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let database = BookRecordDatabase()
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zone, pages: pages, database: database, accountIsCurrent: { true })
        let report = try await cycle.run()
        XCTAssertTrue(try XCTUnwrap(journal.entry(for: id)).pendingApplication)
        XCTAssertGreaterThanOrEqual(report.needsReview, 1)
        let directory = await library.directory(for: book)
        XCTAssertNotNil(directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertEqual(database.saves, 0)
        let review = StandaloneBookDeletionReview(scope: scope, library: library, journal: journal, accountIsCurrent: { true })
        let listed = StandaloneDeletedBackupItem.collect(journal: journal, books: await library.catalog())
        XCTAssertEqual(listed.count, 1); XCTAssertTrue(try XCTUnwrap(listed.first).needsReview)
        do {
            try await review.resolve(bookID: id, localID: book.id, revision: UUID(), restoreBackup: true)
            XCTFail("A stale deletion must not be restored")
        } catch { }
        try await review.resolve(bookID: id, localID: book.id, revision: deletion.revision, restoreBackup: false)
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: id)).pendingApplication)
        let kept = StandaloneDeletedBackupItem.collect(journal: journal, books: await library.catalog())
        XCTAssertEqual(kept.count, 1); XCTAssertFalse(try XCTUnwrap(kept.first).needsReview)
        let unavailable = StandaloneBookDeletionReview(scope: scope, library: library, journal: journal, accountIsCurrent: { false })
        do {
            try await unavailable.resolve(bookID: id, localID: book.id, revision: deletion.revision, restoreBackup: true)
            XCTFail("A changed account must not restore a backup")
        } catch { }
        try await review.resolve(bookID: id, localID: book.id, revision: deletion.revision, restoreBackup: true)
        let restored = try XCTUnwrap(journal.entry(for: id))
        guard case .book(let metadata) = restored.current else { return XCTFail("The backup should be queued") }
        XCTAssertEqual(restored.baseRevision, deletion.revision); XCTAssertTrue(restored.pending)
        XCTAssertFalse(restored.pendingApplication); XCTAssertTrue(restored.conflicts.isEmpty)
        let staged = try await stager.reopen(bookID: id, revision: metadata.revision)
        XCTAssertEqual(try Data(contentsOf: staged.assetURL), try Data(contentsOf: fixture))
        try await library.remove(book)
    }

    @MainActor func testRecoveryCycleReportsUnmappedAndBooklessReadingData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let remoteID = CloudStandaloneBookID()
        let remoteJournal = try CloudReadingJournal(scope: scope, baseDirectory: root.appendingPathComponent("remote"))
        let mark = Bookmark(name: "Cloud only", position: ReadingPosition(page: 0))
        let key = try CloudReadingKey(scope: scope, bookID: remoteID.readingBookID, kind: .bookmark, itemID: mark.id)
        try remoteJournal.edit(key, payload: .bookmark(mark))
        var version = try XCTUnwrap(remoteJournal.entries[key.recordName]); version.current.editionFingerprint = String(repeating: "a", count: 64)
        let record = try CloudReadingRecordCodec.record(entry: version, bookID: remoteID.readingBookID, zoneID: zone)
        let pages = RecoveryPages([CloudRecoveryPage(records: [record], deletedRecordCount: 0, nextToken: Data([1]), moreComing: false)])
        let library = try LocalLibrary(namespace: "recovery-backlog-\(UUID().uuidString)")
        let reading = try ReadingStore(namespace: "cycle", baseDirectory: root)
        try reading.add(Bookmark(name: "Missing local book", position: ReadingPosition(page: 0)), id: "orphan")
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let database = BookRecordDatabase()
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zone, pages: pages, database: database, accountIsCurrent: { true })
        let report = try await cycle.run()
        XCTAssertGreaterThanOrEqual(report.pendingItems, 2)
        XCTAssertGreaterThanOrEqual(report.needsReview, 2)
        XCTAssertEqual(database.saves, 0)
        let atomic = try XCTUnwrap(reading.cloudReadingStore)
        XCTAssertTrue(atomic.hasUnmappedReadingData)
        XCTAssertTrue(try XCTUnwrap(atomic.outbox[key.recordName]).pendingApplication == true)
    }

    @MainActor func testRecoveryCycleNeverUploadsAfterIncompleteDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let pages = RecoveryPages([CloudRecoveryPage(records: [], deletedRecordCount: 1, nextToken: Data([1]), moreComing: false)])
        let library = try LocalLibrary(namespace: "recovery-incomplete-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let reading = try ReadingStore(namespace: "cycle", baseDirectory: root)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let database = BookRecordDatabase()
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zone, pages: pages, database: database, accountIsCurrent: { true })
        do { _ = try await cycle.run(); XCTFail("An incomplete scan must stop the cycle") } catch {}
        XCTAssertEqual(database.saves, 0); XCTAssertTrue(journal.entries.isEmpty)
        try await library.remove(book)
    }

    @MainActor func testBookConflictListKeepsBothChoicesAndRejectsAmbiguousIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let local = try await stager.stage(source: fixture, bookID: identity, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(local.metadata))
        let remote = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: identity, revision: UUID())
        try await journal.observe(.tombstone(remote))
        var book = LocalBookEntry(id: "local", title: "Device title", format: .pdf)
        book.cloudIdentities = [scope.cloudAccountKey: identity]
        let items = StandaloneBookConflictItem.collect(journal: journal, books: [book])
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.title, "Device title")
        XCTAssertEqual(items.first?.current.revision, local.metadata.revision)
        XCTAssertEqual(items.first?.remote.revision, remote.revision)
        XCTAssertTrue(StandaloneBookConflictItem.collect(journal: journal, books: [book, book]).isEmpty)
    }

    @MainActor func testBookConflictResolutionPreservesDeviceAndSourceOnCloudDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let library = try LocalLibrary(namespace: "conflict-delete-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let identity = try await library.ensureCloudIdentity(for: book, scope: scope)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let local = try await stager.stage(source: fixture, bookID: identity, title: book.title, format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(local.metadata))
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: identity, revision: UUID())
        try await journal.observe(.tombstone(deletion))
        let reading = try ReadingStore(namespace: "restore", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: [book.id: identity.readingBookID])
        let resolver = try StandaloneBookConflictResolution(scope: scope, library: library, reading: reading, journal: journal, accountIsCurrent: { true })
        try await resolver.resolve(bookID: identity, expectedCurrent: local.metadata.revision, remoteRevision: deletion.revision, choice: .remote)
        let selected = try XCTUnwrap(journal.entry(for: identity))
        guard case .tombstone = selected.current else { return XCTFail("Cloud deletion must remain a tombstone") }
        XCTAssertTrue(selected.pending); XCTAssertFalse(selected.pendingApplication)
        let directory = await library.directory(for: book)
        XCTAssertNotNil(directory); XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        try await library.remove(book)
    }

    @MainActor func testBookConflictResolutionRejectsReplacingDifferentEdition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let library = try LocalLibrary(namespace: "conflict-edition-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let identity = try await library.ensureCloudIdentity(for: book, scope: scope)
        let other = root.appendingPathComponent("different.pdf")
        var bytes = try Data(contentsOf: fixture); bytes.append(Data("\n% synthetic edition\n".utf8)); try bytes.write(to: other)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let local = try await stager.stage(source: fixture, bookID: identity, title: book.title, format: .pdf)
        let remote = try await stager.stage(source: other, bookID: identity, title: "Other edition", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(local.metadata)); try await journal.observe(.book(remote.metadata))
        let reading = try ReadingStore(namespace: "restore", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: [book.id: identity.readingBookID])
        let resolver = try StandaloneBookConflictResolution(scope: scope, library: library, reading: reading, journal: journal, accountIsCurrent: { true })
        do { try await resolver.resolve(bookID: identity, expectedCurrent: local.metadata.revision, remoteRevision: remote.metadata.revision, choice: .remote); XCTFail("Different editions cannot replace a local copy") } catch {}
        let unchanged = try XCTUnwrap(journal.entry(for: identity))
        XCTAssertEqual(unchanged.current.revision, local.metadata.revision); XCTAssertEqual(unchanged.conflicts.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: local.assetURL))
        try await library.remove(book)
    }

    @MainActor func testResolvedRemoteBookCanBeAppliedBeforeItsConditionalUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let remote = try await stager.stage(source: fixture, bookID: identity, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let local = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: identity, revision: UUID())
        try await journal.edit(.tombstone(local)); try await journal.observe(.book(remote.metadata))
        try await journal.resolveConflict(bookID: identity, expectedLocalRevision: local.revision, remoteRevision: remote.metadata.revision, choice: .remote, validateBeforeCommit: { })
        let selected = try XCTUnwrap(journal.entry(for: identity))
        XCTAssertTrue(selected.pending); XCTAssertTrue(selected.pendingApplication)
        let reading = try ReadingStore(namespace: "restore", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: [:])
        let library = try LocalLibrary(namespace: "resolved-book-\(UUID().uuidString)")
        let application = try StandaloneRecoveryApplication(scope: scope, library: library, reading: reading, journal: journal, accountIsCurrent: { true })
        let result = try await application.restore(identity)
        let finished = try XCTUnwrap(journal.entry(for: identity))
        XCTAssertFalse(finished.pendingApplication); XCTAssertTrue(finished.pending)
        XCTAssertEqual(finished.current.revision, selected.current.revision)
        XCTAssertEqual(result.book.cloudIdentities?[scope.cloudAccountKey], identity)
        XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: remote.assetURL))
        try await library.remove(result.book)
    }

    @MainActor func testRestoreStopsWhenAnotherSessionDeletesBookDuringPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: identity, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.observe(.book(staged.metadata))
        let other = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: identity, revision: UUID())
        let reading = try ReadingStore(namespace: "restore", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: [:])
        let library = try LocalLibrary(namespace: "stale-restore-\(UUID().uuidString)")
        var checks = 0
        let application = try StandaloneRecoveryApplication(scope: scope, library: library, reading: reading, journal: journal, accountIsCurrent: {
            checks += 1
            if checks == 2 { try await other.edit(.tombstone(deletion)) }
            return true
        })
        do { _ = try await application.restore(identity); XCTFail("A stale restore must stop before importing") } catch {}
        let catalog = await library.catalog()
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertEqual(other.entry(for: identity)?.current, .tombstone(deletion))
        XCTAssertTrue(reading.cloudReadingStore?.localToCloudBookIDs?.isEmpty == true)
    }

    @MainActor func testBookConflictDoesNotCommitWhenAccountChangesDuringStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let remote = try await stager.stage(source: fixture, bookID: identity, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let local = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: identity, revision: UUID())
        try await journal.edit(.tombstone(local)); try await journal.observe(.book(remote.metadata))
        var validationCalled = false
        do {
            try await journal.resolveConflict(bookID: identity, expectedLocalRevision: local.revision,
                remoteRevision: remote.metadata.revision, choice: .remote, validateBeforeCommit: {
                    validationCalled = true
                    throw ReaderError.message("Account changed")
                })
            XCTFail("Account change must prevent the journal commit")
        } catch { }
        XCTAssertTrue(validationCalled)
        let unchanged = try XCTUnwrap(journal.entry(for: identity))
        XCTAssertEqual(unchanged.current.revision, local.revision)
        XCTAssertEqual(unchanged.conflicts.map(\.revision), [remote.metadata.revision])
        let reopened = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        XCTAssertEqual(reopened.entry(for: identity)?.current.revision, local.revision)
        XCTAssertEqual(reopened.entry(for: identity)?.conflicts.map(\.revision), [remote.metadata.revision])
        XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: remote.assetURL))
    }

    @MainActor func testBookJournalChecksAccountAfterPinningBeforeEditOrObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        var checks = 0
        let accountChanged: @MainActor () async throws -> Void = {
            checks += 1
            throw ReaderError.message("Account changed")
        }
        do {
            try await journal.edit(.book(staged.metadata), expecting: .missing, validateBeforeCommit: accountChanged)
            XCTFail("An account change must prevent queueing")
        } catch { }
        do {
            try await journal.observe(.book(staged.metadata), validateBeforeCommit: accountChanged)
            XCTFail("An account change must prevent recording a discovered book")
        } catch { }
        XCTAssertEqual(checks, 2)
        XCTAssertNil(journal.entry(for: id))
        let reopened = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        XCTAssertNil(reopened.entry(for: id))
        XCTAssertEqual(try Data(contentsOf: staged.assetURL), try Data(contentsOf: fixture))
    }

    @MainActor func testApplicationRestoresBookAndOnlyMatchingEditionReadingData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: identity, title: "Recovered", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.observe(.book(staged.metadata))
        let reading = try ReadingStore(namespace: "restore", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: [:])
        let atomic = try XCTUnwrap(reading.cloudReadingStore)
        let first = Bookmark(name: "Matching", position: ReadingPosition(page: 0))
        let other = Bookmark(name: "Other edition", position: ReadingPosition(page: 0))
        let invalid = Bookmark(name: "Invalid page", position: ReadingPosition(page: -1))
        let matchingKey = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: first.id)
        let otherKey = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: other.id)
        let invalidKey = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: invalid.id)
        try atomic.observe(matchingKey, bookID: identity.readingBookID, remote: CloudReadingVersion(revision: UUID(), payload: .bookmark(first), editionFingerprint: staged.metadata.sha256))
        try atomic.observe(otherKey, bookID: identity.readingBookID, remote: CloudReadingVersion(revision: UUID(), payload: .bookmark(other), editionFingerprint: String(repeating: "b", count: 64)))
        try atomic.observe(invalidKey, bookID: identity.readingBookID, remote: CloudReadingVersion(revision: UUID(), payload: .bookmark(invalid), editionFingerprint: staged.metadata.sha256))
        let library = try LocalLibrary(namespace: "recovery-application-\(UUID().uuidString)")
        let application = try StandaloneRecoveryApplication(scope: scope, library: library, reading: reading, journal: journal, accountIsCurrent: { true })
        let result = try await application.restore(identity)
        XCTAssertEqual(result.book.cloudIdentities?[scope.cloudAccountKey], identity)
        XCTAssertEqual(result.appliedReadingItems, 1); XCTAssertEqual(result.readingItemsNeedingReview, 1)
        XCTAssertEqual(result.readingItemFailures.count, 1)
        XCTAssertEqual(reading.bookmarks[result.book.id]?.map(\.name), ["Matching"])
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: identity)).pendingApplication)
        XCTAssertTrue(try XCTUnwrap(atomic.outbox[otherKey.recordName]).pendingApplication == true)
        XCTAssertTrue(try XCTUnwrap(atomic.outbox[invalidKey.recordName]).pendingApplication == true)
        let incoming = StandaloneIncomingReadingItem.collect(store: atomic, books: [result.book])
        XCTAssertEqual(Set(incoming.map(\.key.recordName)), Set([otherKey.recordName, invalidKey.recordName]))
        XCTAssertTrue(StandaloneIncomingReadingItem.collect(store: atomic, books: [result.book, result.book]).isEmpty)
        let replay = try await application.restore(identity)
        XCTAssertEqual(replay.book.id, result.book.id); XCTAssertEqual(replay.appliedReadingItems, 0)
        XCTAssertEqual(replay.readingItemsNeedingReview, 1)
        XCTAssertEqual(replay.readingItemFailures.count, 1)
        XCTAssertEqual(reading.bookmarks[result.book.id]?.map(\.name), ["Matching"])
        try await library.remove(result.book)
    }

    @MainActor func testApplicationDoesNotRestoreCloudTombstone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let identity = CloudStandaloneBookID()
        try await journal.observe(.tombstone(CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: identity, revision: UUID())))
        let reading = try ReadingStore(namespace: "restore", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: [:])
        let library = try LocalLibrary(namespace: "recovery-tombstone-\(UUID().uuidString)")
        let application = try StandaloneRecoveryApplication(scope: scope, library: library, reading: reading, journal: journal, accountIsCurrent: { true })
        do { _ = try await application.restore(identity); XCTFail("Deletion requires review") } catch {}
        let catalog = await library.catalog()
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertTrue(try XCTUnwrap(journal.entry(for: identity)).pendingApplication)
    }

    @MainActor func testBookJournalDoesNotWriteWhileAnotherSessionHoldsLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let lock = journal.file.deletingLastPathComponent().appendingPathComponent("journal.lock")
        let descriptor = open(lock.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let id = CloudStandaloneBookID()
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        do { try await journal.edit(.tombstone(deletion)); XCTFail("A locked journal must reject this write") } catch {}
        XCTAssertNil(journal.entry(for: id))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        try await journal.edit(.tombstone(deletion))
        XCTAssertEqual(journal.entry(for: id)?.current, .tombstone(deletion))
    }
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Harbor.pdf")
    }

    @MainActor final class BookRecordDatabase: CloudReadingRecordDatabase {
        var value: CKRecord?
        var forcedConflict: CKRecord?
        var duringSave: (() async throws -> Void)?
        var saves = 0
        var attempts = 0
        func fetch(_ id: CKRecord.ID) async throws -> CKRecord? {
            guard let value, value.recordID == id else { return nil }
            return value.copy() as? CKRecord
        }
        func saveIfUnchanged(_ record: CKRecord) async throws -> CloudReadingRecordSaveResult {
            attempts += 1
            try await duringSave?()
            if let forcedConflict { value = forcedConflict; return .conflict(forcedConflict) }
            saves += 1; value = record.copy() as? CKRecord; return .saved
        }
    }

    @MainActor func testBookTransportRetainsTombstoneAgainstStaleUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let lease = try await stager.lease(bookID: id, revision: staged.metadata.revision)
        let database = BookRecordDatabase()
        var removalWasBlocked = false
        database.duringSave = {
            do { try await stager.discard(bookID: id, revision: staged.metadata.revision) }
            catch { removalWasBlocked = true }
        }
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: zone, database: database, stager: stager, pinOwner: UUID(), accountIsCurrent: { true })
        guard case .saved = try await transport.upload(.book(lease), expected: nil) else { return XCTFail("Expected upload") }
        XCTAssertTrue(removalWasBlocked)
        database.duringSave = nil
        let tombstone = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        guard case .saved = try await transport.upload(.tombstone(tombstone), expected: staged.metadata.revision) else { return XCTFail("Expected deletion record") }
        guard case .conflict(.tombstone(let remote)) = try await transport.upload(.book(lease), expected: staged.metadata.revision) else { return XCTFail("Stale upload must not resurrect the book") }
        XCTAssertEqual(remote, tombstone)
        XCTAssertEqual(database.saves, 2)
        XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: staged.assetURL))
    }

    @MainActor func testBookTransportStagesConflictingRemoteAssetBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let sender = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let receiver = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("receiver"))
        let staged = try await sender.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let database = BookRecordDatabase()
        database.forcedConflict = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone)
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: zone, database: database, stager: receiver, pinOwner: UUID(), accountIsCurrent: { true })
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        guard case .conflict(.book(let received)) = try await transport.upload(.tombstone(deletion), expected: nil) else { return XCTFail("The remote book must remain available for review") }
        XCTAssertEqual(received.metadata, staged.metadata)
        XCTAssertNotEqual(received.assetURL, staged.assetURL)
        XCTAssertEqual(try Data(contentsOf: received.assetURL), try Data(contentsOf: fixture))
        let reopened = try await receiver.reopen(bookID: id, revision: staged.metadata.revision)
        XCTAssertEqual(reopened.metadata, staged.metadata)
        do { try await receiver.discard(bookID: id, revision: staged.metadata.revision); XCTFail("The received conflict must be pinned before it is returned") } catch {}
        XCTAssertEqual(database.saves, 0)
    }

    @MainActor func testBookCoordinatorPreservesDeletionMadeDuringUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(staged.metadata))
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        let database = BookRecordDatabase()
        database.duringSave = { try await journal.edit(.tombstone(deletion)) }
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: zone, database: database, stager: stager, pinOwner: journal.owner, accountIsCurrent: { true })
        let coordinator = try CloudBookSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: { true })
        await coordinator.sync()
        XCTAssertEqual(coordinator.status, .pending)
        XCTAssertEqual(journal.entry(for: id)?.current, .tombstone(deletion))
        XCTAssertEqual(journal.entry(for: id)?.baseRevision, staged.metadata.revision)
        database.duringSave = nil
        await coordinator.sync()
        XCTAssertEqual(coordinator.status, .idle)
        let saved = try XCTUnwrap(database.value)
        guard case .tombstone(let remote) = try CloudBookRecordCodec.decodeValue(saved, scope: scope) else { return XCTFail("The cloud deletion must be retained") }
        XCTAssertEqual(remote, deletion)
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: id)).pending)
    }

    @MainActor func testStandalonePreparationMigratesReadingDataAndQueuesBookOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let library = try LocalLibrary(namespace: "cloud-preparation-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let reading = try ReadingStore(namespace: "standalone", baseDirectory: root)
        let position = ReadingPosition(page: 3)
        try reading.set(ReadingRecord(position: position, acknowledgedTicks: 0, dirty: false, updated: Date(), title: book.title, format: .pdf), id: book.id)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let service = try StandaloneRecoveryPreparation(scope: scope, library: library, reading: reading, stager: stager, journal: journal, accountIsCurrent: { true })
        try await service.prepare()
        let catalog = await library.catalog()
        let identity = try XCTUnwrap(catalog.first?.cloudIdentities?[scope.cloudAccountKey])
        XCTAssertEqual(reading.records[book.id]?.position, position)
        XCTAssertEqual(reading.cloudReadingStore?.localToCloudBookIDs?[book.id], identity.readingBookID)
        let queued = try await service.queueBook(book)
        XCTAssertTrue(queued)
        let first = try XCTUnwrap(journal.entry(for: identity))
        XCTAssertTrue(first.pending)
        let repeated = try await service.queueBook(book)
        XCTAssertFalse(repeated)
        XCTAssertEqual(journal.entry(for: identity)?.current.revision, first.current.revision)
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: identity, revision: UUID())
        try await journal.edit(.tombstone(deletion))
        do { _ = try await service.queueBook(book); XCTFail("A tombstone must not be silently replaced") } catch {}
        XCTAssertEqual(journal.entry(for: identity)?.current, .tombstone(deletion))
        XCTAssertEqual(reading.records[book.id]?.position, position)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    @MainActor func testStandalonePreparationRejectsDifferentAccountWithoutBlockingLocalReading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstScope = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let otherScope = try CloudReadingScope(cloudUserRecordName: "other", source: .imported)
        let library = try LocalLibrary(namespace: "cloud-account-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let reading = try ReadingStore(namespace: "standalone", baseDirectory: root)
        try reading.prepareAtomicReading(scope: firstScope, localToCloudBookIDs: [:])
        let stager = try CloudBookStager(scope: otherScope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: otherScope, stager: stager, baseDirectory: root)
        let service = try StandaloneRecoveryPreparation(scope: otherScope, library: library, reading: reading, stager: stager, journal: journal, accountIsCurrent: { true })
        do { try await service.prepare(); XCTFail("A different iCloud account must not adopt this reading archive") } catch {}
        let bookmark = Bookmark(name: "Still local", position: ReadingPosition(page: 1))
        try reading.add(bookmark, id: book.id)
        XCTAssertEqual(reading.bookmarks[book.id]?.first?.name, "Still local")
        XCTAssertTrue(try XCTUnwrap(reading.cloudReadingStore).hasUnmappedReadingData)
        let catalog = await library.catalog()
        XCTAssertNil(catalog.first?.cloudIdentities?[otherScope.cloudAccountKey])
    }

    @MainActor func testStagedBookCannotOverwriteNewerDeletionAfterPreparationRace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        try await journal.edit(.tombstone(deletion))
        do { try await journal.edit(.book(staged.metadata), expecting: .missing); XCTFail("A newer deletion must block a stale staged upload") } catch {}
        XCTAssertEqual(journal.entry(for: id)?.current, .tombstone(deletion))
        XCTAssertTrue(try XCTUnwrap(journal.entry(for: id)).pending)
    }

    @MainActor func testBookCoordinatorRestoresStagedRemoteAndRecordsApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let sender = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("sender"))
        let receiver = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("receiver"))
        let staged = try await sender.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: receiver, baseDirectory: root)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let database = BookRecordDatabase()
        database.value = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone)
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: zone, database: database, stager: receiver, pinOwner: journal.owner, accountIsCurrent: { true })
        let coordinator = try CloudBookSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: { true })
        await coordinator.sync()
        XCTAssertEqual(coordinator.status, .needsApplication)
        let received = try await receiver.reopen(bookID: id, revision: staged.metadata.revision)
        let library = try LocalLibrary(namespace: "cloud-coordinator-\(UUID().uuidString)")
        let restored = try await library.restoreCloudBook(received, scope: scope)
        XCTAssertEqual(restored.cloudIdentities?[scope.cloudAccountKey], id)
        XCTAssertThrowsError(try journal.markApplied(bookID: id, revision: UUID()))
        try journal.markApplied(bookID: id, revision: staged.metadata.revision)
        let reopened = try CloudBookJournal(scope: scope, stager: receiver, baseDirectory: root)
        XCTAssertFalse(try XCTUnwrap(reopened.entry(for: id)).pendingApplication)
        XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: received.assetURL))
    }

    @MainActor func testBookCoordinatorDoesNotAcknowledgeWhenAccountChangesDuringSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(staged.metadata))
        let database = BookRecordDatabase()
        var current = true
        database.duringSave = { current = false }
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: zone, database: database, stager: stager, pinOwner: journal.owner, accountIsCurrent: { current })
        let coordinator = try CloudBookSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: { current })
        await coordinator.sync()
        XCTAssertEqual(coordinator.status, .accountChanged)
        XCTAssertTrue(try XCTUnwrap(journal.entry(for: id)).pending)
        let reopened = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        XCTAssertTrue(try XCTUnwrap(reopened.entry(for: id)).pending)
        current = true; database.duringSave = nil
        await coordinator.sync()
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: id)).pending)
        XCTAssertEqual(database.saves, 1, "A readback should acknowledge an already-saved version without uploading twice")
    }

    @MainActor func testBookCoordinatorDoesNotAcknowledgeIfAccountCheckCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(staged.metadata))
        let database = BookRecordDatabase()
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: scope.recoveryZoneID,
                                                   database: database, stager: stager, pinOwner: journal.owner, accountIsCurrent: { true })
        var operation: Task<Void, Never>?
        var checks = 0
        var interrupt = true
        let coordinator = try CloudBookSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: {
            checks += 1
            if interrupt && checks == 4 { operation?.cancel() }
            return true
        })
        operation = Task { await coordinator.sync() }
        await operation?.value
        XCTAssertEqual(database.saves, 1)
        XCTAssertTrue(try XCTUnwrap(journal.entry(for: id)).pending)
        interrupt = false
        await coordinator.sync()
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: id)).pending)
        XCTAssertEqual(database.saves, 1)
    }

    @MainActor func testStaleBookJournalCannotReplayOrUploadAfterNewerDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let first = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        try await first.edit(.book(staged.metadata))
        let stale = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        try await first.edit(.tombstone(deletion))
        do { try await stale.edit(.book(staged.metadata)); XCTFail("Stale replay must fail") } catch {}
        let database = BookRecordDatabase()
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: scope.recoveryZoneID,
                                                   database: database, stager: stager, pinOwner: stale.owner, accountIsCurrent: { true })
        let sync = try CloudBookSyncCoordinator(journal: stale, transport: transport, accountIsCurrent: { true })
        await sync.sync()
        guard case .failed = sync.status else { return XCTFail("A stale journal must stop before upload") }
        XCTAssertEqual(database.attempts, 0)
        XCTAssertEqual(first.entry(for: id)?.current, .tombstone(deletion))
    }

    @MainActor func testBookSyncRechecksChangeAfterAccountFence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let old = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        let newer = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        try await journal.edit(.tombstone(old))
        let database = BookRecordDatabase()
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: scope.recoveryZoneID,
                                                   database: database, stager: stager, pinOwner: journal.owner, accountIsCurrent: { true })
        var checks = 0
        let sync = try CloudBookSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: {
            checks += 1
            if checks == 3 { try await journal.edit(.tombstone(newer)) }
            return true
        })
        await sync.sync()
        XCTAssertEqual(sync.status, .pending); XCTAssertEqual(database.attempts, 0)
        XCTAssertEqual(journal.entry(for: id)?.current, .tombstone(newer))
        await sync.sync()
        XCTAssertEqual(sync.status, .idle); XCTAssertEqual(database.saves, 1)
    }

    @MainActor func testBookCoordinatorAcknowledgesRacingIdenticalRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(staged.metadata))
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let database = BookRecordDatabase()
        database.forcedConflict = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone)
        let transport = try CloudKitBookTransport(scope: scope, bookID: id, zoneID: zone, database: database, stager: stager, pinOwner: journal.owner, accountIsCurrent: { true })
        let coordinator = try CloudBookSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: { true })
        await coordinator.sync()
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertFalse(try XCTUnwrap(journal.entry(for: id)).pending)
    }

    func testBookTombstoneRetainsIdentityAndNeverDeletesSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let id = CloudStandaloneBookID()
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let bytes = try Data(contentsOf: fixture)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let record = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone)
        let tombstone = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        let deleted = try CloudBookRecordCodec.record(tombstone, scope: scope, zoneID: zone, existing: record)
        XCTAssertEqual(deleted.recordID.recordName, staged.metadata.recordName)
        XCTAssertNil(deleted["bookFile"])
        XCTAssertNil(deleted.encryptedValues["metadata"])
        guard case .tombstone(let decoded) = try CloudBookRecordCodec.decodeValue(deleted, scope: scope) else { return XCTFail("Expected a tombstone") }
        XCTAssertEqual(decoded, tombstone)
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
        XCTAssertEqual(try Data(contentsOf: staged.assetURL), bytes)
        let restored = try await CloudBookRecordCodec.record(staged, scope: scope, zoneID: zone, existing: deleted)
        XCTAssertNil(restored.encryptedValues["tombstone"])
        guard case .book(let metadata, _) = try CloudBookRecordCodec.decodeValue(restored, scope: scope) else { return XCTFail("Expected a book") }
        XCTAssertEqual(metadata, staged.metadata)
        restored.encryptedValues["tombstone"] = try JSONEncoder().encode(tombstone) as CKRecordValue
        XCTAssertThrowsError(try CloudBookRecordCodec.decodeValue(restored, scope: scope))
        let other = try CloudReadingScope(cloudUserRecordName: "other", source: .imported)
        XCTAssertThrowsError(try CloudBookRecordCodec.record(tombstone, scope: other, zoneID: zone))
    }

    func testAssetLeasePreventsConcurrentStagingRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: .init(), title: "Book", format: .pdf)
        let other = try CloudBookStager(scope: scope, baseDirectory: root)
        var lease: CloudBookAssetLease? = try await stager.lease(bookID: staged.metadata.bookID, revision: staged.metadata.revision)
        do { try await other.discard(bookID: staged.metadata.bookID, revision: staged.metadata.revision); XCTFail("An asset in use must not be removed") } catch {}
        XCTAssertEqual(lease?.staged.metadata, staged.metadata)
        lease = nil
        try await other.discard(bookID: staged.metadata.bookID, revision: staged.metadata.revision)
        do { _ = try await stager.reopen(bookID: staged.metadata.bookID, revision: staged.metadata.revision); XCTFail("Discarded staging must not reopen") } catch {}
    }

    func testRecoveryPinsSurviveRestartAndRequireEveryOwnerToRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let first = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await first.stage(source: fixture, bookID: .init(), title: "Book", format: .pdf)
        let ownerA = UUID(), ownerB = UUID()
        try await first.pin(bookID: staged.metadata.bookID, revision: staged.metadata.revision, owner: ownerA)
        try await first.pin(bookID: staged.metadata.bookID, revision: staged.metadata.revision, owner: ownerB)
        let reopened = try CloudBookStager(scope: scope, baseDirectory: root)
        do { try await reopened.discard(bookID: staged.metadata.bookID, revision: staged.metadata.revision); XCTFail("Pinned data must survive restart") } catch {}
        try await reopened.unpin(bookID: staged.metadata.bookID, revision: staged.metadata.revision, owner: ownerA)
        do { try await reopened.discard(bookID: staged.metadata.bookID, revision: staged.metadata.revision); XCTFail("Another owner still needs the data") } catch {}
        try await reopened.unpin(bookID: staged.metadata.bookID, revision: staged.metadata.revision, owner: ownerB)
        try await reopened.discard(bookID: staged.metadata.bookID, revision: staged.metadata.revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testExistingPinCanBeRevalidatedWhileAssetIsLeased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: .init(), title: "Book", format: .pdf)
        let owner = UUID()
        try await stager.pin(bookID: staged.metadata.bookID, revision: staged.metadata.revision, owner: owner)
        let lease = try await stager.lease(bookID: staged.metadata.bookID, revision: staged.metadata.revision)
        try await stager.pin(bookID: staged.metadata.bookID, revision: staged.metadata.revision, owner: owner, expected: staged.metadata)
        do { try await stager.pin(bookID: staged.metadata.bookID, revision: staged.metadata.revision, owner: UUID()); XCTFail("A new pin cannot race an active lease") } catch {}
        XCTAssertEqual(lease.staged.metadata, staged.metadata)
    }

    @MainActor func testBookJournalKeepsPendingDeletionAndConflictAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let id = CloudStandaloneBookID()
        let first = try await stager.stage(source: fixture, bookID: id, title: "Book", format: .pdf)
        let remote = try await stager.stage(source: fixture, bookID: id, title: "Remote", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let stale = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        try await journal.edit(.book(first.metadata))
        let deletion = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        try await journal.edit(.tombstone(deletion))
        try journal.acknowledge(bookID: id, revision: first.metadata.revision)
        try await journal.observe(.book(remote.metadata))
        let reopened = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let entry = try XCTUnwrap(reopened.entry(for: id))
        XCTAssertEqual(entry.current, .tombstone(deletion))
        XCTAssertEqual(entry.baseRevision, first.metadata.revision)
        XCTAssertTrue(entry.pending)
        XCTAssertEqual(entry.pendingRevisions, [deletion.revision])
        XCTAssertEqual(entry.conflicts, [.book(remote.metadata)])
        do { try await stale.edit(.tombstone(deletion)); XCTFail("A stale journal must not overwrite newer state") } catch {}
        do { try await stager.discard(bookID: id, revision: first.metadata.revision); XCTFail("The pending asset must remain pinned") } catch {}
        do { try await stager.discard(bookID: id, revision: remote.metadata.revision); XCTFail("The conflict asset must remain pinned") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    @MainActor func testBookConflictResolutionCopiesChosenAssetAndRequiresApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let remote = try await stager.stage(source: fixture, bookID: id, title: "Remote", format: .pdf)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        let local = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
        try await journal.edit(.tombstone(local))
        try await journal.observe(.book(remote.metadata))
        do {
            try await journal.resolveConflict(bookID: id, expectedLocalRevision: UUID(), remoteRevision: remote.metadata.revision, choice: .remote, validateBeforeCommit: { })
            XCTFail("A stale choice must be rejected")
        } catch {}
        try await journal.resolveConflict(bookID: id, expectedLocalRevision: local.revision, remoteRevision: remote.metadata.revision, choice: .remote, validateBeforeCommit: { })
        let resolved = try XCTUnwrap(journal.entry(for: id))
        guard case .book(let metadata) = resolved.current else { return XCTFail("The reviewed book should be retained") }
        XCTAssertNotEqual(metadata.revision, remote.metadata.revision)
        XCTAssertEqual(metadata.sha256, remote.metadata.sha256)
        XCTAssertTrue(resolved.pending)
        XCTAssertTrue(resolved.pendingApplication)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        let copy = try await stager.reopen(bookID: id, revision: metadata.revision)
        let library = try LocalLibrary(namespace: "cloud-conflict-\(UUID().uuidString)")
        _ = try await library.restoreCloudBook(copy, scope: scope)
        try journal.markApplied(bookID: id, revision: metadata.revision)
        let reopened = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root)
        XCTAssertFalse(try XCTUnwrap(reopened.entry(for: id)).pendingApplication)
        XCTAssertTrue(try XCTUnwrap(reopened.entry(for: id)).pending)
        do { try await stager.discard(bookID: id, revision: remote.metadata.revision); XCTFail("The original conflict must remain recoverable") } catch {}
    }

    @MainActor func testArchiveBookConflictResolutionRetainsEPUBAndCBZBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let script = project.appendingPathComponent("App/Resources/Archive/jszip.min.js")
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let journal = try CloudBookJournal(scope: scope, stager: stager, baseDirectory: root, archiveScript: script)
        for format in [BookFormat.epub, .cbz] {
            let id = CloudStandaloneBookID()
            let source = project.appendingPathComponent("Fixtures/Harbor.\(format.rawValue)")
            let remote = try await stager.stage(source: source, bookID: id, title: "Book", format: format, archiveScript: script)
            let local = CloudBookTombstone(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: id, revision: UUID())
            try await journal.edit(.tombstone(local))
            try await journal.observe(.book(remote.metadata))
            try await journal.resolveConflict(bookID: id, expectedLocalRevision: local.revision, remoteRevision: remote.metadata.revision, choice: .remote, validateBeforeCommit: { })
            guard case .book(let metadata) = try XCTUnwrap(journal.entry(for: id)).current else { return XCTFail("Expected resolved archive") }
            let staged = try await stager.reopen(bookID: id, revision: metadata.revision)
            XCTAssertEqual(try Data(contentsOf: staged.assetURL), try Data(contentsOf: source))
        }
    }

    func testNewCloudIdentitiesAreStableDistinctAndAccountScoped() async throws {
        let namespace = "cloud-identity-\(UUID().uuidString)"
        let library = try LocalLibrary(namespace: namespace)
        let first = try await library.importFile(fixture, folderBookID: "folder-a")
        let second = try await library.importFile(fixture, folderBookID: "folder-b")
        let stale = try LocalLibrary(namespace: namespace)
        let scope = try CloudReadingScope(cloudUserRecordName: "account-a", source: .imported)
        let otherScope = try CloudReadingScope(cloudUserRecordName: "account-b", source: .imported)
        let id = try await library.ensureCloudIdentity(for: first, scope: scope)
        do { _ = try await stale.ensureCloudIdentity(for: second, scope: scope); XCTFail("A stale catalog must not replace a newer identity") } catch {}
        let again = try await library.ensureCloudIdentity(for: first, scope: scope)
        let otherBook = try await library.ensureCloudIdentity(for: second, scope: scope)
        let otherAccount = try await library.ensureCloudIdentity(for: first, scope: otherScope)
        XCTAssertEqual(id, again)
        XCTAssertNotEqual(id, otherBook)
        XCTAssertNotEqual(id, otherAccount)
        let reopened = try LocalLibrary(namespace: namespace)
        let reopenedID = try await reopened.ensureCloudIdentity(for: first, scope: scope)
        XCTAssertEqual(reopenedID, id)
        let serverScope = try CloudReadingScope(cloudUserRecordName: "account-a", source: .jellyfin(serverID: "server", userID: "user"))
        do { _ = try await reopened.ensureCloudIdentity(for: first, scope: serverScope); XCTFail("Server scopes cannot own standalone files") } catch {}
    }

    @MainActor func testReadingStoreCertifiesOnlyVerifiedRetainedBytesAndCorrectScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LocalLibrary(namespace: "cloud-proof-\(UUID().uuidString)")
        let book = try await library.importFile(fixture, folderBookID: "local-book")
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = try await library.ensureCloudIdentity(for: book, scope: scope)
        let reading = try ReadingStore(namespace: "proof", baseDirectory: root)
        try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: [book.id: identity.readingBookID])
        let digest = try await reading.verifyStandaloneEdition(book, library: library, scope: scope)
        XCTAssertEqual(digest, book.contentDigest)
        let bookmark = Bookmark(name: "Verified", position: ReadingPosition(page: 1))
        try reading.add(bookmark, id: book.id)
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: bookmark.id)
        XCTAssertEqual(reading.cloudReadingStore?.outbox[key.recordName]?.entry.current.editionFingerprint, digest)
        let retainedURL = await library.originalFile(for: book)
        let retained = try XCTUnwrap(retainedURL)
        try Data("damaged".utf8).write(to: retained)
        do { _ = try await reading.verifyStandaloneEdition(book, library: library, scope: scope); XCTFail("Changed bytes must fail verification") } catch {}
        try reading.renameBookmark(bookmark, id: book.id, name: "Still local")
        XCTAssertNil(reading.cloudReadingStore?.outbox[key.recordName]?.entry.current.editionFingerprint)
        let otherScope = try CloudReadingScope(cloudUserRecordName: "other", source: .imported)
        do { _ = try await reading.verifyStandaloneEdition(book, library: library, scope: otherScope); XCTFail("A different account must not certify the book") } catch {}
        XCTAssertEqual(reading.bookmarks[book.id]?.first?.name, "Still local")
    }

    func testRestoreKeepsEqualCloudBooksDistinctAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = "cloud-restore-\(UUID().uuidString)"
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let firstID = CloudStandaloneBookID(), secondID = CloudStandaloneBookID()
        let first = try await stager.stage(source: fixture, bookID: firstID, title: "First", format: .pdf)
        let second = try await stager.stage(source: fixture, bookID: secondID, title: "Second", format: .pdf)
        let original = try Data(contentsOf: fixture)
        let library = try LocalLibrary(namespace: namespace)
        let a = try await library.restoreCloudBook(first, scope: scope)
        let b = try await library.restoreCloudBook(second, scope: scope)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.cloudIdentities?[scope.cloudAccountKey], firstID)
        XCTAssertEqual(b.cloudIdentities?[scope.cloudAccountKey], secondID)
        XCTAssertEqual(a.folderSource, false)
        let reopened = try LocalLibrary(namespace: namespace)
        let again = try await reopened.restoreCloudBook(first, scope: scope)
        XCTAssertEqual(again.id, a.id)
        let catalog = await reopened.catalog()
        XCTAssertEqual(catalog.count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture), original)
        let other = try CloudReadingScope(cloudUserRecordName: "other", source: .imported)
        do { _ = try await reopened.restoreCloudBook(first, scope: other); XCTFail("A different account must not restore this asset") } catch {}
        try Data("corrupt".utf8).write(to: second.assetURL)
        do { _ = try await reopened.restoreCloudBook(second, scope: scope); XCTFail("Corrupt staged bytes must not be restored") } catch {}
        let catalogAfterFailure = await reopened.catalog()
        XCTAssertEqual(catalogAfterFailure.count, 2)
    }

    func testRestoredArchivesRetainOriginalAndReadableContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let script = project.appendingPathComponent("App/Resources/Archive/jszip.min.js")
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let library = try LocalLibrary(namespace: "cloud-archive-restore-\(UUID().uuidString)", archiveScript: script)
        for format in [BookFormat.epub, .cbz] {
            let source = project.appendingPathComponent("Fixtures/Harbor.\(format.rawValue)")
            let staged = try await stager.stage(source: source, bookID: .init(), title: "Fixture", format: format, archiveScript: script)
            let entry = try await library.restoreCloudBook(staged, scope: scope)
            let savedDirectory = await library.directory(for: entry)
            let saved = try XCTUnwrap(savedDirectory)
            _ = try BookCache.contents(saved, format: format)
            let originalFile = await library.originalFile(for: entry)
            let retained = try XCTUnwrap(originalFile)
            XCTAssertEqual(try Data(contentsOf: retained), try Data(contentsOf: source))
        }
    }

    func testRestoreDoesNotAdoptUnboundLocalBookWithSameIDAndBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let staged = try await stager.stage(source: fixture, bookID: id, title: "Cloud", format: .pdf)
        let library = try LocalLibrary(namespace: "cloud-collision-\(UUID().uuidString)")
        let local = try await library.importFile(fixture, folderBookID: id.readingBookID)
        do { _ = try await library.restoreCloudBook(staged, scope: scope); XCTFail("An unbound local item must not be adopted automatically") } catch {}
        let catalog = await library.catalog()
        XCTAssertEqual(catalog.count, 1)
        XCTAssertNil(catalog.first?.cloudIdentities?[scope.cloudAccountKey])
        XCTAssertEqual(catalog.first?.id, local.id)
    }

    func testRestoreRejectsMismatchedOrphanCopyWithoutReplacingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = "cloud-orphan-\(UUID().uuidString)"
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let orphan = Book(id: identity.readingBookID, title: "Orphan", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        let storage = try DurableBookStore(namespace: namespace)
        let original = try Data(contentsOf: fixture)
        let saved = try await storage.install(fixture, book: orphan, retainOriginal: true)
        let different = root.appendingPathComponent("different.pdf")
        var bytes = original; bytes.append(Data("\n% different edition\n".utf8))
        try bytes.write(to: different)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("stage"))
        let staged = try await stager.stage(source: different, bookID: identity, title: "Cloud", format: .pdf)
        let library = try LocalLibrary(namespace: namespace)
        do { _ = try await library.restoreCloudBook(staged, scope: scope); XCTFail("A mismatched orphan must not be adopted") } catch {}
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("book.pdf")), original)
        let catalog = await library.catalog()
        XCTAssertTrue(catalog.isEmpty)
    }

    func testExplicitAdoptionKeepsIdenticalBooksDistinctAndRejectsCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = "cloud-adoption-\(UUID().uuidString)"
        let library = try LocalLibrary(namespace: namespace)
        let a = try await library.importFile(fixture, folderBookID: "folder-a")
        let b = try await library.importFile(fixture, folderBookID: "folder-b")
        let digest = try XCTUnwrap(a.contentDigest)
        XCTAssertEqual(digest, b.contentDigest)
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let first = CloudStandaloneBookID(), second = CloudStandaloneBookID()
        func metadata(_ id: CloudStandaloneBookID) -> CloudBookMetadata {
            CloudBookMetadata(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey,
                              bookID: id, revision: UUID(), title: "Book", format: .pdf,
                              byteCount: Int64((try? Data(contentsOf: fixture).count) ?? 0), sha256: digest)
        }
        try await library.adoptCloudIdentity(metadata(first), for: a, scope: scope)
        do { try await library.adoptCloudIdentity(metadata(first), for: b, scope: scope); XCTFail("Identity collision") } catch {}
        try await library.adoptCloudIdentity(metadata(second), for: b, scope: scope)
        let restarted = try LocalLibrary(namespace: namespace)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let firstStage = try await restarted.stageCloudBook(a, scope: scope, stager: stager)
        let secondStage = try await restarted.stageCloudBook(b, scope: scope, stager: stager)
        XCTAssertEqual(firstStage.metadata.bookID, first)
        XCTAssertEqual(secondStage.metadata.bookID, second)
        XCTAssertNotEqual(firstStage.metadata.recordName, secondStage.metadata.recordName)
        let originalURL = await restarted.originalFile(for: a)
        let original = try XCTUnwrap(originalURL)
        try Data("corrupt".utf8).write(to: original)
        do { _ = try await restarted.stageCloudBook(a, scope: scope, stager: stager); XCTFail("Corrupt retained file must not stage") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture), try Data(contentsOf: secondStage.assetURL))
    }

    func testStageRestartAndEncryptedRecordPreserveOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Original.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: source)
        let before = try Data(contentsOf: source)
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic-account", source: .imported)
        let id = CloudStandaloneBookID(), revision = UUID()
        let stager = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("staging"))
        let staged = try await stager.stage(source: source, bookID: id, title: "A book", format: .pdf, revision: revision)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try Data(contentsOf: staged.assetURL), before)
        let restarted = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("staging"))
        let reopened = try await restarted.reopen(bookID: id, revision: revision)
        XCTAssertEqual(reopened.metadata, staged.metadata)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let record = try await CloudBookRecordCodec.record(reopened, scope: scope, zoneID: zone)
        XCTAssertNotNil(record.encryptedValues["metadata"] as? Data)
        XCTAssertNil(record["metadata"])
        XCTAssertNotNil(record["bookFile"] as? CKAsset)
        let (decoded, asset) = try CloudBookRecordCodec.decode(record, scope: scope)
        XCTAssertEqual(decoded, staged.metadata)
        XCTAssertEqual(try Data(contentsOf: asset), before)
        let other = try CloudReadingScope(cloudUserRecordName: "different-account", source: .imported)
        XCTAssertThrowsError(try CloudBookRecordCodec.decode(record, scope: other))
        let readingKey = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .position)
        XCTAssertEqual(readingKey.bookKey, stableKey(id.readingBookID))
        try await restarted.discard(bookID: id, revision: revision)
        XCTAssertEqual(try Data(contentsOf: source), before)
        do { _ = try await restarted.reopen(bookID: id, revision: revision); XCTFail("Discarded staging must not reopen") } catch {}
    }

    func testDownloadedAssetIntegrityAndMissingDataNeverOverwriteARevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at: fixture, to: source)
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let id = CloudStandaloneBookID(), revision = UUID()
        let first = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("first"))
        let original = try await first.stage(source: source, bookID: id, title: "Title", format: .pdf, revision: revision)
        let second = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("second"))
        let received = try await second.stage(source: source, bookID: id, title: "Title", format: .pdf, revision: revision, expected: original.metadata)
        XCTAssertEqual(received.metadata, original.metadata)
        do { _ = try await second.stage(source: source, bookID: id, title: "Title", format: .pdf, revision: revision); XCTFail("A published revision cannot be replaced") } catch {}
        XCTAssertEqual(try Data(contentsOf: received.assetURL), try Data(contentsOf: source))
        try Data("corrupt".utf8).write(to: received.assetURL)
        do { _ = try await second.reopen(bookID: id, revision: revision); XCTFail("Corrupt staged data must be rejected") } catch {}
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        do { _ = try await CloudBookRecordCodec.record(received, scope: scope, zoneID: zone); XCTFail("Corrupt staged data must not become an upload record") } catch {}
        let third = try CloudBookStager(scope: scope, baseDirectory: root.appendingPathComponent("third"))
        do { _ = try await third.stage(source: received.assetURL, bookID: id, title: "Title", format: .pdf, revision: revision, expected: original.metadata); XCTFail("Corrupt download must not be committed") } catch {}
        do { _ = try await third.reopen(bookID: id, revision: revision); XCTFail("Partial download must remain unavailable") } catch {}
        do { _ = try await third.stage(source: root.appendingPathComponent("missing.pdf"), bookID: id, title: "Title", format: .pdf); XCTFail("Missing source must fail") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRecordIdentityAndMetadataAreValidated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        let first = try await stager.stage(source: fixture, bookID: .init(), title: "One", format: .pdf)
        let second = try await stager.stage(source: fixture, bookID: .init(), title: "Two", format: .pdf)
        XCTAssertNotEqual(first.metadata.bookID, second.metadata.bookID)
        XCTAssertNotEqual(first.metadata.recordName, second.metadata.recordName)
        XCTAssertEqual(first.metadata.sha256, second.metadata.sha256)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let firstRecord = try await CloudBookRecordCodec.record(first, scope: scope, zoneID: zone)
        do { _ = try await CloudBookRecordCodec.record(second, scope: scope, zoneID: zone, existing: firstRecord); XCTFail("Different book records cannot be replaced") } catch {}
        firstRecord.encryptedValues["metadata"] = Data("invalid".utf8) as CKRecordValue
        XCTAssertThrowsError(try CloudBookRecordCodec.decode(firstRecord, scope: scope))
        let missing = CKRecord(recordType: CloudBookRecordCodec.recordType, recordID: .init(recordName: first.metadata.recordName, zoneID: zone))
        XCTAssertThrowsError(try CloudBookRecordCodec.decode(missing, scope: scope))
    }

    func testArchiveFormatsAreValidatedAndOriginalBytesPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let script = project.appendingPathComponent("App/Resources/Archive/jszip.min.js")
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let stager = try CloudBookStager(scope: scope, baseDirectory: root)
        for format in [BookFormat.epub, .cbz] {
            let source = project.appendingPathComponent("Fixtures/Harbor.\(format.rawValue)")
            let original = try Data(contentsOf: source)
            let staged = try await stager.stage(source: source, bookID: .init(), title: "Fixture", format: format, archiveScript: script)
            XCTAssertEqual(try Data(contentsOf: staged.assetURL), original)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testLocalQuotaAndCancellationLeaveNoCompletedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let limited = try CloudBookStager(scope: scope, baseDirectory: root, maxBookBytes: 1)
        let book = CloudStandaloneBookID(), revision = UUID()
        do { _ = try await limited.stage(source: fixture, bookID: book, title: "Fixture", format: .pdf, revision: revision); XCTFail("Local staging limit must be enforced") } catch {}
        do { _ = try await limited.reopen(bookID: book, revision: revision); XCTFail("An incomplete revision cannot be reopened") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let normal = try CloudBookStager(scope: scope, baseDirectory: root)
        let cancelledRevision = UUID()
        let task = Task { try await normal.stage(source: fixture, bookID: book, title: "Fixture", format: .pdf, revision: cancelledRevision) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled staging must not succeed") } catch {}
        do { _ = try await normal.reopen(bookID: book, revision: cancelledRevision); XCTFail("Cancelled staging cannot publish") } catch {}
    }

    func testStandaloneArchivesRetainOriginalAndRecoverOnlyOnReselection() async throws {
        let namespace = "cloud-original-test-\(UUID())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        defer {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))"))
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))"))
        }
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let script = project.appendingPathComponent("App/Resources/Archive/jszip.min.js")
        let library = try LocalLibrary(namespace: namespace, archiveScript: script)
        for format in [BookFormat.epub, .cbz] {
            let source = project.appendingPathComponent("Fixtures/Harbor.\(format.rawValue)")
            let bytes = try Data(contentsOf: source)
            let book = try await library.importFile(source)
            let originalURL = await library.originalFile(for: book)
            let original = try XCTUnwrap(originalURL)
            XCTAssertEqual(try Data(contentsOf: original), bytes)
            let directoryURL = await library.directory(for: book)
            let directory = try XCTUnwrap(directoryURL)
            let fingerprint = format == .epub ? try await BookFingerprint.epub(directory: directory, hasDurableSidecars: true) : ""
            // Simulate a pre-retention import: it remains readable but its raw
            // archive is unavailable until the matching file is reselected.
            try FileManager.default.removeItem(at: original)
            let metadataURL = directory.appendingPathComponent(".libravia-metadata.json")
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
            metadata.removeValue(forKey: "retainedOriginal")
            try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
            let legacy = await library.originalFile(for: book)
            XCTAssertNil(legacy)
            if format == .epub {
                // Older EPUBs could contain this name as publication content.
                // It must stay in the fingerprint and must never be replaced.
                let publicationData = Data("publication resource".utf8)
                try publicationData.write(to: original)
                let withResource = try await BookFingerprint.epub(directory: directory, hasDurableSidecars: true)
                XCTAssertNotEqual(withResource, fingerprint)
                do { _ = try await library.importFile(source); XCTFail("A legacy publication file cannot be replaced") } catch {}
                XCTAssertEqual(try Data(contentsOf: original), publicationData)
                try FileManager.default.removeItem(at: original)
            }
            let reselected = try await library.importFile(source)
            XCTAssertEqual(reselected.id, book.id)
            let recoveredURL = await library.originalFile(for: book)
            let recovered = try XCTUnwrap(recoveredURL)
            XCTAssertEqual(try Data(contentsOf: recovered), bytes)
            if format == .epub {
                let restoredFingerprint = try await BookFingerprint.epub(directory: directory, hasDurableSidecars: true)
                XCTAssertEqual(restoredFingerprint, fingerprint)
            }
            // Damage to the app-owned archive is repaired only by explicit
            // reselection of the exact source; the extracted edition is unchanged.
            let damaged = Data("damaged original".utf8)
            try damaged.write(to: recovered)
            let store = try DurableBookStore(namespace: namespace)
            let expectedDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            do { try await store.restoreOriginal(fixture, book: book.book, expectedDigest: expectedDigest); XCTFail("Wrong edition must not replace the retained archive") } catch {}
            XCTAssertEqual(try Data(contentsOf: recovered), damaged)
            _ = try await library.importFile(source)
            XCTAssertEqual(try Data(contentsOf: recovered), bytes)
            if format == .epub {
                let repairedFingerprint = try await BookFingerprint.epub(directory: directory, hasDurableSidecars: true)
                XCTAssertEqual(repairedFingerprint, fingerprint)
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testNewArchiveRejectsReservedOriginalName() async throws {
        let namespace = "cloud-original-test-\(UUID())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))"))
            try? FileManager.default.removeItem(at: support.appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))"))
        }
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let archive = temp.appendingPathComponent("collision.epub")
        try FileManager.default.copyItem(at: project.appendingPathComponent("Fixtures/Harbor.epub"), to: archive)
        try Data("publication data".utf8).write(to: temp.appendingPathComponent(".libravia-original"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = temp
        zip.arguments = ["-q", archive.path, ".libravia-original"]
        try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
        let before = try Data(contentsOf: archive)
        let library = try LocalLibrary(namespace: namespace, archiveScript: project.appendingPathComponent("App/Resources/Archive/jszip.min.js"))
        do { _ = try await library.importFile(archive); XCTFail("Reserved app-owned filename must be rejected") } catch {}
        XCTAssertEqual(try Data(contentsOf: archive), before)
        let catalog = await library.catalog()
        XCTAssertTrue(catalog.isEmpty)
    }
}
