import Foundation
import CloudKit
import CryptoKit
import PDFKit
import Darwin

/// This identity is assigned once per standalone library item. It is neither
/// the local folder path nor a digest, so equal editions can remain separate.
struct CloudStandaloneBookID: Codable, Hashable, Sendable {
    let value: UUID
    init(_ value: UUID = UUID()) { self.value = value }
    var readingBookID: String { "cloud-book-\(value.uuidString.lowercased())" }
}

struct CloudBookMetadata: Codable, Equatable, Sendable {
    let accountKey: String
    let sourceKey: String
    let bookID: CloudStandaloneBookID
    let revision: UUID
    let title: String
    let format: BookFormat
    let byteCount: Int64
    let sha256: String

    var recordName: String { stableKey("\(sourceKey)|\(bookID.readingBookID)|book-file") }
    func validate(scope: CloudReadingScope) throws {
        guard scope.isValid, accountKey == scope.cloudAccountKey, sourceKey == scope.sourceKey,
              sourceKey == (try CloudReadingSource.imported.key()),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 512,
              format != .unsupported, byteCount > 0, byteCount <= 512 * 1024 * 1024,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ReaderError.message("The iCloud book metadata is invalid or belongs to another account.")
        }
    }
}

/// A cloud deletion is a retained version, not a physical record deletion.
/// It never authorizes deleting a user's original file or a server item.
struct CloudBookTombstone: Codable, Equatable, Sendable {
    let accountKey: String
    let sourceKey: String
    let bookID: CloudStandaloneBookID
    let revision: UUID

    var recordName: String { stableKey("\(sourceKey)|\(bookID.readingBookID)|book-file") }
    func validate(scope: CloudReadingScope) throws {
        guard scope.isValid, accountKey == scope.cloudAccountKey, sourceKey == scope.sourceKey,
              sourceKey == (try CloudReadingSource.imported.key()) else {
            throw ReaderError.message("The iCloud book deletion belongs to a different account or source.")
        }
    }
}

enum CloudBookRecordValue {
    case book(CloudBookMetadata, URL)
    case tombstone(CloudBookTombstone)

    var revision: UUID {
        switch self { case .book(let metadata, _): metadata.revision; case .tombstone(let tombstone): tombstone.revision }
    }
}

struct StagedCloudBook: Sendable {
    let metadata: CloudBookMetadata
    let assetURL: URL
}

/// Holds an advisory lock until CloudKit has finished reading the staged asset.
final class CloudBookAssetLease: @unchecked Sendable {
    let staged: StagedCloudBook
    private let descriptor: Int32
    fileprivate init(staged: StagedCloudBook, descriptor: Int32) { self.staged = staged; self.descriptor = descriptor }
    deinit { _ = close(descriptor) }
}

/// Local staging only. A completed revision remains available for retry until
/// the future transport explicitly retires it. No source file is modified.
actor CloudBookStager {
    private let root: URL
    private let maxBookBytes: Int64
    let scope: CloudReadingScope
    init(scope: CloudReadingScope, baseDirectory: URL? = nil, maxBookBytes: Int64 = 512 * 1024 * 1024) throws {
        guard scope.sourceKey == (try CloudReadingSource.imported.key()) else { throw ReaderError.message("Only standalone books can be staged here.") }
        guard maxBookBytes > 0, maxBookBytes <= 512 * 1024 * 1024 else { throw ReaderError.message("The staging limit is invalid.") }
        self.scope = scope
        self.maxBookBytes = maxBookBytes
        root = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("LibraViaCloudBooks/\(scope.cloudAccountKey)/\(scope.sourceKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
    }

    /// `expected` is supplied for downloads. Integrity is checked before the
    /// completed revision is made visible; partial copies stay uncommitted.
    func stage(source: URL, bookID: CloudStandaloneBookID, title: String, format: BookFormat,
               revision: UUID = UUID(), expected: CloudBookMetadata? = nil, expectedSHA256: String? = nil,
               archiveScript: URL? = nil) async throws -> StagedCloudBook {
        if let expected {
            try expected.validate(scope: scope)
            guard expected.bookID == bookID, expected.revision == revision, expected.format == format, expected.title == title else {
                throw ReaderError.message("The downloaded book metadata does not match this item.")
            }
        }
        let fm = FileManager.default
        let temp = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        try PrivateBookFiles.protect(temp)
        let asset = temp.appendingPathComponent("original")
        let limit = maxBookBytes
        let work = Task.detached(priority: .utility) { try Self.copyAndHash(source: source, destination: asset, maxBytes: limit) }
        let (size, digest) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        let metadata = CloudBookMetadata(accountKey: scope.cloudAccountKey, sourceKey: scope.sourceKey, bookID: bookID,
                                         revision: revision, title: title, format: format, byteCount: size, sha256: digest)
        try metadata.validate(scope: scope)
        if let expectedSHA256, digest != expectedSHA256 { throw ReaderError.message("The retained original does not match this saved edition. Reselect the matching original.") }
        if let expected, expected != metadata { throw ReaderError.message("The downloaded book is incomplete or damaged.") }
        if format == .pdf {
            guard let document = PDFDocument(url: asset), !document.isLocked, document.pageCount > 0 else { throw ReaderError.message("The PDF is damaged or locked.") }
        } else {
            let unpacked = temp.appendingPathComponent("validation", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
            try await ArchiveExtractor.extract(asset, to: unpacked, scriptURL: archiveScript)
            _ = try BookCache.contents(unpacked, format: format)
            try fm.removeItem(at: unpacked)
        }
        try Task.checkCancellation()
        try PrivateBookFiles.write(JSONEncoder().encode(metadata), to: temp.appendingPathComponent("metadata.json"))
        try PrivateBookFiles.write(Data(), to: temp.appendingPathComponent("complete"))
        let destination = root.appendingPathComponent(stableKey(bookID.readingBookID), isDirectory: true).appendingPathComponent(revision.uuidString, isDirectory: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: destination.path) else { throw ReaderError.message("This iCloud book revision already exists.") }
        try fm.moveItem(at: temp, to: destination)
        return StagedCloudBook(metadata: metadata, assetURL: destination.appendingPathComponent("original"))
    }

    func reopen(bookID: CloudStandaloneBookID, revision: UUID) async throws -> StagedCloudBook {
        let directory = root.appendingPathComponent(stableKey(bookID.readingBookID), isDirectory: true).appendingPathComponent(revision.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path) else { throw ReaderError.message("The staged iCloud book is unavailable.") }
        let metadata = try JSONDecoder().decode(CloudBookMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        try metadata.validate(scope: scope)
        guard metadata.bookID == bookID, metadata.revision == revision else { throw ReaderError.message("The staged iCloud book identity is invalid.") }
        let staged = StagedCloudBook(metadata: metadata, assetURL: directory.appendingPathComponent("original"))
        try await CloudBookIntegrity.verify(staged)
        return staged
    }

    /// All staging users share this lock, including distinct stager instances.
    /// An upload retains the returned lease until its CloudKit call completes.
    func lease(bookID: CloudStandaloneBookID, revision: UUID) async throws -> CloudBookAssetLease {
        let directory = root.appendingPathComponent(stableKey(bookID.readingBookID), isDirectory: true).appendingPathComponent(revision.uuidString, isDirectory: true)
        let descriptor = open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ReaderError.message("The staged iCloud book is unavailable.") }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { close(descriptor); throw ReaderError.message("The staged iCloud book is being removed. Try again.") }
        do {
            let staged = try await reopen(bookID: bookID, revision: revision)
            return CloudBookAssetLease(staged: staged, descriptor: descriptor)
        } catch { close(descriptor); throw error }
    }

    /// Pins survive process exit. A crash may leave an extra pin, which is
    /// safer than removing the only staged copy of an unacknowledged asset.
    func pin(bookID: CloudStandaloneBookID, revision: UUID, owner: UUID, expected: CloudBookMetadata? = nil) async throws {
        let directory = root.appendingPathComponent(stableKey(bookID.readingBookID), isDirectory: true).appendingPathComponent(revision.uuidString, isDirectory: true)
        let descriptor = open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ReaderError.message("The staged iCloud book is unavailable.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { throw ReaderError.message("The staged iCloud book is in use. Try again.") }
        let staged = try await reopen(bookID: bookID, revision: revision)
        if let expected, staged.metadata != expected { throw ReaderError.message("The staged iCloud book revision is inconsistent.") }
        let pins = directory.appendingPathComponent("pins", isDirectory: true)
        let marker = pins.appendingPathComponent(owner.uuidString)
        if FileManager.default.fileExists(atPath: marker.path) {
            let pinInfo = try pins.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let markerInfo = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard pinInfo.isDirectory == true, pinInfo.isSymbolicLink != true,
                  markerInfo.isRegularFile == true, markerInfo.isSymbolicLink != true else {
                throw ReaderError.message("The staged iCloud book is unavailable.")
            }
            return
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ReaderError.message("The staged iCloud book is in use. Try again.") }
        let rechecked = try await reopen(bookID: bookID, revision: revision)
        if let expected, rechecked.metadata != expected { throw ReaderError.message("The staged iCloud book revision is inconsistent.") }
        try FileManager.default.createDirectory(at: pins, withIntermediateDirectories: true)
        let pinInfo = try pins.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard pinInfo.isDirectory == true, pinInfo.isSymbolicLink != true else { throw ReaderError.message("The staged iCloud book is unavailable.") }
        try PrivateBookFiles.protect(pins)
        try PrivateBookFiles.write(Data(), to: marker)
    }

    /// The owner must first durably remove every journal reference to this
    /// revision. Removing a pin never deletes the staged asset itself.
    func unpin(bookID: CloudStandaloneBookID, revision: UUID, owner: UUID) throws {
        let directory = root.appendingPathComponent(stableKey(bookID.readingBookID), isDirectory: true).appendingPathComponent(revision.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let descriptor = open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ReaderError.message("The staged iCloud book is unavailable.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ReaderError.message("The staged iCloud book is in use. Try again.") }
        let pins = directory.appendingPathComponent("pins", isDirectory: true)
        if FileManager.default.fileExists(atPath: pins.path) {
            let info = try pins.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw ReaderError.message("The staged iCloud book is unavailable.") }
        }
        let marker = pins.appendingPathComponent(owner.uuidString)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    /// Only call after a transport has finished using its CKAsset. This removes
    /// staging, never the user's source or the standalone library copy.
    func discard(bookID: CloudStandaloneBookID, revision: UUID) throws {
        let directory = root.appendingPathComponent(stableKey(bookID.readingBookID), isDirectory: true).appendingPathComponent(revision.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let descriptor = open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ReaderError.message("The staged iCloud book could not be removed.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ReaderError.message("The staged iCloud book is still in use. Try again after sync finishes.") }
        let pins = directory.appendingPathComponent("pins", isDirectory: true)
        if FileManager.default.fileExists(atPath: pins.path) {
            let info = try pins.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw ReaderError.message("The staged iCloud book is unavailable.") }
            if !(try FileManager.default.contentsOfDirectory(atPath: pins.path)).isEmpty {
                throw ReaderError.message("The staged iCloud book is needed for recovery and cannot be removed yet.")
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    private static func copyAndHash(source: URL, destination: URL, maxBytes: Int64) throws -> (Int64, String) {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, operationError: Error?
        var result: (Int64, String)?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReaderError.message("The original book is unavailable.") }
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ReaderError.message("There is not enough device storage to prepare the book.") }
                try PrivateBookFiles.protect(destination)
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var digest = SHA256(), size: Int64 = 0
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation()
                    size += Int64(data.count)
                    guard size <= maxBytes else { throw ReaderError.message("This book exceeds the available staging allowance.") }
                    try output.write(contentsOf: data); digest.update(data: data)
                }
                try Task.checkCancellation()
                result = (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        guard let result else { throw ReaderError.message("The original book is unavailable.") }
        return result
    }
}

enum CloudBookIntegrity {
    static func verify(_ staged: StagedCloudBook) async throws {
        let task = Task.detached(priority: .utility) {
            let values = try staged.assetURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReaderError.message("The staged iCloud book is unavailable.") }
            let handle = try FileHandle(forReadingFrom: staged.assetURL)
            defer { try? handle.close() }
            var digest = SHA256(), size: Int64 = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                size += Int64(data.count)
                guard size <= 512 * 1024 * 1024 else { throw ReaderError.message("The staged iCloud book is damaged.") }
                digest.update(data: data)
            }
            try Task.checkCancellation()
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard size == staged.metadata.byteCount, hash == staged.metadata.sha256 else { throw ReaderError.message("The staged iCloud book is incomplete or damaged.") }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Record construction is local only. The caller must verify account fencing,
/// conditional writes and staged bytes immediately before a real upload.
enum CloudBookRecordCodec {
    static let recordType = "StandaloneBookV1"
    static func record(_ staged: StagedCloudBook, scope: CloudReadingScope, zoneID: CKRecordZone.ID, existing: CKRecord? = nil) async throws -> CKRecord {
        try staged.metadata.validate(scope: scope)
        try await CloudBookIntegrity.verify(staged)
        let id = CKRecord.ID(recordName: staged.metadata.recordName, zoneID: zoneID)
        guard existing == nil || (existing?.recordID == id && existing?.recordType == recordType) else { throw ReaderError.message("The iCloud book identity is invalid.") }
        let record = existing ?? CKRecord(recordType: recordType, recordID: id)
        record.encryptedValues["metadata"] = try JSONEncoder().encode(staged.metadata) as CKRecordValue
        record.encryptedValues["tombstone"] = nil
        record["bookFile"] = CKAsset(fileURL: staged.assetURL)
        return record
    }
    static func record(_ tombstone: CloudBookTombstone, scope: CloudReadingScope, zoneID: CKRecordZone.ID, existing: CKRecord? = nil) throws -> CKRecord {
        try tombstone.validate(scope: scope)
        let id = CKRecord.ID(recordName: tombstone.recordName, zoneID: zoneID)
        guard existing == nil || (existing?.recordID == id && existing?.recordType == recordType) else { throw ReaderError.message("The iCloud book identity is invalid.") }
        let record = existing ?? CKRecord(recordType: recordType, recordID: id)
        record.encryptedValues["metadata"] = nil
        record["bookFile"] = nil
        record.encryptedValues["tombstone"] = try JSONEncoder().encode(tombstone) as CKRecordValue
        return record
    }
    static func decode(_ record: CKRecord, scope: CloudReadingScope) throws -> (CloudBookMetadata, URL) {
        guard record.recordType == recordType, record.encryptedValues["tombstone"] == nil,
              let bytes = record.encryptedValues["metadata"] as? Data,
              let asset = record["bookFile"] as? CKAsset, let url = asset.fileURL else { throw ReaderError.message("The iCloud book record is incomplete.") }
        let metadata = try JSONDecoder().decode(CloudBookMetadata.self, from: bytes)
        try metadata.validate(scope: scope)
        guard record.recordID.recordName == metadata.recordName else { throw ReaderError.message("The iCloud book identity is invalid.") }
        return (metadata, url)
    }
    static func decodeValue(_ record: CKRecord, scope: CloudReadingScope) throws -> CloudBookRecordValue {
        guard record.recordType == recordType else { throw ReaderError.message("The iCloud book record is invalid.") }
        if let data = record.encryptedValues["tombstone"] as? Data {
            guard record.encryptedValues["metadata"] == nil, record["bookFile"] == nil else {
                throw ReaderError.message("The iCloud book record is inconsistent.")
            }
            let tombstone = try JSONDecoder().decode(CloudBookTombstone.self, from: data)
            try tombstone.validate(scope: scope)
            guard record.recordID.recordName == tombstone.recordName else { throw ReaderError.message("The iCloud book identity is invalid.") }
            return .tombstone(tombstone)
        }
        let (metadata, url) = try decode(record, scope: scope)
        return .book(metadata, url)
    }
}

enum CloudBookMutation {
    case book(CloudBookAssetLease)
    case tombstone(CloudBookTombstone)
}

enum CloudBookRemoteVersion {
    case book(StagedCloudBook)
    case tombstone(CloudBookTombstone)

    var revision: UUID {
        switch self { case .book(let book): book.metadata.revision; case .tombstone(let tombstone): tombstone.revision }
    }
}

enum CloudBookUploadResult {
    case saved
    case conflict(CloudBookRemoteVersion)
}

enum CloudBookJournalVersion: Codable, Equatable {
    case book(CloudBookMetadata)
    case tombstone(CloudBookTombstone)

    var bookID: CloudStandaloneBookID {
        switch self { case .book(let metadata): metadata.bookID; case .tombstone(let tombstone): tombstone.bookID }
    }
    var revision: UUID {
        switch self { case .book(let metadata): metadata.revision; case .tombstone(let tombstone): tombstone.revision }
    }
    func validate(scope: CloudReadingScope) throws {
        switch self { case .book(let metadata): try metadata.validate(scope: scope); case .tombstone(let tombstone): try tombstone.validate(scope: scope) }
    }
}

/// A local-first book outbox. Book revisions are pinned before the journal can
/// reference them; a crash may leak a pin, but cannot make a pending asset
/// eligible for cleanup. Cloud records are never physically deleted here.
@MainActor final class CloudBookJournal {
    enum ExpectedCurrent { case missing, revision(UUID) }
    struct Entry: Codable {
        let bookID: CloudStandaloneBookID
        var current: CloudBookJournalVersion
        var baseRevision: UUID?
        var pending: Bool
        var pendingRevisions: [UUID]
        var conflicts: [CloudBookJournalVersion]
        var pendingApplication: Bool
    }
    private struct Archive: Codable {
        let version: Int
        let scope: CloudReadingScope
        let owner: UUID
        var revision: UUID
        var entries: [String: Entry]
    }
    private var archive: Archive
    fileprivate let stager: CloudBookStager
    private let archiveScript: URL?
    let file: URL
    var entries: [String: Entry] { archive.entries }
    var owner: UUID { archive.owner }
    var scope: CloudReadingScope { archive.scope }

    init(scope: CloudReadingScope, stager: CloudBookStager, baseDirectory: URL? = nil, archiveScript: URL? = nil) throws {
        guard scope.isValid, scope.sourceKey == (try CloudReadingSource.imported.key()), stager.scope == scope else {
            throw ReaderError.message("The iCloud book journal scope is invalid.")
        }
        self.stager = stager
        self.archiveScript = archiveScript
        let root = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("LibraViaCloudBookJournal/\(scope.cloudAccountKey)/\(scope.sourceKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        let journalFile = root.appendingPathComponent("book-journal.json")
        file = journalFile
        archive = try PrivateBookFiles.withExclusiveLock(at: root.appendingPathComponent("journal.lock")) {
          if FileManager.default.fileExists(atPath: journalFile.path) {
            let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: journalFile))
            guard saved.version == 1, saved.scope == scope else { throw ReaderError.message("The iCloud book journal belongs to a different account or source.") }
            for (name, entry) in saved.entries {
                guard name == Self.key(entry.bookID), entry.current.bookID == entry.bookID,
                      entry.conflicts.allSatisfy({ $0.bookID == entry.bookID }),
                      Set(entry.conflicts.map(\.revision)).count == entry.conflicts.count,
                      entry.pending == !entry.pendingRevisions.isEmpty,
                      !entry.pending || entry.pendingRevisions.last == entry.current.revision else {
                    throw ReaderError.message("The saved iCloud book journal is inconsistent.")
                }
                try entry.current.validate(scope: scope)
                for conflict in entry.conflicts { try conflict.validate(scope: scope) }
            }
            return saved
          } else {
            let initial = Archive(version: 1, scope: scope, owner: UUID(), revision: UUID(), entries: [:])
            try PrivateBookFiles.write(JSONEncoder().encode(initial), to: journalFile)
            return initial
          }
        }
    }

    private static func key(_ id: CloudStandaloneBookID) -> String { stableKey(id.readingBookID) }
    func entry(for id: CloudStandaloneBookID) -> Entry? { archive.entries[Self.key(id)] }

    private func commit(_ updated: Archive) throws {
        try PrivateBookFiles.withExclusiveLock(at: file.deletingLastPathComponent().appendingPathComponent("journal.lock")) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == archive.scope, disk.owner == archive.owner, disk.revision == archive.revision else {
                throw ReaderError.message("The iCloud book journal changed in another session. Reopen it before syncing.")
            }
            var next = updated; next.revision = UUID()
            try PrivateBookFiles.write(JSONEncoder().encode(next), to: file)
            archive = next
        }
    }

    func requireCurrentRevision() throws {
        try PrivateBookFiles.withExclusiveLock(at: file.deletingLastPathComponent().appendingPathComponent("journal.lock")) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == archive.scope, disk.owner == archive.owner, disk.revision == archive.revision else {
                throw ReaderError.message("The iCloud book journal changed in another session. Reopen it before syncing.")
            }
        }
    }

    private func pinIfNeeded(_ version: CloudBookJournalVersion) async throws {
        try version.validate(scope: archive.scope)
        if case .book(let metadata) = version {
            try await stager.pin(bookID: metadata.bookID, revision: metadata.revision, owner: archive.owner, expected: metadata)
        }
    }

    func edit(_ version: CloudBookJournalVersion, expecting: ExpectedCurrent? = nil,
              validateBeforeCommit: @MainActor () async throws -> Void = {}) async throws {
        try await pinIfNeeded(version)
        try await validateBeforeCommit()
        try Task.checkCancellation()
        let key = Self.key(version.bookID)
        var next = archive
        if let expecting {
            switch expecting {
            case .missing:
                guard next.entries[key] == nil else { throw ReaderError.message("The book recovery state changed. Review it before uploading.") }
            case .revision(let revision):
                guard next.entries[key]?.current.revision == revision else { throw ReaderError.message("The book recovery state changed. Review it before uploading.") }
            }
        }
        if let existing = next.entries[key], existing.current.revision == version.revision {
            guard existing.current == version else { throw ReaderError.message("The iCloud book revision is inconsistent.") }
            try requireCurrentRevision()
            return
        }
        var entry = next.entries[key] ?? Entry(bookID: version.bookID, current: version, baseRevision: nil,
                                               pending: false, pendingRevisions: [], conflicts: [], pendingApplication: false)
        if entry.pendingApplication && !entry.conflicts.contains(where: { $0.revision == entry.current.revision }) {
            entry.conflicts.append(entry.current)
        }
        entry.current = version; entry.pending = true; entry.pendingApplication = false
        entry.pendingRevisions.append(version.revision)
        next.entries[key] = entry
        try commit(next)
    }

    func observe(_ version: CloudBookJournalVersion,
                 validateBeforeCommit: @MainActor () async throws -> Void = {}) async throws {
        try await pinIfNeeded(version)
        try await validateBeforeCommit()
        try Task.checkCancellation()
        let key = Self.key(version.bookID)
        var next = archive
        guard var entry = next.entries[key] else {
            next.entries[key] = Entry(bookID: version.bookID, current: version, baseRevision: version.revision,
                                      pending: false, pendingRevisions: [], conflicts: [], pendingApplication: true)
            try commit(next); return
        }
        if entry.current.revision == version.revision {
            guard entry.current == version else { throw ReaderError.message("The iCloud book revision is inconsistent.") }
            entry.pending = false; entry.pendingRevisions = []; entry.baseRevision = version.revision
        } else if entry.pending || entry.pendingApplication || !entry.conflicts.isEmpty {
            if let existing = entry.conflicts.first(where: { $0.revision == version.revision }) {
                guard existing == version else { throw ReaderError.message("The iCloud book revision is inconsistent.") }
            } else if version.revision != entry.baseRevision { entry.conflicts.append(version) }
        } else {
            entry.current = version; entry.baseRevision = version.revision; entry.pendingApplication = true
        }
        next.entries[key] = entry
        try commit(next)
    }

    func acknowledge(bookID: CloudStandaloneBookID, revision: UUID) throws {
        let key = Self.key(bookID)
        guard var entry = archive.entries[key], entry.pending,
              let index = entry.pendingRevisions.firstIndex(of: revision) else { return }
        var next = archive
        entry.baseRevision = revision; entry.pendingRevisions.removeFirst(index + 1)
        if entry.current.revision == revision { entry.pending = false }
        next.entries[key] = entry
        try commit(next)
    }

    enum ConflictChoice { case local, remote }

    /// Preserve each alternative until the owner chooses. A chosen book is
    /// copied to a new pinned revision so a stale write cannot reuse a version.
    func resolveConflict(bookID: CloudStandaloneBookID, expectedLocalRevision: UUID,
                         remoteRevision: UUID, choice: ConflictChoice,
                         validateBeforeCommit: @MainActor () async throws -> Void) async throws {
        let key = Self.key(bookID)
        guard let original = archive.entries[key], original.current.revision == expectedLocalRevision,
              let remote = original.conflicts.first(where: { $0.revision == remoteRevision }) else {
            throw ReaderError.message("The book conflict changed. Review it again.")
        }
        let originalArchiveRevision = archive.revision
        let selected = choice == .local ? original.current : remote
        let replacement: CloudBookJournalVersion
        switch selected {
        case .tombstone(let tombstone):
            replacement = .tombstone(CloudBookTombstone(accountKey: tombstone.accountKey, sourceKey: tombstone.sourceKey,
                                                        bookID: tombstone.bookID, revision: UUID()))
        case .book(let metadata):
            let lease = try await stager.lease(bookID: bookID, revision: metadata.revision)
            guard lease.staged.metadata == metadata else { throw ReaderError.message("The staged iCloud book revision is inconsistent.") }
            let copy = try await stager.stage(source: lease.staged.assetURL, bookID: bookID, title: metadata.title,
                                               format: metadata.format, expectedSHA256: metadata.sha256, archiveScript: archiveScript)
            withExtendedLifetime(lease) {}
            replacement = .book(copy.metadata)
        }
        try await pinIfNeeded(replacement)
        // Staging and pinning suspend. Revalidate the account and session
        // immediately before the synchronous journal revision check and commit.
        try await validateBeforeCommit()
        try Task.checkCancellation()
        guard archive.revision == originalArchiveRevision, var entry = archive.entries[key],
              entry.current.revision == expectedLocalRevision,
              entry.conflicts.contains(where: { $0.revision == remoteRevision }) else {
            throw ReaderError.message("The book conflict changed during recovery. Review it again.")
        }
        var next = archive
        entry.baseRevision = remoteRevision; entry.current = replacement
        entry.pending = true; entry.pendingRevisions = [replacement.revision]
        entry.conflicts.removeAll { $0.revision == remoteRevision }
        entry.pendingApplication = entry.pendingApplication || choice == .remote
        next.entries[key] = entry
        try commit(next)
    }

    /// Call only after the corresponding local restore or deletion decision is
    /// complete. A crash before this commit safely repeats that idempotent work.
    func markApplied(bookID: CloudStandaloneBookID, revision: UUID) throws {
        let key = Self.key(bookID)
        guard var entry = archive.entries[key], entry.current.revision == revision,
              entry.pendingApplication, entry.conflicts.isEmpty else {
            throw ReaderError.message("The iCloud book changed. Review it before finishing recovery.")
        }
        var next = archive; entry.pendingApplication = false; next.entries[key] = entry
        try commit(next)
    }

    /// Replace only the exact reviewed cloud deletion with a new backup.
    func restoreReviewedDeletion(_ staged: StagedCloudBook, expectedDeletion: UUID,
                                 validateBeforeCommit: @MainActor () async throws -> Void) async throws {
        let version = CloudBookJournalVersion.book(staged.metadata)
        try await pinIfNeeded(version)
        try await validateBeforeCommit()
        try Task.checkCancellation()
        let key = Self.key(staged.metadata.bookID)
        guard var entry = archive.entries[key], case .tombstone = entry.current,
              entry.current.revision == expectedDeletion, entry.baseRevision == expectedDeletion,
              !entry.pending, entry.conflicts.isEmpty else {
            throw ReaderError.message("The deleted backup changed. Review it again.")
        }
        entry.current = version; entry.pending = true; entry.pendingRevisions = [version.revision]
        entry.pendingApplication = false
        var next = archive; next.entries[key] = entry
        try commit(next)
    }
}

/// Conditional book records used by experimental recovery. Account fencing
/// and real two-device asset recovery still require verification.
@MainActor final class CloudKitBookTransport {
    fileprivate let scope: CloudReadingScope
    fileprivate let bookID: CloudStandaloneBookID
    private let zoneID: CKRecordZone.ID
    private let database: any CloudReadingRecordDatabase
    fileprivate let stager: CloudBookStager
    private let archiveScript: URL?
    fileprivate let pinOwner: UUID
    private let accountIsCurrent: @MainActor () async throws -> Bool

    init(scope: CloudReadingScope, bookID: CloudStandaloneBookID, zoneID: CKRecordZone.ID,
         database: any CloudReadingRecordDatabase, stager: CloudBookStager, pinOwner: UUID,
         archiveScript: URL? = nil, accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard scope.isValid, scope.sourceKey == (try CloudReadingSource.imported.key()), stager.scope == scope else {
            throw ReaderError.message("The iCloud book identity is invalid.")
        }
        self.scope = scope; self.bookID = bookID; self.zoneID = zoneID
        self.database = database; self.stager = stager; self.pinOwner = pinOwner; self.archiveScript = archiveScript; self.accountIsCurrent = accountIsCurrent
    }

    private func checkAccount() async throws {
        try Task.checkCancellation()
        guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Sync is paused.") }
        try Task.checkCancellation()
    }

    private var recordID: CKRecord.ID {
        let name = stableKey("\(scope.sourceKey)|\(bookID.readingBookID)|book-file")
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func read() async throws -> (CKRecord, CloudBookRecordValue)? {
        try await checkAccount()
        let record = try await database.fetch(recordID)
        try await checkAccount()
        guard let record else { return nil }
        guard record.recordID == recordID else { throw ReaderError.message("The iCloud book identity is invalid.") }
        let value = try CloudBookRecordCodec.decodeValue(record, scope: scope)
        switch value {
        case .book(let metadata, _): guard metadata.bookID == bookID else { throw ReaderError.message("The iCloud book identity is invalid.") }
        case .tombstone(let tombstone): guard tombstone.bookID == bookID else { throw ReaderError.message("The iCloud book identity is invalid.") }
        }
        return (record, value)
    }

    /// Copy a fetched CKAsset into validated, durable staging before returning.
    private func materialize(_ value: CloudBookRecordValue) async throws -> CloudBookRemoteVersion {
        switch value {
        case .tombstone(let tombstone): return .tombstone(tombstone)
        case .book(let metadata, let url):
            if let existing = try? await stager.reopen(bookID: bookID, revision: metadata.revision) {
                guard existing.metadata == metadata else { throw ReaderError.message("The staged iCloud book revision is inconsistent.") }
                try await stager.pin(bookID: bookID, revision: metadata.revision, owner: pinOwner, expected: metadata)
                try await checkAccount()
                return .book(existing)
            }
            let staged = try await stager.stage(source: url, bookID: bookID, title: metadata.title,
                                                format: metadata.format, revision: metadata.revision, expected: metadata, archiveScript: archiveScript)
            try await stager.pin(bookID: bookID, revision: metadata.revision, owner: pinOwner, expected: metadata)
            try await checkAccount()
            return .book(staged)
        }
    }

    func fetch() async throws -> CloudBookRemoteVersion? {
        guard let (_, value) = try await read() else { return nil }
        return try await materialize(value)
    }

    func upload(_ mutation: CloudBookMutation, expected: UUID?) async throws -> CloudBookUploadResult {
        switch mutation {
        case .book(let lease):
            guard lease.staged.metadata.bookID == bookID else { throw ReaderError.message("The iCloud book identity is invalid.") }
            try lease.staged.metadata.validate(scope: scope)
        case .tombstone(let tombstone):
            try tombstone.validate(scope: scope)
            guard tombstone.bookID == bookID else { throw ReaderError.message("The iCloud book identity is invalid.") }
        }
        let existing = try await read()
        if let existing, existing.1.revision != expected { return .conflict(try await materialize(existing.1)) }
        if existing == nil, expected != nil { throw ReaderError.message("The iCloud book record is missing; recovery is required.") }
        let record: CKRecord
        switch mutation {
        case .book(let lease):
            record = try await CloudBookRecordCodec.record(lease.staged, scope: scope, zoneID: zoneID, existing: existing?.0)
        case .tombstone(let tombstone):
            record = try CloudBookRecordCodec.record(tombstone, scope: scope, zoneID: zoneID, existing: existing?.0)
        }
        try await checkAccount()
        let result = try await database.saveIfUnchanged(record)
        // Keep the CKAsset's lease alive throughout the save, even if the
        // optimizer would otherwise release it after record construction.
        if case .book(let lease) = mutation { withExtendedLifetime(lease) {} }
        try await checkAccount()
        switch result {
        case .saved: return .saved
        case .conflict(let server):
            guard server.recordID == recordID else { throw ReaderError.message("The iCloud book identity is invalid.") }
            let value = try CloudBookRecordCodec.decodeValue(server, scope: scope)
            switch value {
            case .book(let metadata, _): guard metadata.bookID == bookID else { throw ReaderError.message("The iCloud book identity is invalid.") }
            case .tombstone(let tombstone): guard tombstone.bookID == bookID else { throw ReaderError.message("The iCloud book identity is invalid.") }
            }
            return .conflict(try await materialize(value))
        }
    }
}

/// Coordinates one book while preserving local changes made during network
/// requests. A service must still schedule retries and apply incoming versions.
@MainActor final class CloudBookSyncCoordinator {
    enum Status: Equatable { case idle, pending, syncing, needsApplication, conflict, accountChanged, failed(String) }
    private let journal: CloudBookJournal
    private let transport: CloudKitBookTransport
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private(set) var status: Status = .idle
    private var running = false

    init(journal: CloudBookJournal, transport: CloudKitBookTransport,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard journal.scope == transport.scope, journal.owner == transport.pinOwner,
              journal.stager === transport.stager else {
            throw ReaderError.message("The iCloud book recovery state does not match its transport.")
        }
        self.journal = journal; self.transport = transport; self.accountIsCurrent = accountIsCurrent
    }

    private func version(_ remote: CloudBookRemoteVersion) -> CloudBookJournalVersion {
        switch remote { case .book(let staged): .book(staged.metadata); case .tombstone(let tombstone): .tombstone(tombstone) }
    }

    private func reportCurrentStatus(bookID: CloudStandaloneBookID) {
        guard let entry = journal.entry(for: bookID) else { status = .idle; return }
        if !entry.conflicts.isEmpty { status = .conflict }
        else if entry.pendingApplication { status = .needsApplication }
        else { status = entry.pending ? .pending : .idle }
    }

    private func stillUploadable(_ entry: CloudBookJournal.Entry) throws -> Bool {
        try journal.requireCurrentRevision()
        guard let latest = journal.entry(for: entry.bookID) else { return false }
        return latest.current == entry.current && latest.baseRevision == entry.baseRevision && latest.pending &&
            latest.conflicts.isEmpty && !latest.pendingApplication
    }

    private func currentAccount() async throws -> Bool {
        try Task.checkCancellation()
        let current = try await accountIsCurrent()
        try Task.checkCancellation()
        return current
    }

    func sync() async {
        guard !running else { return }
        running = true; status = .syncing
        defer { running = false }
        do {
            guard try await currentAccount() else { status = .accountChanged; return }
            let remote = try await transport.fetch()
            guard try await currentAccount() else { status = .accountChanged; return }
            if let remote {
                try await journal.observe(version(remote), validateBeforeCommit: {
                    guard try await self.currentAccount() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
                })
            }
            let bookID = transport.bookID
            guard let entry = journal.entry(for: bookID) else { status = .idle; return }
            guard entry.conflicts.isEmpty else { status = .conflict; return }
            guard !entry.pendingApplication else { status = .needsApplication; return }
            guard entry.pending else { status = .idle; return }
            guard remote != nil || entry.baseRevision == nil else {
                throw ReaderError.message("The iCloud book record is missing; recovery is required.")
            }
            let result: CloudBookUploadResult
            switch entry.current {
            case .book(let metadata):
                let lease = try await journal.stager.lease(bookID: bookID, revision: metadata.revision)
                guard lease.staged.metadata == metadata else { throw ReaderError.message("The staged iCloud book revision is inconsistent.") }
                guard try await currentAccount() else { status = .accountChanged; return }
                guard try stillUploadable(entry) else { reportCurrentStatus(bookID: bookID); return }
                result = try await transport.upload(.book(lease), expected: entry.baseRevision)
                withExtendedLifetime(lease) {}
            case .tombstone(let tombstone):
                guard try await currentAccount() else { status = .accountChanged; return }
                guard try stillUploadable(entry) else { reportCurrentStatus(bookID: bookID); return }
                result = try await transport.upload(.tombstone(tombstone), expected: entry.baseRevision)
            }
            guard try await currentAccount() else { status = .accountChanged; return }
            switch result {
            case .saved: try journal.acknowledge(bookID: bookID, revision: entry.current.revision)
            case .conflict(let remote):
                try await journal.observe(version(remote), validateBeforeCommit: {
                    guard try await self.currentAccount() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
                })
            }
            reportCurrentStatus(bookID: bookID)
        } catch {
            if (try? await accountIsCurrent()) == false { status = .accountChanged }
            else { status = .failed(error.localizedDescription) }
        }
    }
}

/// Prepares standalone books and reading data locally before any transport is
/// scheduled. It does not create CloudKit zones or start network operations.
@MainActor final class StandaloneRecoveryPreparation {
    private let scope: CloudReadingScope
    private let library: LocalLibrary
    private let reading: ReadingStore
    private let stager: CloudBookStager
    private let journal: CloudBookJournal
    private let accountIsCurrent: @MainActor () async throws -> Bool

    init(scope: CloudReadingScope, library: LocalLibrary, reading: ReadingStore,
         stager: CloudBookStager, journal: CloudBookJournal,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard scope.isValid, scope.sourceKey == (try CloudReadingSource.imported.key()),
              stager.scope == scope, journal.scope == scope, journal.stager === stager else {
            throw ReaderError.message("The standalone recovery state belongs to a different account or source.")
        }
        self.scope = scope; self.library = library; self.reading = reading
        self.stager = stager; self.journal = journal; self.accountIsCurrent = accountIsCurrent
    }

    private func checkAccount() async throws {
        do {
            guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
        } catch {
            reading.invalidateCloudVerification()
            throw error
        }
    }

    /// Identity assignment and snapshot migration are local. Missing books
    /// remain unmapped in the reading outbox until their identity is resolved.
    func prepare() async throws {
        try await checkAccount()
        if let atomic = reading.cloudReadingStore {
            guard atomic.scope == scope, atomic.localToCloudBookIDs != nil else {
                throw ReaderError.message("Reading data is associated with a different cloud account. Recovery is required.")
            }
        }
        let books = await library.catalog()
        var bindings: [String: String] = [:]
        for book in books {
            try await checkAccount()
            let identity = try await library.ensureCloudIdentity(for: book, scope: scope)
            bindings[book.id] = identity.readingBookID
        }
        try await checkAccount()
        if let atomic = reading.cloudReadingStore {
            let existing = atomic.localToCloudBookIDs ?? [:]
            let combined = existing.merging(bindings) { old, _ in old }
            guard bindings.allSatisfy({ local, cloud in existing[local] == nil || existing[local] == cloud }),
                  Set(combined.values).count == combined.count else {
                throw ReaderError.message("Standalone book identities need review before recovery.")
            }
            for (local, cloud) in bindings where existing[local] == nil {
                guard cloud.hasPrefix("cloud-book-"), let id = UUID(uuidString: String(cloud.dropFirst("cloud-book-".count))) else {
                    throw ReaderError.message("A standalone book identity is invalid.")
                }
                try reading.bindStandaloneCloudIdentity(localBookID: local, cloudBookID: CloudStandaloneBookID(id))
            }
        } else {
            try reading.prepareAtomicReading(scope: scope, localToCloudBookIDs: bindings)
        }
    }

    /// Stage a new or metadata-updated book once. A cloud tombstone or a
    /// conflicting edition requires review and is never silently resurrected.
    @discardableResult func queueBook(_ book: LocalBookEntry) async throws -> Bool {
        try await checkAccount()
        guard let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("Prepare this library for recovery first.")
        }
        let fingerprint = try await reading.verifyStandaloneEdition(book, library: library, scope: scope)
        try await checkAccount()
        guard reading.cloudReadingStore === atomic,
              let cloud = atomic.localToCloudBookIDs?[book.id], cloud.hasPrefix("cloud-book-"),
              let uuid = UUID(uuidString: String(cloud.dropFirst("cloud-book-".count))) else {
            throw ReaderError.message("The book identity changed. Prepare the library again.")
        }
        let identity = CloudStandaloneBookID(uuid)
        guard cloud == identity.readingBookID else { throw ReaderError.message("The book identity is invalid.") }
        let existing = journal.entry(for: identity)
        if let existing {
            guard existing.conflicts.isEmpty, !existing.pendingApplication else {
                throw ReaderError.message("Resolve this book's recovery state before uploading it.")
            }
            switch existing.current {
            case .tombstone:
                // A reviewed deletion leaves the device copy intentionally
                // unbacked until the owner explicitly restores its backup.
                guard !existing.pending else { throw ReaderError.message("The backup deletion has not finished syncing.") }
                return false
            case .book(let metadata):
                guard metadata.sha256 == fingerprint, metadata.format == book.format else {
                    throw ReaderError.message("This book is a different edition. Review it before syncing.")
                }
                if metadata.title == book.title { return false }
            }
        }
        let staged = try await library.stageCloudBook(book, scope: scope, stager: stager)
        try await checkAccount()
        guard staged.metadata.bookID == identity, staged.metadata.sha256 == fingerprint else {
            throw ReaderError.message("The book changed during recovery preparation.")
        }
        let expected: CloudBookJournal.ExpectedCurrent = existing.map { .revision($0.current.revision) } ?? .missing
        try await journal.edit(.book(staged.metadata), expecting: expected, validateBeforeCommit: {
            try await self.checkAccount()
            guard self.reading.cloudReadingStore === atomic,
                  atomic.localToCloudBookIDs?[book.id] == identity.readingBookID else {
                throw ReaderError.message("The book identity changed. Prepare the library again.")
            }
        })
        return true
    }
}

/// Routes records found in a source-specific zone into the durable journals.
/// The files remain staged for explicit, edition-verified application.
@MainActor final class CloudRecoveryRecordReceiver {
    private let scope: CloudReadingScope
    private let zoneID: CKRecordZone.ID
    private let reading: CloudAtomicReadingStore
    private let books: CloudBookJournal?
    private let archiveScript: URL?
    private let accountIsCurrent: @MainActor () async throws -> Bool

    init(scope: CloudReadingScope, zoneID: CKRecordZone.ID, reading: CloudAtomicReadingStore,
         books: CloudBookJournal?, archiveScript: URL? = nil,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard scope.isValid, reading.scope == scope, books == nil || books?.scope == scope else {
            throw ReaderError.message("The iCloud recovery stores do not match their source.")
        }
        self.scope = scope; self.zoneID = zoneID; self.reading = reading; self.books = books
        self.archiveScript = archiveScript; self.accountIsCurrent = accountIsCurrent
    }

    func receive(_ record: CKRecord) async throws {
        guard record.recordID.zoneID == zoneID, try await accountIsCurrent() else {
            throw ReaderError.message("The iCloud recovery record or account changed.")
        }
        switch record.recordType {
        case CloudReadingRecordCodec.recordType:
            let (key, bookID, version) = try CloudReadingRecordCodec.decode(record, expectedSource: scope.sourceKey)
            guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
            try reading.observe(key, bookID: bookID, remote: version)
        case CloudBookRecordCodec.recordType:
            guard let books else { throw ReaderError.message("The iCloud book belongs to an unexpected source.") }
            let value = try CloudBookRecordCodec.decodeValue(record, scope: scope)
            switch value {
            case .tombstone(let tombstone):
                guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
                try await books.observe(.tombstone(tombstone), validateBeforeCommit: {
                    guard try await self.accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
                })
            case .book(let metadata, let asset):
                let staged: StagedCloudBook
                if let existing = try? await books.stager.reopen(bookID: metadata.bookID, revision: metadata.revision) {
                    guard existing.metadata == metadata else { throw ReaderError.message("The staged iCloud book revision is inconsistent.") }
                    staged = existing
                } else {
                    staged = try await books.stager.stage(source: asset, bookID: metadata.bookID, title: metadata.title,
                                                          format: metadata.format, revision: metadata.revision,
                                                          expected: metadata, archiveScript: archiveScript)
                }
                guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
                try await books.observe(.book(staged.metadata), validateBeforeCommit: {
                    guard try await self.accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
                })
            }
        default:
            throw ReaderError.message("The iCloud recovery record type is not supported by this version.")
        }
    }
}

/// After explicit library identification and stopping old clients, stage every
/// old-zone record before switching the local journal to its corrected source.
/// An incomplete scan leaves the old journal active and can be replayed.
@MainActor final class LegacyJellyfinMigration {
    private let account: Account
    private let target: CloudReadingScope
    private let reading: ReadingStore
    private let pages: any CloudRecoveryPageSource
    private let zones: any CloudRecoveryZoneDatabase
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private let stillCurrent: @MainActor () -> Bool
    private var running = false

    init(account: Account, target: CloudReadingScope, reading: ReadingStore,
         pages: any CloudRecoveryPageSource, zones: any CloudRecoveryZoneDatabase,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool,
         stillCurrent: @escaping @MainActor () -> Bool) throws {
        guard reading.belongs(to: account), target.isValid,
              target.sourceKey == (try CloudReadingSource.scopedJellyfin(account).key()),
              let old = reading.cloudReadingStore, old.localToCloudBookIDs == nil,
              old.scope.cloudAccountKey == target.cloudAccountKey,
              old.scope.sourceKey == (try CloudReadingSource.jellyfin(serverID: account.serverID, userID: account.userID).key()) else {
            throw ReaderError.message("The earlier recovery data does not match this account and library.")
        }
        self.account = account; self.target = target; self.reading = reading
        self.pages = pages; self.zones = zones; self.accountIsCurrent = accountIsCurrent; self.stillCurrent = stillCurrent
    }

    func runAfterLibraryConfirmation() async throws {
        guard !running, let old = reading.cloudReadingStore else { throw ReaderError.message("Recovery is already running or unavailable.") }
        running = true; defer { running = false }
        let source = old.scope
        let fence: @MainActor () async throws -> Bool = {
            try Task.checkCancellation()
            guard self.stillCurrent(), self.reading.cloudReadingStore === old,
                  try await self.accountIsCurrent(), self.stillCurrent(), self.reading.cloudReadingStore === old else { return false }
            try self.reading.requireRecoveryScope(source)
            return true
        }
        guard try await fence() else { throw ReaderError.message("The account or library changed. Recovery is paused.") }
        let access = try CloudRecoveryZoneAccess(scope: source, database: zones, accountIsCurrent: fence)
        guard try await access.inspect() == .present else {
            throw ReaderError.message("The earlier iCloud recovery area is unavailable and needs review.")
        }
        let receiver = try CloudRecoveryRecordReceiver(scope: source, zoneID: source.recoveryZoneID,
                                                        reading: old, books: nil, accountIsCurrent: fence)
        let scan = CloudRecoveryDiscovery(source: pages, zoneID: source.recoveryZoneID,
                                          accountIsCurrent: fence, receive: { try await receiver.receive($0) })
        try await scan.scan()
        guard try await access.inspect() == .present, try await fence() else {
            throw ReaderError.message("The earlier iCloud recovery area or account changed. Recovery is paused.")
        }
        // No suspension between the final identity check and the journal switch.
        try reading.migrateLegacyJellyfinReading(account: account, targetScope: target)
    }
}

/// Discover the destination account completely before moving the local marker.
/// A partial scan only stages changes in the destination journal for retry.
@MainActor final class JellyfinRecoveryAccountSwitch {
    private let account: Account
    private let target: CloudReadingScope
    private let reading: ReadingStore
    private let pages: any CloudRecoveryPageSource
    private let zones: any CloudRecoveryZoneDatabase
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private let stillCurrent: @MainActor () -> Bool
    private var running = false

    init(account: Account, target: CloudReadingScope, reading: ReadingStore,
         pages: any CloudRecoveryPageSource, zones: any CloudRecoveryZoneDatabase,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool,
         stillCurrent: @escaping @MainActor () -> Bool) throws {
        guard reading.belongs(to: account), target.isValid,
              target.sourceKey == (try CloudReadingSource.scopedJellyfin(account).key()),
              let old = reading.cloudReadingStore, old.localToCloudBookIDs == nil,
              old.scope.sourceKey == target.sourceKey, old.scope.cloudAccountKey != target.cloudAccountKey else {
            throw ReaderError.message("The recovery accounts or Jellyfin library do not match.")
        }
        self.account = account; self.target = target; self.reading = reading; self.pages = pages; self.zones = zones
        self.accountIsCurrent = accountIsCurrent; self.stillCurrent = stillCurrent
    }

    func runAfterConfirmation() async throws {
        guard !running, let old = reading.cloudReadingStore else { throw ReaderError.message("Recovery is already running or unavailable.") }
        running = true; defer { running = false }
        let fence: @MainActor () async throws -> Bool = {
            try Task.checkCancellation()
            guard self.stillCurrent(), self.reading.cloudReadingStore === old,
                  try await self.accountIsCurrent(), self.stillCurrent(), self.reading.cloudReadingStore === old else { return false }
            try self.reading.requireRecoveryScope(old.scope)
            return true
        }
        guard try await fence() else { throw ReaderError.message("The account or library changed. Recovery is paused.") }
        let access = try CloudRecoveryZoneAccess(scope: target, database: zones, accountIsCurrent: fence)
        guard try await access.inspect() == .present else { throw ReaderError.message("The destination recovery area is unavailable and needs review.") }
        let destination = try reading.jellyfinSwitchDestination(account: account, targetScope: target)
        let receiver = try CloudRecoveryRecordReceiver(scope: target, zoneID: target.recoveryZoneID,
                                                        reading: destination, books: nil, accountIsCurrent: fence)
        let discovery = CloudRecoveryDiscovery(source: pages, zoneID: target.recoveryZoneID,
                                                accountIsCurrent: fence, receive: { try await receiver.receive($0) })
        try await discovery.scan()
        guard try await access.inspect() == .present, try await fence() else {
            throw ReaderError.message("The account or recovery area changed. Recovery is paused.")
        }
        try reading.switchJellyfinRecoveryAccount(account: account, targetScope: target)
    }
}

/// Inspect the destination's complete book and reading journals before moving
/// local reading to it. Matching content alone never adopts a cloud identity.
@MainActor final class StandaloneRecoveryAccountSwitch {
    private let target: CloudReadingScope
    private let reading: ReadingStore
    private let library: LocalLibrary
    private let journal: CloudBookJournal
    private let pages: any CloudRecoveryPageSource
    private let zones: any CloudRecoveryZoneDatabase
    private let archiveScript: URL?
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private let stillCurrent: @MainActor () -> Bool
    private var running = false

    init(target: CloudReadingScope, reading: ReadingStore, library: LocalLibrary, journal: CloudBookJournal,
         pages: any CloudRecoveryPageSource, zones: any CloudRecoveryZoneDatabase, archiveScript: URL? = nil,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool,
         stillCurrent: @escaping @MainActor () -> Bool) throws {
        guard target.isValid, target.sourceKey == (try CloudReadingSource.imported.key()), journal.scope == target,
              let old = reading.cloudReadingStore, old.localToCloudBookIDs != nil,
              old.scope.sourceKey == target.sourceKey, old.scope.cloudAccountKey != target.cloudAccountKey else {
            throw ReaderError.message("The standalone recovery accounts do not match.")
        }
        self.target = target; self.reading = reading; self.library = library; self.journal = journal
        self.pages = pages; self.zones = zones; self.archiveScript = archiveScript
        self.accountIsCurrent = accountIsCurrent; self.stillCurrent = stillCurrent
    }

    func runAfterConfirmation(allowSourceOnlyItems: Bool = false) async throws {
        guard !running, let old = reading.cloudReadingStore else { throw ReaderError.message("Recovery is already running or unavailable.") }
        running = true; defer { running = false }
        let fence: @MainActor () async throws -> Bool = {
            try Task.checkCancellation()
            guard self.stillCurrent(), self.reading.cloudReadingStore === old,
                  try await self.accountIsCurrent(), self.stillCurrent(), self.reading.cloudReadingStore === old else { return false }
            try self.reading.requireRecoveryScope(old.scope)
            return true
        }
        guard try await fence() else { throw ReaderError.message("The account or library changed. Recovery is paused.") }
        let access = try CloudRecoveryZoneAccess(scope: target, database: zones, accountIsCurrent: fence)
        guard try await access.inspect() == .present else { throw ReaderError.message("The destination recovery area is unavailable and needs review.") }
        let destination = try reading.standaloneSwitchDestination(targetScope: target)
        let receiver = try CloudRecoveryRecordReceiver(scope: target, zoneID: target.recoveryZoneID, reading: destination,
                                                        books: journal, archiveScript: archiveScript, accountIsCurrent: fence)
        let discovery = CloudRecoveryDiscovery(source: pages, zoneID: target.recoveryZoneID,
                                                accountIsCurrent: fence, receive: { try await receiver.receive($0) })
        try await discovery.scan()
        guard try await fence() else { throw ReaderError.message("The account or library changed. Recovery is paused.") }
        let books = await library.catalog()
        var bindings: [String: String] = [:]
        for book in books {
            guard try await fence() else { throw ReaderError.message("The account or library changed. Recovery is paused.") }
            let identity = try await library.ensureCloudIdentity(for: book, scope: target)
            bindings[book.id] = identity.readingBookID
        }
        let latest = await library.catalog()
        let originals = Dictionary(grouping: books, by: \.id)
        guard originals.count == books.count, latest.count == books.count, Set(latest.map(\.id)).count == latest.count, latest.allSatisfy({ book in
            bindings[book.id] == book.cloudIdentities?[target.cloudAccountKey]?.readingBookID &&
            originals[book.id]?.first.map({ $0.format == book.format && $0.contentDigest == book.contentDigest }) == true
        }), try await access.inspect() == .present, try await fence() else {
            throw ReaderError.message("The library or recovery account changed. Review the switch again.")
        }
        try journal.requireCurrentRevision()
        try reading.switchStandaloneRecoveryAccount(targetScope: target, catalogBindings: bindings,
                                                    allowSourceOnlyItems: allowSourceOnlyItems)
    }
}

/// Applies a discovered standalone book without touching its original source.
/// Tombstones and conflicts remain staged for a separate reviewed decision.
@MainActor final class StandaloneRecoveryApplication {
    struct Result {
        let book: LocalBookEntry
        let appliedReadingItems: Int
        let readingItemsNeedingReview: Int
        let readingItemFailures: [String]
    }
    private let scope: CloudReadingScope
    private let library: LocalLibrary
    private let reading: ReadingStore
    private let journal: CloudBookJournal
    private let accountIsCurrent: @MainActor () async throws -> Bool

    init(scope: CloudReadingScope, library: LocalLibrary, reading: ReadingStore, journal: CloudBookJournal,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard scope.isValid, scope.sourceKey == (try CloudReadingSource.imported.key()), journal.scope == scope,
              let atomic = reading.cloudReadingStore, atomic.scope == scope, atomic.localToCloudBookIDs != nil else {
            throw ReaderError.message("The standalone recovery stores do not match their account or source.")
        }
        self.scope = scope; self.library = library; self.reading = reading; self.journal = journal; self.accountIsCurrent = accountIsCurrent
    }

    private func checkAccount() async throws {
        do {
            guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
        } catch { reading.invalidateCloudVerification(); throw error }
    }

    func restore(_ id: CloudStandaloneBookID) async throws -> Result {
        try await checkAccount()
        try journal.requireCurrentRevision()
        guard let atomic = reading.cloudReadingStore, atomic.scope == scope,
              let entry = journal.entry(for: id), entry.conflicts.isEmpty,
              (!entry.pending || entry.pendingApplication), case .book(let metadata) = entry.current else {
            throw ReaderError.message("This book needs review before it can be restored.")
        }
        let lease = try await journal.stager.lease(bookID: id, revision: metadata.revision)
        guard lease.staged.metadata == metadata else { throw ReaderError.message("The staged iCloud book revision is inconsistent.") }
        try await checkAccount()
        try journal.requireCurrentRevision()
        let book = try await library.restoreCloudBook(lease.staged, scope: scope)
        withExtendedLifetime(lease) {}
        try await checkAccount()
        try journal.requireCurrentRevision()
        guard reading.cloudReadingStore === atomic,
              let current = journal.entry(for: id), current.current.revision == metadata.revision,
              current.conflicts.isEmpty, (!current.pending || current.pendingApplication) else {
            throw ReaderError.message("The iCloud book changed during recovery. Review it before continuing.")
        }
        try reading.bindStandaloneCloudIdentity(localBookID: book.id, cloudBookID: id)
        let fingerprint = try await reading.verifyStandaloneEdition(book, library: library, scope: scope)
        try await checkAccount()
        try journal.requireCurrentRevision()
        guard fingerprint == metadata.sha256, reading.cloudReadingStore === atomic,
              let latest = journal.entry(for: id), latest.current.revision == metadata.revision,
              latest.conflicts.isEmpty, (!latest.pending || latest.pendingApplication) else {
            throw ReaderError.message("The book edition changed during recovery. Review it before continuing.")
        }
        if latest.pendingApplication { try journal.markApplied(bookID: id, revision: metadata.revision) }
        var applied = 0, review = 0, failures: [String] = []
        let items = atomic.outbox.values.filter { $0.bookID == id.readingBookID && $0.pendingApplication == true }
        for item in items {
            try await checkAccount()
            try journal.requireCurrentRevision()
            guard item.entry.conflicts.isEmpty,
                  item.entry.current.editionFingerprint == fingerprint else { review += 1; continue }
            do {
                try reading.applyObservedCloudVersion(item.entry.key, book: book.book,
                                                      verifiedEditionFingerprint: fingerprint,
                                                      expectedRevision: item.entry.current.revision)
                applied += 1
            } catch {
                // A damaged item or a local storage failure must not hide
                // independent valid items. The failing version stays staged.
                try await checkAccount()
                failures.append(error.localizedDescription)
            }
        }
        return Result(book: book, appliedReadingItems: applied, readingItemsNeedingReview: review,
                      readingItemFailures: failures)
    }
}

/// One bounded recovery pass. Discovery completes before any uploads, so an
/// interrupted or incomplete scan cannot be mistaken for an empty cloud.
@MainActor final class StandaloneRecoveryCycle {
    struct Report {
        var restoredBooks = 0
        var appliedReadingItems = 0
        var needsReview = 0
        var pendingItems = 0
        var failures: [String] = []
    }
    private let scope: CloudReadingScope
    private let library: LocalLibrary
    private let reading: ReadingStore
    private let journal: CloudBookJournal
    private let preparation: StandaloneRecoveryPreparation
    private let zoneID: CKRecordZone.ID
    private let pages: any CloudRecoveryPageSource
    private let database: any CloudReadingRecordDatabase
    private let archiveScript: URL?
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private var running = false

    init(scope: CloudReadingScope, library: LocalLibrary, reading: ReadingStore, journal: CloudBookJournal,
         zoneID: CKRecordZone.ID, pages: any CloudRecoveryPageSource, database: any CloudReadingRecordDatabase,
         archiveScript: URL? = nil, accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        self.scope = scope; self.library = library; self.reading = reading; self.journal = journal
        self.zoneID = zoneID; self.pages = pages; self.database = database; self.archiveScript = archiveScript
        self.accountIsCurrent = accountIsCurrent
        preparation = try StandaloneRecoveryPreparation(scope: scope, library: library, reading: reading,
                                                         stager: journal.stager, journal: journal, accountIsCurrent: accountIsCurrent)
    }

    private func checkAccount() async throws {
        try Task.checkCancellation()
        do {
            guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
        } catch { reading.invalidateCloudVerification(); throw error }
    }

    func run() async throws -> Report {
        guard !running else { throw ReaderError.message("A recovery pass is already running.") }
        running = true; defer { running = false }
        try await checkAccount()
        try await preparation.prepare()
        guard let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("Reading data is unavailable for recovery.")
        }
        let receiver = try CloudRecoveryRecordReceiver(scope: scope, zoneID: zoneID, reading: atomic, books: journal,
                                                        archiveScript: archiveScript, accountIsCurrent: accountIsCurrent)
        let scan = CloudRecoveryDiscovery(source: pages, zoneID: zoneID, accountIsCurrent: accountIsCurrent,
                                          receive: { try await receiver.receive($0) })
        try await scan.scan()
        try await checkAccount()
        let application = try StandaloneRecoveryApplication(scope: scope, library: library, reading: reading,
                                                               journal: journal, accountIsCurrent: accountIsCurrent)
        var report = Report()
        for entry in Array(journal.entries.values) {
            let incomingReading = atomic.outbox.values.contains { $0.bookID == entry.bookID.readingBookID && $0.pendingApplication == true }
            guard entry.pendingApplication || incomingReading else { continue }
            try await checkAccount()
            if case .tombstone = entry.current, entry.pendingApplication, entry.conflicts.isEmpty, !entry.pending {
                let matchingBooks = await library.catalog().filter { $0.cloudIdentities?[scope.cloudAccountKey] == entry.bookID }
                try await checkAccount()
                // A remote deletion with no device copy has no local file to
                // remove. Keep any independent reading records staged for review.
                if matchingBooks.isEmpty {
                    try journal.markApplied(bookID: entry.bookID, revision: entry.current.revision)
                    continue
                }
            }
            guard entry.conflicts.isEmpty, (!entry.pending || entry.pendingApplication), case .book = entry.current else { report.needsReview += 1; continue }
            do {
                let result = try await application.restore(entry.bookID)
                if entry.pendingApplication { report.restoredBooks += 1 }
                report.appliedReadingItems += result.appliedReadingItems
                report.needsReview += result.readingItemsNeedingReview
                report.failures.append(contentsOf: result.readingItemFailures)
            } catch {
                try await checkAccount()
                report.failures.append(error.localizedDescription)
            }
        }
        for book in await library.catalog() {
            try await checkAccount()
            do { _ = try await preparation.queueBook(book) }
            catch { try await checkAccount(); report.failures.append(error.localizedDescription) }
        }
        for entry in Array(journal.entries.values) where entry.pending {
            try await checkAccount()
            guard entry.conflicts.isEmpty, !entry.pendingApplication else { report.needsReview += 1; continue }
            let transport = try CloudKitBookTransport(scope: scope, bookID: entry.bookID, zoneID: zoneID, database: database,
                                                       stager: journal.stager, pinOwner: journal.owner, archiveScript: archiveScript,
                                                       accountIsCurrent: accountIsCurrent)
            let coordinator = try CloudBookSyncCoordinator(journal: journal, transport: transport, accountIsCurrent: accountIsCurrent)
            await coordinator.sync()
            try await checkAccount()
            switch coordinator.status {
            case .conflict, .needsApplication: report.needsReview += 1
            case .failed(let message): report.failures.append(message)
            case .accountChanged: throw ReaderError.message("The iCloud account changed. Recovery is paused.")
            default: break
            }
        }
        for item in Array(atomic.outbox.values) where item.entry.pending {
            try await checkAccount()
            // Do not publish reading data for a missing, deleted, conflicted,
            // or not-yet-confirmed book. Retry it after its file is durable.
            guard item.bookID.hasPrefix("cloud-book-"),
                  let uuid = UUID(uuidString: String(item.bookID.dropFirst("cloud-book-".count))),
                  let book = journal.entry(for: CloudStandaloneBookID(uuid)),
                  book.conflicts.isEmpty, !book.pending, !book.pendingApplication,
                  case .book = book.current, book.baseRevision == book.current.revision else {
                report.needsReview += 1; continue
            }
            let transport = try CloudKitReadingTransport(scope: scope, bookID: item.bookID, zoneID: zoneID,
                                                          database: database, accountIsCurrent: accountIsCurrent)
            let coordinator = CloudAtomicReadingSyncCoordinator(store: atomic, transport: transport, accountIsCurrent: accountIsCurrent)
            await coordinator.sync(item.entry.key, bookID: item.bookID)
            try await checkAccount()
            switch coordinator.status {
            case .conflict, .needsApplication, .needsEditionVerification: report.needsReview += 1
            case .failed(let message): report.failures.append(message)
            case .accountChanged: throw ReaderError.message("The iCloud account changed. Recovery is paused.")
            default: break
            }
        }
        // Recompute from durable state after the pass. Changes can be added
        // during a network request, and discovered reading data may have no
        // corresponding book on this device yet.
        let bookBacklog = journal.entries.values.filter { $0.pending || $0.pendingApplication || !$0.conflicts.isEmpty }
        let readingBacklog = atomic.outbox.values.filter { $0.entry.pending || $0.pendingApplication == true || !$0.entry.conflicts.isEmpty }
        report.pendingItems = bookBacklog.count + readingBacklog.count + (atomic.hasUnmappedReadingData ? 1 : 0)
        report.needsReview = bookBacklog.filter { $0.pendingApplication || !$0.conflicts.isEmpty }.count +
            readingBacklog.filter { $0.pendingApplication == true || !$0.entry.conflicts.isEmpty || ($0.entry.pending && $0.entry.current.editionFingerprint == nil) }.count +
            (atomic.hasUnmappedReadingData ? 1 : 0)
        return report
    }
}

/// A recovery pass for one opened Jellyfin edition. The supplied book refresh
/// must retrieve current server progress; offline failure leaves cloud data staged.
@MainActor final class JellyfinReadingRecoveryCycle {
    struct Report {
        var applied = 0
        var needsReview = 0
        var pendingItems = 0
        var failures: [String] = []
    }
    private let scope: CloudReadingScope
    private let source: CloudReadingSource
    private let reading: ReadingStore
    private let zoneID: CKRecordZone.ID
    private let pages: any CloudRecoveryPageSource
    private let database: any CloudReadingRecordDatabase
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private let stillCurrent: @MainActor () -> Bool
    private let freshBook: @MainActor () async throws -> Book
    private let mayApplyPosition: @MainActor () -> Bool
    private var running = false

    init(scope: CloudReadingScope, source: CloudReadingSource, reading: ReadingStore,
         zoneID: CKRecordZone.ID, pages: any CloudRecoveryPageSource, database: any CloudReadingRecordDatabase,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool,
         stillCurrent: @escaping @MainActor () -> Bool,
         mayApplyPosition: @escaping @MainActor () -> Bool = { true },
         freshBook: @escaping @MainActor () async throws -> Book) throws {
        guard source.isJellyfin, scope.isValid, scope.sourceKey == (try source.key()),
              let atomic = reading.cloudReadingStore, atomic.scope == scope, atomic.localToCloudBookIDs == nil else {
            throw ReaderError.message("The Jellyfin recovery stores do not match their account or source.")
        }
        self.scope = scope; self.source = source; self.reading = reading; self.zoneID = zoneID
        self.pages = pages; self.database = database; self.accountIsCurrent = accountIsCurrent
        self.stillCurrent = stillCurrent; self.mayApplyPosition = mayApplyPosition; self.freshBook = freshBook
    }

    private func checkSession() async throws {
        try Task.checkCancellation()
        do {
            guard stillCurrent(), try await accountIsCurrent(), stillCurrent() else {
                throw ReaderError.message("The account or open book changed. Recovery is paused.")
            }
        } catch { reading.invalidateCloudVerification(); throw error }
    }

    func run(prepared: PreparedBook) async throws -> Report {
        guard !running else { throw ReaderError.message("A recovery pass is already running.") }
        running = true; defer { running = false }
        try await checkSession()
        guard let atomic = reading.cloudReadingStore, atomic.scope == scope else { throw CancellationError() }
        let receiver = try CloudRecoveryRecordReceiver(scope: scope, zoneID: zoneID, reading: atomic, books: nil,
                                                        accountIsCurrent: accountIsCurrent)
        let discovery = CloudRecoveryDiscovery(source: pages, zoneID: zoneID, accountIsCurrent: accountIsCurrent,
                                                receive: { try await receiver.receive($0) })
        try await discovery.scan()
        try await checkSession()
        let fingerprint = try await reading.verifyJellyfinEdition(prepared, source: source, stillCurrent: stillCurrent)
        try await checkSession()
        var report = Report()
        for item in Array(atomic.outbox.values) where item.bookID == prepared.id && item.pendingApplication == true {
            try await checkSession()
            guard item.entry.conflicts.isEmpty,
                  item.entry.current.editionFingerprint == fingerprint,
                  item.entry.key.kind != .position || mayApplyPosition() else { report.needsReview += 1; continue }
            do {
                let book: Book
                if item.entry.key.kind == .position { book = try await freshBook() }
                else { book = prepared.book }
                try await checkSession()
                guard item.entry.key.kind != .position || mayApplyPosition() else { report.needsReview += 1; continue }
                guard book.id == prepared.id, book.format == prepared.book.format else {
                    throw ReaderError.message("The server book changed. Review the reading data before restoring.")
                }
                try reading.applyObservedCloudVersion(item.entry.key, book: book,
                                                      verifiedEditionFingerprint: fingerprint,
                                                      expectedRevision: item.entry.current.revision)
                report.applied += 1
            } catch { try await checkSession(); report.failures.append(error.localizedDescription) }
        }
        for item in Array(atomic.outbox.values) where item.bookID == prepared.id && item.entry.pending {
            try await checkSession()
            let transport = try CloudKitReadingTransport(scope: scope, bookID: item.bookID, zoneID: zoneID,
                                                          database: database, accountIsCurrent: accountIsCurrent)
            let coordinator = CloudAtomicReadingSyncCoordinator(store: atomic, transport: transport, accountIsCurrent: accountIsCurrent)
            await coordinator.sync(item.entry.key, bookID: item.bookID)
            try await checkSession()
            switch coordinator.status {
            case .conflict, .needsApplication, .needsEditionVerification: report.needsReview += 1
            case .failed(let message): report.failures.append(message)
            case .accountChanged: throw ReaderError.message("The iCloud account changed. Recovery is paused.")
            default: break
            }
        }
        let backlog = atomic.outbox.values.filter {
            $0.bookID == prepared.id && ($0.entry.pending || $0.pendingApplication == true || !$0.entry.conflicts.isEmpty)
        }
        report.pendingItems = backlog.count
        report.needsReview = backlog.filter {
            $0.pendingApplication == true || !$0.entry.conflicts.isEmpty || ($0.entry.pending && $0.entry.current.editionFingerprint == nil)
        }.count
        return report
    }
}

/// Applies one explicitly reviewed book-file choice. A different retained local
/// edition is never replaced; a selected deletion removes only the cloud copy.
@MainActor final class StandaloneBookDeletionReview {
    private let scope: CloudReadingScope
    private let library: LocalLibrary
    private let journal: CloudBookJournal
    private let accountIsCurrent: @MainActor () async throws -> Bool

    init(scope: CloudReadingScope, library: LocalLibrary, journal: CloudBookJournal,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) {
        self.scope = scope; self.library = library; self.journal = journal; self.accountIsCurrent = accountIsCurrent
    }

    func resolve(bookID: CloudStandaloneBookID, localID: String, revision: UUID, restoreBackup: Bool) async throws {
        func check() async throws {
            try Task.checkCancellation()
            guard journal.scope == scope, try await accountIsCurrent() else {
                throw ReaderError.message("The account changed. Review the deletion again.")
            }
        }
        func currentBook() async throws -> LocalBookEntry {
            let matches = await library.catalog().filter { $0.cloudIdentities?[scope.cloudAccountKey] == bookID }
            guard matches.count == 1, let book = matches.first, book.id == localID else {
                throw ReaderError.message("The device book changed. Review the deletion again.")
            }
            return book
        }
        try await check()
        let book = try await currentBook()
        try await check()
        guard let entry = journal.entry(for: bookID), case .tombstone = entry.current,
              entry.current.revision == revision, entry.baseRevision == revision,
              !entry.pending, entry.conflicts.isEmpty else {
            throw ReaderError.message("The deleted backup changed. Review it again.")
        }
        if !restoreBackup {
            if entry.pendingApplication { try journal.markApplied(bookID: bookID, revision: revision) }
            return
        }
        let staged = try await library.stageCloudBook(book, scope: scope, stager: journal.stager)
        guard staged.metadata.bookID == bookID else { throw ReaderError.message("The book identity changed.") }
        try await journal.restoreReviewedDeletion(staged, expectedDeletion: revision, validateBeforeCommit: {
            try await check()
            _ = try await currentBook()
            try await check()
        })
    }
}

@MainActor final class StandaloneBookConflictResolution {
    private let scope: CloudReadingScope
    private let library: LocalLibrary
    private let reading: ReadingStore
    private let journal: CloudBookJournal
    private let accountIsCurrent: @MainActor () async throws -> Bool

    init(scope: CloudReadingScope, library: LocalLibrary, reading: ReadingStore, journal: CloudBookJournal,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard scope.isValid, scope.sourceKey == (try CloudReadingSource.imported.key()), journal.scope == scope,
              let atomic = reading.cloudReadingStore, atomic.scope == scope, atomic.localToCloudBookIDs != nil else {
            throw ReaderError.message("The standalone recovery stores do not match their account or source.")
        }
        self.scope = scope; self.library = library; self.reading = reading; self.journal = journal; self.accountIsCurrent = accountIsCurrent
    }
    private func checkAccount() async throws {
        try Task.checkCancellation()
        do {
            guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
        } catch { reading.invalidateCloudVerification(); throw error }
    }
    func resolve(bookID: CloudStandaloneBookID, expectedCurrent: UUID, remoteRevision: UUID,
                 choice: CloudBookJournal.ConflictChoice) async throws {
        try await checkAccount()
        guard let original = journal.entry(for: bookID), original.current.revision == expectedCurrent,
              let remote = original.conflicts.first(where: { $0.revision == remoteRevision }) else {
            throw ReaderError.message("The book conflict changed. Review it again.")
        }
        let selected = choice == .local ? original.current : remote
        if case .book(let metadata) = selected {
            let matches = await library.catalog().filter { $0.cloudIdentities?[scope.cloudAccountKey] == bookID }
            guard matches.count <= 1 else { throw ReaderError.message("The book identity needs review.") }
            if let existing = matches.first {
                try await checkAccount()
                let proof = try await library.verifyCloudEdition(for: existing, scope: scope)
                guard proof.fingerprint == metadata.sha256, existing.format == metadata.format else {
                    throw ReaderError.message("This is a different edition. Both copies are kept for further review.")
                }
            }
        }
        try await checkAccount()
        try await journal.resolveConflict(bookID: bookID, expectedLocalRevision: expectedCurrent,
                                          remoteRevision: remoteRevision, choice: choice,
                                          validateBeforeCommit: { try await self.checkAccount() })
        try await checkAccount()
        guard let resolved = journal.entry(for: bookID), resolved.conflicts.isEmpty else { return }
        switch resolved.current {
        case .tombstone:
            if resolved.pendingApplication { try journal.markApplied(bookID: bookID, revision: resolved.current.revision) }
        case .book:
            if resolved.pendingApplication {
                let application = try StandaloneRecoveryApplication(scope: scope, library: library, reading: reading,
                                                                     journal: journal, accountIsCurrent: accountIsCurrent)
                _ = try await application.restore(bookID)
            }
        }
    }
}
