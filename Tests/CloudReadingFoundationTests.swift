import XCTest
import CloudKit
@testable import BookCore

final class CloudReadingFoundationTests: XCTestCase {
    func testJellyfinRecoverySourceIncludesNormalizedEndpointWithoutExposingIt() throws {
        let first = Account(server: URL(string: "https://EXAMPLE.invalid:443/library/")!, userID: "user", serverID: "server", username: "test", token: "secret-token")
        var equivalent = first; equivalent.server = URL(string: "https://example.invalid/library")!; equivalent.token = "different-token"
        var other = first; other.server = URL(string: "https://other.invalid/library")!
        let source = try CloudReadingSource.scopedJellyfin(first)
        XCTAssertEqual(try source.key(), try CloudReadingSource.scopedJellyfin(equivalent).key())
        XCTAssertNotEqual(try source.key(), try CloudReadingSource.scopedJellyfin(other).key())
        XCTAssertNotEqual(try source.key(), try CloudReadingSource.jellyfin(serverID: first.serverID, userID: first.userID).key())
        XCTAssertTrue(source.isJellyfin)
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        XCTAssertFalse(encoded.contains("example.invalid")); XCTAssertFalse(encoded.contains("secret-token"))
        var invalid = first; invalid.userID = ""
        XCTAssertThrowsError(try CloudReadingSource.scopedJellyfin(invalid))
    }

    @MainActor func testEarlyJellyfinSourceIsHeldForReviewRatherThanMerged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let legacy = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: account.serverID, userID: account.userID))
        let scoped = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        let mark = Bookmark(name: "Earlier data", position: ReadingPosition(page: 0))
        try reading.add(mark, id: "book")
        try reading.prepareAtomicReading(scope: legacy)
        XCTAssertThrowsError(try reading.requireRecoveryScope(scoped))
        let reopened = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.id, mark.id)
        try reopened.requireRecoveryScope(legacy)
        XCTAssertThrowsError(try reopened.requireRecoveryScope(scoped))
    }

    @MainActor func testLegacyJellyfinMigrationSnapshotKeepsEveryAlternativeAndFencesIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let source = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: account.serverID, userID: account.userID))
        let target = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        let store = try CloudAtomicReadingStore(scope: source, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let stale = try CloudAtomicReadingStore(scope: source, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        let mark = Bookmark(name: "Deleted locally", position: ReadingPosition(page: 1))
        let markKey = try CloudReadingKey(scope: source, bookID: "book", kind: .bookmark, itemID: mark.id)
        try store.set(mark, bookID: "book"); try store.remove(mark, bookID: "book")
        var otherMark = mark; otherMark.name = "Edited elsewhere"
        let alternative = CloudReadingVersion(revision: UUID(), payload: .bookmark(otherMark))
        try store.observe(markKey, bookID: "book", remote: alternative)
        let note = ReadingAnnotation(anchor: .page(1), selectedText: nil, context: nil, note: "Incoming", color: nil)
        let noteKey = try CloudReadingKey(scope: source, bookID: "book", kind: .annotation, itemID: note.id)
        let incoming = CloudReadingVersion(revision: UUID(), payload: .annotation(note))
        try store.observe(noteKey, bookID: "book", remote: incoming)
        let snapshot = try store.legacyJellyfinMigrationSnapshot(account: account, targetScope: target)
        XCTAssertEqual(snapshot.sourceScope, source); XCTAssertEqual(snapshot.targetScope, target)
        let deleted = try XCTUnwrap(snapshot.outbox[markKey.recordName])
        XCTAssertNil(deleted.entry.current.payload); XCTAssertTrue(deleted.entry.pending)
        XCTAssertEqual(deleted.entry.conflicts.map(\.revision), [alternative.revision])
        XCTAssertEqual(snapshot.outbox[noteKey.recordName]?.entry.current.revision, incoming.revision)
        XCTAssertTrue(snapshot.outbox[noteKey.recordName]?.pendingApplication == true)
        let plan = try snapshot.makePlan()
        let migratedMark = try CloudReadingKey(scope: target, bookID: "book", kind: .bookmark, itemID: mark.id)
        let migratedNote = try CloudReadingKey(scope: target, bookID: "book", kind: .annotation, itemID: note.id)
        let translatedMark = try XCTUnwrap(plan.outbox[migratedMark.recordName])
        XCTAssertNil(translatedMark.entry.current.payload)
        XCTAssertNil(translatedMark.entry.baseRevision)
        XCTAssertTrue(translatedMark.entry.pending)
        XCTAssertEqual(translatedMark.entry.conflicts.map(\.revision), [alternative.revision])
        XCTAssertEqual(translatedMark.legacyConflictRevisions, [alternative.revision])
        let translatedNote = try XCTUnwrap(plan.outbox[migratedNote.recordName])
        XCTAssertNil(translatedNote.entry.current.payload)
        XCTAssertEqual(translatedNote.entry.conflicts.map(\.revision), [incoming.revision])
        XCTAssertEqual(translatedNote.legacyConflictRevisions, [incoming.revision])
        XCTAssertNil(translatedNote.entry.baseRevision)
        XCTAssertNotEqual(translatedNote.entry.current.revision, incoming.revision)
        XCTAssertThrowsError(try stale.legacyJellyfinMigrationSnapshot(account: account, targetScope: target))
        var wrongAccount = account; wrongAccount.serverID = "other"
        XCTAssertThrowsError(try store.legacyJellyfinMigrationSnapshot(account: wrongAccount, targetScope: target))
        let otherCloud = try CloudReadingScope(cloudUserRecordName: "other", source: .scopedJellyfin(account))
        XCTAssertThrowsError(try store.legacyJellyfinMigrationSnapshot(account: account, targetScope: otherCloud))
        let reopened = try CloudAtomicReadingStore(scope: source, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.outbox[markKey.recordName]?.entry.current.revision, deleted.entry.current.revision)
        XCTAssertEqual(reopened.outbox[noteKey.recordName]?.entry.current.revision, incoming.revision)
    }

    @MainActor func testJellyfinAccountSwitchPlanPreservesBothAccountsAlternatives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let source = try CloudReadingScope(cloudUserRecordName: "first", source: .scopedJellyfin(account))
        let destination = try CloudReadingScope(cloudUserRecordName: "second", source: .scopedJellyfin(account))
        let old = try CloudAtomicReadingStore(scope: source, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let target = try CloudAtomicReadingStore(scope: destination, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let mark = Bookmark(name: "Current device", position: ReadingPosition(page: 1))
        try old.set(mark, bookID: "book")
        let oldKey = try CloudReadingKey(scope: source, bookID: "book", kind: .bookmark, itemID: mark.id)
        var oldAlternative = mark; oldAlternative.name = "First account alternative"
        let fromOldCloud = CloudReadingVersion(revision: UUID(), payload: .bookmark(oldAlternative))
        try old.observe(oldKey, bookID: "book", remote: fromOldCloud)
        let key = try CloudReadingKey(scope: destination, bookID: "book", kind: .bookmark, itemID: mark.id)
        try target.set(mark, bookID: "book")
        let targetBase = try XCTUnwrap(target.outbox[key.recordName]?.entry.current.revision)
        try target.acknowledge(key, revision: targetBase)
        var targetMark = mark; targetMark.name = "Second account local"
        try target.set(targetMark, bookID: "book")
        let targetLocalRevision = try XCTUnwrap(target.outbox[key.recordName]?.entry.current.revision)
        var remoteMark = mark; remoteMark.name = "Second account cloud"
        let targetRemote = CloudReadingVersion(revision: UUID(), payload: .bookmark(remoteMark))
        try target.observe(key, bookID: "book", remote: targetRemote)
        let plan = try old.jellyfinAccountSwitchPlan(account: account, targetScope: destination, target: target)
        let item = try XCTUnwrap(plan.outbox[key.recordName])
        if case .bookmark(let value) = item.entry.current.payload { XCTAssertEqual(value.name, "Current device") }
        else { XCTFail("The current device version must remain current") }
        XCTAssertEqual(Set(item.entry.conflicts.map(\.revision)), Set([fromOldCloud.revision, targetLocalRevision, targetRemote.revision]))
        XCTAssertEqual(Set(item.legacyConflictRevisions ?? []), Set([fromOldCloud.revision, targetLocalRevision]))
        XCTAssertEqual(item.entry.baseRevision, targetBase)
        XCTAssertTrue(item.entry.pending)
        XCTAssertEqual(old.bookmarks["book"]?.first?.name, "Current device")
        XCTAssertEqual(target.bookmarks["book"]?.first?.name, "Second account local")
        XCTAssertThrowsError(try old.jellyfinAccountSwitchPlan(account: account, targetScope: source, target: nil))
        var other = account; other.server = URL(string: "https://other.invalid")!
        XCTAssertThrowsError(try old.jellyfinAccountSwitchPlan(account: other, targetScope: destination, target: target))
    }

    @MainActor func testDestinationOnlyPendingChangeIsStagedWithoutInventingDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .scopedJellyfin(account))
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reading.prepareAtomicReading(scope: first)
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let digest = String(repeating: "a", count: 64)
        try target.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        let mark = Bookmark(name: "Pending destination bookmark", position: ReadingPosition(page: 1))
        try target.set(mark, bookID: "book")
        let key = try CloudReadingKey(scope: second, bookID: "book", kind: .bookmark, itemID: mark.id)
        let revision = try XCTUnwrap(target.outbox[key.recordName]?.entry.current.revision)
        let conflicted = Bookmark(name: "Pending with cloud alternative", position: ReadingPosition(page: 2))
        try target.set(conflicted, bookID: "book")
        let conflictKey = try CloudReadingKey(scope: second, bookID: "book", kind: .bookmark, itemID: conflicted.id)
        var alternative = conflicted; alternative.name = "Existing cloud alternative"
        let remote = CloudReadingVersion(revision: UUID(), payload: .bookmark(alternative), editionFingerprint: digest)
        try target.observe(conflictKey, bookID: "book", remote: remote)
        target.invalidateAllEditionVerifications()
        let legacy = Bookmark(name: "Pending older bookmark", position: ReadingPosition(page: 3))
        try target.set(legacy, bookID: "book")
        let legacyKey = try CloudReadingKey(scope: second, bookID: "book", kind: .bookmark, itemID: legacy.id)
        let legacyRevision = try XCTUnwrap(target.outbox[legacyKey.recordName]?.entry.current.revision)
        try reading.switchJellyfinRecoveryAccount(account: account, targetScope: second)
        let atomic = try XCTUnwrap(reading.cloudReadingStore)
        let item = try XCTUnwrap(atomic.outbox[key.recordName])
        XCTAssertEqual(item.entry.current.revision, revision)
        if case .bookmark(let saved) = item.entry.current.payload { XCTAssertEqual(saved.name, mark.name) }
        else { XCTFail("The pending destination bookmark must remain current") }
        XCTAssertTrue(item.entry.pending)
        XCTAssertTrue(item.pendingApplication == true)
        XCTAssertTrue(item.entry.conflicts.isEmpty)
        let conflict = try XCTUnwrap(atomic.outbox[conflictKey.recordName])
        XCTAssertTrue(conflict.pendingApplication == true)
        XCTAssertEqual(conflict.entry.conflicts.map(\.revision), [remote.revision])
        if case .bookmark(let saved) = conflict.entry.current.payload { XCTAssertEqual(saved.name, conflicted.name) }
        else { XCTFail("The real pending value must remain current") }
        XCTAssertTrue(reading.bookmarks.isEmpty)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        try atomic.setVerifiedEdition(localBookID: book.id, fingerprint: digest)
        XCTAssertThrowsError(try reading.applyObservedCloudVersion(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: UUID()))
        try reading.applyObservedCloudVersion(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: revision)
        XCTAssertEqual(reading.bookmarks[book.id]?.first?.name, mark.name)
        let applied = try XCTUnwrap(atomic.outbox[key.recordName])
        XCTAssertEqual(applied.entry.current.revision, revision)
        XCTAssertTrue(applied.entry.pending)
        XCTAssertFalse(applied.pendingApplication == true)
        XCTAssertThrowsError(try reading.applyObservedCloudVersion(legacyKey, book: book, verifiedEditionFingerprint: digest, expectedRevision: legacyRevision))
        try reading.applyObservedCloudVersion(legacyKey, book: book, verifiedEditionFingerprint: digest,
                                              expectedRevision: legacyRevision, confirmLegacyEdition: true)
        let reviewed = try XCTUnwrap(atomic.outbox[legacyKey.recordName])
        XCTAssertNotEqual(reviewed.entry.current.revision, legacyRevision)
        XCTAssertEqual(reviewed.entry.current.editionFingerprint, digest)
        XCTAssertTrue(reviewed.entry.pending)
        XCTAssertFalse(reviewed.pendingApplication == true)
        let reopened = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        XCTAssertEqual(reopened.bookmarks[book.id]?.first?.name, mark.name)
        XCTAssertTrue(reopened.cloudReadingStore?.outbox[key.recordName]?.entry.pending == true)
    }

    @MainActor func testJellyfinAccountSwitchResumesInterruptedMarkerAndCanReturn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .scopedJellyfin(account))
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        let mark = Bookmark(name: "First account", position: ReadingPosition(page: 1))
        try reading.add(mark, id: "book")
        try reading.prepareAtomicReading(scope: first)
        let stale = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        let source = try XCTUnwrap(reading.cloudReadingStore)
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        var other = mark; other.name = "Second account"
        try target.set(other, bookID: "book")
        let key = try CloudReadingKey(scope: second, bookID: "book", kind: .bookmark, itemID: mark.id)
        let secondRevision = try XCTUnwrap(target.outbox[key.recordName]?.entry.current.revision)
        let originalTarget = try Data(contentsOf: target.file)
        let plan = try source.jellyfinAccountSwitchPlan(account: account, targetScope: second, target: target)
        XCTAssertThrowsError(try source.installJellyfinAccountSwitch(plan, target: target) { throw ReaderError.message("interrupted") })
        let backups = target.file.deletingLastPathComponent().appendingPathComponent("account-switch-backups")
        let saved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: saved), originalTarget)
        try reading.requireRecoveryScope(first)
        try reading.switchJellyfinRecoveryAccount(account: account, targetScope: second)
        try reading.requireRecoveryScope(second)
        XCTAssertThrowsError(try stale.renameBookmark(mark, id: "book", name: "Stale"))
        let switched = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        XCTAssertEqual(switched.bookmarks["book"]?.first?.name, "First account")
        XCTAssertEqual(switched.cloudReadingStore?.outbox[key.recordName]?.entry.conflicts.map(\.revision), [secondRevision])
        try switched.renameBookmark(mark, id: "book", name: "Edited on second")
        try switched.switchJellyfinRecoveryAccount(account: account, targetScope: first)
        let returned = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try returned.requireRecoveryScope(first)
        XCTAssertEqual(returned.bookmarks["book"]?.first?.name, "Edited on second")
        let originalKey = try CloudReadingKey(scope: first, bookID: "book", kind: .bookmark, itemID: mark.id)
        XCTAssertTrue(returned.cloudReadingStore?.outbox[originalKey.recordName]?.entry.conflicts.contains(where: { $0.revision == secondRevision }) == true)
    }

    @MainActor func testJellyfinAccountSwitchRejectsStaleDestinationPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .scopedJellyfin(account))
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .scopedJellyfin(account))
        let source = try CloudAtomicReadingStore(scope: first, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let plan = try source.jellyfinAccountSwitchPlan(account: account, targetScope: second, target: target)
        try target.set(Bookmark(name: "New destination change", position: ReadingPosition(page: 1)), bookID: "book")
        XCTAssertThrowsError(try source.installJellyfinAccountSwitch(plan, target: target) { XCTFail("Must not switch marker") })
        XCTAssertEqual(target.bookmarks["book"]?.first?.name, "New destination change")
    }

    @MainActor func testStandaloneAccountSwitchPlanUsesOnlyExplicitBookBindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .imported)
        let firstID = CloudStandaloneBookID(), secondID = CloudStandaloneBookID(), unboundID = CloudStandaloneBookID()
        let source = try CloudAtomicReadingStore(scope: first, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                 baseDirectory: root, localToCloudBookIDs: ["local": firstID.readingBookID])
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                 baseDirectory: root, localToCloudBookIDs: ["local": secondID.readingBookID])
        let mark = Bookmark(name: "On device", position: ReadingPosition(page: 1))
        try source.set(mark, bookID: "local")
        let firstKey = try CloudReadingKey(scope: first, bookID: firstID.readingBookID, kind: .bookmark, itemID: mark.id)
        var old = mark; old.name = "First account cloud"
        let oldVersion = CloudReadingVersion(revision: UUID(), payload: .bookmark(old))
        try source.observe(firstKey, bookID: firstID.readingBookID, remote: oldVersion)
        var secondMark = mark; secondMark.name = "Second account local"
        try target.set(secondMark, bookID: "local")
        let secondKey = try CloudReadingKey(scope: second, bookID: secondID.readingBookID, kind: .bookmark, itemID: mark.id)
        let secondRevision = try XCTUnwrap(target.outbox[secondKey.recordName]?.entry.current.revision)
        let missing = Bookmark(name: "No local book mapping", position: ReadingPosition(page: 2))
        try source.set(missing, bookID: "missing")
        let orphan = Bookmark(name: "First account only", position: ReadingPosition(page: 3))
        let orphanKey = try CloudReadingKey(scope: first, bookID: unboundID.readingBookID, kind: .bookmark, itemID: orphan.id)
        try source.observe(orphanKey, bookID: unboundID.readingBookID, remote: CloudReadingVersion(revision: UUID(), payload: .bookmark(orphan)))
        let plan = try source.standaloneAccountSwitchPlan(targetScope: second, target: target,
                                                          catalogBindings: ["local": secondID.readingBookID])
        let item = try XCTUnwrap(plan.outbox[secondKey.recordName])
        XCTAssertEqual(item.bookID, secondID.readingBookID)
        if case .bookmark(let value) = item.entry.current.payload { XCTAssertEqual(value.name, "On device") }
        else { XCTFail("The local reading change must be mapped") }
        XCTAssertEqual(Set(item.entry.conflicts.map(\.revision)), Set([oldVersion.revision, secondRevision]))
        XCTAssertEqual(Set(item.legacyConflictRevisions ?? []), Set([oldVersion.revision, secondRevision]))
        XCTAssertEqual(plan.unmappedBookIDs, ["missing"])
        XCTAssertEqual(plan.unmappedOutbox.values.first?.bookID, "missing")
        XCTAssertEqual(plan.sourceOnlyItems, 1)
        XCTAssertNotNil(source.outbox[orphanKey.recordName])
        XCTAssertThrowsError(try source.standaloneAccountSwitchPlan(targetScope: second, target: target,
                                                                      catalogBindings: ["local": CloudStandaloneBookID().readingBookID]))
    }

    @MainActor func testStandaloneAccountSwitchStagesDestinationOnlyPendingBookmark() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .imported)
        let firstID = CloudStandaloneBookID(), secondID = CloudStandaloneBookID()
        let source = try CloudAtomicReadingStore(scope: first, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                 baseDirectory: root, localToCloudBookIDs: ["local": firstID.readingBookID])
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                 baseDirectory: root, localToCloudBookIDs: ["local": secondID.readingBookID])
        let bookmark = Bookmark(name: "Destination bookmark", position: ReadingPosition(page: 4))
        try target.set(bookmark, bookID: "local")
        let key = try CloudReadingKey(scope: second, bookID: secondID.readingBookID, kind: .bookmark, itemID: bookmark.id)
        let revision = try XCTUnwrap(target.outbox[key.recordName]?.entry.current.revision)
        let plan = try source.standaloneAccountSwitchPlan(targetScope: second, target: target, catalogBindings: ["local": secondID.readingBookID])
        let item = try XCTUnwrap(plan.outbox[key.recordName])
        XCTAssertEqual(item.entry.current.revision, revision)
        XCTAssertTrue(item.entry.pending)
        XCTAssertTrue(item.pendingApplication == true)
        XCTAssertTrue(item.entry.conflicts.isEmpty)
        if case .bookmark(let saved) = item.entry.current.payload { XCTAssertEqual(saved.name, bookmark.name) }
        else { XCTFail("The destination bookmark must not become a deletion") }
    }

    @MainActor func testStandaloneAccountSwitchResumesAndKeepsUnmappedChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .imported)
        let firstID = CloudStandaloneBookID(), secondID = CloudStandaloneBookID()
        let reading = try ReadingStore(namespace: "standalone-switch", baseDirectory: root)
        let mark = Bookmark(name: "Current", position: ReadingPosition(page: 1))
        try reading.add(mark, id: "local")
        try reading.prepareAtomicReading(scope: first, localToCloudBookIDs: ["local": firstID.readingBookID])
        let missing = Bookmark(name: "Unmapped", position: ReadingPosition(page: 2))
        try reading.add(missing, id: "missing")
        let stale = try ReadingStore(namespace: "standalone-switch", baseDirectory: root)
        let source = try XCTUnwrap(reading.cloudReadingStore)
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                 baseDirectory: root, localToCloudBookIDs: ["local": secondID.readingBookID])
        var other = mark; other.name = "Destination"
        try target.set(other, bookID: "local")
        let key = try CloudReadingKey(scope: second, bookID: secondID.readingBookID, kind: .bookmark, itemID: mark.id)
        let destinationRevision = try XCTUnwrap(target.outbox[key.recordName]?.entry.current.revision)
        let bindings = ["local": secondID.readingBookID]
        let plan = try source.standaloneAccountSwitchPlan(targetScope: second, target: target, catalogBindings: bindings)
        XCTAssertThrowsError(try source.installStandaloneAccountSwitch(plan, target: target) { throw ReaderError.message("interrupted") })
        try reading.requireRecoveryScope(first)
        try reading.switchStandaloneRecoveryAccount(targetScope: second, catalogBindings: bindings)
        try reading.requireRecoveryScope(second)
        XCTAssertThrowsError(try stale.renameBookmark(mark, id: "local", name: "Stale"))
        let reopened = try ReadingStore(namespace: "standalone-switch", baseDirectory: root)
        XCTAssertEqual(reopened.bookmarks["local"]?.first?.name, "Current")
        XCTAssertEqual(reopened.bookmarks["missing"]?.first?.name, "Unmapped")
        XCTAssertTrue(reopened.cloudReadingStore?.hasUnmappedReadingData == true)
        XCTAssertEqual(reopened.cloudReadingStore?.outbox[key.recordName]?.entry.conflicts.map(\.revision), [destinationRevision])
        try reopened.renameBookmark(mark, id: "local", name: "Edited on second")
        try reopened.renameBookmark(missing, id: "missing", name: "Unmapped change on second")
        try reopened.switchStandaloneRecoveryAccount(targetScope: first, catalogBindings: ["local": firstID.readingBookID])
        let returned = try ReadingStore(namespace: "standalone-switch", baseDirectory: root)
        XCTAssertEqual(returned.bookmarks["local"]?.first?.name, "Edited on second")
        XCTAssertEqual(returned.bookmarks["missing"]?.first?.name, "Unmapped change on second")
        XCTAssertTrue(returned.cloudReadingStore?.hasUnmappedReadingData == true)
        let recoveredID = CloudStandaloneBookID()
        try returned.bindStandaloneCloudIdentity(localBookID: "missing", cloudBookID: recoveredID)
        let recoveredKey = try CloudReadingKey(scope: first, bookID: recoveredID.readingBookID, kind: .bookmark, itemID: missing.id)
        let recovered = try XCTUnwrap(returned.cloudReadingStore?.outbox[recoveredKey.recordName])
        XCTAssertTrue(recovered.entry.conflicts.contains { if case .bookmark(let value) = $0.payload { return value.name == "Unmapped" }; return false })
        XCTAssertEqual(Set(recovered.entry.conflicts.map(\.revision)), Set(recovered.legacyConflictRevisions ?? []))
    }

    @MainActor func testStandaloneAccountSwitchRequiresExplicitReviewOfSourceOnlyItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .imported)
        let reading = try ReadingStore(namespace: "standalone-review", baseDirectory: root)
        try reading.prepareAtomicReading(scope: first, localToCloudBookIDs: [:])
        let source = try XCTUnwrap(reading.cloudReadingStore)
        let identity = CloudStandaloneBookID()
        let mark = Bookmark(name: "Cloud only", position: ReadingPosition(page: 1))
        let key = try CloudReadingKey(scope: first, bookID: identity.readingBookID, kind: .bookmark, itemID: mark.id)
        try source.observe(key, bookID: identity.readingBookID, remote: CloudReadingVersion(revision: UUID(), payload: .bookmark(mark)))
        let target = try CloudAtomicReadingStore(scope: second, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                 baseDirectory: root, localToCloudBookIDs: [:])
        let plan = try source.standaloneAccountSwitchPlan(targetScope: second, target: target, catalogBindings: [:])
        XCTAssertThrowsError(try source.installStandaloneAccountSwitch(plan, target: target, allowSourceOnlyItems: true) { throw ReaderError.message("interrupted") })
        XCTAssertThrowsError(try reading.switchStandaloneRecoveryAccount(targetScope: second, catalogBindings: [:]))
        try reading.requireRecoveryScope(first)
        try reading.switchStandaloneRecoveryAccount(targetScope: second, catalogBindings: [:], allowSourceOnlyItems: true)
        try reading.requireRecoveryScope(second)
        let original = try CloudAtomicReadingStore(scope: first, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertNotNil(original.outbox[key.recordName])
    }
    @MainActor func testLegacyJellyfinMigrationSurvivesRestartAndPreservesConflictProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let source = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: account.serverID, userID: account.userID))
        let target = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        let mark = Bookmark(name: "Local", position: ReadingPosition(page: 1))
        try reading.add(mark, id: "book")
        try reading.prepareAtomicReading(scope: source)
        let stale = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        let old = try XCTUnwrap(reading.cloudReadingStore)
        let oldKey = try CloudReadingKey(scope: source, bookID: "book", kind: .bookmark, itemID: mark.id)
        var remote = mark; remote.name = "Earlier alternative"
        let alternative = CloudReadingVersion(revision: UUID(), payload: .bookmark(remote))
        try old.observe(oldKey, bookID: "book", remote: alternative)
        let snapshot = try old.legacyJellyfinMigrationSnapshot(account: account, targetScope: target)
        let plan = try snapshot.makePlan()
        // Simulate an interruption after the target write and before the marker.
        XCTAssertThrowsError(try old.installLegacyJellyfinMigration(plan, baseDirectory: root) { throw ReaderError.message("interrupted") })
        try reading.migrateLegacyJellyfinReading(account: account, targetScope: target)
        XCTAssertThrowsError(try stale.renameBookmark(mark, id: "book", name: "Stale"))
        try reading.renameBookmark(mark, id: "book", name: "Edited after migration")
        let reopened = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reopened.requireRecoveryScope(target)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Edited after migration")
        let newKey = try CloudReadingKey(scope: target, bookID: "book", kind: .bookmark, itemID: mark.id)
        let item = try XCTUnwrap(reopened.cloudReadingStore?.outbox[newKey.recordName])
        XCTAssertEqual(item.legacyConflictRevisions, [alternative.revision])
        XCTAssertEqual(item.entry.conflicts.map(\.revision), [alternative.revision])
        XCTAssertNil(item.entry.baseRevision)
        let atomic = try XCTUnwrap(reopened.cloudReadingStore)
        let digest = String(repeating: "a", count: 64)
        try atomic.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        var newZoneMark = mark; newZoneMark.name = "New zone"
        let newZone = CloudReadingVersion(revision: UUID(), payload: .bookmark(newZoneMark), editionFingerprint: digest)
        try atomic.observe(newKey, bookID: book.id, remote: newZone)
        try reopened.resolveCloudConflict(newKey, book: book, verifiedEditionFingerprint: digest,
                                          expectedLocalRevision: item.entry.current.revision, remoteRevision: newZone.revision,
                                          choice: .remote)
        let afterNewZone = try XCTUnwrap(atomic.outbox[newKey.recordName])
        XCTAssertEqual(afterNewZone.entry.baseRevision, newZone.revision)
        try reopened.resolveCloudConflict(newKey, book: book, verifiedEditionFingerprint: digest,
                                          expectedLocalRevision: afterNewZone.entry.current.revision, remoteRevision: alternative.revision,
                                          choice: .remote, confirmUnverifiedEdition: true)
        let resolved = try XCTUnwrap(atomic.outbox[newKey.recordName])
        XCTAssertEqual(resolved.entry.baseRevision, newZone.revision)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Earlier alternative")
        XCTAssertTrue(resolved.legacyConflictRevisions?.isEmpty == true)
        let untouched = try CloudAtomicReadingStore(scope: source, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(untouched.outbox[oldKey.recordName]?.entry.conflicts.map(\.revision), [alternative.revision])
    }

    @MainActor func testLegacyJellyfinMigrationRejectsChangedSourceAndExistingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "test", token: "synthetic")
        let source = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: account.serverID, userID: account.userID))
        let target = try CloudReadingScope(cloudUserRecordName: "account", source: .scopedJellyfin(account))
        let reading = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reading.prepareAtomicReading(scope: source)
        let old = try XCTUnwrap(reading.cloudReadingStore)
        let plan = try old.legacyJellyfinMigrationSnapshot(account: account, targetScope: target).makePlan()
        try reading.add(Bookmark(name: "New", position: ReadingPosition(page: 1)), id: "book")
        XCTAssertThrowsError(try old.installLegacyJellyfinMigration(plan, baseDirectory: root) { XCTFail("Must not switch marker") })
        _ = try CloudAtomicReadingStore(scope: target, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        XCTAssertThrowsError(try reading.migrateLegacyJellyfinReading(account: account, targetScope: target))
        let reopened = try ReadingStore(namespace: account.namespace, baseDirectory: root)
        try reopened.requireRecoveryScope(source)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "New")
    }
    @MainActor func testStaleLegacySessionCannotOverwriteReadingOrFormatting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        let stale = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        try first.add(Bookmark(name: "Kept", position: ReadingPosition(page: 2)), id: "book")
        try first.setOriginalFormatting(true, bookID: "book")
        XCTAssertThrowsError(try stale.add(Bookmark(name: "Rejected", position: ReadingPosition(page: 3)), id: "book"))
        XCTAssertThrowsError(try stale.setOriginalFormatting(false, bookID: "book"))
        XCTAssertThrowsError(try stale.delete())
        XCTAssertTrue(stale.bookmarks.isEmpty)
        let reopened = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        XCTAssertEqual(reopened.bookmarks["book"]?.map(\.name), ["Kept"])
        XCTAssertTrue(reopened.usesOriginalFormatting(bookID: "book"))
    }

    @MainActor func testCorruptReadingOutboxIsRejectedWithoutOverwritingArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let bookmark = Bookmark(name: "Keep", position: ReadingPosition(page: 1))
        try store.set(bookmark, bookID: "book")
        let original = try Data(contentsOf: store.file)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var outbox = try XCTUnwrap(archive["outbox"] as? [String: Any])
        let name = try XCTUnwrap(outbox.keys.first)
        var item = try XCTUnwrap(outbox[name] as? [String: Any])
        var entry = try XCTUnwrap(item["entry"] as? [String: Any])
        entry["pending"] = false // Pending revisions still contain an unuploaded change.
        item["entry"] = entry; outbox[name] = item; archive["outbox"] = outbox
        let corrupted = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
        try corrupted.write(to: store.file, options: .atomic)
        XCTAssertThrowsError(try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true))
        XCTAssertEqual(try Data(contentsOf: store.file), corrupted)
        try original.write(to: store.file, options: .atomic)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Keep")
        XCTAssertTrue(reopened.outbox.values.first?.entry.pending == true)
    }
    @MainActor func testNamespaceLockAndStaleMigrationProtectReadingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        let stale = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        let lock = store.root.deletingLastPathComponent().appendingPathComponent("\(stableKey("synthetic")).reading.lock")
        let mark = Bookmark(name: "Kept", position: ReadingPosition(page: 2))
        try PrivateBookFiles.withExclusiveLock(at: lock) {
            XCTAssertThrowsError(try store.add(mark, id: "book"))
            XCTAssertThrowsError(try store.prepareAtomicReading(scope: scope))
            XCTAssertThrowsError(try store.delete())
            XCTAssertThrowsError(try ReadingStore(namespace: "synthetic", baseDirectory: root))
        }
        try store.add(mark, id: "book")
        XCTAssertThrowsError(try stale.prepareAtomicReading(scope: scope))
        try store.prepareAtomicReading(scope: scope)
        let marker = store.root.appendingPathComponent("atomic-reading-scope.json")
        let other = try CloudReadingScope(cloudUserRecordName: "other", source: .imported)
        try PrivateBookFiles.write(JSONEncoder().encode(other), to: marker)
        XCTAssertThrowsError(try store.add(Bookmark(name: "Rejected", position: ReadingPosition(page: 3)), id: "book"))
        XCTAssertThrowsError(try store.delete(allowUnsynced: true))
        try PrivateBookFiles.write(JSONEncoder().encode(scope), to: marker)
        XCTAssertEqual(try ReadingStore(namespace: "synthetic", baseDirectory: root).bookmarks["book"]?.map(\.name), ["Kept"])
    }

    @MainActor func testRecoverySetupRejectsDifferentAccountAndStaleSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CloudReadingScope(cloudUserRecordName: "first", source: .imported)
        let second = try CloudReadingScope(cloudUserRecordName: "second", source: .imported)
        let store = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        let stale = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        try store.requireRecoveryScope(first)
        let bookmark = Bookmark(name: "Private", position: ReadingPosition(page: 1))
        try store.add(bookmark, id: "book")
        try store.prepareAtomicReading(scope: first)
        try store.requireRecoveryScope(first)
        XCTAssertThrowsError(try store.requireRecoveryScope(second))
        XCTAssertThrowsError(try stale.requireRecoveryScope(first))
        let reopened = try ReadingStore(namespace: "synthetic", baseDirectory: root)
        XCTAssertThrowsError(try reopened.requireRecoveryScope(second))
        try reopened.requireRecoveryScope(first)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.id, bookmark.id)
        try reopened.renameBookmark(bookmark, id: "book", name: "Still available offline")
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Still available offline")
    }
    @MainActor final class FakeZoneDatabase: CloudRecoveryZoneDatabase {
        var value: CloudRecoveryZoneState = .missing
        var creates = 0
        var afterInspection: (() -> Void)?
        func state(of id: CKRecordZone.ID) async throws -> CloudRecoveryZoneState { afterInspection?(); return value }
        func create(_ id: CKRecordZone.ID) async throws { creates += 1; value = .present }
    }

    func testAutomaticRecoveryRetryBacksOffAndResets() {
        var policy = AutomaticRecoveryRetryPolicy()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(policy.isDue(at: now))
        policy.recordFailure(at: now)
        XCTAssertFalse(policy.isDue(at: now.addingTimeInterval(29)))
        XCTAssertTrue(policy.isDue(at: now.addingTimeInterval(30)))
        for _ in 0..<10 { policy.recordFailure(at: now) }
        XCTAssertEqual(policy.nextAttempt, now.addingTimeInterval(900))
        policy.recordSuccess(at: now)
        XCTAssertEqual(policy.failures, 0); XCTAssertEqual(policy.nextAttempt, now.addingTimeInterval(300))
        policy.reset(); XCTAssertTrue(policy.isDue(at: now))
    }

    @MainActor func testRecoveryServiceStopsWhenAutomaticSyncIsDisabled() async throws {
        let monitor = CloudReadingAccountMonitor(accountAvailable: { true }, accountName: { "account" })
        let zones = FakeZoneDatabase(); zones.value = .present
        var enabled = true, attempted = 0
        let service = StandaloneCloudRecoveryService(monitor: monitor, zones: zones) { _, _, fence in
            attempted += 1; enabled = false
            guard try await fence() else { throw CancellationError() }
            return StandaloneRecoveryCycle.Report()
        }
        let inspection = try await service.inspect()
        do { _ = try await service.run(inspection, ifEnabled: { enabled }); XCTFail("A disabled automatic pass must stop") } catch {}
        XCTAssertEqual(attempted, 1)
        do { _ = try await service.run(inspection, ifEnabled: { enabled }); XCTFail("A disabled automatic pass must not start") } catch {}
        XCTAssertEqual(attempted, 1)
    }

    @MainActor func testRecoveryServiceUsesRequestedJellyfinSource() async throws {
        let monitor = CloudReadingAccountMonitor(accountAvailable: { true }, accountName: { "account" })
        let zones = FakeZoneDatabase(); zones.value = .present
        let source = CloudReadingSource.jellyfin(serverID: "server", userID: "user")
        let service = StandaloneCloudRecoveryService(monitor: monitor, zones: zones, source: source) { _, _, _ in StandaloneRecoveryCycle.Report() }
        let inspection = try await service.inspect()
        XCTAssertEqual(inspection.scope.sourceKey, try source.key())
        XCTAssertNotEqual(inspection.scope.sourceKey, try CloudReadingSource.imported.key())
    }

    @MainActor func testEarlierMigrationUsesInspectedAccountEvenWhenNewZoneIsMissing() async throws {
        var account = "first"
        let monitor = CloudReadingAccountMonitor(accountAvailable: { true }, accountName: { account })
        let zones = FakeZoneDatabase()
        var attempts = 0
        let service = StandaloneCloudRecoveryService(monitor: monitor, zones: zones,
            source: .jellyfin(serverID: "server", userID: "user"), legacyRunner: { _, fence in
                guard try await fence() else { throw CancellationError() }
                attempts += 1
            }) { _, _, _ in StandaloneRecoveryCycle.Report() }
        let inspection = try await service.inspect()
        XCTAssertEqual(inspection.zoneState, .missing)
        try await service.migrateEarlierLibrary(inspection)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(zones.creates, 0)
        account = "second"
        do { try await service.migrateEarlierLibrary(inspection); XCTFail("A changed account cannot migrate") } catch {}
        XCTAssertEqual(attempts, 1)
    }

    @MainActor func testAccountSwitchServiceRequiresCurrentInspectedAccountAndZone() async throws {
        var account = "first"
        let monitor = CloudReadingAccountMonitor(accountAvailable: { true }, accountName: { account })
        let zones = FakeZoneDatabase(); zones.value = .present
        var switches = 0
        let service = StandaloneCloudRecoveryService(monitor: monitor, zones: zones, accountSwitchRunner: { _, fence in
            guard try await fence() else { throw CancellationError() }
            switches += 1
        }) { _, _, _ in StandaloneRecoveryCycle.Report() }
        let inspection = try await service.inspect()
        zones.value = .missing
        do { try await service.switchRecoveryAccount(inspection); XCTFail("A missing zone cannot switch") } catch {}
        XCTAssertEqual(switches, 0)
        zones.value = .present
        try await service.switchRecoveryAccount(inspection)
        XCTAssertEqual(switches, 1)
        account = "second"
        do { try await service.switchRecoveryAccount(inspection); XCTFail("An old account inspection cannot switch") } catch {}
        XCTAssertEqual(switches, 1)
    }

    @MainActor func testAppRecoveryServiceBindsZoneDecisionToAccount() async throws {
        var account = "first"
        let monitor = CloudReadingAccountMonitor(accountAvailable: { true }, accountName: { account })
        let zones = FakeZoneDatabase()
        var runs = 0
        let service = StandaloneCloudRecoveryService(monitor: monitor, zones: zones) { scope, zone, fence in
            guard try await fence(), scope.recoveryZoneID == zone else { throw CancellationError() }
            runs += 1
            return StandaloneRecoveryCycle.Report()
        }
        let missing = try await service.inspect()
        XCTAssertEqual(missing.zoneState, .missing)
        do { _ = try await service.run(missing); XCTFail("Missing zones cannot sync") } catch {}
        XCTAssertEqual(runs, 0); XCTAssertEqual(zones.creates, 0)
        let ready = try await service.createAfterReviewedDecision(missing)
        XCTAssertEqual(ready.zoneState, .present); XCTAssertEqual(zones.creates, 1)
        _ = try await service.run(ready); XCTAssertEqual(runs, 1)
        account = "second"
        do { _ = try await service.run(ready); XCTFail("A changed account cannot reuse the inspection") } catch {}
        XCTAssertEqual(runs, 1)
    }

    @MainActor func testMissingAndDeletedZonesRequireDecisionAndAccountFence() async throws {
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let database = FakeZoneDatabase()
        var valid = true
        let access = try CloudRecoveryZoneAccess(scope: scope, database: database, accountIsCurrent: { valid })
        let missing = try await access.inspect()
        XCTAssertEqual(missing, .missing); XCTAssertEqual(database.creates, 0)
        database.value = .deletedByUser
        do { try await access.createAfterReviewedDecision(); XCTFail("A deletion needs separate recovery review") } catch {}
        XCTAssertEqual(database.creates, 0)
        database.value = .missing; database.afterInspection = { valid = false }
        do { try await access.createAfterReviewedDecision(); XCTFail("An account change must stop creation") } catch {}
        XCTAssertEqual(database.creates, 0)
        valid = true; database.afterInspection = nil
        try await access.createAfterReviewedDecision()
        XCTAssertEqual(database.creates, 1)
        let present = try await access.inspect()
        XCTAssertEqual(present, .present)
    }

    @MainActor func testSupersededAccountCheckDoesNotInvalidateNewSession() async throws {
        var account = "first"
        var suspended = false
        var continuation: CheckedContinuation<Bool, Never>?
        let monitor = CloudReadingAccountMonitor(accountAvailable: {
            if suspended { return await withCheckedContinuation { continuation = $0 } }
            return true
        }, accountName: { account })
        let firstToken = try await monitor.refresh()
        let old = try XCTUnwrap(firstToken)
        suspended = true
        let check = Task { try await monitor.validate(old) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        guard let pending = continuation else { check.cancel(); return XCTFail("The account check did not suspend") }
        suspended = false; account = "second"
        let nextToken = try await monitor.refresh()
        let current = try XCTUnwrap(nextToken)
        pending.resume(returning: false)
        let oldResult = try await check.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(monitor.accepts(current))
        let stale = try await monitor.validate(old)
        XCTAssertFalse(stale); XCTAssertTrue(monitor.accepts(current))
        let valid = try await monitor.validate(current)
        XCTAssertTrue(valid)
    }

    @MainActor func testCancelledAccountValidationDoesNotInvalidateAnotherRequest() async throws {
        var suspended = false
        var continuation: CheckedContinuation<Bool, Never>?
        let monitor = CloudReadingAccountMonitor(accountAvailable: {
            if suspended { return await withCheckedContinuation { continuation = $0 } }
            return true
        }, accountName: { "account" })
        let refreshed = try await monitor.refresh()
        let token = try XCTUnwrap(refreshed)
        suspended = true
        let check = Task { try await monitor.validate(token) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        guard let pending = continuation else { check.cancel(); return XCTFail("The account check did not suspend") }
        check.cancel(); suspended = false; pending.resume(returning: true)
        let result = try await check.value
        XCTAssertFalse(result)
        XCTAssertTrue(monitor.accepts(token))
        let valid = try await monitor.validate(token)
        XCTAssertTrue(valid)
    }

    func testRecoveryZoneIdentityUsesSourceAndPrivateAccountScope() throws {
        let source = CloudReadingSource.jellyfin(serverID: "server", userID: "user")
        let first = try CloudReadingScope(cloudUserRecordName: "account", source: source)
        let same = try CloudReadingScope(accountKey: stableKey("account"), source: source)
        let other = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        XCTAssertEqual(first, same); XCTAssertEqual(first.recoveryZoneID, same.recoveryZoneID)
        XCTAssertNotEqual(first.recoveryZoneID, other.recoveryZoneID)
        XCTAssertFalse(first.recoveryZoneID.zoneName.contains("server"))
        XCTAssertThrowsError(try CloudReadingScope(accountKey: "invalid", source: source))
    }
    @MainActor func testReadingTransactionDoesNotWriteWhileAnotherSessionHoldsLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let lock = store.file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("\(scope.sourceKey).reading.lock")
        let bookmark = Bookmark(name: "Pending", position: ReadingPosition(page: 1))
        try PrivateBookFiles.withExclusiveLock(at: lock) {
            XCTAssertThrowsError(try store.set(bookmark, bookID: "book"))
            XCTAssertTrue(store.bookmarks.isEmpty)
        }
        try store.set(bookmark, bookID: "book")
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Pending")
    }
    @MainActor func testConflictResolutionPreservesOtherAlternativesAndQueuesReviewedChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try ReadingStore(namespace: "standalone", baseDirectory: root)
        try store.prepareAtomicReading(scope: scope, localToCloudBookIDs: ["local": identity.readingBookID])
        let atomic = try XCTUnwrap(store.cloudReadingStore)
        let digest = String(repeating: "a", count: 64)
        try atomic.setVerifiedEdition(localBookID: "local", fingerprint: digest)
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        let local = Bookmark(name: "Local", position: ReadingPosition(page: 1))
        try store.add(local, id: book.id)
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: local.id)
        let localRevision = try XCTUnwrap(atomic.outbox[key.recordName]?.entry.current.revision)
        var alternative = local; alternative.name = "Remote"
        let first = CloudReadingVersion(revision: UUID(), payload: .bookmark(alternative), editionFingerprint: digest)
        alternative.name = "Other"
        let second = CloudReadingVersion(revision: UUID(), payload: .bookmark(alternative), editionFingerprint: digest)
        try atomic.observe(key, bookID: identity.readingBookID, remote: first)
        try atomic.observe(key, bookID: identity.readingBookID, remote: second)
        XCTAssertThrowsError(try store.resolveCloudConflict(key, book: book, verifiedEditionFingerprint: digest, expectedLocalRevision: UUID(), remoteRevision: first.revision, choice: .remote))
        try store.resolveCloudConflict(key, book: book, verifiedEditionFingerprint: digest, expectedLocalRevision: localRevision, remoteRevision: first.revision, choice: .remote)
        XCTAssertEqual(store.bookmarks[book.id]?.first?.name, "Remote")
        let resolved = try XCTUnwrap(atomic.outbox[key.recordName]?.entry)
        XCTAssertEqual(resolved.baseRevision, first.revision)
        XCTAssertTrue(resolved.pending)
        XCTAssertEqual(resolved.conflicts.map(\.revision), [second.revision])
        try store.resolveCloudConflict(key, book: book, verifiedEditionFingerprint: digest, expectedLocalRevision: resolved.current.revision, remoteRevision: second.revision, choice: .local)
        let reopened = try ReadingStore(namespace: "standalone", baseDirectory: root)
        XCTAssertEqual(reopened.bookmarks[book.id]?.first?.name, "Remote")
        let final = try XCTUnwrap(reopened.cloudReadingStore?.outbox[key.recordName]?.entry)
        XCTAssertTrue(final.conflicts.isEmpty)
        XCTAssertTrue(final.pending)
        XCTAssertEqual(final.baseRevision, second.revision)
        XCTAssertEqual(final.current.editionFingerprint, digest)
    }
    @MainActor func testReviewListRequiresUnambiguousAccountBoundBook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        let mark = Bookmark(name: "Review me", position: ReadingPosition(page: 1))
        try store.set(mark, bookID: "local")
        var book = LocalBookEntry(id: "local", title: "Book", format: .pdf)
        XCTAssertTrue(StandaloneReadingReviewItem.collect(store: store, books: [book]).isEmpty)
        book.cloudIdentities = [scope.cloudAccountKey: identity]
        let items = StandaloneReadingReviewItem.collect(store: store, books: [book])
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.book.title, "Book")
        XCTAssertTrue(StandaloneReadingReviewItem.collect(store: store, books: [book, book]).isEmpty)
        if case .bookmark(let value) = items.first?.payload { XCTAssertEqual(value.name, "Review me") }
        else { XCTFail("The exact bookmark should be presented") }
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: mark.id)
        var remoteMark = mark; remoteMark.name = "Cloud version"
        let remote = CloudReadingVersion(revision: UUID(), payload: .bookmark(remoteMark), editionFingerprint: String(repeating: "a", count: 64))
        try store.observe(key, bookID: identity.readingBookID, remote: remote)
        let conflicts = StandaloneReadingConflictItem.collect(store: store, books: [book])
        XCTAssertEqual(conflicts.count, 1); XCTAssertEqual(conflicts.first?.remote.revision, remote.revision)
        XCTAssertTrue(StandaloneReadingConflictItem.collect(store: store, books: [book, book]).isEmpty)
    }

    @MainActor func testChoosingEarlierStagedCloudVersionAppliesItLocally() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        let mark = Bookmark(name: "Earlier", position: ReadingPosition(page: 1))
        var laterMark = mark; laterMark.name = "Later"
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: mark.id)
        let fingerprint = String(repeating: "a", count: 64)
        let earlier = CloudReadingVersion(revision: UUID(), payload: .bookmark(mark), editionFingerprint: fingerprint)
        let later = CloudReadingVersion(revision: UUID(), payload: .bookmark(laterMark), editionFingerprint: fingerprint)
        try store.observe(key, bookID: identity.readingBookID, remote: earlier)
        try store.observe(key, bookID: identity.readingBookID, remote: later)
        try store.setVerifiedEdition(localBookID: "local", fingerprint: fingerprint)
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        try store.resolveConflict(key, book: book, verifiedEditionFingerprint: fingerprint,
                                  expectedLocalRevision: earlier.revision, remoteRevision: later.revision, choice: .local)
        XCTAssertEqual(store.bookmarks[book.id]?.first?.name, "Earlier")
        XCTAssertTrue(try XCTUnwrap(store.outbox[key.recordName]).entry.pending)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.bookmarks[book.id]?.first?.name, "Earlier")
    }

    @MainActor func testReviewedLegacyChangeKeepsConflictsAndRejectsStaleReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        var bookmark = Bookmark(name: "Earlier", position: ReadingPosition(page: 1))
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: bookmark.id)
        try store.set(bookmark, bookID: "local")
        let stale = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        bookmark.name = "Reviewed"; try store.set(bookmark, bookID: "local")
        let current = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        let digest = String(repeating: "a", count: 64)
        let remote = CloudReadingVersion(revision: UUID(), payload: nil, editionFingerprint: digest)
        try store.observe(key, bookID: identity.readingBookID, remote: remote)
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        XCTAssertThrowsError(try store.certifyReviewedLocalVersion(key, book: book, expectedRevision: current, verifiedEditionFingerprint: digest))
        try store.setVerifiedEdition(localBookID: book.id, fingerprint: digest)
        XCTAssertThrowsError(try store.certifyReviewedLocalVersion(key, book: book, expectedRevision: stale, verifiedEditionFingerprint: digest))
        try store.certifyReviewedLocalVersion(key, book: book, expectedRevision: current, verifiedEditionFingerprint: digest)
        let reviewed = try XCTUnwrap(store.outbox[key.recordName])
        XCTAssertNotEqual(reviewed.entry.current.revision, current)
        XCTAssertEqual(reviewed.entry.current.editionFingerprint, digest)
        XCTAssertEqual(reviewed.entry.conflicts.map(\.revision), [remote.revision])
        XCTAssertTrue(reviewed.entry.pendingRevisions.contains(current)); XCTAssertTrue(reviewed.entry.pending)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.outbox[key.recordName]?.entry.current.revision, reviewed.entry.current.revision)
        XCTAssertEqual(reopened.outbox[key.recordName]?.entry.conflicts.map(\.revision), [remote.revision])
    }

    @MainActor func testChoosingLegacyConflictRequiresExplicitEditionConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        let digest = String(repeating: "a", count: 64)
        try store.setVerifiedEdition(localBookID: "local", fingerprint: digest)
        var bookmark = Bookmark(name: "Device", position: ReadingPosition(page: 1))
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: bookmark.id)
        try store.set(bookmark, bookID: "local")
        let local = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        bookmark.name = "Older cloud"
        let legacy = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark))
        try store.observe(key, bookID: identity.readingBookID, remote: legacy)
        bookmark.name = "Other edition"
        let different = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark), editionFingerprint: String(repeating: "b", count: 64))
        try store.observe(key, bookID: identity.readingBookID, remote: different)
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        XCTAssertThrowsError(try store.resolveConflict(key, book: book, verifiedEditionFingerprint: digest,
            expectedLocalRevision: local, remoteRevision: legacy.revision, choice: .remote))
        XCTAssertThrowsError(try store.resolveConflict(key, book: book, verifiedEditionFingerprint: digest,
            expectedLocalRevision: local, remoteRevision: different.revision, choice: .remote, confirmUnverifiedEdition: true))
        XCTAssertEqual(store.bookmarks[book.id]?.first?.name, "Device")
        try store.resolveConflict(key, book: book, verifiedEditionFingerprint: digest,
            expectedLocalRevision: local, remoteRevision: legacy.revision, choice: .remote, confirmUnverifiedEdition: true)
        let resolved = try XCTUnwrap(store.outbox[key.recordName])
        XCTAssertEqual(store.bookmarks[book.id]?.first?.name, "Older cloud")
        XCTAssertEqual(resolved.entry.current.editionFingerprint, digest)
        XCTAssertEqual(resolved.entry.baseRevision, legacy.revision)
        XCTAssertEqual(resolved.entry.conflicts.map(\.revision), [different.revision])
        XCTAssertTrue(resolved.entry.pending)
    }

    @MainActor func testReviewedLegacyDeletionRemainsTombstone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        let mark = Bookmark(name: "Deleted", position: ReadingPosition(page: 1))
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: mark.id)
        try store.set(mark, bookID: "local"); try store.remove(mark, bookID: "local")
        let revision = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        let digest = String(repeating: "b", count: 64)
        try store.setVerifiedEdition(localBookID: "local", fingerprint: digest)
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        try store.certifyReviewedLocalVersion(key, book: book, expectedRevision: revision, verifiedEditionFingerprint: digest)
        let reviewed = try XCTUnwrap(store.outbox[key.recordName])
        XCTAssertNil(reviewed.entry.current.payload); XCTAssertTrue(reviewed.entry.pending)
        XCTAssertEqual(reviewed.entry.current.editionFingerprint, digest)
        XCTAssertTrue(store.bookmarks[book.id]?.isEmpty ?? true)
    }

    @MainActor func testEditionVerificationIsSessionScopedAndNeverCertifiesOlderChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        var bookmark = Bookmark(name: "Legacy", position: ReadingPosition(page: 1))
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: bookmark.id)
        try store.set(bookmark, bookID: "local")
        let oldRevision = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        let digest = String(repeating: "a", count: 64)
        try store.setVerifiedEdition(localBookID: "local", fingerprint: digest)
        XCTAssertNil(store.outbox[key.recordName]?.entry.current.editionFingerprint)
        XCTAssertEqual(store.outbox[key.recordName]?.entry.current.revision, oldRevision)
        bookmark.name = "Verified"
        try store.set(bookmark, bookID: "local")
        XCTAssertEqual(store.outbox[key.recordName]?.entry.current.editionFingerprint, digest)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        bookmark.name = "Before recheck"
        try reopened.set(bookmark, bookID: "local")
        XCTAssertNil(reopened.outbox[key.recordName]?.entry.current.editionFingerprint)
        XCTAssertThrowsError(try reopened.setVerifiedEdition(localBookID: "local", fingerprint: String(repeating: "b", count: 64)))
        bookmark.name = "Changed edition"
        try reopened.set(bookmark, bookID: "local")
        XCTAssertNil(reopened.outbox[key.recordName]?.entry.current.editionFingerprint)
        try reopened.setVerifiedEdition(localBookID: "local", fingerprint: digest)
        bookmark.name = "Rechecked"
        try reopened.set(bookmark, bookID: "local")
        XCTAssertEqual(reopened.outbox[key.recordName]?.entry.current.editionFingerprint, digest)
    }

    @MainActor func testApplyVerifiedIncomingDataAtomicallyAndKeepTombstone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try ReadingStore(namespace: "standalone", baseDirectory: root)
        try store.prepareAtomicReading(scope: scope, localToCloudBookIDs: ["local": identity.readingBookID])
        let atomic = try XCTUnwrap(store.cloudReadingStore)
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .epub, isFolder: false, imageTag: nil, ticks: 0)
        let digest = String(repeating: "a", count: 64)
        let bookmark = Bookmark(name: "Remote", position: ReadingPosition(fraction: 0.5, cfi: "epubcfi(/6/2!/4/2:1)"))
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: bookmark.id)
        let remote = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark), editionFingerprint: digest)
        try atomic.observe(key, bookID: identity.readingBookID, remote: remote)
        try atomic.setVerifiedEdition(localBookID: book.id, fingerprint: digest)
        XCTAssertThrowsError(try store.applyObservedCloudVersion(key, book: book, verifiedEditionFingerprint: String(repeating: "b", count: 64), expectedRevision: remote.revision))
        XCTAssertThrowsError(try store.applyObservedCloudVersion(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: UUID()))
        XCTAssertTrue(store.bookmarks.isEmpty)
        try store.applyObservedCloudVersion(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: remote.revision)
        XCTAssertEqual(store.bookmarks["local"]?.first?.name, "Remote")
        XCTAssertFalse(try XCTUnwrap(atomic.outbox[key.recordName]).entry.pending)
        let deletion = CloudReadingVersion(revision: UUID(), payload: nil, editionFingerprint: digest)
        try atomic.observe(key, bookID: identity.readingBookID, remote: deletion)
        try store.applyObservedCloudVersion(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: deletion.revision)
        let reopened = try ReadingStore(namespace: "standalone", baseDirectory: root)
        XCTAssertTrue(reopened.bookmarks["local"]?.isEmpty == true)
        let entry = try XCTUnwrap(reopened.cloudReadingStore?.outbox[key.recordName])
        XCTAssertNil(entry.entry.current.payload)
        XCTAssertEqual(entry.entry.current.revision, deletion.revision)
        XCTAssertFalse(entry.entry.pending)
    }

    @MainActor func testLegacyOrMismatchedEditionIsNotApplied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .position)
        let version = CloudReadingVersion(revision: UUID(), payload: .position(CloudPrecisePosition(position: ReadingPosition(page: 4), contentFingerprint: nil, acknowledgedServerTicks: nil)))
        try store.observe(key, bookID: identity.readingBookID, remote: version)
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        try store.setVerifiedEdition(localBookID: book.id, fingerprint: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try store.applyObserved(key, book: book, verifiedEditionFingerprint: String(repeating: "a", count: 64), expectedRevision: version.revision))
        XCTAssertNil(store.records["local"])
        XCTAssertTrue(try XCTUnwrap(store.outbox[key.recordName]).pendingApplication == true)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.outbox[key.recordName]?.entry.current.revision, version.revision)
    }

    @MainActor func testReviewedIncomingLegacyVersionUsesNewConditionalRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:],
                                                baseDirectory: root, localToCloudBookIDs: ["local": identity.readingBookID])
        let book = Book(id: "local", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        let digest = String(repeating: "a", count: 64)
        try store.setVerifiedEdition(localBookID: book.id, fingerprint: digest)
        let bookmark = Bookmark(name: "Older cloud", position: ReadingPosition(page: 1))
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: bookmark.id)
        let legacy = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark))
        try store.observe(key, bookID: identity.readingBookID, remote: legacy)
        XCTAssertThrowsError(try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: legacy.revision))
        XCTAssertThrowsError(try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: UUID(), confirmLegacyEdition: true))
        XCTAssertTrue(store.bookmarks.isEmpty)
        try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: legacy.revision, confirmLegacyEdition: true)
        let item = try XCTUnwrap(store.outbox[key.recordName])
        XCTAssertEqual(store.bookmarks[book.id]?.first?.name, "Older cloud")
        XCTAssertEqual(item.entry.baseRevision, legacy.revision)
        XCTAssertNotEqual(item.entry.current.revision, legacy.revision)
        XCTAssertEqual(item.entry.current.editionFingerprint, digest)
        XCTAssertTrue(item.entry.pending); XCTAssertFalse(item.pendingApplication == true)
        let different = Bookmark(name: "Different edition", position: ReadingPosition(page: 1))
        let differentKey = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: different.id)
        let differentVersion = CloudReadingVersion(revision: UUID(), payload: .bookmark(different), editionFingerprint: String(repeating: "b", count: 64))
        try store.observe(differentKey, bookID: identity.readingBookID, remote: differentVersion)
        XCTAssertThrowsError(try store.applyObserved(differentKey, book: book, verifiedEditionFingerprint: digest,
            expectedRevision: differentVersion.revision, confirmLegacyEdition: true))
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.bookmarks[book.id]?.first?.id, bookmark.id)
        XCTAssertEqual(reopened.outbox[key.recordName]?.entry.current.revision, item.entry.current.revision)
    }

    @MainActor func testJellyfinPositionRequiresMatchingServerProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: "server", userID: "user"))
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let digest = String(repeating: "c", count: 64)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let remote = CloudReadingVersion(revision: UUID(), payload: .position(CloudPrecisePosition(position: ReadingPosition(page: 8), contentFingerprint: nil, acknowledgedServerTicks: 20_000)), editionFingerprint: digest)
        try store.observe(key, bookID: "book", remote: remote)
        var book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 30_000)
        XCTAssertThrowsError(try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: remote.revision))
        XCTAssertNil(store.records[book.id]); XCTAssertTrue(try XCTUnwrap(store.outbox[key.recordName]).pendingApplication == true)
        book.ticks = 20_000
        try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: remote.revision)
        XCTAssertEqual(store.records[book.id]?.position.page, 8)
        XCTAssertEqual(store.records[book.id]?.acknowledgedTicks, 20_000)
    }

    @MainActor func testCloudPositionDoesNotOverwriteUnsyncedServerProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .jellyfin(serverID: "server", userID: "user"))
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let digest = String(repeating: "c", count: 64)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        let local = ReadingRecord(position: ReadingPosition(page: 2), acknowledgedTicks: 0, dirty: true, updated: Date(), title: "Book", format: .pdf)
        try store.set(local, bookID: "book")
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let uploaded = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        try store.acknowledge(key, revision: uploaded)
        let remote = CloudReadingVersion(revision: UUID(), payload: .position(CloudPrecisePosition(position: ReadingPosition(page: 8), contentFingerprint: nil, acknowledgedServerTicks: nil)), editionFingerprint: digest)
        try store.observe(key, bookID: "book", remote: remote)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
        XCTAssertThrowsError(try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: remote.revision))
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.records[book.id]?.position.page, 2)
        XCTAssertTrue(try XCTUnwrap(reopened.records[book.id]).dirty)
        XCTAssertTrue(try XCTUnwrap(reopened.outbox[key.recordName]).pendingApplication == true)
    }

    @MainActor func testInvalidRemoteBookmarkStaysStaged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let digest = String(repeating: "d", count: 64)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        let bookmark = Bookmark(name: "Invalid", position: ReadingPosition(fraction: 2, page: 0))
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: bookmark.id)
        let remote = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark), editionFingerprint: digest)
        try store.observe(key, bookID: "book", remote: remote)
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .epub, isFolder: false, imageTag: nil, ticks: 0)
        XCTAssertThrowsError(try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: remote.revision))
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.outbox[key.recordName]).pendingApplication == true)
    }

    @MainActor func testUnrepresentableRestoredPagesStayStagedAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let digest = String(repeating: "d", count: 64)
        for format in [BookFormat.pdf, .cbz] {
            let book = Book(id: format.rawValue, title: "Synthetic", author: "", summary: "", format: format, isFolder: false, ticks: 0)
            try store.setVerifiedEdition(localBookID: book.id, fingerprint: digest)
            let bookmark = Bookmark(name: "Invalid page", position: .init(page: Int.max))
            for payload in [CloudReadingPayload.bookmark(bookmark), .position(CloudPrecisePosition(position: .init(page: Int.max), contentFingerprint: digest, acknowledgedServerTicks: nil))] {
                let key = try CloudReadingKey(scope: scope, bookID: book.id, kind: payload.kind, itemID: payload.itemID)
                let remote = CloudReadingVersion(revision: UUID(), payload: payload, editionFingerprint: digest)
                try store.observe(key, bookID: book.id, remote: remote)
                XCTAssertThrowsError(try store.applyObserved(key, book: book, verifiedEditionFingerprint: digest, expectedRevision: remote.revision))
                let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
                XCTAssertTrue(reopened.records.isEmpty)
                XCTAssertTrue(reopened.bookmarks.isEmpty)
                XCTAssertTrue(try XCTUnwrap(reopened.outbox[key.recordName]).pendingApplication == true)
            }
        }
    }

    @MainActor func testStandaloneMigrationUsesStableCloudIdentityAndRetainsLocalKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let store = try ReadingStore(namespace: "standalone", baseDirectory: root)
        let record = ReadingRecord(position: ReadingPosition(page: 8), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        let mark = Bookmark(name: "Page", position: record.position)
        try store.set(record, id: "device-book"); try store.add(mark, id: "device-book")
        try store.prepareAtomicReading(scope: scope, localToCloudBookIDs: ["device-book": id.readingBookID])
        let reopened = try ReadingStore(namespace: "standalone", baseDirectory: root)
        XCTAssertEqual(reopened.records["device-book"]?.position.page, 8)
        try reopened.renameBookmark(mark, id: "device-book", name: "Renamed")
        let atomic = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        let key = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .bookmark, itemID: mark.id)
        XCTAssertEqual(atomic.outbox[key.recordName]?.bookID, id.readingBookID)
        XCTAssertEqual(atomic.bookmarks["device-book"]?.first?.name, "Renamed")
        XCTAssertThrowsError(try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["device-book": CloudStandaloneBookID().readingBookID]))
    }

    @MainActor func testStandaloneBindingsRejectMissingDuplicateAndChangedIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let id = CloudStandaloneBookID()
        let record = ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        XCTAssertThrowsError(try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: ["a": id.readingBookID, "b": id.readingBookID]))
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: [:])
        try store.set(record, bookID: "new")
        XCTAssertEqual(store.records["new"]?.position.page, 1)
        XCTAssertTrue(store.hasUnmappedReadingData)
        XCTAssertTrue(store.outbox.isEmpty)
        let beforeBinding = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertTrue(beforeBinding.hasUnmappedReadingData)
        try store.bind(localBookID: "new", cloudBookID: id)
        XCTAssertFalse(store.hasUnmappedReadingData)
        XCTAssertThrowsError(try store.bind(localBookID: "new", cloudBookID: CloudStandaloneBookID()))
        XCTAssertThrowsError(try store.bind(localBookID: "other", cloudBookID: id))
        let key = try CloudReadingKey(scope: scope, bookID: id.readingBookID, kind: .position)
        XCTAssertEqual(store.outbox[key.recordName]?.bookID, id.readingBookID)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertEqual(reopened.localToCloudBookIDs?["new"], id.readingBookID)
    }

    @MainActor func testUnmappedDeletionSurvivesRestartAndConflictsWithRemoteValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let identity = CloudStandaloneBookID()
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, localToCloudBookIDs: [:])
        let bookmark = Bookmark(name: "Removed locally", position: ReadingPosition(page: 4))
        try store.set(bookmark, bookID: "device-book")
        try store.remove(bookmark, bookID: "device-book")
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        XCTAssertTrue(reopened.hasUnmappedReadingData)
        let key = try CloudReadingKey(scope: scope, bookID: identity.readingBookID, kind: .bookmark, itemID: bookmark.id)
        let remote = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark))
        try reopened.observe(key, bookID: identity.readingBookID, remote: remote)
        try reopened.bind(localBookID: "device-book", cloudBookID: identity)
        let result = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        let item = try XCTUnwrap(result.outbox[key.recordName])
        XCTAssertNil(item.entry.current.payload)
        XCTAssertTrue(item.entry.pending)
        XCTAssertEqual(item.entry.conflicts.map(\.revision), [remote.revision])
        XCTAssertFalse(result.hasUnmappedReadingData)
        XCTAssertTrue(result.bookmarks["device-book"]?.isEmpty == true)
    }
    @MainActor func testAtomicOutboxAcknowledgesOlderEditWithoutLosingNewerEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        var record = ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        try store.set(record, bookID: "book")
        let first = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        record.position.page = 2
        try store.set(record, bookID: "book")
        let second = try XCTUnwrap(store.outbox[key.recordName]?.entry.current.revision)
        try store.acknowledge(key, revision: first)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let entry = try XCTUnwrap(reopened.outbox[key.recordName]?.entry)
        XCTAssertEqual(entry.baseRevision, first)
        XCTAssertEqual(entry.current.revision, second)
        XCTAssertEqual(entry.pendingRevisions, [second])
        XCTAssertTrue(entry.pending)
        XCTAssertEqual(reopened.records["book"]?.position.page, 2)
    }

    @MainActor func testAtomicIncomingVersionAndLocalEditSurviveRestartAsConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "synthetic", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let bookmark = Bookmark(name: "Remote", position: ReadingPosition(page: 2))
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: bookmark.id)
        let remote = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark))
        XCTAssertThrowsError(try store.observe(key, bookID: "other", remote: remote))
        try store.observe(key, bookID: "book", remote: remote)
        XCTAssertTrue(store.bookmarks.isEmpty) // Edition identity has not been verified.
        var local = bookmark; local.name = "Local"
        try store.set(local, bookID: "book")
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let item = try XCTUnwrap(reopened.outbox[key.recordName])
        XCTAssertEqual(reopened.bookmarks["book"]?.first?.name, "Local")
        XCTAssertTrue(item.entry.pending)
        XCTAssertEqual(item.entry.conflicts.map(\.revision), [remote.revision])
        let inconsistent = CloudReadingVersion(revision: remote.revision, payload: nil)
        XCTAssertThrowsError(try reopened.observe(key, bookID: "book", remote: inconsistent))
    }

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

    @MainActor final class FakeRecordDatabase: CloudReadingRecordDatabase {
        var value: CKRecord?
        var forcedConflict: CKRecord?
        var afterSave: (() -> Void)?
        var saves = 0
        func fetch(_ id: CKRecord.ID) async throws -> CKRecord? {
            guard let value, value.recordID == id else { return nil }
            return value.copy() as? CKRecord
        }
        func saveIfUnchanged(_ record: CKRecord) async throws -> CloudReadingRecordSaveResult {
            if let forcedConflict { value = forcedConflict; return .conflict(forcedConflict) }
            saves += 1; value = record.copy() as? CKRecord; afterSave?(); return .saved
        }
    }

    @MainActor func testCloudKitRecordErrorsExtractOnlyTheConflictingItem() {
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let id = CKRecord.ID(recordName: "one", zoneID: zone)
        let other = CKRecord.ID(recordName: "other", zoneID: zone)
        let server = CKRecord(recordType: "ReadingDataV1", recordID: id)
        let conflict = NSError(domain: CKErrorDomain, code: CKError.Code.serverRecordChanged.rawValue,
                               userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
                              userInfo: [CKPartialErrorsByItemIDKey: [id: conflict]])
        XCTAssertEqual(CloudKitReadingRecordDatabase.conflictRecord(from: conflict, recordID: id)?.recordID, id)
        XCTAssertEqual(CloudKitReadingRecordDatabase.conflictRecord(from: partial, recordID: id)?.recordID, id)
        XCTAssertNil(CloudKitReadingRecordDatabase.conflictRecord(from: partial, recordID: other))
    }

    @MainActor func testConditionalCloudTransportKeepsRacingRemoteVersionAndRejectsMissingBase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let journal = try CloudReadingJournal(scope: scope, baseDirectory: root)
        let payload = CloudReadingPayload.position(CloudPrecisePosition(position: ReadingPosition(page: 2), contentFingerprint: nil, acknowledgedServerTicks: nil))
        try journal.edit(key, payload: payload)
        var first = try XCTUnwrap(journal.entries[key.recordName])
        first.current.editionFingerprint = String(repeating: "a", count: 64)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let database = FakeRecordDatabase()
        let transport = try CloudKitReadingTransport(scope: scope, bookID: "book", zoneID: zone, database: database, accountIsCurrent: { true })
        guard case .saved = try await transport.upload(first, expected: nil) else { return XCTFail("The first record should be saved") }
        let fetched = try await transport.fetch(key)
        XCTAssertEqual(fetched?.revision, first.current.revision)
        var local = first; local.current = CloudReadingVersion(revision: UUID(), payload: payload, editionFingerprint: String(repeating: "a", count: 64))
        var competing = first; competing.current = CloudReadingVersion(revision: UUID(), payload: nil)
        database.forcedConflict = try CloudReadingRecordCodec.record(entry: competing, bookID: "book", zoneID: zone)
        guard case .conflict(let remote) = try await transport.upload(local, expected: first.current.revision) else { return XCTFail("A racing version must be retained") }
        XCTAssertEqual(remote.revision, competing.current.revision)
        XCTAssertEqual(database.saves, 1)
        database.forcedConflict = nil; database.value = nil
        do { _ = try await transport.upload(local, expected: first.current.revision); XCTFail("A missing acknowledged record needs recovery") } catch {}
        XCTAssertEqual(database.saves, 1)
    }

    @MainActor func testConditionalCloudTransportFencesAccountChangesAndWrongBook() async throws {
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let entry = CloudReadingEntry(key: key, current: CloudReadingVersion(revision: UUID(), payload: nil, editionFingerprint: String(repeating: "a", count: 64)), baseRevision: nil, pending: true, pendingRevisions: [], conflicts: [])
        let database = FakeRecordDatabase()
        var current = true
        database.afterSave = { current = false }
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let transport = try CloudKitReadingTransport(scope: scope, bookID: "book", zoneID: zone, database: database, accountIsCurrent: { current })
        let other = try CloudReadingKey(scope: scope, bookID: "other", kind: .position)
        do { _ = try await transport.fetch(other); XCTFail("Another book must be rejected") } catch {}
        do { _ = try await transport.upload(entry, expected: nil); XCTFail("An account change must not acknowledge a write") } catch {}
        XCTAssertEqual(database.saves, 1)
    }

    @MainActor func testCancelledSaveKeepsLocalChangePendingUntilRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: String(repeating: "a", count: 64))
        let bookmark = Bookmark(name: "Interrupted save", position: ReadingPosition(page: 1))
        try store.set(bookmark, bookID: "book")
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: bookmark.id)
        let database = FakeRecordDatabase()
        let transport = try CloudKitReadingTransport(scope: scope, bookID: "book", zoneID: scope.recoveryZoneID,
                                                      database: database, accountIsCurrent: { true })
        let coordinator = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: { true })
        var operation: Task<Void, Never>?
        database.afterSave = { operation?.cancel() }
        operation = Task { await coordinator.sync(key, bookID: "book") }
        await operation?.value
        XCTAssertEqual(database.saves, 1)
        XCTAssertTrue(try XCTUnwrap(store.outbox[key.recordName]).entry.pending)
        database.afterSave = nil
        await coordinator.sync(key, bookID: "book")
        XCTAssertFalse(try XCTUnwrap(store.outbox[key.recordName]).entry.pending)
        XCTAssertEqual(database.saves, 1, "Retry must recognize a save that already reached the server")
    }

    @MainActor func testCoordinatorDoesNotAcknowledgeCancelledTransportThatReturnsSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: String(repeating: "a", count: 64))
        let bookmark = Bookmark(name: "Interrupted transport", position: ReadingPosition(page: 1))
        try store.set(bookmark, bookID: "book")
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: bookmark.id)
        let transport = FakeTransport()
        let coordinator = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: { true })
        var operation: Task<Void, Never>?
        transport.afterUpload = { operation?.cancel() }
        operation = Task { await coordinator.sync(key, bookID: "book") }
        await operation?.value
        XCTAssertEqual(transport.uploadCount, 1)
        XCTAssertTrue(try XCTUnwrap(store.outbox[key.recordName]).entry.pending)
        transport.afterUpload = nil
        await coordinator.sync(key, bookID: "book")
        XCTAssertFalse(try XCTUnwrap(store.outbox[key.recordName]).entry.pending)
        XCTAssertEqual(transport.uploadCount, 1)
    }

    @MainActor func testConditionalRetryAcknowledgesAlreadySavedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: String(repeating: "a", count: 64))
        let local = ReadingRecord(position: ReadingPosition(page: 3), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        try store.set(local, bookID: "book")
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let entry = try XCTUnwrap(store.outbox[key.recordName]?.entry)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let database = FakeRecordDatabase()
        database.forcedConflict = try CloudReadingRecordCodec.record(entry: entry, bookID: "book", zoneID: zone)
        let transport = try CloudKitReadingTransport(scope: scope, bookID: "book", zoneID: zone, database: database, accountIsCurrent: { true })
        let coordinator = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: { true })
        await coordinator.sync(key, bookID: "book")
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertFalse(try XCTUnwrap(store.outbox[key.recordName]?.entry).pending)
    }

    @MainActor func testAtomicSyncPreservesInFlightEditAndFencesAccountChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: String(repeating: "a", count: 64))
        var record = ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        try store.set(record, bookID: "book")
        let transport = FakeTransport()
        transport.afterUpload = { record.position.page = 2; try store.set(record, bookID: "book") }
        let sync = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: { true })
        await sync.sync(key, bookID: "book")
        XCTAssertEqual(sync.status, .pending)
        XCTAssertEqual(store.records["book"]?.position.page, 2)
        XCTAssertEqual(store.outbox[key.recordName]?.entry.baseRevision, transport.value?.revision)
        var current = true
        transport.afterUpload = { current = false }
        let switched = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: { current })
        await switched.sync(key, bookID: "book")
        XCTAssertEqual(switched.status, .accountChanged)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        XCTAssertTrue(try XCTUnwrap(reopened.outbox[key.recordName]).entry.pending)
        XCTAssertEqual(reopened.records["book"]?.position.page, 2)
    }

    @MainActor func testAccountSwitchKeepsLocalEditsAndResumesOriginalRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var currentAccount = "first"
        let monitor = CloudReadingAccountMonitor(accountAvailable: { true }, accountName: { currentAccount })
        let initialToken = try await monitor.refresh()
        let firstToken = try XCTUnwrap(initialToken)
        let scope = try monitor.scope(for: firstToken, source: .imported)
        let store = try ReadingStore(namespace: "synthetic-switch", baseDirectory: root)
        try store.prepareAtomicReading(scope: scope)
        let atomic = try XCTUnwrap(store.cloudReadingStore)
        try atomic.setVerifiedEdition(localBookID: "book", fingerprint: String(repeating: "a", count: 64))
        var record = ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        try store.set(record, id: "book")
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let firstCloud = FakeTransport()
        let initial = CloudAtomicReadingSyncCoordinator(store: atomic, transport: firstCloud, accountIsCurrent: { try await monitor.validate(firstToken) })
        await initial.sync(key, bookID: "book")
        XCTAssertEqual(initial.status, .idle)
        currentAccount = "second"
        record.position.page = 2
        try store.set(record, id: "book")
        let secondCloud = FakeTransport()
        let rejected = CloudAtomicReadingSyncCoordinator(store: atomic, transport: secondCloud, accountIsCurrent: { try await monitor.validate(firstToken) })
        await rejected.sync(key, bookID: "book")
        XCTAssertEqual(rejected.status, .accountChanged); XCTAssertEqual(secondCloud.uploadCount, 0)
        let switchedToken = try await monitor.refresh()
        let secondToken = try XCTUnwrap(switchedToken)
        let secondScope = try monitor.scope(for: secondToken, source: .imported)
        XCTAssertThrowsError(try store.requireRecoveryScope(secondScope))
        record.position.page = 3
        try store.set(record, id: "book")
        XCTAssertEqual(store.records["book"]?.position.page, 3)
        currentAccount = "first"
        let returnedToken = try await monitor.refresh()
        let resumedToken = try XCTUnwrap(returnedToken)
        try store.requireRecoveryScope(try monitor.scope(for: resumedToken, source: .imported))
        let resumed = CloudAtomicReadingSyncCoordinator(store: atomic, transport: firstCloud, accountIsCurrent: { try await monitor.validate(resumedToken) })
        await resumed.sync(key, bookID: "book")
        XCTAssertEqual(resumed.status, .idle)
        guard case .position(let value) = firstCloud.value?.payload else { return XCTFail("The final position should reach the original account") }
        XCTAssertEqual(value.position.page, 3); XCTAssertEqual(secondCloud.uploadCount, 0)
        let reopened = try ReadingStore(namespace: "synthetic-switch", baseDirectory: root)
        XCTAssertEqual(reopened.records["book"]?.position.page, 3)
    }

    @MainActor func testStaleSessionCannotReplayOrUploadAfterAnotherSessionEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let first = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let digest = String(repeating: "a", count: 64)
        try first.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        let record = ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        try first.set(record, bookID: "book")
        let mark = Bookmark(name: "Incoming", position: ReadingPosition(page: 1))
        let markKey = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: mark.id)
        let incoming = CloudReadingVersion(revision: UUID(), payload: .bookmark(mark))
        try first.observe(markKey, bookID: "book", remote: incoming)
        let stale = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        try stale.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        var changed = record; changed.position.page = 2
        try first.set(changed, bookID: "book")
        XCTAssertThrowsError(try stale.observe(markKey, bookID: "book", remote: incoming))
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let transport = FakeTransport()
        let sync = CloudAtomicReadingSyncCoordinator(store: stale, transport: transport, accountIsCurrent: { true })
        await sync.sync(key, bookID: "book")
        guard case .failed = sync.status else { return XCTFail("A stale session must stop before upload") }
        XCTAssertEqual(transport.uploadCount, 0)
    }

    @MainActor func testSyncRechecksLocalEditAfterAccountFence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: String(repeating: "a", count: 64))
        var record = ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        try store.set(record, bookID: "book")
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        let transport = FakeTransport()
        var checks = 0
        let sync = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: {
            checks += 1
            if checks == 3 { record.position.page = 2; try store.set(record, bookID: "book") }
            return true
        })
        await sync.sync(key, bookID: "book")
        XCTAssertEqual(sync.status, .pending)
        XCTAssertEqual(transport.uploadCount, 0)
        XCTAssertEqual(store.records["book"]?.position.page, 2)
        await sync.sync(key, bookID: "book")
        XCTAssertEqual(sync.status, .idle)
        XCTAssertEqual(transport.uploadCount, 1)
    }

    @MainActor func testAtomicSyncDoesNotUploadUnverifiedOrPreviousSessionEdition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .position)
        var record = ReadingRecord(position: ReadingPosition(page: 1), acknowledgedTicks: 0, dirty: false, updated: Date(), title: "Book", format: .pdf)
        try store.set(record, bookID: "book")
        let transport = FakeTransport()
        let sync = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: { true })
        await sync.sync(key, bookID: "book")
        XCTAssertEqual(sync.status, .needsEditionVerification)
        XCTAssertEqual(transport.uploadCount, 0)
        let digest = String(repeating: "a", count: 64)
        try store.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        await sync.sync(key, bookID: "book")
        XCTAssertEqual(sync.status, .needsEditionVerification) // Legacy change is not retroactively certified.
        record.position.page = 2
        try store.set(record, bookID: "book")
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root, requireExisting: true)
        let resumed = CloudAtomicReadingSyncCoordinator(store: reopened, transport: transport, accountIsCurrent: { true })
        await resumed.sync(key, bookID: "book")
        XCTAssertEqual(resumed.status, .needsEditionVerification)
        XCTAssertEqual(transport.uploadCount, 0)
        try reopened.setVerifiedEdition(localBookID: "book", fingerprint: digest)
        await resumed.sync(key, bookID: "book")
        XCTAssertEqual(resumed.status, .idle)
        XCTAssertEqual(transport.uploadCount, 1)
    }

    @MainActor func testAtomicSyncStagesRemoteWithoutOverwritingUnverifiedBook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try CloudReadingScope(cloudUserRecordName: "account", source: .imported)
        let store = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        let bookmark = Bookmark(name: "Remote", position: ReadingPosition(page: 3))
        let key = try CloudReadingKey(scope: scope, bookID: "book", kind: .bookmark, itemID: bookmark.id)
        let transport = FakeTransport()
        transport.value = CloudReadingVersion(revision: UUID(), payload: .bookmark(bookmark))
        let sync = CloudAtomicReadingSyncCoordinator(store: store, transport: transport, accountIsCurrent: { true })
        await sync.sync(key, bookID: "book")
        XCTAssertEqual(sync.status, .needsApplication)
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertEqual(transport.uploadCount, 0)
        let reopened = try CloudAtomicReadingStore(scope: scope, legacyRecords: [:], legacyBookmarks: [:], legacyAnnotations: [:], baseDirectory: root)
        XCTAssertEqual(reopened.outbox[key.recordName]?.pendingApplication, true)
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
        let inconsistent = CloudReadingVersion(revision: first.revision, payload: .position(CloudPrecisePosition(position: ReadingPosition(page: 1), contentFingerprint: nil, acknowledgedServerTicks: nil)))
        XCTAssertThrowsError(try journal.observe(key, remote: inconsistent))
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
        var entry = try XCTUnwrap(journal.entries[key.recordName])
        entry.current.editionFingerprint = String(repeating: "a", count: 64)
        let zone = CKRecordZone.ID(zoneName: "synthetic", ownerName: CKCurrentUserDefaultName)
        let record = try CloudReadingRecordCodec.record(entry: entry, bookID: "book", zoneID: zone)
        XCTAssertThrowsError(try CloudReadingRecordCodec.record(entry: entry, bookID: "different", zoneID: zone))
        XCTAssertNotNil(record.encryptedValues["readingData"])
        let (decodedKey, decodedBookID, decoded) = try CloudReadingRecordCodec.decode(record, expectedSource: scope.sourceKey)
        XCTAssertEqual(decodedKey, key)
        XCTAssertEqual(decodedBookID, "book")
        XCTAssertEqual(decoded.revision, entry.current.revision)
        XCTAssertEqual(decoded.editionFingerprint, entry.current.editionFingerprint)
        XCTAssertThrowsError(try CloudReadingRecordCodec.decode(record, expectedSource: "other"))
    }
}
