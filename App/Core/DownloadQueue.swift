import Foundation

enum OfflineDownloadState: String, Codable, Sendable {
    case queued, downloading, available, failed, cancelled
}

/// Reserve an identity before a remove suspends so an open, save, or local
/// import cannot race with the file operation. Tokens stop an old completion
/// from releasing a new session's reservation.
@MainActor final class OfflineOperationReservations {
    enum Scope: Hashable { case local, server }
    private struct Key: Hashable { var scope: Scope; var id: String }
    private var removals: [Key: UUID] = [:]
    private var localImport: UUID?

    func beginRemoval(_ id: String, scope: Scope) -> UUID? {
        let key = Key(scope: scope, id: id)
        guard removals[key] == nil, scope != .local || localImport == nil else { return nil }
        let token = UUID(); removals[key] = token; return token
    }
    func endRemoval(_ id: String, scope: Scope, token: UUID) {
        let key = Key(scope: scope, id: id)
        if removals[key] == token { removals.removeValue(forKey: key) }
    }
    func permitsAccess(_ id: String, scope: Scope) -> Bool { removals[Key(scope: scope, id: id)] == nil }
    func beginLocalImport() -> UUID? {
        guard localImport == nil, !removals.keys.contains(where: { $0.scope == .local }) else { return nil }
        let token = UUID(); localImport = token; return token
    }
    func endLocalImport(_ token: UUID) { if localImport == token { localImport = nil } }
    func clearServer() { removals = removals.filter { $0.key.scope != .server } }
}

/// Stop the remaining steps if the account changes while storage I/O suspends.
@MainActor func removeAccountDeviceCopy(stillCurrent: () -> Bool,
                                        removeSaved: () async throws -> Void,
                                        removeCached: () async throws -> Void,
                                        removeJournal: () throws -> Void) async throws -> Bool {
    guard stillCurrent() else { return false }
    try await removeSaved()
    guard stillCurrent() else { return false }
    try await removeCached()
    guard stillCurrent() else { return false }
    try removeJournal()
    return true
}

struct OfflineDownload: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let author: String
    let summary: String
    let format: BookFormat
    let imageTag: String?
    let ticks: Int64
    let libraryID: String?
    let libraryName: String?
    var state: OfflineDownloadState
    var progress: Double?
    var failure: String?

    init(book: Book) {
        id = book.id; title = book.title; author = book.author; summary = book.summary
        format = book.format; imageTag = book.imageTag; ticks = book.ticks
        libraryID = book.libraryID; libraryName = book.libraryName
        state = .queued; progress = nil; failure = nil
    }
    var book: Book {
        Book(id: id, title: title, author: author, summary: summary, format: format,
             isFolder: false, imageTag: imageTag, ticks: ticks, libraryID: libraryID, libraryName: libraryName)
    }
}

/// The journal describes work, never the existence of a complete book. A
/// validated DurableBookStore entry is the authority for available content.
@MainActor final class OfflineDownloadJournal {
    let root: URL
    private let file: URL
    private(set) var entries: [OfflineDownload]
    private var revision = 0

    init(namespace: String) throws {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyfinBooksDownloads/\(stableKey(namespace))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        file = root.appendingPathComponent("queue.json")
        if FileManager.default.fileExists(atPath: file.path) {
            entries = try JSONDecoder().decode([OfflineDownload].self, from: Data(contentsOf: file))
        } else { entries = [] }
        // A process restart cannot keep an in-flight task alive. Start it again
        // from the beginning; partial downloads were never published.
        var recovered = entries
        for index in recovered.indices where recovered[index].state == .downloading {
            recovered[index].state = .queued; recovered[index].progress = nil
        }
        if recovered.contains(where: { $0.state == .queued }) { try replace(recovered) }
    }

    private func replace(_ updated: [OfflineDownload]) throws {
        try PrivateBookFiles.write(JSONEncoder().encode(updated), to: file)
        entries = updated
        revision += 1
    }

    func enqueue(_ book: Book) throws {
        guard !book.isFolder, book.format != .unsupported else { throw ReaderError.message("This format cannot be saved offline.") }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.id == book.id }) {
            guard updated[index].state == .failed || updated[index].state == .cancelled else { return }
            updated[index] = OfflineDownload(book: book)
        } else { updated.append(OfflineDownload(book: book)) }
        try replace(updated)
    }

    func set(_ id: String, state: OfflineDownloadState, progress: Double? = nil, failure: String? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[index].state = state
        updated[index].progress = progress.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        updated[index].failure = failure
        try replace(updated)
    }

    func remove(_ id: String) throws {
        try replace(entries.filter { $0.id != id })
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        entries = []; revision += 1
    }

    /// Discard stale storage observations if an enqueue, cancellation, retry,
    /// completion, account switch, or newer refresh happened while awaiting I/O.
    func reconcileAvailable(isAvailable: (Book) async -> Bool, stillCurrent: () -> Bool) async throws {
        let snapshot = entries.filter { $0.state == .available }
        for item in snapshot {
            let observedRevision = revision
            let exists = await isAvailable(item.book)
            guard stillCurrent(), observedRevision == revision else { return }
            if !exists {
                try set(item.id, state: .failed, failure: "The saved copy is missing or damaged. Remove it and retry.")
            }
        }
    }
}
