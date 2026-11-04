import Foundation
import CryptoKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// The imported library is deliberately independent of any server account.
struct LocalBookEntry: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let format: BookFormat
    var author: String? = nil
    var hasCover: Bool? = nil
    var metadataVersion: Int? = nil
    var contentDigest: String? = nil
    var folderSource: Bool? = nil
    var cloudIdentities: [String: CloudStandaloneBookID]? = nil

    var book: Book {
        Book(id: id, title: title, author: author ?? "", summary: "", format: format,
             isFolder: false, imageTag: hasCover == true ? "local" : nil, ticks: 0)
    }
}

/// A folder entry represents a user's source file, never ownership of that file.
struct FolderBookEntry: Codable, Identifiable, Sendable {
    let id: String
    var relativePath: String
    var resourceIdentity: Data?
    var format: BookFormat
    var available: Bool
    var contentDigest: String? = nil
    var title: String { URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent }
}

private struct FolderRecord: Codable {
    var id: UUID
    var name: String
    var lastPath: String
    var identity: Data?
    var bookmark: Data
    var books: [FolderBookEntry]
}
private struct FolderIndex: Codable {
    var active: UUID?
    var folders: [FolderRecord] = []
}

/// Security-scoped source access is short lived. The catalog and reader copies
/// live in app storage; scanning never writes, renames, or removes source files.
actor LocalFolderLibrary {
    private let indexURL: URL
    private var index: FolderIndex

    init(namespace: String = LocalLibrary.namespace) throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(directory)
        indexURL = directory.appendingPathComponent("folders.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            index = try JSONDecoder().decode(FolderIndex.self, from: Data(contentsOf: indexURL))
        } else { index = FolderIndex() }
    }
    var folderName: String? { activeRecord?.name }
    var books: [FolderBookEntry] { (activeRecord?.books ?? []).sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending } }
    private var activeRecord: FolderRecord? { index.folders.first { $0.id == index.active } }
    private func save(_ replacement: FolderIndex) throws {
        try PrivateBookFiles.write(JSONEncoder().encode(replacement), to: indexURL)
        index = replacement
    }
    private static func identity(_ url: URL) -> Data? {
        guard let value = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
    }
    private static func makeBookmark(_ url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    private static func resolve(_ data: Data) throws -> (URL, Bool) {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return (url, stale)
    }
    func select(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ReaderError.message("Choose a readable folder.") }
        let bookmark = try Self.makeBookmark(url)
        let identity = Self.identity(url)
        let path = url.standardizedFileURL.path
        var updated = index
        if let position = updated.folders.firstIndex(where: { ($0.identity != nil && $0.identity == identity) || $0.lastPath == path }) {
            updated.folders[position].bookmark = bookmark
            updated.folders[position].identity = identity
            updated.folders[position].lastPath = path
            updated.folders[position].name = url.lastPathComponent
            updated.active = updated.folders[position].id
        } else {
            let folder = FolderRecord(id: UUID(), name: url.lastPathComponent, lastPath: path, identity: identity, bookmark: bookmark, books: [])
            updated.folders.append(folder); updated.active = folder.id
        }
        try save(updated)
    }
    func refresh() throws -> [FolderBookEntry] {
        guard let active = index.active, let position = index.folders.firstIndex(where: { $0.id == active }) else { return [] }
        var record = index.folders[position]
        let (folder, stale) = try Self.resolve(record.bookmark)
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        if stale { record.bookmark = try Self.makeBookmark(folder) }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path + "/"
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw ReaderError.message("The selected folder is unavailable. Select it again to reconnect.") }
        var found: [(String, BookFormat, Data?)] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
            if info.isSymbolicLink == true { continue }
            guard info.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw ReaderError.message("The selected folder could not be indexed safely.") }
            let format = BookFormat(path: path)
            guard format != .unsupported else { continue }
            found.append((String(path.dropFirst(prefix.count)), format, Self.identity(file)))
            guard found.count <= 20_000 else { throw ReaderError.message("This folder contains too many books to index.") }
        }
        if failure != nil { throw ReaderError.message("The selected folder is unavailable. Select it again to reconnect.") }
        let present = Set(found.map { $0.0 })
        var books = record.books.map { entry in var entry = entry; entry.available = false; return entry }
        var claimed = Set<String>()
        for (path, format, identity) in found {
            let exact = books.firstIndex { $0.relativePath == path && !claimed.contains($0.id) }
            let moved = identity.flatMap { value in books.firstIndex { $0.resourceIdentity == value && !present.contains($0.relativePath) && !claimed.contains($0.id) } }
            if let index = exact ?? moved {
                books[index].relativePath = path; books[index].format = format; books[index].resourceIdentity = identity; books[index].available = true
                claimed.insert(books[index].id)
            } else {
                let entry = FolderBookEntry(id: "folder-\(UUID().uuidString)", relativePath: path, resourceIdentity: identity, format: format, available: true)
                books.append(entry); claimed.insert(entry.id)
            }
        }
        record.books = books
        var updated = index; updated.folders[position] = record; try save(updated)
        return self.books
    }
    func importBook(_ entry: FolderBookEntry, into library: LocalLibrary) async throws -> LocalBookEntry {
        guard let active = index.active, let position = index.folders.firstIndex(where: { $0.id == active }),
              let current = index.folders[position].books.first(where: { $0.id == entry.id && $0.available }) else {
            throw ReaderError.message("This source file is unavailable. Reconnect the folder and refresh.")
        }
        let (folder, _) = try Self.resolve(index.folders[position].bookmark)
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(current.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ReaderError.message("This source file is unavailable. Reconnect the folder and refresh.")
        }
        let imported = try await library.importFile(file, folderBookID: current.id, expectedDigest: current.contentDigest)
        guard index.active == active, let currentPosition = index.folders.firstIndex(where: { $0.id == active }),
              let bookPosition = index.folders[currentPosition].books.firstIndex(where: { $0.id == current.id }) else { throw CancellationError() }
        var updated = index; updated.folders[currentPosition].books[bookPosition].contentDigest = imported.contentDigest
        try save(updated)
        return imported
    }
}

actor LocalLibrary {
    static let namespace = "on-my-device"
    private let content: DurableBookStore
    private let indexURL: URL
    private let coverDirectory: URL
    private let archiveScript: URL?
    private var entries: [LocalBookEntry]

    init(namespace: String = LocalLibrary.namespace, archiveScript: URL? = nil) throws {
        content = try DurableBookStore(namespace: namespace)
        self.archiveScript = archiveScript
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyfinBooksLocalLibrary/\(stableKey(namespace))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(directory)
        indexURL = directory.appendingPathComponent("catalog.json")
        coverDirectory = directory.appendingPathComponent("covers", isDirectory: true)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            entries = try JSONDecoder().decode([LocalBookEntry].self, from: Data(contentsOf: indexURL))
        } else { entries = [] }
    }

    func catalog() async -> [LocalBookEntry] {
        // Older catalogs gain metadata on demand; failed or missing copies stay visible.
        for entry in entries where entry.metadataVersion == nil {
            guard let directory = await content.saved(entry.book),
                  let index = entries.firstIndex(where: { $0.id == entry.id && $0.metadataVersion == nil }) else { continue }
            let enriched = enrich(entry, directory: directory)
            let previous = entries[index]
            entries[index] = enriched
            do { try PrivateBookFiles.write(JSONEncoder().encode(entries), to: indexURL) }
            catch { entries[index] = previous }
        }
        return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Copy while the provider's security scope is active. The chosen file is never moved or removed.
    func importFile(_ source: URL, folderBookID: String? = nil, expectedDigest: String? = nil) async throws -> LocalBookEntry {
        let format = BookFormat(path: source.lastPathComponent)
        guard format != .unsupported else { throw ReaderError.message("Choose an EPUB, PDF, or CBZ book.") }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 512 * 1024 * 1024 else { throw ReaderError.message("Books must be smaller than 512 MB.") }
                try FileManager.default.copyItem(at: url, to: temporary)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? (copyError as NSError?) { throw error }
        try PrivateBookFiles.protect(temporary)
        try Task.checkCancellation()
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw ReaderError.message("Books must be smaller than 512 MB.") }
        if format == .pdf {
            guard let document = PDFDocument(url: temporary), !document.isLocked, document.pageCount > 0 else {
                throw ReaderError.message("This PDF is damaged or locked and cannot be imported.")
            }
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedDigest, digest != expectedDigest {
            throw ReaderError.message("This source file has changed. The earlier device copy and its reading data are still available; import the new edition separately.")
        }
        let id = folderBookID ?? "local-\(format.rawValue)-\(digest)"
        let existing = entries.first(where: { $0.id == id })
        if let existing {
            guard folderBookID == nil || existing.contentDigest == digest else {
                throw ReaderError.message("This source file has changed. The earlier device copy and its reading data are still available; import the new edition separately.")
            }
            if await content.saved(existing.book) != nil {
                try await content.restoreOriginal(temporary, book: existing.book, expectedDigest: digest)
                return existing
            }
        }
        let name = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = LocalBookEntry(id: id, title: name.isEmpty ? "Untitled Book" : name, format: format)
        if folderBookID != nil { entry.contentDigest = digest; entry.folderSource = true }
        entry.cloudIdentities = existing?.cloudIdentities
        let directory = try await content.install(temporary, book: entry.book, retainOriginal: true, archiveScript: archiveScript)
        try Task.checkCancellation()
        entry = enrich(entry, directory: directory)
        let previous = entries
        entries.removeAll { $0.id == id }
        entries.append(entry)
        do { try PrivateBookFiles.write(JSONEncoder().encode(entries), to: indexURL) }
        catch { entries = previous; throw error }
        return entry
    }

    func directory(for entry: LocalBookEntry) async -> URL? {
        guard let directory = await content.saved(entry.book) else { return nil }
        if entry.format == .pdf {
            guard let document = PDFDocument(url: directory.appendingPathComponent("book.pdf")),
                  !document.isLocked, document.pageCount > 0 else { return nil }
        }
        return directory
    }

    /// Existing imports without retained source archives remain readable; nil
    /// means the user must explicitly reselect the matching original to sync it.
    func originalFile(for entry: LocalBookEntry) async -> URL? {
        await content.originalFile(for: entry.book)
    }

    /// Adoption is explicit: content equality alone must never merge distinct books.
    /// The existing local identity and reading data are left untouched.
    func adoptCloudIdentity(_ metadata: CloudBookMetadata, for entry: LocalBookEntry,
                            scope: CloudReadingScope) throws {
        try metadata.validate(scope: scope)
        let identity = metadata.bookID
        guard scope.isValid, let index = entries.firstIndex(where: { $0.id == entry.id }),
              entries[index].format == metadata.format,
              let digest = knownDigest(entries[index]), digest == metadata.sha256 else {
            throw ReaderError.message("The cloud book does not match this local edition.")
        }
        guard !entries.contains(where: { $0.id != entry.id && $0.cloudIdentities?[scope.cloudAccountKey] == identity }),
              entries[index].cloudIdentities?[scope.cloudAccountKey].map({ $0 == identity }) ?? true else {
            throw ReaderError.message("This cloud identity is already assigned to another book.")
        }
        let previous = entries
        if entries[index].cloudIdentities == nil { entries[index].cloudIdentities = [:] }
        entries[index].cloudIdentities?[scope.cloudAccountKey] = identity
        do { try PrivateBookFiles.write(JSONEncoder().encode(entries), to: indexURL) }
        catch { entries = previous; throw error }
    }

    /// Checks the copied bytes against the catalog edition before publishing a
    /// staging revision, including when the retained file changed after lookup.
    func stageCloudBook(_ entry: LocalBookEntry, scope: CloudReadingScope,
                        stager: CloudBookStager) async throws -> StagedCloudBook {
        guard stager.scope == scope, let current = entries.first(where: { $0.id == entry.id }),
              let identity = current.cloudIdentities?[scope.cloudAccountKey],
              let digest = knownDigest(current), let original = await content.originalFile(for: current.book) else {
            throw ReaderError.message("The original book or its cloud identity is unavailable. Reselect the matching original.")
        }
        return try await stager.stage(source: original, bookID: identity, title: current.title,
                                      format: current.format, expectedSHA256: digest, archiveScript: archiveScript)
    }

    private func knownDigest(_ entry: LocalBookEntry) -> String? {
        let prefix = "local-\(entry.format.rawValue)-"
        let digest = entry.contentDigest ?? (entry.id.hasPrefix(prefix) ? String(entry.id.dropFirst(prefix.count)) : "")
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return digest
    }

    func remove(_ entry: LocalBookEntry) async throws {
        try await content.remove(entry.book)
        let previous = entries
        entries.removeAll { $0.id == entry.id }
        do { try PrivateBookFiles.write(JSONEncoder().encode(entries), to: indexURL) }
        catch { entries = previous; throw error }
        try? FileManager.default.removeItem(at: coverURL(entry.id))
    }

    func cover(for id: String) -> Data? {
        guard entries.contains(where: { $0.id == id && $0.hasCover == true }) else { return nil }
        return try? Data(contentsOf: coverURL(id), options: .mappedIfSafe)
    }

    func storageBytes() async throws -> Int64 {
        let books = try await content.storageBytes()
        guard FileManager.default.fileExists(atPath: coverDirectory.path) else { return books }
        let covers = try ManagedStorageUsage.bytes(in: coverDirectory)
        let (sum, overflow) = books.addingReportingOverflow(covers)
        return overflow ? Int64.max : sum
    }

    private func coverURL(_ id: String) -> URL { coverDirectory.appendingPathComponent(stableKey(id)).appendingPathExtension("png") }

    private func enrich(_ entry: LocalBookEntry, directory: URL) -> LocalBookEntry {
        let metadata = LocalBookMetadata.read(format: entry.format, directory: directory)
        var result = LocalBookEntry(id: entry.id, title: metadata.title ?? entry.title, format: entry.format,
                                    author: metadata.author, hasCover: false, metadataVersion: 1,
                                    contentDigest: entry.contentDigest, folderSource: entry.folderSource,
                                    cloudIdentities: entry.cloudIdentities)
        if let image = metadata.cover {
            do {
                try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
                try PrivateBookFiles.protect(coverDirectory)
                try PrivateBookFiles.write(image, to: coverURL(entry.id))
                result.hasCover = true
            } catch { result.hasCover = false }
        }
        return result
    }
}

struct LocalBookMetadata {
    var title: String?
    var author: String?
    var cover: Data?

    static func read(format: BookFormat, directory: URL) -> Self {
        guard let content = try? BookCache.contents(directory, format: format) else { return Self() }
        switch format {
        case .pdf:
            guard let document = PDFDocument(url: content.0), !document.isLocked else { return Self() }
            let title = clean(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            let author = clean(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
            return Self(title: title?.lowercased() == "untitled" ? nil : title,
                        author: author?.lowercased() == "anonymous" ? nil : author,
                        cover: document.page(at: 0).flatMap(pdfCover))
        case .cbz:
            return Self(cover: content.1.first.flatMap(imageCover))
        case .epub:
            guard let size = try? content.0.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 2 * 1024 * 1024, let data = try? Data(contentsOf: content.0),
                  let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
                  xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return Self() }
            let delegate = EPUBMetadataParser()
            let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse() else { return Self() }
            var cover: Data?
            if let href = delegate.coverHref, let url = safeResource(href, relativeTo: content.0, root: directory) {
                cover = imageCover(url)
            }
            return Self(title: clean(delegate.title), author: clean(delegate.author), cover: cover)
        case .unsupported: return Self()
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }

    private static func safeResource(_ href: String, relativeTo package: URL, root: URL) -> URL? {
        guard let components = URLComponents(string: href), components.scheme == nil, components.host == nil,
              components.query == nil, components.fragment == nil,
              let path = components.percentEncodedPath.removingPercentEncoding, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return nil }
        let candidate = package.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return candidate.path.hasPrefix(rootPath) ? candidate : nil
    }

    private static func imageCover(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary) else { return nil }
        return png(image)
    }

    private static func pdfCover(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let scale = min(600 / bounds.width, 600 / bounds.height)
        let width = max(1, Int((bounds.width * scale).rounded())), height = max(1, Int((bounds.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage().flatMap(png)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private final class EPUBMetadataParser: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var author: String?
    private var current: String?
    private var buffer = ""
    private var coverID: String?
    private var items: [(String, String, String)] = []
    var coverHref: String? {
        items.first(where: { $0.2.split(separator: " ").contains("cover-image") })?.1
            ?? items.first(where: { $0.0 == coverID })?.1
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if namespaceURI == "http://purl.org/dc/elements/1.1/", (elementName == "title" && title == nil || elementName == "creator" && author == nil) {
            current = elementName; buffer = ""
        }
        if elementName == "meta", attributes["name"] == "cover" { coverID = attributes["content"] }
        if elementName == "item", let id = attributes["id"], let href = attributes["href"] { items.append((id, href, attributes["properties"] ?? "")) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil, buffer.count < 4096 { buffer += string.prefix(4096 - buffer.count) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard current == elementName else { return }
        if elementName == "title" { title = buffer } else { author = buffer }
        current = nil; buffer = ""
    }
}
