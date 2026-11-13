import Foundation
import CloudKit
import CryptoKit
import PDFKit

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
        guard accountKey == scope.cloudAccountKey, sourceKey == scope.sourceKey,
              sourceKey == (try CloudReadingSource.imported.key()),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 512,
              format != .unsupported, byteCount > 0, byteCount <= 512 * 1024 * 1024,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ReaderError.message("The iCloud book metadata is invalid or belongs to another account.")
        }
    }
}

struct StagedCloudBook: Sendable {
    let metadata: CloudBookMetadata
    let assetURL: URL
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

    /// Only call after a transport has finished using its CKAsset. This removes
    /// staging, never the user's source or the standalone library copy.
    func discard(bookID: CloudStandaloneBookID, revision: UUID) throws {
        let directory = root.appendingPathComponent(stableKey(bookID.readingBookID), isDirectory: true).appendingPathComponent(revision.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
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
        record["bookFile"] = CKAsset(fileURL: staged.assetURL)
        return record
    }
    static func decode(_ record: CKRecord, scope: CloudReadingScope) throws -> (CloudBookMetadata, URL) {
        guard record.recordType == recordType, let bytes = record.encryptedValues["metadata"] as? Data,
              let asset = record["bookFile"] as? CKAsset, let url = asset.fileURL else { throw ReaderError.message("The iCloud book record is incomplete.") }
        let metadata = try JSONDecoder().decode(CloudBookMetadata.self, from: bytes)
        try metadata.validate(scope: scope)
        guard record.recordID.recordName == metadata.recordName else { throw ReaderError.message("The iCloud book identity is invalid.") }
        return (metadata, url)
    }
}
