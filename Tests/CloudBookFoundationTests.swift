import XCTest
import CloudKit
import CryptoKit
@testable import BookCore

final class CloudBookFoundationTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Harbor.pdf")
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
