import Foundation
import CryptoKit

func stableKey(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

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
    private(set) var records: [String: ReadingRecord] = [:]
    private(set) var bookmarks: [String: [Bookmark]] = [:]
    init(namespace: String) throws {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JellyfinBooks/\(stableKey(namespace))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        for name in ["positions.json", "bookmarks.json"] {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try PrivateBookFiles.protect(file) }
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("positions.json")) { records = try JSONDecoder().decode([String: ReadingRecord].self, from: data) }
        if let data = try? Data(contentsOf: root.appendingPathComponent("bookmarks.json")) { bookmarks = try JSONDecoder().decode([String: [Bookmark]].self, from: data) }
    }
    private func savePositions() throws { try PrivateBookFiles.write(JSONEncoder().encode(records), to: root.appendingPathComponent("positions.json")) }
    func set(_ record: ReadingRecord, id: String) throws { records[id] = record; try savePositions() }
    func movePosition(from oldID: String, to book: Book, record: ReadingRecord) throws {
        guard oldID != book.id, records[oldID] != nil else { throw ReaderError.message("The saved position is no longer available to transfer.") }
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
    func add(_ bookmark: Bookmark, id: String) throws { bookmarks[id, default: []].append(bookmark); try saveBookmarks() }
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
    func removeBookmark(_ bookmark: Bookmark, id: String) throws { bookmarks[id]?.removeAll { $0.id == bookmark.id }; try saveBookmarks() }
    private func saveBookmarks() throws { try PrivateBookFiles.write(JSONEncoder().encode(bookmarks), to: root.appendingPathComponent("bookmarks.json")) }
    func delete() throws {
        records = [:]; bookmarks = [:]
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
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where directory.lastPathComponent != protected { try FileManager.default.removeItem(at: directory) }
    }
}
private final class ContainerParser: NSObject, XMLParserDelegate {
    var path: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) { if elementName == "rootfile", path == nil { path = attributeDict["full-path"] } }
}
