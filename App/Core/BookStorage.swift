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
    static func prepared(_ book: PreparedBook) async throws -> String {
        if book.book.format == .epub { return try await epub(directory: book.directory, hasDurableSidecars: book.hasDurableSidecars) }
        return try await compute(files: book.book.format == .pdf ? [book.document] : book.images)
    }
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
    /// Nonblocking interprocess exclusion around read/check/write transactions.
    /// Lock files contain no user data and must live outside replaceable data files.
    static func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ReaderError.message("The local recovery state is unavailable.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ReaderError.message("The local recovery state is in use. Try again.")
        }
        return try body()
    }

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
    private let namespaceLock: URL
    private var atomicStore: CloudAtomicReadingStore?
    private var editionVerificationGenerations: [String: UUID] = [:]
    private(set) var records: [String: ReadingRecord] = [:]
    private(set) var bookmarks: [String: [Bookmark]] = [:]
    private(set) var annotations: [String: [ReadingAnnotation]] = [:]
    private var originalFormatting: [String: Bool] = [:]
    // Exact file snapshots let stale sessions reject writes instead of silently
    // replacing changes committed by another session. Missing files have no entry.
    private var legacyFiles: [String: Data] = [:]
    init(namespace: String, baseDirectory: URL? = nil) throws {
        self.baseDirectory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = self.baseDirectory.appendingPathComponent("JellyfinBooks/\(stableKey(namespace))")
        namespaceLock = root.deletingLastPathComponent().appendingPathComponent("\(stableKey(namespace)).reading.lock")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
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
            for name in ["positions.json", "bookmarks.json", "annotations.json", "book-formatting.json"] {
                let file = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { legacyFiles[name] = try Data(contentsOf: file) }
            }
            let marker = root.appendingPathComponent("atomic-reading-scope.json")
            if FileManager.default.fileExists(atPath: marker.path) {
                let scope = try JSONDecoder().decode(CloudReadingScope.self, from: Data(contentsOf: marker))
                let atomic = try CloudAtomicReadingStore(scope: scope, legacyRecords: records, legacyBookmarks: bookmarks, legacyAnnotations: annotations, baseDirectory: self.baseDirectory, requireExisting: true)
                records = atomic.records; bookmarks = atomic.bookmarks; annotations = atomic.annotations; atomicStore = atomic
            }
        }
    }
    func usesOriginalFormatting(bookID: String) -> Bool { originalFormatting[bookID] == true }
    func belongs(to account: Account) -> Bool { root.lastPathComponent == stableKey(account.namespace) }
    /// Recovery setup must not silently attach an existing local journal to a
    /// different iCloud account or source. The on-disk marker also catches a
    /// migration performed by another open session.
    func requireRecoveryScope(_ scope: CloudReadingScope) throws {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            guard scope.isValid else { throw ReaderError.message("The recovery account is unavailable.") }
            let marker = root.appendingPathComponent("atomic-reading-scope.json")
            guard FileManager.default.fileExists(atPath: marker.path) else {
                guard atomicStore == nil else { throw ReaderError.message("Reading data changed in another session. Reopen it before recovery.") }
                return
            }
            let stored = try JSONDecoder().decode(CloudReadingScope.self, from: Data(contentsOf: marker))
            guard stored == scope else {
                throw ReaderError.message("This device's reading recovery is linked to another iCloud account or library. Return to the original account and library to resume. Your local reading data is unchanged.")
            }
            guard atomicStore?.scope == stored else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before recovery.")
            }
        }
    }
    func setOriginalFormatting(_ value: Bool, bookID: String) throws {
        var next = originalFormatting
        if value { next[bookID] = true } else { next.removeValue(forKey: bookID) }
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try writeLegacy(JSONEncoder().encode(next), name: "book-formatting.json")
            originalFormatting = next
        }
    }
    /// Explicit local migration only. No iCloud operations or consent implied.
    /// A stale orphan from an interrupted migration is never adopted silently.
    func prepareAtomicReading(scope: CloudReadingScope, localToCloudBookIDs: [String: String]? = nil) throws {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            guard atomicStore == nil else { throw ReaderError.message("This reading store has already been migrated.") }
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("atomic-reading-scope.json").path) else {
                throw ReaderError.message("Reading data was migrated in another session. Reopen it first.")
            }
            // A different legacy session may have edited since this instance opened.
            // Compare the disk snapshot while holding the same lock used by writers.
            func read<T: Decodable>(_ type: T.Type, _ name: String, default fallback: T) throws -> T {
                let file = root.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { return fallback }
                return try JSONDecoder().decode(type, from: Data(contentsOf: file))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(read([String: ReadingRecord].self, "positions.json", default: [:])) == encoder.encode(records),
                  try encoder.encode(read([String: [Bookmark]].self, "bookmarks.json", default: [:])) == encoder.encode(bookmarks),
                  try encoder.encode(read([String: [ReadingAnnotation]].self, "annotations.json", default: [:])) == encoder.encode(annotations) else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before migrating.")
            }
            let atomic = try CloudAtomicReadingStore(scope: scope, legacyRecords: records, legacyBookmarks: bookmarks, legacyAnnotations: annotations, baseDirectory: baseDirectory, localToCloudBookIDs: localToCloudBookIDs)
            guard try atomic.matchesLegacy(records: records, bookmarks: bookmarks, annotations: annotations) else {
                throw ReaderError.message("An interrupted reading-data migration requires recovery.")
            }
            try PrivateBookFiles.write(JSONEncoder().encode(scope), to: root.appendingPathComponent("atomic-reading-scope.json"))
            atomicStore = atomic
        }
    }
    /// Called only after the user has identified the earlier library. The old
    /// source key did not include the server endpoint and cannot prove that
    /// association by itself.
    func migrateLegacyJellyfinReading(account: Account, targetScope: CloudReadingScope) throws {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            guard root.lastPathComponent == stableKey(account.namespace), let source = atomicStore else {
                throw ReaderError.message("The earlier recovery library is unavailable.")
            }
            try validateAtomicScope()
            let snapshot = try source.legacyJellyfinMigrationSnapshot(account: account, targetScope: targetScope)
            let plan = try snapshot.makePlan()
            try source.installLegacyJellyfinMigration(plan, baseDirectory: baseDirectory) {
                try PrivateBookFiles.write(JSONEncoder().encode(targetScope), to: root.appendingPathComponent("atomic-reading-scope.json"))
            }
            let target = try CloudAtomicReadingStore(scope: targetScope, legacyRecords: [:], legacyBookmarks: [:],
                                                     legacyAnnotations: [:], baseDirectory: baseDirectory, requireExisting: true)
            atomicStore = target
            records = target.records; bookmarks = target.bookmarks; annotations = target.annotations
            editionVerificationGenerations = [:]
        }
    }
    /// The caller must first obtain an explicit account-switch decision and
    /// stop recovery work for this reading namespace.
    func jellyfinSwitchDestination(account: Account, targetScope: CloudReadingScope) throws -> CloudAtomicReadingStore {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            guard belongs(to: account), let source = atomicStore,
                  source.localToCloudBookIDs == nil, targetScope.isValid,
                  source.scope.sourceKey == (try CloudReadingSource.scopedJellyfin(account).key()),
                  targetScope.sourceKey == source.scope.sourceKey,
                  targetScope.cloudAccountKey != source.scope.cloudAccountKey else {
                throw ReaderError.message("The recovery account or library changed. Review it again.")
            }
            try validateAtomicScope()
            try source.requireCurrentRevision()
            return try CloudAtomicReadingStore(scope: targetScope, legacyRecords: [:], legacyBookmarks: [:],
                                                legacyAnnotations: [:], baseDirectory: baseDirectory)
        }
    }
    func switchJellyfinRecoveryAccount(account: Account, targetScope: CloudReadingScope) throws {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            guard belongs(to: account), let source = atomicStore,
                  source.scope.sourceKey == (try CloudReadingSource.scopedJellyfin(account).key()),
                  targetScope.sourceKey == source.scope.sourceKey,
                  targetScope.cloudAccountKey != source.scope.cloudAccountKey else {
                throw ReaderError.message("The recovery account or library changed. Review it again.")
            }
            try validateAtomicScope()
            let target = try CloudAtomicReadingStore(scope: targetScope, legacyRecords: [:], legacyBookmarks: [:],
                                                     legacyAnnotations: [:], baseDirectory: baseDirectory)
            let switchMarker = {
                try PrivateBookFiles.write(JSONEncoder().encode(targetScope), to: self.root.appendingPathComponent("atomic-reading-scope.json"))
            }
            if try !source.resumePreparedAccountSwitch(target: target, switchMarker: switchMarker) {
                let plan = try source.jellyfinAccountSwitchPlan(account: account, targetScope: targetScope, target: target)
                try source.installJellyfinAccountSwitch(plan, target: target, switchMarker: switchMarker)
            }
            atomicStore = target
            records = target.records; bookmarks = target.bookmarks; annotations = target.annotations
            editionVerificationGenerations = [:]
        }
    }
    /// Local commit only. The caller must inspect the destination cloud and
    /// confirm any source-only items before invoking this operation.
    func standaloneSwitchDestination(targetScope: CloudReadingScope) throws -> CloudAtomicReadingStore {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try validateAtomicScope()
            guard let source = atomicStore, source.localToCloudBookIDs != nil, targetScope.isValid,
                  source.scope.sourceKey == (try CloudReadingSource.imported.key()),
                  targetScope.sourceKey == source.scope.sourceKey,
                  targetScope.cloudAccountKey != source.scope.cloudAccountKey else {
                throw ReaderError.message("The recovery account changed. Review it again.")
            }
            try source.requireCurrentRevision()
            return try openStandaloneSwitchDestination(targetScope)
        }
    }

    private func openStandaloneSwitchDestination(_ targetScope: CloudReadingScope) throws -> CloudAtomicReadingStore {
        let path = baseDirectory.appendingPathComponent("LibraViaAtomicReading/\(targetScope.cloudAccountKey)/\(targetScope.sourceKey)/reading-state.json")
        let exists = FileManager.default.fileExists(atPath: path.path)
        let target = try CloudAtomicReadingStore(scope: targetScope, legacyRecords: [:], legacyBookmarks: [:],
                                                 legacyAnnotations: [:], baseDirectory: baseDirectory, requireExisting: exists,
                                                 localToCloudBookIDs: exists ? nil : [:])
        guard target.localToCloudBookIDs != nil else { throw ReaderError.message("The destination recovery data needs review.") }
        return target
    }

    func switchStandaloneRecoveryAccount(targetScope: CloudReadingScope, catalogBindings: [String: String],
                                         allowSourceOnlyItems: Bool = false) throws {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            guard let source = atomicStore, source.localToCloudBookIDs != nil, targetScope.isValid,
                  source.scope.sourceKey == (try CloudReadingSource.imported.key()),
                  targetScope.sourceKey == source.scope.sourceKey,
                  targetScope.cloudAccountKey != source.scope.cloudAccountKey else {
                throw ReaderError.message("The recovery account changed. Review it again.")
            }
            try validateAtomicScope()
            let target = try openStandaloneSwitchDestination(targetScope)
            guard let existingBindings = target.localToCloudBookIDs else {
                throw ReaderError.message("The destination recovery data needs review.")
            }
            let marker = {
                try PrivateBookFiles.write(JSONEncoder().encode(targetScope), to: self.root.appendingPathComponent("atomic-reading-scope.json"))
            }
            let matchesPreparedBindings = catalogBindings.allSatisfy { existingBindings[$0.key] == $0.value }
            let resumed = matchesPreparedBindings
                ? try source.resumePreparedAccountSwitch(target: target, allowSourceOnlyItems: allowSourceOnlyItems, switchMarker: marker)
                : false
            if !resumed {
                let plan = try source.standaloneAccountSwitchPlan(targetScope: targetScope, target: target, catalogBindings: catalogBindings)
                try source.installStandaloneAccountSwitch(plan, target: target, allowSourceOnlyItems: allowSourceOnlyItems, switchMarker: marker)
            }
            atomicStore = target
            records = target.records; bookmarks = target.bookmarks; annotations = target.annotations
            editionVerificationGenerations = [:]
        }
    }
    private func validateAtomicScope() throws {
        let marker = root.appendingPathComponent("atomic-reading-scope.json")
        guard let atomicStore, FileManager.default.fileExists(atPath: marker.path),
              try JSONDecoder().decode(CloudReadingScope.self, from: Data(contentsOf: marker)) == atomicStore.scope else {
            throw ReaderError.message("Reading data changed in another session. Reopen it before editing.")
        }
    }
    private func saveAtomicIfEnabled() throws -> Bool {
        guard let atomicStore else {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("atomic-reading-scope.json").path) else {
                throw ReaderError.message("Reading data was migrated in another session. Reopen it before editing.")
            }
            return false
        }
        try validateAtomicScope()
        try atomicStore.replace(records: records, bookmarks: bookmarks, annotations: annotations)
        return true
    }
    /// Caller holds namespaceLock for both the comparison and atomic write.
    private func validateLegacyFile(_ name: String) throws {
        let file = root.appendingPathComponent(name)
        let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == legacyFiles[name] else {
            throw ReaderError.message("Reading data changed in another session. Reopen it before editing.")
        }
    }
    private func writeLegacy(_ data: Data, name: String) throws {
        try validateLegacyFile(name)
        try PrivateBookFiles.write(data, to: root.appendingPathComponent(name))
        legacyFiles[name] = data
    }
    private func savePositions() throws {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            if try saveAtomicIfEnabled() { return }
            try writeLegacy(JSONEncoder().encode(records), name: "positions.json")
        }
    }
    func set(_ record: ReadingRecord, id: String) throws {
        let previous = records[id]
        records[id] = record
        do { try savePositions() } catch { records[id] = previous; throw error }
    }
    /// Preserve the old place durably before replacing it. An interrupted
    /// legacy two-file write can leave an extra bookmark, never a lost place.
    func replaceReviewedPosition(_ record: ReadingRecord, id: String, expected: ReadingRecord, backupID: UUID) throws {
        guard records[id] == expected else { throw ReaderError.message("The saved position changed. Close and reopen the book to review it again.") }
        let backup = Bookmark(id: backupID, name: "Earlier saved place · \(expected.updated.formatted(date: .abbreviated, time: .shortened))",
                              position: expected.position, contentFingerprint: expected.contentFingerprint)
        _ = try addIfAbsent(backup, id: id, format: expected.format)
        try set(record, id: id)
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
            guard existing.contentFingerprint == bookmark.contentFingerprint else { return false }
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
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            if try saveAtomicIfEnabled() { return }
            try writeLegacy(JSONEncoder().encode(bookmarks), name: "bookmarks.json")
        }
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
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            if try saveAtomicIfEnabled() { return }
            try writeLegacy(JSONEncoder().encode(annotations), name: "annotations.json")
        }
    }
    var hasUnsyncedCloudChanges: Bool {
        guard let atomicStore else { return false }
        return atomicStore.hasUnmappedReadingData || atomicStore.outbox.values.contains(where: { $0.entry.pending || !$0.entry.conflicts.isEmpty || $0.pendingApplication == true })
    }
    var cloudReadingStore: CloudAtomicReadingStore? { atomicStore }

    func bindStandaloneCloudIdentity(localBookID: String, cloudBookID: CloudStandaloneBookID) throws {
        guard let atomicStore else { throw ReaderError.message("Cloud reading data is not available for this library.") }
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try validateAtomicScope()
            try atomicStore.bind(localBookID: localBookID, cloudBookID: cloudBookID)
        }
    }

    func invalidateCloudVerification() {
        editionVerificationGenerations.removeAll()
        atomicStore?.invalidateAllEditionVerifications()
    }

    /// Suspend certification before hashing so edits made while the check is
    /// in flight remain local but cannot be attached to a stale edition.
    func verifyStandaloneEdition(_ entry: LocalBookEntry, library: LocalLibrary, scope: CloudReadingScope) async throws -> String {
        guard let atomicStore else { throw ReaderError.message("Cloud reading data is not available for this library.") }
        let generation = UUID(); editionVerificationGenerations[entry.id] = generation
        atomicStore.invalidateEditionVerification(localBookID: entry.id)
        let edition = try await library.verifyCloudEdition(for: entry, scope: scope)
        guard self.atomicStore === atomicStore, editionVerificationGenerations[entry.id] == generation, !Task.isCancelled else { throw CancellationError() }
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try validateAtomicScope()
            try atomicStore.registerVerifiedStandaloneEdition(edition)
        }
        return edition.fingerprint
    }

    /// Verify the same extracted content used by the reader. The owner supplies
    /// a session fence so a server/account or opened-book change during hashing
    /// cannot certify a different Jellyfin book.
    func verifyJellyfinEdition(_ prepared: PreparedBook, source: CloudReadingSource,
                               stillCurrent: @MainActor () -> Bool) async throws -> String {
        let id = prepared.book.id, generation = UUID()
        editionVerificationGenerations[id] = generation
        atomicStore?.invalidateEditionVerification(localBookID: id)
        guard source.isJellyfin, let atomicStore, atomicStore.localToCloudBookIDs == nil,
              atomicStore.scope.sourceKey == (try source.key()), !id.isEmpty,
              prepared.book.format != .unsupported, stillCurrent() else {
            throw ReaderError.message("The Jellyfin book or account is unavailable for recovery.")
        }
        func validateContents() throws {
            let directory = prepared.directory.standardizedFileURL.resolvingSymlinksInPath()
            guard directory == prepared.directory.standardizedFileURL else { throw ReaderError.message("The book content cannot be verified.") }
            let (document, images) = try BookCache.contents(directory, format: prepared.book.format)
            guard document.standardizedFileURL == prepared.document.standardizedFileURL,
                  images.map(\.standardizedFileURL) == prepared.images.map(\.standardizedFileURL) else {
                throw ReaderError.message("The book content changed during verification.")
            }
            for file in prepared.book.format == .cbz ? images : [document] {
                let path = file.standardizedFileURL
                guard path.path.hasPrefix(directory.path + "/"), path.resolvingSymlinksInPath() == path else {
                    throw ReaderError.message("The book content cannot be verified.")
                }
            }
        }
        func fingerprint() async throws -> String {
            if prepared.book.format == .epub {
                return try await BookFingerprint.epub(directory: prepared.directory, hasDurableSidecars: prepared.hasDurableSidecars)
            }
            return try await BookFingerprint.compute(files: prepared.book.format == .pdf ? [prepared.document] : prepared.images)
        }
        try validateContents()
        let digest = try await fingerprint()
        try validateContents()
        guard self.atomicStore === atomicStore, editionVerificationGenerations[id] == generation,
              stillCurrent(), !Task.isCancelled else { throw CancellationError() }
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try validateAtomicScope()
            try atomicStore.setVerifiedEdition(localBookID: id, fingerprint: digest)
        }
        return digest
    }

    /// Synchronization may stage records independently, but only this entry
    /// point refreshes the reader-visible snapshot after verified application.
    func applyObservedCloudVersion(_ key: CloudReadingKey, book: Book, verifiedEditionFingerprint: String,
                                   expectedRevision: UUID, confirmLegacyEdition: Bool = false,
                                   confirmedJellyfinDeletionTicks: Int64? = nil) throws {
        guard let atomicStore else { throw ReaderError.message("Cloud reading data is not available for this library.") }
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try validateAtomicScope()
            try atomicStore.applyObserved(key, book: book, verifiedEditionFingerprint: verifiedEditionFingerprint,
                                          expectedRevision: expectedRevision, confirmLegacyEdition: confirmLegacyEdition,
                                          confirmedJellyfinDeletionTicks: confirmedJellyfinDeletionTicks)
            records = atomicStore.records; bookmarks = atomicStore.bookmarks; annotations = atomicStore.annotations
        }
    }

    func certifyReviewedLocalVersion(_ key: CloudReadingKey, book: Book, expectedRevision: UUID,
                                     verifiedEditionFingerprint: String) throws {
        guard let atomicStore else { throw ReaderError.message("Cloud reading data is not available for this library.") }
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try validateAtomicScope()
            try atomicStore.certifyReviewedLocalVersion(key, book: book, expectedRevision: expectedRevision,
                                                        verifiedEditionFingerprint: verifiedEditionFingerprint)
        }
    }

    func resolveCloudConflict(_ key: CloudReadingKey, book: Book, verifiedEditionFingerprint: String,
                              expectedLocalRevision: UUID, remoteRevision: UUID,
                              choice: CloudAtomicReadingStore.ConflictChoice, confirmUnverifiedEdition: Bool = false,
                              confirmedJellyfinDeletionTicks: Int64? = nil) throws {
        guard let atomicStore else { throw ReaderError.message("Cloud reading data is not available for this library.") }
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            try validateAtomicScope()
            try atomicStore.resolveConflict(key, book: book, verifiedEditionFingerprint: verifiedEditionFingerprint,
                                            expectedLocalRevision: expectedLocalRevision, remoteRevision: remoteRevision, choice: choice,
                                            confirmUnverifiedEdition: confirmUnverifiedEdition,
                                            confirmedJellyfinDeletionTicks: confirmedJellyfinDeletionTicks)
            records = atomicStore.records; bookmarks = atomicStore.bookmarks; annotations = atomicStore.annotations
        }
    }
    func delete(allowUnsynced: Bool = false) throws {
        try PrivateBookFiles.withExclusiveLock(at: namespaceLock) {
            if atomicStore != nil { try validateAtomicScope() }
            guard atomicStore != nil || !FileManager.default.fileExists(atPath: root.appendingPathComponent("atomic-reading-scope.json").path) else {
                throw ReaderError.message("Reading data was migrated in another session. Reopen it before removing it.")
            }
            for name in ["positions.json", "bookmarks.json", "annotations.json", "book-formatting.json"] {
                try validateLegacyFile(name)
            }
            guard allowUnsynced || !hasUnsyncedCloudChanges else { throw ReaderError.message("Reading data has unsynced changes and cannot be removed without confirmation.") }
            if let atomicStore { try atomicStore.deleteLocal() }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            atomicStore = nil; editionVerificationGenerations = [:]; records = [:]; bookmarks = [:]; annotations = [:]
            originalFormatting = [:]; legacyFiles = [:]
        }
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
