import Foundation
import Darwin
import CryptoKit
import PDFKit

func stableKey(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

/// Logical file sizes, rather than allocated blocks. Temporary staging is not
/// reported as a completed book and symbolic links are never followed.
enum ManagedStorageUsage {
    static func bytes(in directory: URL) throws -> Int64 {
        let fm = FileManager.default
        var traversalError: Error?
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                             options: [], errorHandler: { _, error in traversalError = error; return false }) else {
            throw ReaderError.message("Storage use could not be calculated.")
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            // URL directory enumerators do not traverse symbolic links. Calling
            // skipDescendants on a link can skip unrelated siblings instead.
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                guard let fileSize = values.fileSize else { throw ReaderError.message("Storage use could not be calculated.") }
                let size = Int64(max(0, fileSize))
                let (sum, overflow) = total.addingReportingOverflow(size)
                total = overflow ? Int64.max : sum
            }
        }
        if let traversalError { throw traversalError }
        return total
    }

    static func bookBytes(in root: URL) throws -> Int64 {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var total: Int64 = 0
        for child in children where !child.lastPathComponent.hasPrefix("staging-") {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let (sum, overflow) = total.addingReportingOverflow(try bytes(in: child))
            total = overflow ? Int64.max : sum
        }
        return total
    }
}

/// Fingerprints are computed off the main actor with bounded memory. Hashing
/// each file separately preserves page boundaries in an ordered comic.
enum BookFingerprint {
    static func compute(files: [URL]) async throws -> String {
        let task = Task.detached(priority: .utility) { try digest(files: files, root: nil) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func epub(directory: URL, hasDurableSidecars: Bool = false) async throws -> String {
        let task = Task.detached(priority: .utility) { try epubDigest(directory: directory, hasDurableSidecars: hasDurableSidecars) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func epubDigest(directory: URL, hasDurableSidecars: Bool) throws -> String {
        let canonicalRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        let metadataURL = canonicalRoot.appendingPathComponent(".libravia-metadata.json")
        let retainsOriginal = hasDurableSidecars && ((try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(SavedBookMetadata.self, from: $0) }?.retainedOriginal == true)
        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, _ in traversalFailed = true; return false }) else { throw ReaderError.message("Book content is unavailable.") }
        var files: [URL] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw ReaderError.message("Book content cannot be verified.") }
            var reserved = hasDurableSidecars ? ["complete", ".libravia-metadata.json", ".libravia-cover"] : ["complete"]
            if retainsOriginal { reserved.append(".libravia-original") }
            let appOwned = reserved.contains {
                file.standardizedFileURL.path == canonicalRoot.appendingPathComponent($0).standardizedFileURL.path
            }
            if info.isRegularFile == true, !appOwned { files.append(file) }
            guard files.count <= 10_000 else { throw ReaderError.message("Book content cannot be verified.") }
        }
        guard !traversalFailed else { throw ReaderError.message("Book content cannot be verified.") }
        files.sort { $0.path < $1.path }
        return try digest(files: files, root: canonicalRoot)
    }
    private static func digest(files: [URL], root: URL?) throws -> String {
        guard !files.isEmpty else { throw ReaderError.message("Book content is unavailable.") }
        var combined = SHA256()
        for file in files {
            try Task.checkCancellation()
            if let root {
                let prefix = root.path + "/"
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { throw ReaderError.message("Book content cannot be verified.") }
                combined.update(data: Data(SHA256.hash(data: Data(path.dropFirst(prefix.count).utf8))))
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation(); digest.update(data: chunk)
            }
            combined.update(data: Data(digest.finalize()))
        }
        return combined.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Native file protection; user-created reading state remains eligible for device backup.
enum PrivateBookFiles {
    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        #endif
    }
    static func excludeFromBackup(_ url: URL) throws {
        var resource = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }
}

@MainActor final class ReadingStore {
    let root: URL
    private let baseDirectory: URL
    private var atomicStore: CloudAtomicReadingStore?
    private(set) var records: [String: ReadingRecord] = [:]
    private(set) var bookmarks: [String: [Bookmark]] = [:]
    private(set) var annotations: [String: [ReadingAnnotation]] = [:]
    private var originalFormatting: [String: Bool] = [:]
    init(namespace: String, baseDirectory: URL? = nil) throws {
        self.baseDirectory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = self.baseDirectory.appendingPathComponent("JellyfinBooks/\(stableKey(namespace))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        for name in ["positions.json", "bookmarks.json", "annotations.json"] {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try PrivateBookFiles.protect(file) }
        }
        let positionsFile = root.appendingPathComponent("positions.json")
        if FileManager.default.fileExists(atPath: positionsFile.path) {
            records = try JSONDecoder().decode([String: ReadingRecord].self, from: Data(contentsOf: positionsFile))
        }
        let bookmarksFile = root.appendingPathComponent("bookmarks.json")
        if FileManager.default.fileExists(atPath: bookmarksFile.path) {
            bookmarks = try JSONDecoder().decode([String: [Bookmark]].self, from: Data(contentsOf: bookmarksFile))
        }
        let annotationFile = root.appendingPathComponent("annotations.json")
        if FileManager.default.fileExists(atPath: annotationFile.path) {
            annotations = try JSONDecoder().decode([String: [ReadingAnnotation]].self, from: Data(contentsOf: annotationFile))
        }
        let formattingFile = root.appendingPathComponent("book-formatting.json")
        if FileManager.default.fileExists(atPath: formattingFile.path) {
            try PrivateBookFiles.protect(formattingFile)
            originalFormatting = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: formattingFile))
        }
        let marker = root.appendingPathComponent("atomic-reading-scope.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            let scope = try JSONDecoder().decode(CloudReadingScope.self, from: Data(contentsOf: marker))
            let atomic = try CloudAtomicReadingStore(scope: scope, legacyRecords: records, legacyBookmarks: bookmarks, legacyAnnotations: annotations, baseDirectory: self.baseDirectory, requireExisting: true)
            records = atomic.records; bookmarks = atomic.bookmarks; annotations = atomic.annotations; atomicStore = atomic
        }
    }
    func usesOriginalFormatting(bookID: String) -> Bool { originalFormatting[bookID] == true }
    func setOriginalFormatting(_ value: Bool, bookID: String) throws {
        var next = originalFormatting
        if value { next[bookID] = true } else { next.removeValue(forKey: bookID) }
        try PrivateBookFiles.write(JSONEncoder().encode(next), to: root.appendingPathComponent("book-formatting.json"))
        originalFormatting = next
    }
    /// Explicit local migration only. No iCloud operations or consent implied.
    /// A stale orphan from an interrupted migration is never adopted silently.
    func prepareAtomicReading(scope: CloudReadingScope) throws {
        guard atomicStore == nil else { throw ReaderError.message("This reading store has already been migrated.") }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("atomic-reading-scope.json").path) else {
            throw ReaderError.message("Reading data was migrated in another session. Reopen it first.")
        }
        let atomic = try CloudAtomicReadingStore(scope: scope, legacyRecords: records, legacyBookmarks: bookmarks, legacyAnnotations: annotations, baseDirectory: baseDirectory)
        guard try atomic.matchesLegacy(records: records, bookmarks: bookmarks, annotations: annotations) else {
            throw ReaderError.message("An interrupted reading-data migration requires recovery.")
        }
        try PrivateBookFiles.write(JSONEncoder().encode(scope), to: root.appendingPathComponent("atomic-reading-scope.json"))
        atomicStore = atomic
    }
    private func saveAtomicIfEnabled() throws -> Bool {
        guard let atomicStore else {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("atomic-reading-scope.json").path) else {
                throw ReaderError.message("Reading data was migrated in another session. Reopen it before editing.")
            }
            return false
        }
        try atomicStore.replace(records: records, bookmarks: bookmarks, annotations: annotations)
        return true
    }
    private func savePositions() throws {
        if try saveAtomicIfEnabled() { return }
        try PrivateBookFiles.write(JSONEncoder().encode(records), to: root.appendingPathComponent("positions.json"))
    }
    func set(_ record: ReadingRecord, id: String) throws {
        let previous = records[id]
        records[id] = record
        do { try savePositions() } catch { records[id] = previous; throw error }
    }
    func movePosition(from oldID: String, to book: Book, record: ReadingRecord) throws {
        guard oldID != book.id, records[oldID] != nil else { throw ReaderError.message("The saved position is no longer available to transfer.") }
        guard (annotations[oldID] ?? []).isEmpty, (annotations[book.id] ?? []).isEmpty else {
            throw ReaderError.message("One of these books has local annotations. They cannot be transferred or combined automatically.")
        }
        let sourceBookmarks = bookmarks[oldID] ?? []
        let targetBookmarks = bookmarks[book.id] ?? []
        // If an earlier transfer stopped after copying bookmarks but before
        // writing the position, allow the same transfer to finish safely.
        let copiedBookmarks = !sourceBookmarks.isEmpty &&
            targetBookmarks.map(\.id) == sourceBookmarks.map(\.id)
        guard records[book.id] == nil, targetBookmarks.isEmpty || copiedBookmarks else {
            throw ReaderError.message("The selected book already has reading data on this device. Nothing was changed.")
        }
        let previousRecords = records, previousBookmarks = bookmarks
        // Copy bookmarks first. An interrupted move can leave an extra copy,
        // but cannot lose the only copy of a bookmark.
        do {
            if let oldBookmarks = bookmarks[oldID] { bookmarks[book.id] = oldBookmarks; try saveBookmarks() }
            records[book.id] = record
            records.removeValue(forKey: oldID)
            try savePositions()
            bookmarks.removeValue(forKey: oldID)
            try saveBookmarks()
        } catch {
            records = previousRecords; bookmarks = previousBookmarks
            try? savePositions(); try? saveBookmarks()
            throw error
        }
    }
    func add(_ bookmark: Bookmark, id: String) throws {
        let previous = bookmarks[id]
        bookmarks[id, default: []].append(bookmark)
        do { try saveBookmarks() } catch { bookmarks[id] = previous; throw error }
    }
    @discardableResult func addIfAbsent(_ bookmark: Bookmark, id: String, format: BookFormat) throws -> Bool {
        let exists = bookmarks[id, default: []].contains { existing in
            if format == .epub {
                if let cfi = bookmark.position.cfi, let oldCFI = existing.position.cfi { return cfi == oldCFI }
                return bookmark.position.cfi == nil && existing.position.cfi == nil && bookmark.position.fraction == existing.position.fraction
            }
            return existing.position.page == bookmark.position.page
        }
        guard !exists else { return false }
        let previous = bookmarks[id]
        bookmarks[id, default: []].append(bookmark)
        do { try saveBookmarks() } catch { bookmarks[id] = previous; throw error }
        return true
    }
    func renameBookmark(_ bookmark: Bookmark, id: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReaderError.message("Enter a bookmark name.") }
        guard let index = bookmarks[id]?.firstIndex(where: { $0.id == bookmark.id }) else { throw ReaderError.message("This bookmark is no longer available.") }
        let previous = bookmarks[id]
        bookmarks[id]?[index].name = trimmed
        do { try saveBookmarks() } catch { bookmarks[id] = previous; throw error }
    }
    func removeBookmark(_ bookmark: Bookmark, id: String) throws {
        let previous = bookmarks[id]
        bookmarks[id]?.removeAll { $0.id == bookmark.id }
        do { try saveBookmarks() } catch { bookmarks[id] = previous; throw error }
    }
    private func saveBookmarks() throws {
        if try saveAtomicIfEnabled() { return }
        try PrivateBookFiles.write(JSONEncoder().encode(bookmarks), to: root.appendingPathComponent("bookmarks.json"))
    }
    func saveAnnotation(_ annotation: ReadingAnnotation, id: String) throws {
        let previous = annotations[id]
        if let index = annotations[id]?.firstIndex(where: { $0.id == annotation.id }) { annotations[id]?[index] = annotation }
        else { annotations[id, default: []].append(annotation) }
        do { try saveAnnotations() } catch { annotations[id] = previous; throw error }
    }
    func removeAnnotation(_ annotation: ReadingAnnotation, id: String) throws {
        let previous = annotations[id]
        annotations[id]?.removeAll { $0.id == annotation.id }
        do { try saveAnnotations() } catch { annotations[id] = previous; throw error }
    }
    private func saveAnnotations() throws {
        if try saveAtomicIfEnabled() { return }
        try PrivateBookFiles.write(JSONEncoder().encode(annotations), to: root.appendingPathComponent("annotations.json"))
    }
    var hasUnsyncedCloudChanges: Bool { atomicStore?.outbox.values.contains(where: { $0.entry.pending || !$0.entry.conflicts.isEmpty }) ?? false }
    func delete(allowUnsynced: Bool = false) throws {
        guard atomicStore != nil || !FileManager.default.fileExists(atPath: root.appendingPathComponent("atomic-reading-scope.json").path) else {
            throw ReaderError.message("Reading data was migrated in another session. Reopen it before removing it.")
        }
        guard allowUnsynced || !hasUnsyncedCloudChanges else { throw ReaderError.message("Reading data has unsynced changes and cannot be removed without confirmation.") }
        if let atomicStore { try atomicStore.deleteLocal() }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        atomicStore = nil; records = [:]; bookmarks = [:]; annotations = [:]
    }
}

/// Minimal source-scoped catalog information needed to reopen a saved book.
private struct SavedBookMetadata: Codable {
    let id: String
    let title: String
    let author: String
    let summary: String
    let format: BookFormat
    let imageTag: String?
    let ticks: Int64
    let libraryID: String?
    let libraryName: String?
    var retainedOriginal: Bool? = nil

    init(_ book: Book, retainedOriginal: Bool = false) {
        id = book.id; title = book.title; author = book.author; summary = book.summary
        format = book.format; imageTag = book.imageTag; ticks = book.ticks
        libraryID = book.libraryID; libraryName = book.libraryName
        self.retainedOriginal = retainedOriginal ? true : nil
    }
    var book: Book {
        Book(id: id, title: title, author: author, summary: summary, format: format,
             isFolder: false, imageTag: imageTag, ticks: ticks, libraryID: libraryID, libraryName: libraryName)
    }
}

/// User-selected copies are kept outside the evictable cache. Installation is
/// staged in the same directory so an interrupted copy cannot appear complete.
actor DurableBookStore {
    let root: URL
    private var retired = false

    init(namespace: String) throws {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyfinBooksSaved/\(stableKey(namespace))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
    }

    func saved(_ book: Book) -> URL? {
        guard !retired else { return nil }
        let directory = root.appendingPathComponent(stableKey(book.id))
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path),
              (book.format != .pdf || FileManager.default.fileExists(atPath: directory.appendingPathComponent("book.pdf").path)),
              (try? BookCache.contents(directory, format: book.format)) != nil else { return nil }
        if book.format == .pdf {
            guard let document = PDFDocument(url: directory.appendingPathComponent("book.pdf")),
                  !document.isLocked, document.pageCount > 0 else { return nil }
        }
        return directory
    }

    func availableKeys() throws -> Set<String> {
        guard !retired else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { directory in
                guard !directory.lastPathComponent.hasPrefix("staging-"),
                      let data = try? Data(contentsOf: directory.appendingPathComponent(".libravia-metadata.json")),
                      let metadata = try? JSONDecoder().decode(SavedBookMetadata.self, from: data),
                      directory.lastPathComponent == stableKey(metadata.id), saved(metadata.book) != nil else { return nil }
                return directory.lastPathComponent
            })
    }

    func storageBytes() throws -> Int64 {
        guard !retired else { throw CancellationError() }
        return try ManagedStorageUsage.bookBytes(in: root)
    }

    func catalog() throws -> [Book] {
        guard !retired else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { directory in
            guard !directory.lastPathComponent.hasPrefix("staging-"),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(".libravia-metadata.json")),
                  let metadata = try? JSONDecoder().decode(SavedBookMetadata.self, from: data),
                  directory.lastPathComponent == stableKey(metadata.id) else { return nil }
            return metadata.book
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func cover(_ book: Book) -> Data? {
        guard let directory = saved(book),
              let data = try? Data(contentsOf: directory.appendingPathComponent(".libravia-cover")), data.count <= 10 * 1024 * 1024 else { return nil }
        return data
    }

    /// Copies the input; the caller retains ownership of the original file.
    func install(_ source: URL, book: Book, cover: Data? = nil, retainOriginal: Bool = false, archiveScript: URL? = nil) async throws -> URL {
        let fm = FileManager.default
        try Task.checkCancellation()
        guard !retired else { throw CancellationError() }
        guard book.format != .unsupported else { throw ReaderError.message("This format is not supported.") }
        if let existing = saved(book) { return existing }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw ReaderError.message("Books must be smaller than 512 MB.") }
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try PrivateBookFiles.protect(staging)
        if book.format == .pdf {
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
            let header = try handle.read(upToCount: 1024) ?? Data()
            guard String(decoding: header, as: UTF8.self).contains("%PDF-") else { throw ReaderError.message("The file is not a valid PDF.") }
            guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0 else {
                throw ReaderError.message("This PDF is damaged or locked and cannot be saved.")
            }
            let target = staging.appendingPathComponent("book.pdf")
            try fm.copyItem(at: source, to: target)
            try PrivateBookFiles.protect(target)
        } else {
            try await ArchiveExtractor.extract(source, to: staging, scriptURL: archiveScript)
        }
        try Task.checkCancellation()
        guard !retired else { throw CancellationError() }
        _ = try BookCache.contents(staging, format: book.format)
        let metadataFile = staging.appendingPathComponent(".libravia-metadata.json")
        let coverFile = staging.appendingPathComponent(".libravia-cover")
        let originalFile = staging.appendingPathComponent(".libravia-original")
        guard !fm.fileExists(atPath: metadataFile.path), !fm.fileExists(atPath: coverFile.path), !fm.fileExists(atPath: originalFile.path) else {
            throw ReaderError.message("The book contains reserved storage names.")
        }
        if retainOriginal && book.format != .pdf {
            try fm.copyItem(at: source, to: originalFile)
            try PrivateBookFiles.protect(originalFile)
            try Task.checkCancellation()
            guard !retired else { throw CancellationError() }
        }
        try PrivateBookFiles.write(JSONEncoder().encode(SavedBookMetadata(book, retainedOriginal: retainOriginal && book.format != .pdf)), to: metadataFile)
        if let cover, cover.count <= 10 * 1024 * 1024 {
            try PrivateBookFiles.write(cover, to: coverFile)
        }
        try PrivateBookFiles.write(Data(), to: staging.appendingPathComponent("complete"))
        let destination = root.appendingPathComponent(stableKey(book.id))
        // Never replace a prior copy after an interrupted or concurrent install.
        if fm.fileExists(atPath: destination.path) {
            if let existing = saved(book) { return existing }
            throw ReaderError.message("The saved copy needs attention before it can be replaced.")
        }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    /// Restore or replace an app-owned archive only after verifying the
    /// reselected file against the existing book identity.
    func restoreOriginal(_ source: URL, book: Book, expectedDigest: String) throws {
        guard !retired else { throw CancellationError() }
        guard book.format == .epub || book.format == .cbz, let directory = saved(book) else { return }
        let destination = directory.appendingPathComponent(".libravia-original")
        let metadataURL = directory.appendingPathComponent(".libravia-metadata.json")
        var metadata = try JSONDecoder().decode(SavedBookMetadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.id == book.id, metadata.format == book.format else { throw ReaderError.message("The saved book identity is invalid.") }
        var destinationStat = stat()
        let destinationExists = lstat(destination.path, &destinationStat) == 0
        if destinationExists {
            guard metadata.retainedOriginal == true,
                  (destinationStat.st_mode & S_IFMT) == S_IFREG else {
                throw ReaderError.message("The saved book contains a reserved name. Import a separate copy to sync its original.")
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let temporary = root.appendingPathComponent("staging-original-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try PrivateBookFiles.protect(temporary)
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); hash.update(data: bytes)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest, !retired else { throw ReaderError.message("The selected original does not match this saved book.") }
        try Task.checkCancellation()
        // Record ownership before the atomic move. If interrupted, a later
        // reselect can retry because the destination remains absent.
        metadata.retainedOriginal = true
        try PrivateBookFiles.write(JSONEncoder().encode(metadata), to: metadataURL)
        if destinationExists {
            // Both paths are inside the same app-owned volume. Atomic rename
            // preserves the previous copy if replacement fails or is interrupted.
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            // Do not overwrite a file that appeared during legacy recovery.
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
    func originalFile(for book: Book) -> URL? {
        guard let directory = saved(book) else { return nil }
        if book.format == .pdf { return directory.appendingPathComponent("book.pdf") }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".libravia-metadata.json")),
              let metadata = try? JSONDecoder().decode(SavedBookMetadata.self, from: data),
              metadata.id == book.id, metadata.format == book.format, metadata.retainedOriginal == true else { return nil }
        let url = directory.appendingPathComponent(".libravia-original")
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
        return url
    }

    func remove(_ book: Book) throws {
        guard !retired else { throw CancellationError() }
        let directory = root.appendingPathComponent(stableKey(book.id))
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Stop account-bound work without deleting the user's saved copies.
    func retire() { retired = true }

    /// Retire before deleting to prevent a suspended extraction from publishing.
    func delete() throws {
        retired = true
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

actor BookCache {
    let root: URL
    let budget: Int64
    private var protected: String?
    private var deleted = false
    init(namespace: String, budget: Int64 = 1_073_741_824) throws {
        self.budget = budget
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("JellyfinBooks/\(stableKey(namespace))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        try PrivateBookFiles.excludeFromBackup(root)
    }
    func protect(_ id: String?) { protected = id.map(stableKey) }
    func cached(_ book: Book) -> URL? {
        guard !deleted else { return nil }
        let directory = root.appendingPathComponent(stableKey(book.id))
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        return directory
    }
    func availableKeys() throws -> Set<String> {
        guard !deleted else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("complete").path) }
            .map(\.lastPathComponent))
    }
    func storageBytes() throws -> Int64 {
        guard !deleted else { throw CancellationError() }
        return try ManagedStorageUsage.bookBytes(in: root)
    }
    func remove(_ book: Book) throws {
        guard !deleted else { throw CancellationError() }
        let key = stableKey(book.id)
        guard key != protected else { throw ReaderError.message("Close this book before removing its device copy.") }
        let directory = root.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func install(_ source: URL, book: Book, protectInstalled: Bool = true) async throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: source) }
        try Task.checkCancellation()
        guard !deleted else { throw CancellationError() }
        try PrivateBookFiles.protect(source)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw ReaderError.message("Books must be smaller than 512 MB.") }
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(staging)
        defer { try? fm.removeItem(at: staging) }
        if book.format == .pdf {
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
            let header = try handle.read(upToCount: 1024) ?? Data()
            guard String(decoding: header, as: UTF8.self).contains("%PDF-") else { throw ReaderError.message("The server did not return a valid PDF.") }
            try fm.copyItem(at: source, to: staging.appendingPathComponent("book.pdf"))
            try PrivateBookFiles.protect(staging.appendingPathComponent("book.pdf"))
        } else {
            try await ArchiveExtractor.extract(source, to: staging)
        }
        try Task.checkCancellation()
        guard !deleted else { throw CancellationError() }
        _ = try Self.contents(staging, format: book.format)
        try PrivateBookFiles.write(Data(), to: staging.appendingPathComponent("complete"))
        let destination = root.appendingPathComponent(stableKey(book.id))
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        try PrivateBookFiles.excludeFromBackup(destination)
        if protectInstalled { protected = stableKey(book.id) }
        try evict()
        return destination
    }
    static func validateEntry(path: String, size: UInt64, total: UInt64, count: Int) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !components.contains(".."), !components.contains(where: { $0.contains(":") }), size <= 128 * 1024 * 1024, total <= 768 * 1024 * 1024, count <= 10_000 else { throw ReaderError.message("This archive contains unsafe paths or exceeds extraction limits.") }
    }
    static func contents(_ directory: URL, format: BookFormat) throws -> (URL, [URL]) {
        let fm = FileManager.default
        if format == .pdf { return (directory.appendingPathComponent("book.pdf"), []) }
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { throw ReaderError.message("Could not open this book.") }
        let files = enumerator.compactMap { $0 as? URL }
        if format == .epub {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("META-INF/container.xml")) else { throw ReaderError.message("The EPUB container is missing.") }
            let parser = XMLParser(data: data); let delegate = ContainerParser(); parser.delegate = delegate
            guard parser.parse(), let path = delegate.path else { throw ReaderError.message("The EPUB package could not be located.") }
            try validateEntry(path: path, size: 0, total: 0, count: 1)
            let opf = directory.appendingPathComponent(path)
            guard fm.fileExists(atPath: opf.path), !fm.fileExists(atPath: directory.appendingPathComponent("META-INF/encryption.xml").path) else { throw ReaderError.message("Encrypted EPUBs are not supported.") }
            return (opf, [])
        }
        let images = files.filter { ["jpg", "jpeg", "png", "webp", "gif"].contains($0.pathExtension.lowercased()) && !$0.path.contains("__MACOSX") }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard format == .cbz, !images.isEmpty else { throw ReaderError.message("This book has no supported image pages.") }
        return (images[0], images)
    }
    private func size(_ directory: URL) -> Int64 {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return iterator.compactMap { $0 as? URL }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func evict() throws {
        let fm = FileManager.default
        let directories = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]).filter { !$0.lastPathComponent.hasPrefix("staging-") }.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = directories.reduce(Int64(0)) { $0 + size($1) }
        for directory in directories where total > budget && directory.lastPathComponent != protected { let bytes = size(directory); try fm.removeItem(at: directory); total -= bytes }
    }
    /// Retire this account cache before deleting it so suspended installs cannot publish afterward.
    func delete() throws {
        deleted = true; protected = nil
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func clear() throws {
        guard !deleted else { throw CancellationError() }
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where directory.lastPathComponent != protected && !directory.lastPathComponent.hasPrefix("staging-") {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
private final class ContainerParser: NSObject, XMLParserDelegate {
    var path: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) { if elementName == "rootfile", path == nil { path = attributeDict["full-path"] } }
}
