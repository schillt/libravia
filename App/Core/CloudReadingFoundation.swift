import Foundation
import CloudKit

/// Only stable source identifiers are accepted. Credentials, server URLs and
/// book bytes have no representation in these reading-data types.
enum CloudReadingSource: Codable {
    case jellyfin(serverID: String, userID: String)
    case imported

    func key() throws -> String {
        if case .jellyfin(let serverID, let userID) = self, serverID.isEmpty || userID.isEmpty {
            throw ReaderError.message("A Jellyfin server and user identity are required.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return stableKey(String(decoding: try encoder.encode(self), as: UTF8.self))
    }
}

struct CloudReadingScope: Codable, Equatable {
    let cloudAccountKey: String
    let sourceKey: String
    var isValid: Bool {
        func hash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        return hash(cloudAccountKey) && hash(sourceKey)
    }

    init(cloudUserRecordName: String, source: CloudReadingSource) throws {
        guard !cloudUserRecordName.isEmpty else { throw ReaderError.message("An iCloud account is required.") }
        cloudAccountKey = stableKey(cloudUserRecordName)
        sourceKey = try source.key()
    }
}

enum CloudReadingKind: String, Codable, Hashable { case position, bookmark, annotation }

struct CloudReadingKey: Codable, Hashable {
    let sourceKey: String
    let bookKey: String
    let kind: CloudReadingKind
    let itemID: UUID?

    init(scope: CloudReadingScope, bookID: String, kind: CloudReadingKind, itemID: UUID? = nil) throws {
        guard !bookID.isEmpty, (kind == .position) == (itemID == nil) else {
            throw ReaderError.message("The reading-data identity is invalid.")
        }
        sourceKey = scope.sourceKey; bookKey = stableKey(bookID); self.kind = kind; self.itemID = itemID
    }
    var recordName: String {
        stableKey("\(sourceKey)|\(bookKey)|\(kind.rawValue)|\(itemID?.uuidString ?? "position")")
    }
}

struct CloudPrecisePosition: Codable {
    let position: ReadingPosition
    /// A CFI may be used only when the edition and Jellyfin position still match.
    let contentFingerprint: String?
    let acknowledgedServerTicks: Int64?
}

enum CloudReadingPayload: Codable {
    case position(CloudPrecisePosition)
    case bookmark(Bookmark)
    case annotation(ReadingAnnotation)

    var kind: CloudReadingKind {
        switch self { case .position: .position; case .bookmark: .bookmark; case .annotation: .annotation }
    }
    var itemID: UUID? {
        switch self { case .position: nil; case .bookmark(let value): value.id; case .annotation(let value): value.id }
    }
}

/// `payload == nil` is a durable tombstone, not a physical CloudKit deletion.
struct CloudReadingVersion: Codable {
    let revision: UUID
    let payload: CloudReadingPayload?
}

struct CloudReadingEntry: Codable {
    let key: CloudReadingKey
    var current: CloudReadingVersion
    var baseRevision: UUID?
    var pending: Bool
    var pendingRevisions: [UUID]
    var conflicts: [CloudReadingVersion]
}

/// A single atomic file keeps the local value and pending state together.
/// It is intentionally not wired to ReadingStore until a migration can make
/// the reading data and outbox one transaction.
@MainActor final class CloudReadingJournal {
    private struct Archive: Codable { let version: Int; let scope: CloudReadingScope; var entries: [String: CloudReadingEntry] }
    let root: URL
    private let file: URL
    let scope: CloudReadingScope
    private(set) var entries: [String: CloudReadingEntry]

    init(scope: CloudReadingScope, baseDirectory: URL? = nil) throws {
        guard scope.isValid else { throw ReaderError.message("The iCloud reading scope is invalid.") }
        self.scope = scope
        root = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("LibraViaCloudReading/\(scope.cloudAccountKey)/\(scope.sourceKey)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        file = root.appendingPathComponent("reading-journal.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard archive.version == 1, archive.scope == scope,
                  archive.entries.allSatisfy({ $0.key == $0.value.key.recordName && $0.value.key.sourceKey == scope.sourceKey }) else {
                throw ReaderError.message("The iCloud reading journal belongs to a different account or source.")
            }
            entries = archive.entries
        } else { entries = [:] }
    }

    private func save(_ updated: [String: CloudReadingEntry]) throws {
        let archive = Archive(version: 1, scope: scope, entries: updated)
        try PrivateBookFiles.write(JSONEncoder().encode(archive), to: file)
        entries = updated
    }
    private func validate(_ key: CloudReadingKey, _ payload: CloudReadingPayload?) throws {
        guard key.sourceKey == scope.sourceKey, (key.kind == .position) == (key.itemID == nil),
              payload == nil || (payload?.kind == key.kind && payload?.itemID == key.itemID) else {
            throw ReaderError.message("The reading change belongs to a different source or item.")
        }
        if let payload, try JSONEncoder().encode(payload).count > 512 * 1024 {
            throw ReaderError.message("This reading change is too large to sync.")
        }
    }

    func edit(_ key: CloudReadingKey, payload: CloudReadingPayload?) throws {
        try validate(key, payload)
        var updated = entries
        var entry = updated[key.recordName] ?? CloudReadingEntry(key: key, current: CloudReadingVersion(revision: UUID(), payload: nil), baseRevision: nil, pending: false, pendingRevisions: [], conflicts: [])
        guard entry.conflicts.isEmpty else { throw ReaderError.message("Resolve the existing reading-data conflict first.") }
        entry.current = CloudReadingVersion(revision: UUID(), payload: payload)
        entry.pending = true
        entry.pendingRevisions.append(entry.current.revision)
        updated[key.recordName] = entry
        try save(updated)
    }

    /// Acknowledging an older in-flight edit cannot discard a newer edit.
    func acknowledge(_ key: CloudReadingKey, revision: UUID) throws {
        try validate(key, nil)
        guard var entry = entries[key.recordName], entry.pending,
              let index = entry.pendingRevisions.firstIndex(of: revision) else { return }
        var updated = entries
        entry.baseRevision = revision
        entry.pendingRevisions.removeFirst(index + 1)
        if entry.current.revision == revision { entry.pending = false }
        updated[key.recordName] = entry
        try save(updated)
    }

    func observe(_ key: CloudReadingKey, remote: CloudReadingVersion) throws {
        try validate(key, remote.payload)
        var updated = entries
        guard var entry = updated[key.recordName] else {
            updated[key.recordName] = CloudReadingEntry(key: key, current: remote, baseRevision: remote.revision, pending: false, pendingRevisions: [], conflicts: [])
            try save(updated); return
        }
        if entry.current.revision == remote.revision {
            // Same revision with different contents is corrupt, not an acknowledgement.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(entry.current.payload) == encoder.encode(remote.payload) else {
                throw ReaderError.message("The iCloud reading record is inconsistent.")
            }
            entry.pending = false; entry.pendingRevisions = []; entry.baseRevision = remote.revision
        } else if entry.pending || !entry.conflicts.isEmpty {
            if remote.revision != entry.baseRevision && !entry.conflicts.contains(where: { $0.revision == remote.revision }) { entry.conflicts.append(remote) }
        } else {
            entry.current = remote; entry.baseRevision = remote.revision
        }
        updated[key.recordName] = entry
        try save(updated)
    }

    /// Resolution is explicit; both sides remain stored until this method is called.
    func resolve(_ key: CloudReadingKey, against revision: UUID, payload: CloudReadingPayload?) throws {
        try validate(key, payload)
        guard var entry = entries[key.recordName], entry.conflicts.contains(where: { $0.revision == revision }) else {
            throw ReaderError.message("The selected reading-data conflict is no longer available.")
        }
        var updated = entries
        entry.baseRevision = revision; entry.current = CloudReadingVersion(revision: UUID(), payload: payload)
        entry.pending = true; entry.pendingRevisions = [entry.current.revision]
        entry.conflicts.removeAll { $0.revision == revision }
        updated[key.recordName] = entry
        try save(updated)
    }
}

/// Constructs encrypted private-database records only; it does not perform
/// network operations or enable sync. The caller must fence account changes.
enum CloudReadingRecordCodec {
    private struct Wire: Codable { let key: CloudReadingKey; let bookID: String; let value: CloudReadingVersion }
    static let recordType = "ReadingDataV1"
    static func record(entry: CloudReadingEntry, bookID: String, zoneID: CKRecordZone.ID, existing: CKRecord? = nil) throws -> CKRecord {
        guard !bookID.isEmpty, stableKey(bookID) == entry.key.bookKey else { throw ReaderError.message("The iCloud book identity is invalid.") }
        let id = CKRecord.ID(recordName: entry.key.recordName, zoneID: zoneID)
        guard existing == nil || existing?.recordID == id else { throw ReaderError.message("The iCloud record identity is invalid.") }
        let record = existing ?? CKRecord(recordType: recordType, recordID: id)
        guard record.recordType == recordType else { throw ReaderError.message("The iCloud record type is invalid.") }
        record["sourceKey"] = entry.key.sourceKey as CKRecordValue
        record.encryptedValues["readingData"] = try JSONEncoder().encode(Wire(key: entry.key, bookID: bookID, value: entry.current)) as CKRecordValue
        return record
    }
    static func decode(_ record: CKRecord, expectedSource: String) throws -> (CloudReadingKey, String, CloudReadingVersion) {
        guard record.recordType == recordType, let data = record.encryptedValues["readingData"] as? Data else {
            throw ReaderError.message("The iCloud reading record is invalid.")
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.key.sourceKey == expectedSource, !wire.bookID.isEmpty, stableKey(wire.bookID) == wire.key.bookKey,
              record.recordID.recordName == wire.key.recordName,
              wire.value.payload == nil || (wire.value.payload?.kind == wire.key.kind && wire.value.payload?.itemID == wire.key.itemID) else {
            throw ReaderError.message("The iCloud reading record belongs to a different source or item.")
        }
        return (wire.key, wire.bookID, wire.value)
    }
}

/// Holds the complete reading snapshot and its outbox in one atomic file.
/// Legacy files remain untouched. Adoption requires a separate migration of
/// every ReadingStore caller; this type is not yet used by the application.
@MainActor final class CloudAtomicReadingStore {
    struct OutboxItem: Codable { let bookID: String; var entry: CloudReadingEntry }
    private struct Archive: Codable {
        let version: Int
        let scope: CloudReadingScope
        var revision: UUID
        var records: [String: ReadingRecord]
        var bookmarks: [String: [Bookmark]]
        var annotations: [String: [ReadingAnnotation]]
        var outbox: [String: OutboxItem]
    }
    private var archive: Archive
    let file: URL
    var records: [String: ReadingRecord] { archive.records }
    var bookmarks: [String: [Bookmark]] { archive.bookmarks }
    var annotations: [String: [ReadingAnnotation]] { archive.annotations }
    var outbox: [String: OutboxItem] { archive.outbox }

    init(scope: CloudReadingScope, legacyRecords: [String: ReadingRecord], legacyBookmarks: [String: [Bookmark]],
         legacyAnnotations: [String: [ReadingAnnotation]], baseDirectory: URL? = nil, requireExisting: Bool = false) throws {
        guard scope.isValid else { throw ReaderError.message("The iCloud reading scope is invalid.") }
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("LibraViaAtomicReading/\(scope.cloudAccountKey)/\(scope.sourceKey)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        file = root.appendingPathComponent("reading-state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard saved.version == 1, saved.scope == scope, saved.outbox.allSatisfy({ name, item in
                name == item.entry.key.recordName && item.entry.key.sourceKey == scope.sourceKey &&
                !item.bookID.isEmpty && stableKey(item.bookID) == item.entry.key.bookKey
            }) else { throw ReaderError.message("The saved reading state belongs to a different account or source.") }
            archive = saved
        } else {
            guard !requireExisting else { throw ReaderError.message("The migrated reading data is unavailable. Recovery is required.") }
            var initial = Archive(version: 1, scope: scope, revision: UUID(), records: legacyRecords, bookmarks: legacyBookmarks, annotations: legacyAnnotations, outbox: [:])
            for (bookID, record) in legacyRecords {
                try Self.enqueue(&initial, bookID: bookID, kind: .position, itemID: nil,
                                 payload: .position(CloudPrecisePosition(position: record.position, contentFingerprint: nil, acknowledgedServerTicks: record.acknowledgedTicks)))
            }
            for (bookID, items) in legacyBookmarks {
                guard Set(items.map(\.id)).count == items.count else { throw ReaderError.message("Duplicate bookmark identities require recovery before syncing.") }
                for item in items { try Self.enqueue(&initial, bookID: bookID, kind: .bookmark, itemID: item.id, payload: .bookmark(item)) }
            }
            for (bookID, items) in legacyAnnotations {
                guard Set(items.map(\.id)).count == items.count else { throw ReaderError.message("Duplicate annotation identities require recovery before syncing.") }
                for item in items { try Self.enqueue(&initial, bookID: bookID, kind: .annotation, itemID: item.id, payload: .annotation(item)) }
            }
            try PrivateBookFiles.write(JSONEncoder().encode(initial), to: file)
            archive = initial
        }
    }

    func matchesLegacy(records: [String: ReadingRecord], bookmarks: [String: [Bookmark]], annotations: [String: [ReadingAnnotation]]) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive.records) == encoder.encode(records) &&
            encoder.encode(archive.bookmarks) == encoder.encode(bookmarks) && encoder.encode(archive.annotations) == encoder.encode(annotations)
    }

    func deleteLocal() throws {
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func enqueue(_ archive: inout Archive, bookID: String, kind: CloudReadingKind, itemID: UUID?, payload: CloudReadingPayload?) throws {
        let key = try CloudReadingKey(scope: archive.scope, bookID: bookID, kind: kind, itemID: itemID)
        guard payload == nil || (payload?.kind == kind && payload?.itemID == itemID) else { throw ReaderError.message("The reading-data identity is invalid.") }
        var entry = archive.outbox[key.recordName]?.entry ?? CloudReadingEntry(key: key, current: CloudReadingVersion(revision: UUID(), payload: nil), baseRevision: nil, pending: false, pendingRevisions: [], conflicts: [])
        entry.current = CloudReadingVersion(revision: UUID(), payload: payload)
        entry.pending = true; entry.pendingRevisions.append(entry.current.revision)
        archive.outbox[key.recordName] = OutboxItem(bookID: bookID, entry: entry)
    }

    private func commit(_ updated: Archive) throws {
        let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
        guard disk.scope == archive.scope, disk.revision == archive.revision else {
            throw ReaderError.message("Reading data changed in another session. Reopen it before editing.")
        }
        var next = updated; next.revision = UUID()
        try PrivateBookFiles.write(JSONEncoder().encode(next), to: file)
        archive = next
    }
    /// Writes the whole local snapshot and all corresponding changes together.
    func replace(records: [String: ReadingRecord], bookmarks: [String: [Bookmark]], annotations: [String: [ReadingAnnotation]]) throws {
        var next = archive
        for id in Set(archive.records.keys).union(records.keys) {
            let before = archive.records[id], after = records[id]
            if before?.position != after?.position {
                let payload = after.map { CloudReadingPayload.position(CloudPrecisePosition(position: $0.position, contentFingerprint: nil, acknowledgedServerTicks: $0.acknowledgedTicks)) }
                try Self.enqueue(&next, bookID: id, kind: .position, itemID: nil, payload: payload)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for id in Set(archive.bookmarks.keys).union(bookmarks.keys) {
            let old = archive.bookmarks[id] ?? [], new = bookmarks[id] ?? []
            guard Set(new.map(\.id)).count == new.count else { throw ReaderError.message("Duplicate bookmark identities require recovery before syncing.") }
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }), newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            for itemID in Set(oldByID.keys).union(newByID.keys) {
                if try encoder.encode(oldByID[itemID]) != encoder.encode(newByID[itemID]) {
                    try Self.enqueue(&next, bookID: id, kind: .bookmark, itemID: itemID, payload: newByID[itemID].map(CloudReadingPayload.bookmark))
                }
            }
        }
        for id in Set(archive.annotations.keys).union(annotations.keys) {
            let old = archive.annotations[id] ?? [], new = annotations[id] ?? []
            guard Set(new.map(\.id)).count == new.count else { throw ReaderError.message("Duplicate annotation identities require recovery before syncing.") }
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }), newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            for itemID in Set(oldByID.keys).union(newByID.keys) where oldByID[itemID] != newByID[itemID] {
                try Self.enqueue(&next, bookID: id, kind: .annotation, itemID: itemID, payload: newByID[itemID].map(CloudReadingPayload.annotation))
            }
        }
        next.records = records; next.bookmarks = bookmarks; next.annotations = annotations
        try commit(next)
    }
    func set(_ record: ReadingRecord, bookID: String) throws {
        var next = archive; next.records[bookID] = record
        try Self.enqueue(&next, bookID: bookID, kind: .position, itemID: nil,
                         payload: .position(CloudPrecisePosition(position: record.position, contentFingerprint: nil, acknowledgedServerTicks: record.acknowledgedTicks)))
        try commit(next)
    }
    func set(_ bookmark: Bookmark, bookID: String) throws {
        var next = archive; var items = next.bookmarks[bookID] ?? []
        items.removeAll { $0.id == bookmark.id }; items.append(bookmark); next.bookmarks[bookID] = items
        try Self.enqueue(&next, bookID: bookID, kind: .bookmark, itemID: bookmark.id, payload: .bookmark(bookmark)); try commit(next)
    }
    func remove(_ bookmark: Bookmark, bookID: String) throws {
        var next = archive; next.bookmarks[bookID]?.removeAll { $0.id == bookmark.id }
        try Self.enqueue(&next, bookID: bookID, kind: .bookmark, itemID: bookmark.id, payload: nil); try commit(next)
    }
    func set(_ annotation: ReadingAnnotation, bookID: String) throws {
        var next = archive; var items = next.annotations[bookID] ?? []
        items.removeAll { $0.id == annotation.id }; items.append(annotation); next.annotations[bookID] = items
        try Self.enqueue(&next, bookID: bookID, kind: .annotation, itemID: annotation.id, payload: .annotation(annotation)); try commit(next)
    }
    func remove(_ annotation: ReadingAnnotation, bookID: String) throws {
        var next = archive; next.annotations[bookID]?.removeAll { $0.id == annotation.id }
        try Self.enqueue(&next, bookID: bookID, kind: .annotation, itemID: annotation.id, payload: nil); try commit(next)
    }
}

/// An adapter must perform conditional writes against the expected revision;
/// returning a conflict must never replace the remote value. This abstraction
/// has no production CloudKit implementation and makes no account guarantees.
@MainActor protocol CloudReadingTransport {
    func fetch(_ key: CloudReadingKey) async throws -> CloudReadingVersion?
    func upload(_ entry: CloudReadingEntry, expected: UUID?) async throws -> CloudReadingUploadResult
}

enum CloudReadingUploadResult {
    case saved
    case conflict(CloudReadingVersion)
}

/// Drives individual journal entries. The fence guards local acceptance of
/// responses; a real CloudKit adapter still needs an independently verified
/// guarantee that an in-flight write cannot reach a different iCloud account.
@MainActor final class CloudReadingSyncCoordinator {
    enum Status: Equatable { case idle, syncing, conflict, accountChanged, failed(String) }
    private let journal: CloudReadingJournal
    private let transport: any CloudReadingTransport
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private(set) var status: Status = .idle
    private var running = false

    init(journal: CloudReadingJournal, transport: any CloudReadingTransport,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) {
        self.journal = journal; self.transport = transport; self.accountIsCurrent = accountIsCurrent
    }

    func sync(_ key: CloudReadingKey) async {
        guard !running else { return }
        running = true; status = .syncing
        defer { running = false }
        do {
            guard key.sourceKey == journal.scope.sourceKey else {
                throw ReaderError.message("The reading change belongs to a different source.")
            }
            guard try await accountIsCurrent() else { status = .accountChanged; return }
            let remote = try await transport.fetch(key)
            guard try await accountIsCurrent() else { status = .accountChanged; return }
            if let remote { try journal.observe(key, remote: remote) }
            guard let entry = journal.entries[key.recordName] else { status = .idle; return }
            guard entry.conflicts.isEmpty else { status = .conflict; return }
            guard entry.pending else { status = .idle; return }
            // A previously observed remote record disappearing is ambiguous:
            // preserve the local edit until deletion recovery is resolved.
            if remote == nil, entry.baseRevision != nil {
                throw ReaderError.message("The iCloud reading record is missing; recovery is required.")
            }
            guard try await accountIsCurrent() else { status = .accountChanged; return }
            let result = try await transport.upload(entry, expected: entry.baseRevision)
            guard try await accountIsCurrent() else { status = .accountChanged; return }
            switch result {
            case .saved:
                try journal.acknowledge(key, revision: entry.current.revision)
                status = .idle
            case .conflict(let version):
                try journal.observe(key, remote: version)
                status = .conflict
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

/// On notification, invalidate all issued tokens before any future operation.
/// A transport must also recheck the actual iCloud identity immediately before
/// and after network work; this monitor alone is not a cross-account guarantee.
@MainActor final class CloudReadingAccountMonitor {
    struct Token: Equatable { let accountKey: String; let generation: UUID }
    private let container: CKContainer
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private(set) var token: Token?

    init(container: CKContainer = .default()) {
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func invalidate() { generation = UUID(); token = nil }
    func refresh() async throws -> Token? {
        invalidate()
        let expected = generation
        guard try await container.accountStatus() == .available else { return nil }
        let user = try await container.userRecordID()
        guard generation == expected else { throw CancellationError() }
        let result = Token(accountKey: stableKey(user.recordName), generation: expected)
        token = result; return result
    }
    func accepts(_ candidate: Token) -> Bool { token == candidate && generation == candidate.generation }
    func validate(_ candidate: Token) async throws -> Bool {
        guard accepts(candidate), try await container.accountStatus() == .available else { invalidate(); return false }
        let user = try await container.userRecordID()
        guard accepts(candidate), stableKey(user.recordName) == candidate.accountKey else { invalidate(); return false }
        return true
    }
    var privateDatabase: CKDatabase { container.privateCloudDatabase }
}
