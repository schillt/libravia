import Foundation
import CloudKit

/// Only stable source identifiers are accepted. Credentials, server URLs and
/// book bytes have no representation in these reading-data types.
enum CloudReadingSource: Codable {
    /// Retained for decoding and isolating records from early development.
    case jellyfin(serverID: String, userID: String)
    /// Hash of the normalized endpoint, server ID, and user ID used locally.
    case jellyfinAccount(namespaceKey: String)
    case imported

    static func scopedJellyfin(_ account: Account) throws -> Self {
        guard !account.serverID.isEmpty, !account.userID.isEmpty else {
            throw ReaderError.message("A Jellyfin server and user identity are required.")
        }
        return .jellyfinAccount(namespaceKey: stableKey(account.namespace))
    }

    var isJellyfin: Bool {
        switch self { case .jellyfin, .jellyfinAccount: true; case .imported: false }
    }

    func key() throws -> String {
        if case .jellyfin(let serverID, let userID) = self, serverID.isEmpty || userID.isEmpty {
            throw ReaderError.message("A Jellyfin server and user identity are required.")
        }
        if case .jellyfinAccount(let namespaceKey) = self,
           !(namespaceKey.count == 64 && namespaceKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) {
            throw ReaderError.message("The Jellyfin account identity is invalid.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return stableKey(String(decoding: try encoder.encode(self), as: UTF8.self))
    }
}

struct CloudReadingScope: Codable, Equatable, Sendable {
    let cloudAccountKey: String
    let sourceKey: String
    var isValid: Bool {
        func hash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        return hash(cloudAccountKey) && hash(sourceKey)
    }

    init(cloudUserRecordName: String, source: CloudReadingSource) throws {
        guard !cloudUserRecordName.isEmpty else { throw ReaderError.message("An iCloud account is required.") }
        try self.init(accountKey: stableKey(cloudUserRecordName), source: source)
    }

    /// Accept only the already-hashed identity issued by the account monitor.
    init(accountKey: String, source: CloudReadingSource) throws {
        cloudAccountKey = accountKey
        sourceKey = try source.key()
        guard isValid else { throw ReaderError.message("The iCloud account identity is invalid.") }
    }

    /// Each source gets its own private zone; the private database separates
    /// iCloud accounts, and no source URL or credentials enter the zone name.
    var recoveryZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "LibraVia-\(sourceKey)", ownerName: CKCurrentUserDefaultName)
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
    /// Fingerprint of the edition to which this version belongs. Legacy
    /// records can omit it, but cannot be applied automatically without it.
    var editionFingerprint: String? = nil

    var hasValidEditionFingerprint: Bool {
        guard let value = editionFingerprint else { return true }
        return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
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
        guard remote.hasValidEditionFingerprint else { throw ReaderError.message("The iCloud edition identity is invalid.") }
        var updated = entries
        guard var entry = updated[key.recordName] else {
            updated[key.recordName] = CloudReadingEntry(key: key, current: remote, baseRevision: remote.revision, pending: false, pendingRevisions: [], conflicts: [])
            try save(updated); return
        }
        if entry.current.revision == remote.revision {
            // Same revision with different contents is corrupt, not an acknowledgement.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(entry.current) == encoder.encode(remote) else {
                throw ReaderError.message("The iCloud reading record is inconsistent.")
            }
            entry.pending = false; entry.pendingRevisions = []; entry.baseRevision = remote.revision
        } else if entry.pending || !entry.conflicts.isEmpty {
            if let existing = entry.conflicts.first(where: { $0.revision == remote.revision }) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(existing) == encoder.encode(remote) else {
                    throw ReaderError.message("The iCloud reading record is inconsistent.")
                }
            } else if remote.revision != entry.baseRevision { entry.conflicts.append(remote) }
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
        guard !bookID.isEmpty, stableKey(bookID) == entry.key.bookKey, entry.current.hasValidEditionFingerprint else { throw ReaderError.message("The iCloud book identity is invalid.") }
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
              wire.value.hasValidEditionFingerprint,
              wire.value.payload == nil || (wire.value.payload?.kind == wire.key.kind && wire.value.payload?.itemID == wire.key.itemID) else {
            throw ReaderError.message("The iCloud reading record belongs to a different source or item.")
        }
        return (wire.key, wire.bookID, wire.value)
    }
}

/// Holds the complete reading snapshot and its outbox in one atomic file.
/// Legacy files remain untouched. Experimental recovery uses this store; live
/// CloudKit and cross-device behavior remain subject to acceptance testing.
@MainActor final class CloudAtomicReadingStore {
    struct OutboxItem: Codable {
        let bookID: String
        var entry: CloudReadingEntry
        // nil is the backward-compatible value for archives written before
        // remote reconciliation existed.
        var pendingApplication: Bool? = nil
        // Revisions from the previous zone are alternatives, never write bases.
        var legacyConflictRevisions: [UUID]? = nil
    }
    /// A migration must account for every queued revision and alternative,
    /// including tombstones and incoming versions not yet applied locally.
    struct LegacyJellyfinMigrationSnapshot {
        let sourceScope: CloudReadingScope
        let targetScope: CloudReadingScope
        let sourceRevision: UUID
        let records: [String: ReadingRecord]
        let bookmarks: [String: [Bookmark]]
        let annotations: [String: [ReadingAnnotation]]
        let outbox: [String: OutboxItem]

        /// Build a reviewable translation without changing either archive.
        func makePlan() throws -> LegacyJellyfinMigrationPlan {
            var local: [CloudReadingKey: (String, CloudReadingPayload)] = [:]
            func add(_ book: String, _ payload: CloudReadingPayload) throws {
                let key = try CloudReadingKey(scope: sourceScope, bookID: book, kind: payload.kind, itemID: payload.itemID)
                guard local[key] == nil else { throw ReaderError.message("Duplicate reading identities require recovery before migration.") }
                local[key] = (book, payload)
            }
            for (book, record) in records {
                try add(book, .position(CloudPrecisePosition(position: record.position, contentFingerprint: record.contentFingerprint, acknowledgedServerTicks: record.acknowledgedTicks)))
            }
            for (book, items) in bookmarks { for item in items { try add(book, .bookmark(item)) } }
            for (book, items) in annotations { for item in items { try add(book, .annotation(item)) } }
            var translated: [String: OutboxItem] = [:]
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            for (name, item) in outbox {
                let old = item.entry
                let expected = try CloudReadingKey(scope: sourceScope, bookID: item.bookID, kind: old.key.kind, itemID: old.key.itemID)
                guard old.key == expected, name == expected.recordName,
                      old.current.payload == nil || (old.current.payload?.kind == expected.kind && old.current.payload?.itemID == expected.itemID),
                      old.conflicts.allSatisfy({ $0.payload == nil || ($0.payload?.kind == expected.kind && $0.payload?.itemID == expected.itemID) }) else {
                    throw ReaderError.message("The earlier reading changes have inconsistent identities.")
                }
                let payload = local.removeValue(forKey: expected)?.1
                let same = try encoder.encode(payload) == encoder.encode(old.current.payload)
                var alternatives = old.conflicts
                if item.pendingApplication == true || !same { alternatives.insert(old.current, at: 0) }
                guard Set(alternatives.map(\.revision)).count == alternatives.count else {
                    throw ReaderError.message("The earlier reading changes have duplicate revisions.")
                }
                let key = try CloudReadingKey(scope: targetScope, bookID: item.bookID, kind: expected.kind, itemID: expected.itemID)
                let current = CloudReadingVersion(revision: UUID(), payload: payload, editionFingerprint: same ? old.current.editionFingerprint : nil)
                let entry = CloudReadingEntry(key: key, current: current, baseRevision: nil, pending: true, pendingRevisions: [current.revision], conflicts: alternatives)
                guard translated[key.recordName] == nil else { throw ReaderError.message("Reading identities collide during migration.") }
                translated[key.recordName] = OutboxItem(bookID: item.bookID, entry: entry, legacyConflictRevisions: alternatives.map(\.revision))
            }
            for (_, value) in local {
                let (book, payload) = value
                let key = try CloudReadingKey(scope: targetScope, bookID: book, kind: payload.kind, itemID: payload.itemID)
                let current = CloudReadingVersion(revision: UUID(), payload: payload)
                let entry = CloudReadingEntry(key: key, current: current, baseRevision: nil, pending: true, pendingRevisions: [current.revision], conflicts: [])
                guard translated[key.recordName] == nil else { throw ReaderError.message("Reading identities collide during migration.") }
                translated[key.recordName] = OutboxItem(bookID: book, entry: entry)
            }
            return LegacyJellyfinMigrationPlan(snapshot: self, outbox: translated)
        }
    }
    struct LegacyJellyfinMigrationPlan {
        let snapshot: LegacyJellyfinMigrationSnapshot
        let outbox: [String: OutboxItem]
    }
    struct JellyfinAccountSwitchPlan {
        let source: LegacyJellyfinMigrationSnapshot
        let targetRevision: UUID?
        let outbox: [String: OutboxItem]
    }
    struct StandaloneAccountSwitchPlan {
        let source: LegacyJellyfinMigrationSnapshot
        let targetRevision: UUID?
        let bindings: [String: String]
        let unmappedBookIDs: Set<String>
        let unmappedOutbox: [String: OutboxItem]
        let outbox: [String: OutboxItem]
        let sourceOnlyItems: Int
    }
    private struct Archive: Codable {
        let version: Int
        let scope: CloudReadingScope
        var revision: UUID
        var records: [String: ReadingRecord]
        var bookmarks: [String: [Bookmark]]
        var annotations: [String: [ReadingAnnotation]]
        var outbox: [String: OutboxItem]
        // nil preserves the original source-item identity behavior. A non-nil
        // map uses explicitly assigned standalone identities, even when empty.
        var localToCloudBookIDs: [String: String]? = nil
        // Reading remains local and durable while identity assignment is pending.
        var unmappedBookIDs: Set<String>? = nil
        var unmappedOutbox: [String: OutboxItem]? = nil
        // A verified SHA-256 is attached only to edits made after verification;
        // older entries are never retroactively certified.
        var verifiedEditions: [String: String]? = nil
        var migrationOrigin: MigrationOrigin? = nil
        var accountSwitchOrigin: AccountSwitchOrigin? = nil
    }
    private struct MigrationOrigin: Codable {
        let source: CloudReadingScope
        let revision: UUID
        let initialTargetRevision: UUID
    }
    private struct AccountSwitchOrigin: Codable {
        let source: CloudReadingScope
        let sourceRevision: UUID
        let previousTargetRevision: UUID
        let initialTargetRevision: UUID
        let backupID: UUID
        var sourceOnlyItems: Int? = nil
    }
    private var archive: Archive
    // Do not reuse a previous session's verification without hashing the book
    // again; local files or server editions may have changed while closed.
    private var activeEditions: [String: String] = [:]
    let file: URL
    private let lockFile: URL
    var records: [String: ReadingRecord] { archive.records }
    var bookmarks: [String: [Bookmark]] { archive.bookmarks }
    var annotations: [String: [ReadingAnnotation]] { archive.annotations }
    var outbox: [String: OutboxItem] { archive.outbox }
    var scope: CloudReadingScope { archive.scope }
    var localToCloudBookIDs: [String: String]? { archive.localToCloudBookIDs }
    var hasUnmappedReadingData: Bool { !(archive.unmappedBookIDs ?? []).isEmpty }

    /// Prepare a cross-account transfer for review. Both journals remain
    /// untouched; a later commit must fence both recorded archive revisions.
    func jellyfinAccountSwitchPlan(account: Account, targetScope: CloudReadingScope,
                                   target: CloudAtomicReadingStore?) throws -> JellyfinAccountSwitchPlan {
        let sourceKey = try CloudReadingSource.scopedJellyfin(account).key()
        guard archive.scope.isValid, targetScope.isValid, archive.scope.sourceKey == sourceKey,
              targetScope.sourceKey == sourceKey, archive.scope.cloudAccountKey != targetScope.cloudAccountKey,
              archive.localToCloudBookIDs == nil, !hasUnmappedReadingData,
              target == nil || (target?.scope == targetScope && target?.localToCloudBookIDs == nil && target?.hasUnmappedReadingData == false) else {
            throw ReaderError.message("The recovery accounts or Jellyfin library do not match.")
        }
        try requireCurrentRevision()
        try target?.requireCurrentRevision()
        let snapshot = LegacyJellyfinMigrationSnapshot(sourceScope: archive.scope, targetScope: targetScope,
            sourceRevision: archive.revision, records: archive.records, bookmarks: archive.bookmarks,
            annotations: archive.annotations, outbox: archive.outbox)
        let translated = try Self.mergeAccountSwitchDestination(try snapshot.makePlan().outbox,
                                                               target: target?.outbox ?? [:], scope: targetScope)
        return JellyfinAccountSwitchPlan(source: snapshot, targetRevision: target?.archive.revision, outbox: translated)
    }

    private static func mergeAccountSwitchDestination(_ source: [String: OutboxItem], target: [String: OutboxItem],
                                                      scope targetScope: CloudReadingScope) throws -> [String: OutboxItem] {
        var translated = source
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (name, existing) in target {
            guard Self.validOutboxItem(existing, name: name, scope: targetScope) else {
                throw ReaderError.message("The destination reading state needs recovery before switching accounts.")
            }
            // Absence in the source journal is not a deletion. Preserve the
            // destination's actual version, pending state, and alternatives;
            // stage it for edition-checked application before uploading it.
            if translated[name] == nil {
                var incoming = existing
                incoming.pendingApplication = existing.pendingApplication == true || existing.entry.pending ||
                    !existing.entry.conflicts.isEmpty || existing.entry.current.payload != nil
                translated[name] = incoming
                continue
            }
            guard var item = translated[name], item.bookID == existing.bookID, item.entry.key == existing.entry.key else {
                throw ReaderError.message("Reading identities collide across recovery accounts.")
            }
            item.entry.baseRevision = existing.entry.baseRevision
            var legacy = Set(item.legacyConflictRevisions ?? [])
            func append(_ version: CloudReadingVersion, foreignBase: Bool) throws {
                if version.revision == item.entry.current.revision {
                    guard try encoder.encode(version) == encoder.encode(item.entry.current) else {
                        throw ReaderError.message("Reading revisions collide across recovery accounts.")
                    }
                    return
                }
                if let previous = item.entry.conflicts.first(where: { $0.revision == version.revision }) {
                    guard try encoder.encode(previous) == encoder.encode(version) else {
                        throw ReaderError.message("Reading revisions collide across recovery accounts.")
                    }
                } else { item.entry.conflicts.append(version) }
                if foreignBase { legacy.insert(version.revision) }
            }
            let currentMatches = try encoder.encode(existing.entry.current.payload) == encoder.encode(item.entry.current.payload) &&
                existing.entry.current.editionFingerprint == item.entry.current.editionFingerprint
            if !currentMatches || existing.pendingApplication == true {
                // A pending destination version is local to that journal and
                // cannot be used as a CloudKit conditional-write revision.
                try append(existing.entry.current, foreignBase: existing.entry.pending)
            }
            for version in existing.entry.conflicts {
                try append(version, foreignBase: (existing.legacyConflictRevisions ?? []).contains(version.revision))
            }
            item.legacyConflictRevisions = Array(legacy).sorted { $0.uuidString < $1.uuidString }
            translated[name] = item
        }
        return translated
    }

    /// Map only catalog-confirmed local identities between accounts. Cloud
    /// items without a local binding remain in the original account's journal.
    func standaloneAccountSwitchPlan(targetScope: CloudReadingScope, target: CloudAtomicReadingStore?,
                                     catalogBindings: [String: String]) throws -> StandaloneAccountSwitchPlan {
        let imported = try CloudReadingSource.imported.key()
        guard scope.isValid, targetScope.isValid, scope.sourceKey == imported, targetScope.sourceKey == imported,
              scope.cloudAccountKey != targetScope.cloudAccountKey, let sourceBindings = archive.localToCloudBookIDs,
              target == nil || (target?.scope == targetScope && target?.localToCloudBookIDs != nil) else {
            throw ReaderError.message("The standalone recovery accounts need review before switching.")
        }
        try Self.validateBindings(catalogBindings, scope: targetScope)
        try requireCurrentRevision(); try target?.requireCurrentRevision()
        let targetBindings = target?.localToCloudBookIDs ?? [:]
        guard catalogBindings.allSatisfy({ targetBindings[$0.key] == nil || targetBindings[$0.key] == $0.value }) else {
            throw ReaderError.message("The destination book identities changed. Review them before switching.")
        }
        let bindings = targetBindings.merging(catalogBindings) { old, _ in old }
        try Self.validateBindings(bindings, scope: targetScope)
        let reverse = Dictionary(uniqueKeysWithValues: sourceBindings.map { ($0.value, $0.key) })
        var normalized: [String: OutboxItem] = [:]
        var sourceOnly = 0
        func add(_ item: OutboxItem, localID: String) throws {
            let key = try CloudReadingKey(scope: scope, bookID: localID, kind: item.entry.key.kind, itemID: item.entry.key.itemID)
            let entry = CloudReadingEntry(key: key, current: item.entry.current, baseRevision: item.entry.baseRevision,
                                          pending: item.entry.pending, pendingRevisions: item.entry.pendingRevisions,
                                          conflicts: item.entry.conflicts)
            guard normalized[key.recordName] == nil else { throw ReaderError.message("Reading identities collide across accounts.") }
            normalized[key.recordName] = OutboxItem(bookID: localID, entry: entry, pendingApplication: item.pendingApplication,
                                                     legacyConflictRevisions: item.legacyConflictRevisions)
        }
        for item in archive.outbox.values {
            guard let local = reverse[item.bookID] else { sourceOnly += 1; continue }
            try add(item, localID: local)
        }
        for item in (archive.unmappedOutbox ?? [:]).values { try add(item, localID: item.bookID) }
        let snapshot = LegacyJellyfinMigrationSnapshot(sourceScope: scope, targetScope: targetScope,
            sourceRevision: archive.revision, records: archive.records, bookmarks: archive.bookmarks,
            annotations: archive.annotations, outbox: normalized)
        let localPlan = try snapshot.makePlan().outbox
        var mapped: [String: OutboxItem] = [:], unmapped: [String: OutboxItem] = [:]
        var missing = Set<String>()
        for item in localPlan.values {
            let cloudID = bindings[item.bookID]
            let bookID = cloudID ?? item.bookID
            let key = try CloudReadingKey(scope: targetScope, bookID: bookID, kind: item.entry.key.kind, itemID: item.entry.key.itemID)
            let entry = CloudReadingEntry(key: key, current: item.entry.current, baseRevision: nil, pending: true,
                                          pendingRevisions: item.entry.pendingRevisions, conflicts: item.entry.conflicts)
            let translated = OutboxItem(bookID: bookID, entry: entry, pendingApplication: false,
                                        legacyConflictRevisions: item.legacyConflictRevisions)
            if cloudID == nil {
                missing.insert(item.bookID); unmapped[key.recordName] = translated
            } else { mapped[key.recordName] = translated }
        }
        var targetBound: [String: OutboxItem] = [:], targetUnmapped: [String: OutboxItem] = [:]
        for localID in target?.archive.unmappedBookIDs ?? [] where bindings[localID] == nil { missing.insert(localID) }
        for item in (target?.archive.unmappedOutbox ?? [:]).values {
            guard let cloudID = bindings[item.bookID] else {
                missing.insert(item.bookID); targetUnmapped[item.entry.key.recordName] = item
                continue
            }
            let key = try CloudReadingKey(scope: targetScope, bookID: cloudID, kind: item.entry.key.kind, itemID: item.entry.key.itemID)
            let entry = CloudReadingEntry(key: key, current: item.entry.current, baseRevision: nil, pending: item.entry.pending,
                                          pendingRevisions: item.entry.pendingRevisions, conflicts: item.entry.conflicts)
            targetBound[key.recordName] = OutboxItem(bookID: cloudID, entry: entry, pendingApplication: item.pendingApplication,
                                                     legacyConflictRevisions: item.legacyConflictRevisions)
        }
        mapped = try Self.mergeAccountSwitchDestination(mapped, target: targetBound, scope: targetScope)
        unmapped = try Self.mergeAccountSwitchDestination(unmapped, target: targetUnmapped, scope: targetScope)
        let merged = try Self.mergeAccountSwitchDestination(mapped, target: target?.outbox ?? [:], scope: targetScope)
        return StandaloneAccountSwitchPlan(source: snapshot, targetRevision: target?.archive.revision, bindings: bindings,
                                           unmappedBookIDs: missing, unmappedOutbox: unmapped, outbox: merged,
                                           sourceOnlyItems: sourceOnly)
    }

    /// Caller holds the reading namespace lock. Keep both journal locks until
    /// the marker switches; the previous destination archive is retained.
    func installJellyfinAccountSwitch(_ plan: JellyfinAccountSwitchPlan, target: CloudAtomicReadingStore,
                                       switchMarker: () throws -> Void) throws {
        try installAccountSwitch(source: plan.source, target: target, targetRevision: plan.targetRevision,
                                 outbox: plan.outbox, bindings: nil, unmappedBookIDs: [], unmappedOutbox: [:],
                                 sourceOnlyItems: 0, switchMarker: switchMarker)
    }

    func installStandaloneAccountSwitch(_ plan: StandaloneAccountSwitchPlan, target: CloudAtomicReadingStore,
                                        allowSourceOnlyItems: Bool = false, switchMarker: () throws -> Void) throws {
        guard plan.sourceOnlyItems == 0 || allowSourceOnlyItems else {
            throw ReaderError.message("Some reading changes exist only in the earlier account and need review before switching.")
        }
        try Self.validateBindings(plan.bindings, scope: target.scope)
        guard plan.unmappedBookIDs.allSatisfy({ !$0.isEmpty && plan.bindings[$0] == nil }),
              plan.unmappedOutbox.allSatisfy({ name, item in
                  plan.unmappedBookIDs.contains(item.bookID) && Self.validOutboxItem(item, name: name, scope: target.scope) &&
                  item.entry.pending && item.entry.baseRevision == nil &&
                  Set(item.entry.conflicts.map(\.revision)) == Set(item.legacyConflictRevisions ?? [])
              }) else { throw ReaderError.message("Unmapped reading changes need review before switching.") }
        try installAccountSwitch(source: plan.source, target: target, targetRevision: plan.targetRevision,
                                 outbox: plan.outbox, bindings: plan.bindings, unmappedBookIDs: plan.unmappedBookIDs,
                                 unmappedOutbox: plan.unmappedOutbox, sourceOnlyItems: plan.sourceOnlyItems, switchMarker: switchMarker)
    }

    private func installAccountSwitch(source: LegacyJellyfinMigrationSnapshot, target: CloudAtomicReadingStore,
                                      targetRevision: UUID?, outbox: [String: OutboxItem], bindings: [String: String]?,
                                      unmappedBookIDs: Set<String>, unmappedOutbox: [String: OutboxItem],
                                      sourceOnlyItems: Int, switchMarker: () throws -> Void) throws {
        guard source.sourceScope == archive.scope, source.sourceRevision == archive.revision,
              source.targetScope == target.scope, source.sourceScope.sourceKey == target.scope.sourceKey,
              source.sourceScope.cloudAccountKey != target.scope.cloudAccountKey,
              let expectedTarget = targetRevision, expectedTarget == target.archive.revision,
              outbox.allSatisfy({ Self.validOutboxItem($0.value, name: $0.key, scope: target.scope) }) else {
            throw ReaderError.message("The recovery state changed. Review the account switch again.")
        }
        try PrivateBookFiles.withExclusiveLock(at: lockFile) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == source.sourceScope, disk.revision == source.sourceRevision else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before switching.")
            }
            try PrivateBookFiles.withExclusiveLock(at: target.lockFile) {
                let previousData = try Data(contentsOf: target.file)
                let previous = try JSONDecoder().decode(Archive.self, from: previousData)
                guard previous.scope == target.scope, previous.revision == expectedTarget else {
                    throw ReaderError.message("The destination recovery data changed. Review it again.")
                }
                let backupID = UUID(), revision = UUID()
                let backups = target.file.deletingLastPathComponent().appendingPathComponent("account-switch-backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                try PrivateBookFiles.protect(backups)
                try PrivateBookFiles.write(previousData, to: backups.appendingPathComponent("\(backupID.uuidString).json"))
                var next = Archive(version: 1, scope: target.scope, revision: revision, records: source.records,
                                   bookmarks: source.bookmarks, annotations: source.annotations, outbox: outbox,
                                   localToCloudBookIDs: bindings, unmappedBookIDs: unmappedBookIDs.isEmpty ? nil : unmappedBookIDs,
                                   unmappedOutbox: unmappedOutbox.isEmpty ? nil : unmappedOutbox)
                next.accountSwitchOrigin = AccountSwitchOrigin(source: source.sourceScope, sourceRevision: source.sourceRevision,
                    previousTargetRevision: previous.revision, initialTargetRevision: revision, backupID: backupID,
                    sourceOnlyItems: sourceOnlyItems)
                try PrivateBookFiles.write(JSONEncoder().encode(next), to: target.file)
                target.archive = next
                try switchMarker()
            }
        }
    }

    /// Resume only an untouched prepared destination whose original archive
    /// and source revision still exist. A changed source must be merged again.
    func resumePreparedAccountSwitch(target: CloudAtomicReadingStore, allowSourceOnlyItems: Bool = false,
                                     switchMarker: () throws -> Void) throws -> Bool {
        guard scope.sourceKey == target.scope.sourceKey, scope.cloudAccountKey != target.scope.cloudAccountKey,
              let origin = target.archive.accountSwitchOrigin, origin.source == scope,
              origin.sourceRevision == archive.revision, origin.initialTargetRevision == target.archive.revision else { return false }
        guard (origin.sourceOnlyItems ?? 0) == 0 || allowSourceOnlyItems else {
            throw ReaderError.message("Some reading changes exist only in the earlier account and need review before switching.")
        }
        return try PrivateBookFiles.withExclusiveLock(at: lockFile) {
            let sourceDisk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard sourceDisk.scope == scope, sourceDisk.revision == archive.revision else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before switching.")
            }
            return try PrivateBookFiles.withExclusiveLock(at: target.lockFile) {
                let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: target.file))
                guard disk.scope == target.scope, disk.revision == origin.initialTargetRevision,
                      disk.accountSwitchOrigin?.backupID == origin.backupID,
                      disk.accountSwitchOrigin?.source == origin.source,
                      disk.accountSwitchOrigin?.sourceRevision == origin.sourceRevision,
                      disk.accountSwitchOrigin?.previousTargetRevision == origin.previousTargetRevision,
                      disk.accountSwitchOrigin?.initialTargetRevision == origin.initialTargetRevision,
                      disk.accountSwitchOrigin?.sourceOnlyItems == origin.sourceOnlyItems else {
                    throw ReaderError.message("The destination recovery data changed. Review it again.")
                }
                let backup = target.file.deletingLastPathComponent().appendingPathComponent("account-switch-backups/\(origin.backupID.uuidString).json")
                let previous = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: backup))
                guard previous.scope == target.scope, previous.revision == origin.previousTargetRevision else {
                    throw ReaderError.message("The destination recovery backup needs review.")
                }
                try switchMarker()
                return true
            }
        }
    }

    /// Read an identity-fenced source snapshot without changing either
    /// journal. A later migration commit must recheck sourceRevision.
    func legacyJellyfinMigrationSnapshot(account: Account, targetScope: CloudReadingScope) throws -> LegacyJellyfinMigrationSnapshot {
        let legacyKey = try CloudReadingSource.jellyfin(serverID: account.serverID, userID: account.userID).key()
        let scopedKey = try CloudReadingSource.scopedJellyfin(account).key()
        guard archive.scope.isValid, targetScope.isValid, archive.scope.cloudAccountKey == targetScope.cloudAccountKey,
              archive.scope.sourceKey == legacyKey, targetScope.sourceKey == scopedKey,
              archive.localToCloudBookIDs == nil, !hasUnmappedReadingData else {
            throw ReaderError.message("The earlier recovery data does not match this account and library.")
        }
        return try PrivateBookFiles.withExclusiveLock(at: lockFile) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == archive.scope, disk.revision == archive.revision else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before migration.")
            }
            return LegacyJellyfinMigrationSnapshot(sourceScope: disk.scope, targetScope: targetScope,
                sourceRevision: disk.revision, records: disk.records, bookmarks: disk.bookmarks,
                annotations: disk.annotations, outbox: disk.outbox)
        }
    }

    /// The namespace lock is held by the caller. Keep both journal locks until
    /// the marker is switched, so an old writer cannot race the final check.
    func installLegacyJellyfinMigration(_ plan: LegacyJellyfinMigrationPlan, baseDirectory: URL,
                                       switchMarker: () throws -> Void) throws {
        let snapshot = plan.snapshot
        guard snapshot.sourceScope == archive.scope, snapshot.sourceRevision == archive.revision,
              snapshot.sourceScope.cloudAccountKey == snapshot.targetScope.cloudAccountKey,
              snapshot.sourceScope.sourceKey != snapshot.targetScope.sourceKey else {
            throw ReaderError.message("The earlier recovery data changed. Review it again.")
        }
        let root = baseDirectory.appendingPathComponent("LibraViaAtomicReading/\(snapshot.targetScope.cloudAccountKey)/\(snapshot.targetScope.sourceKey)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        let destination = root.appendingPathComponent("reading-state.json")
        let targetLock = root.deletingLastPathComponent().appendingPathComponent("\(snapshot.targetScope.sourceKey).reading.lock")
        try PrivateBookFiles.withExclusiveLock(at: lockFile) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == snapshot.sourceScope, disk.revision == snapshot.sourceRevision else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before migration.")
            }
            try PrivateBookFiles.withExclusiveLock(at: targetLock) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    let existing = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: destination))
                    guard let origin = existing.migrationOrigin, existing.scope == snapshot.targetScope,
                          origin.source == snapshot.sourceScope, origin.revision == snapshot.sourceRevision,
                          existing.revision == origin.initialTargetRevision else {
                        throw ReaderError.message("Existing recovery data needs review before migration.")
                    }
                } else {
                    let revision = UUID()
                    let target = Archive(version: 1, scope: snapshot.targetScope, revision: revision,
                                         records: snapshot.records, bookmarks: snapshot.bookmarks, annotations: snapshot.annotations,
                                         outbox: plan.outbox, migrationOrigin: MigrationOrigin(source: snapshot.sourceScope,
                                             revision: snapshot.sourceRevision, initialTargetRevision: revision))
                    try PrivateBookFiles.write(JSONEncoder().encode(target), to: destination)
                }
                try switchMarker()
            }
        }
    }

    private static func validOutboxItem(_ item: OutboxItem, name: String, scope: CloudReadingScope) -> Bool {
        let entry = item.entry, key = entry.key
        func valid(_ version: CloudReadingVersion) -> Bool {
            version.hasValidEditionFingerprint &&
                (version.payload == nil || (version.payload?.kind == key.kind && version.payload?.itemID == key.itemID))
        }
        let conflicts = entry.conflicts.map(\.revision)
        let legacy = item.legacyConflictRevisions ?? []
        return name == key.recordName && key.sourceKey == scope.sourceKey && !item.bookID.isEmpty &&
            stableKey(item.bookID) == key.bookKey && ((key.kind == .position) == (key.itemID == nil)) &&
            valid(entry.current) && entry.conflicts.allSatisfy(valid) &&
            Set(conflicts).count == conflicts.count && !conflicts.contains(entry.current.revision) &&
            Set(legacy).count == legacy.count && Set(legacy).isSubset(of: Set(conflicts)) &&
            Set(entry.pendingRevisions).count == entry.pendingRevisions.count &&
            entry.pending == !entry.pendingRevisions.isEmpty &&
            (!entry.pending || entry.pendingRevisions.last == entry.current.revision)
    }

    init(scope: CloudReadingScope, legacyRecords: [String: ReadingRecord], legacyBookmarks: [String: [Bookmark]],
         legacyAnnotations: [String: [ReadingAnnotation]], baseDirectory: URL? = nil, requireExisting: Bool = false,
         localToCloudBookIDs: [String: String]? = nil) throws {
        guard scope.isValid else { throw ReaderError.message("The iCloud reading scope is invalid.") }
        if let localToCloudBookIDs { try Self.validateBindings(localToCloudBookIDs, scope: scope) }
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("LibraViaAtomicReading/\(scope.cloudAccountKey)/\(scope.sourceKey)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PrivateBookFiles.protect(root)
        let stateFile = root.appendingPathComponent("reading-state.json")
        file = stateFile
        let stateLock = root.deletingLastPathComponent().appendingPathComponent("\(scope.sourceKey).reading.lock")
        lockFile = stateLock
        archive = try PrivateBookFiles.withExclusiveLock(at: stateLock) {
          if FileManager.default.fileExists(atPath: stateFile.path) {
            let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: stateFile))
            if let bindings = saved.localToCloudBookIDs {
                try Self.validateBindings(bindings, scope: scope)
            }
            if let pending = saved.unmappedBookIDs, !pending.isEmpty {
                guard let bindings = saved.localToCloudBookIDs,
                      pending.allSatisfy({ !$0.isEmpty && bindings[$0] == nil }) else {
                    throw ReaderError.message("The pending book identities are inconsistent. Recovery is required.")
                }
            }
            if let items = saved.unmappedOutbox, !items.isEmpty {
                guard let pending = saved.unmappedBookIDs, saved.localToCloudBookIDs != nil,
                      items.allSatisfy({ name, item in
                          pending.contains(item.bookID) && Self.validOutboxItem(item, name: name, scope: scope) &&
                          item.entry.pending && item.entry.baseRevision == nil &&
                          Set(item.entry.conflicts.map(\.revision)) == Set(item.legacyConflictRevisions ?? [])
                      }) else { throw ReaderError.message("The pending reading changes are inconsistent. Recovery is required.") }
            }
            if let editions = saved.verifiedEditions {
                guard editions.allSatisfy({ !$0.key.isEmpty && Self.isFingerprint($0.value) }) else {
                    throw ReaderError.message("The saved book edition identities are invalid.")
                }
            }
            if let localToCloudBookIDs, saved.localToCloudBookIDs != localToCloudBookIDs {
                throw ReaderError.message("The saved book identities differ. Recovery is required before syncing.")
            }
            guard saved.version == 1, saved.scope == scope, saved.outbox.allSatisfy({ name, item in
                Self.validOutboxItem(item, name: name, scope: scope)
            }) else { throw ReaderError.message("The saved reading state is inconsistent or belongs to a different account. Recovery is required.") }
            return saved
          } else {
            guard !requireExisting else { throw ReaderError.message("The migrated reading data is unavailable. Recovery is required.") }
            var initial = Archive(version: 1, scope: scope, revision: UUID(), records: legacyRecords, bookmarks: legacyBookmarks, annotations: legacyAnnotations, outbox: [:], localToCloudBookIDs: localToCloudBookIDs)
            for (bookID, record) in legacyRecords {
                try Self.enqueue(&initial, bookID: bookID, kind: .position, itemID: nil,
                                 payload: .position(CloudPrecisePosition(position: record.position, contentFingerprint: record.contentFingerprint, acknowledgedServerTicks: record.acknowledgedTicks)))
            }
            for (bookID, items) in legacyBookmarks {
                guard Set(items.map(\.id)).count == items.count else { throw ReaderError.message("Duplicate bookmark identities require recovery before syncing.") }
                for item in items { try Self.enqueue(&initial, bookID: bookID, kind: .bookmark, itemID: item.id, payload: .bookmark(item)) }
            }
            for (bookID, items) in legacyAnnotations {
                guard Set(items.map(\.id)).count == items.count else { throw ReaderError.message("Duplicate annotation identities require recovery before syncing.") }
                for item in items { try Self.enqueue(&initial, bookID: bookID, kind: .annotation, itemID: item.id, payload: .annotation(item)) }
            }
            try PrivateBookFiles.write(JSONEncoder().encode(initial), to: stateFile)
            return initial
          }
        }
    }

    func matchesLegacy(records: [String: ReadingRecord], bookmarks: [String: [Bookmark]], annotations: [String: [ReadingAnnotation]]) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive.records) == encoder.encode(records) &&
            encoder.encode(archive.bookmarks) == encoder.encode(bookmarks) && encoder.encode(archive.annotations) == encoder.encode(annotations)
    }

    func deleteLocal() throws {
        try PrivateBookFiles.withExclusiveLock(at: lockFile) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == archive.scope, disk.revision == archive.revision else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before removing it.")
            }
            try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    private static func validateBindings(_ bindings: [String: String], scope: CloudReadingScope) throws {
        guard scope.sourceKey == (try CloudReadingSource.imported.key()),
              bindings.keys.allSatisfy({ !$0.isEmpty }),
              bindings.values.allSatisfy({ value in
                  guard value.hasPrefix("cloud-book-"), let id = UUID(uuidString: String(value.dropFirst("cloud-book-".count))) else { return false }
                  return CloudStandaloneBookID(id).readingBookID == value
              }), Set(bindings.values).count == bindings.count else {
            throw ReaderError.message("The standalone book identities are invalid or duplicated.")
        }
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The caller must hash the actual current book bytes. Once established,
    /// a different edition cannot silently reuse this book's reading data.
    func setVerifiedEdition(localBookID: String, fingerprint: String) throws {
        guard !localBookID.isEmpty, Self.isFingerprint(fingerprint) else {
            activeEditions.removeValue(forKey: localBookID)
            throw ReaderError.message("The book edition identity is invalid.")
        }
        if let existing = archive.verifiedEditions?[localBookID] {
            guard existing == fingerprint else {
                activeEditions.removeValue(forKey: localBookID)
                throw ReaderError.message("This book is a different edition. Recovery is required.")
            }
            activeEditions[localBookID] = fingerprint
            return
        }
        var next = archive
        if next.verifiedEditions == nil { next.verifiedEditions = [:] }
        next.verifiedEditions?[localBookID] = fingerprint
        try commit(next)
        activeEditions[localBookID] = fingerprint
    }

    func registerVerifiedStandaloneEdition(_ edition: VerifiedStandaloneEdition) throws {
        guard archive.scope == edition.scope,
              archive.localToCloudBookIDs?[edition.localBookID] == edition.cloudBookID.readingBookID else {
            activeEditions.removeValue(forKey: edition.localBookID)
            throw ReaderError.message("The verified book belongs to a different cloud identity or account.")
        }
        try setVerifiedEdition(localBookID: edition.localBookID, fingerprint: edition.fingerprint)
    }

    func invalidateEditionVerification(localBookID: String) {
        activeEditions.removeValue(forKey: localBookID)
    }

    func invalidateAllEditionVerifications() { activeEditions.removeAll() }

    func canUploadVerifiedEdition(_ key: CloudReadingKey, bookID: String) -> Bool {
        guard let item = archive.outbox[key.recordName], item.bookID == bookID, item.entry.key == key,
              let fingerprint = item.entry.current.editionFingerprint else { return false }
        let localID: String
        if let bindings = archive.localToCloudBookIDs {
            guard let match = bindings.first(where: { $0.value == bookID })?.key else { return false }
            localID = match
        } else { localID = bookID }
        return activeEditions[localID] == fingerprint
    }

    /// Bind a standalone identity and atomically queue any reading changes made
    /// while the local book did not yet have a cloud identity.
    func bind(localBookID: String, cloudBookID: CloudStandaloneBookID) throws {
        guard var bindings = archive.localToCloudBookIDs, !localBookID.isEmpty else {
            throw ReaderError.message("Standalone book identity mapping is unavailable.")
        }
        let cloudID = cloudBookID.readingBookID
        if let existing = bindings[localBookID] {
            guard existing == cloudID else { throw ReaderError.message("This book already has a different cloud identity.") }
            return
        }
        guard !bindings.values.contains(cloudID) else {
            throw ReaderError.message("This book identity needs explicit recovery before syncing.")
        }
        bindings[localBookID] = cloudID
        try Self.validateBindings(bindings, scope: archive.scope)
        var next = archive; next.localToCloudBookIDs = bindings
        var migrated = Set<String>()
        for (name, item) in next.unmappedOutbox ?? [:] where item.bookID == localBookID {
            let key = try CloudReadingKey(scope: next.scope, bookID: cloudID, kind: item.entry.key.kind, itemID: item.entry.key.itemID)
            let entry = CloudReadingEntry(key: key, current: item.entry.current, baseRevision: nil,
                                          pending: item.entry.pending, pendingRevisions: item.entry.pendingRevisions,
                                          conflicts: item.entry.conflicts)
            let mapped = OutboxItem(bookID: cloudID, entry: entry, pendingApplication: false,
                                    legacyConflictRevisions: item.legacyConflictRevisions)
            let existing = next.outbox[key.recordName].map { [key.recordName: $0] } ?? [:]
            let merged = try Self.mergeAccountSwitchDestination([key.recordName: mapped], target: existing, scope: next.scope)
            next.outbox[key.recordName] = merged[key.recordName]
            next.unmappedOutbox?.removeValue(forKey: name)
            migrated.insert(key.recordName)
        }
        if let record = next.records[localBookID] {
            let key = try CloudReadingKey(scope: next.scope, bookID: cloudID, kind: .position)
            if !migrated.contains(key.recordName) {
                try Self.enqueue(&next, bookID: localBookID, kind: .position, itemID: nil,
                                 payload: .position(CloudPrecisePosition(position: record.position, contentFingerprint: record.contentFingerprint, acknowledgedServerTicks: record.acknowledgedTicks)))
            }
        }
        for bookmark in next.bookmarks[localBookID] ?? [] {
            let key = try CloudReadingKey(scope: next.scope, bookID: cloudID, kind: .bookmark, itemID: bookmark.id)
            if !migrated.contains(key.recordName) { try Self.enqueue(&next, bookID: localBookID, kind: .bookmark, itemID: bookmark.id, payload: .bookmark(bookmark)) }
        }
        for annotation in next.annotations[localBookID] ?? [] {
            let key = try CloudReadingKey(scope: next.scope, bookID: cloudID, kind: .annotation, itemID: annotation.id)
            if !migrated.contains(key.recordName) { try Self.enqueue(&next, bookID: localBookID, kind: .annotation, itemID: annotation.id, payload: .annotation(annotation)) }
        }
        next.unmappedBookIDs?.remove(localBookID)
        try commit(next)
    }

    private static func enqueue(_ archive: inout Archive, bookID: String, kind: CloudReadingKind, itemID: UUID?, payload: CloudReadingPayload?, editionFingerprint: String? = nil) throws {
        let cloudID: String
        if let bindings = archive.localToCloudBookIDs {
            guard let mapped = bindings[bookID] else {
                if archive.unmappedBookIDs == nil { archive.unmappedBookIDs = [] }
                archive.unmappedBookIDs?.insert(bookID)
                let key = try CloudReadingKey(scope: archive.scope, bookID: bookID, kind: kind, itemID: itemID)
                var pending = archive.unmappedOutbox ?? [:]
                try Self.enqueueItem(&pending, key: key, bookID: bookID, payload: payload, editionFingerprint: editionFingerprint)
                archive.unmappedOutbox = pending
                return
            }
            cloudID = mapped
        } else { cloudID = bookID }
        let key = try CloudReadingKey(scope: archive.scope, bookID: cloudID, kind: kind, itemID: itemID)
        try Self.enqueueItem(&archive.outbox, key: key, bookID: cloudID, payload: payload, editionFingerprint: editionFingerprint)
    }

    private static func enqueueItem(_ items: inout [String: OutboxItem], key: CloudReadingKey, bookID: String,
                                    payload: CloudReadingPayload?, editionFingerprint: String?) throws {
        guard payload == nil || (payload?.kind == key.kind && payload?.itemID == key.itemID) else { throw ReaderError.message("The reading-data identity is invalid.") }
        let previous = items[key.recordName]
        var entry = previous?.entry ?? CloudReadingEntry(key: key, current: CloudReadingVersion(revision: UUID(), payload: nil), baseRevision: nil, pending: false, pendingRevisions: [], conflicts: [])
        // A remote value awaiting edition validation must not disappear if the
        // reader changes locally before it can be applied.
        if previous?.pendingApplication == true && !entry.conflicts.contains(where: { $0.revision == entry.current.revision }) {
            entry.conflicts.append(entry.current)
        }
        entry.current = CloudReadingVersion(revision: UUID(), payload: payload, editionFingerprint: editionFingerprint)
        entry.pending = true; entry.pendingRevisions.append(entry.current.revision)
        items[key.recordName] = OutboxItem(bookID: bookID, entry: entry, pendingApplication: false,
                                          legacyConflictRevisions: previous?.legacyConflictRevisions)
    }

    private func commit(_ updated: Archive) throws {
        try PrivateBookFiles.withExclusiveLock(at: lockFile) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == archive.scope, disk.revision == archive.revision else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before editing.")
            }
            var next = updated; next.revision = UUID()
            try PrivateBookFiles.write(JSONEncoder().encode(next), to: file)
            archive = next
        }
    }

    /// A no-op replay or network write must not trust an archive that another
    /// open session has replaced since this instance loaded it.
    func requireCurrentRevision() throws {
        try PrivateBookFiles.withExclusiveLock(at: lockFile) {
            let disk = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard disk.scope == archive.scope, disk.revision == archive.revision else {
                throw ReaderError.message("Reading data changed in another session. Reopen it before syncing.")
            }
        }
    }

    /// Record a successful conditional write without clearing edits that were
    /// made while the request was in flight.
    func acknowledge(_ key: CloudReadingKey, revision: UUID) throws {
        guard key.sourceKey == archive.scope.sourceKey,
              var item = archive.outbox[key.recordName], item.entry.key == key,
              item.entry.pending,
              let index = item.entry.pendingRevisions.firstIndex(of: revision) else { return }
        var next = archive
        item.entry.baseRevision = revision
        item.entry.pendingRevisions.removeFirst(index + 1)
        if item.entry.current.revision == revision { item.entry.pending = false }
        next.outbox[key.recordName] = item
        try commit(next)
    }

    /// Persist a remote version before attempting to apply it to the reader.
    /// A caller must separately verify the local book/edition association.
    func observe(_ key: CloudReadingKey, bookID: String, remote: CloudReadingVersion) throws {
        guard key.sourceKey == archive.scope.sourceKey, !bookID.isEmpty,
              stableKey(bookID) == key.bookKey,
              remote.hasValidEditionFingerprint,
              (key.kind == .position) == (key.itemID == nil),
              remote.payload == nil || (remote.payload?.kind == key.kind && remote.payload?.itemID == key.itemID) else {
            throw ReaderError.message("The iCloud reading record belongs to a different source or item.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(remote.payload).count <= 512 * 1024 else {
            throw ReaderError.message("This reading change is too large to sync.")
        }
        var next = archive
        guard var item = next.outbox[key.recordName] else {
            let entry = CloudReadingEntry(key: key, current: remote, baseRevision: remote.revision,
                                          pending: false, pendingRevisions: [], conflicts: [])
            next.outbox[key.recordName] = OutboxItem(bookID: bookID, entry: entry, pendingApplication: true)
            try commit(next); return
        }
        guard item.bookID == bookID, item.entry.key == key else {
            throw ReaderError.message("The iCloud reading record belongs to a different source or item.")
        }
        let original = item
        if item.entry.current.revision == remote.revision {
            guard try encoder.encode(item.entry.current) == encoder.encode(remote) else {
                throw ReaderError.message("The iCloud reading record is inconsistent.")
            }
            item.entry.pending = false; item.entry.pendingRevisions = []; item.entry.baseRevision = remote.revision
        } else if item.entry.pending || !item.entry.conflicts.isEmpty || item.pendingApplication == true {
            if let existing = item.entry.conflicts.first(where: { $0.revision == remote.revision }) {
                guard try encoder.encode(existing) == encoder.encode(remote) else {
                    throw ReaderError.message("The iCloud reading record is inconsistent.")
                }
            } else if remote.revision != item.entry.baseRevision {
                item.entry.conflicts.append(remote)
            }
        } else {
            item.entry.current = remote; item.entry.baseRevision = remote.revision; item.pendingApplication = true
        }
        // Replaying an interrupted discovery must not change the archive
        // revision when this record was already staged unchanged.
        guard try encoder.encode(original) != encoder.encode(item) else { try requireCurrentRevision(); return }
        next.outbox[key.recordName] = item
        try commit(next)
    }

    /// Apply an observed version only after the caller has independently hashed
    /// the actual local edition. The record and supplied digest must match; a
    /// missing legacy fingerprint remains staged for explicit recovery.
    func applyObserved(_ key: CloudReadingKey, book: Book, verifiedEditionFingerprint: String,
                       expectedRevision: UUID, confirmLegacyEdition: Bool = false,
                       confirmedJellyfinDeletionTicks: Int64? = nil) throws {
        let importedSourceKey = try CloudReadingSource.imported.key()
        let cloudID: String
        if let bindings = archive.localToCloudBookIDs {
            guard let bound = bindings[book.id] else { throw ReaderError.message("This book has no verified cloud identity.") }
            cloudID = bound
        } else { cloudID = book.id }
        guard book.format != .unsupported, key.sourceKey == archive.scope.sourceKey, stableKey(cloudID) == key.bookKey,
              var item = archive.outbox[key.recordName], item.bookID == cloudID, item.entry.key == key,
              item.pendingApplication == true, item.entry.conflicts.isEmpty,
              item.entry.current.revision == expectedRevision,
              (item.entry.current.editionFingerprint == verifiedEditionFingerprint ||
               (confirmLegacyEdition && item.entry.current.editionFingerprint == nil &&
                (item.entry.pending || item.entry.baseRevision == expectedRevision))),
              activeEditions[book.id] == verifiedEditionFingerprint,
              item.entry.current.hasValidEditionFingerprint, !verifiedEditionFingerprint.isEmpty,
              item.entry.current.payload == nil || (item.entry.current.payload?.kind == key.kind && item.entry.current.payload?.itemID == key.itemID) else {
            throw ReaderError.message("The reading data or book edition changed. Review it before restoring.")
        }
        if archive.scope.sourceKey != importedSourceKey, key.kind == .position {
            try validateJellyfinPosition(item.entry.current.payload, book: book, confirmedDeletionTicks: confirmedJellyfinDeletionTicks)
        }
        var next = archive
        try Self.applyPayload(item.entry.current.payload, key: key, book: book, to: &next)
        item.pendingApplication = false
        if item.entry.current.editionFingerprint == nil {
            // Publish a new conditional revision; never rewrite the identity
            // or contents of the legacy cloud revision in place.
            item.entry.current = CloudReadingVersion(revision: UUID(), payload: item.entry.current.payload,
                                                     editionFingerprint: verifiedEditionFingerprint)
            item.entry.pending = true
            item.entry.pendingRevisions = [item.entry.current.revision]
        }
        next.outbox[key.recordName] = item
        try commit(next)
    }

    /// Associate one explicitly reviewed local change with the currently
    /// verified edition. The reviewed revision must still be current; remote
    /// alternatives and the conditional-write base remain untouched.
    func certifyReviewedLocalVersion(_ key: CloudReadingKey, book: Book,
                                     expectedRevision: UUID, verifiedEditionFingerprint: String) throws {
        let cloudID: String
        if let bindings = archive.localToCloudBookIDs {
            guard let bound = bindings[book.id] else { throw ReaderError.message("This book has no verified cloud identity.") }
            cloudID = bound
        } else { cloudID = book.id }
        guard book.format != .unsupported, key.sourceKey == archive.scope.sourceKey, stableKey(cloudID) == key.bookKey,
              var item = archive.outbox[key.recordName], item.bookID == cloudID, item.entry.key == key,
              item.entry.pending, item.pendingApplication != true,
              item.entry.current.revision == expectedRevision, item.entry.current.editionFingerprint == nil,
              item.entry.current.payload == nil || (item.entry.current.payload?.kind == key.kind && item.entry.current.payload?.itemID == key.itemID),
              Self.isFingerprint(verifiedEditionFingerprint), activeEditions[book.id] == verifiedEditionFingerprint else {
            throw ReaderError.message("The reading data or verified edition changed. Review it again.")
        }
        let version = CloudReadingVersion(revision: UUID(), payload: item.entry.current.payload,
                                          editionFingerprint: verifiedEditionFingerprint)
        item.entry.current = version
        item.entry.pendingRevisions.append(version.revision)
        var next = archive; next.outbox[key.recordName] = item
        try commit(next)
    }

    enum ConflictChoice { case local, remote }

    /// Resolve exactly one reviewed alternative. Other alternatives remain
    /// visible, and a later remote edit still requires a conditional write.
    func resolveConflict(_ key: CloudReadingKey, book: Book, verifiedEditionFingerprint: String,
                         expectedLocalRevision: UUID, remoteRevision: UUID, choice: ConflictChoice,
                         confirmUnverifiedEdition: Bool = false, confirmedJellyfinDeletionTicks: Int64? = nil) throws {
        let cloudID: String
        if let bindings = archive.localToCloudBookIDs {
            guard let bound = bindings[book.id] else { throw ReaderError.message("This book has no verified cloud identity.") }
            cloudID = bound
        } else { cloudID = book.id }
        guard book.format != .unsupported, key.sourceKey == archive.scope.sourceKey, stableKey(cloudID) == key.bookKey,
              var item = archive.outbox[key.recordName], item.bookID == cloudID, item.entry.key == key,
              item.entry.current.revision == expectedLocalRevision,
              let remote = item.entry.conflicts.first(where: { $0.revision == remoteRevision }),
              activeEditions[book.id] == verifiedEditionFingerprint,
              Self.isFingerprint(verifiedEditionFingerprint) else {
            throw ReaderError.message("The conflict or book edition changed. Review it again.")
        }
        let selected = choice == .local ? item.entry.current : remote
        guard (selected.editionFingerprint == verifiedEditionFingerprint ||
               (selected.editionFingerprint == nil && confirmUnverifiedEdition)), selected.hasValidEditionFingerprint,
              selected.payload == nil || (selected.payload?.kind == key.kind && selected.payload?.itemID == key.itemID) else {
            throw ReaderError.message("The selected reading data needs edition recovery before it can be used.")
        }
        if archive.scope.sourceKey != (try CloudReadingSource.imported.key()), key.kind == .position {
            try validateJellyfinPosition(selected.payload, book: book, confirmedDeletionTicks: confirmedJellyfinDeletionTicks)
        }
        var next = archive
        // The current value can itself be a staged cloud version that has
        // never been applied locally. Choosing it must materialize it too.
        if choice == .remote || item.pendingApplication == true {
            try Self.applyPayload(selected.payload, key: key, book: book, to: &next)
        }
        if !(item.legacyConflictRevisions ?? []).contains(remoteRevision) { item.entry.baseRevision = remoteRevision }
        item.entry.current = CloudReadingVersion(revision: UUID(), payload: selected.payload, editionFingerprint: verifiedEditionFingerprint)
        item.entry.pending = true; item.entry.pendingRevisions = [item.entry.current.revision]
        item.entry.conflicts.removeAll { $0.revision == remoteRevision }
        item.legacyConflictRevisions?.removeAll { $0 == remoteRevision }
        item.pendingApplication = false
        next.outbox[key.recordName] = item
        try commit(next)
    }

    private func validateJellyfinPosition(_ payload: CloudReadingPayload?, book: Book, confirmedDeletionTicks: Int64?) throws {
        let serverTicks: Int64?
        if case .position(let value) = payload { serverTicks = value.acknowledgedServerTicks }
        else if payload == nil { serverTicks = confirmedDeletionTicks }
        else { serverTicks = nil }
        guard let serverTicks, serverTicks == book.ticks,
              archive.records[book.id].map({ $0.acknowledgedTicks == serverTicks && (payload != nil || !$0.dirty) }) ?? true else {
            throw ReaderError.message("The server position changed or has unsynced edits. Review this reading position before restoring.")
        }
    }

    private static func applyPayload(_ payload: CloudReadingPayload?, key: CloudReadingKey, book: Book, to next: inout Archive) throws {
        switch (key.kind, payload) {
        case (.position, .position(let value)):
            try validateRestoredPosition(value.position, format: book.format)
            if var existing = next.records[book.id] {
                guard !existing.dirty || existing.position == value.position else {
                    throw ReaderError.message("The local server position has unsynced changes. Resolve them before restoring.")
                }
                existing.position = value.position; existing.contentFingerprint = value.contentFingerprint; existing.updated = Date()
                next.records[book.id] = existing
            } else {
                next.records[book.id] = ReadingRecord(position: value.position, acknowledgedTicks: book.ticks,
                                                     dirty: false, updated: Date(), title: book.title, format: book.format, contentFingerprint: value.contentFingerprint)
            }
        case (.position, nil):
            guard next.records[book.id]?.dirty != true else {
                throw ReaderError.message("The local server position has unsynced changes. Resolve them before restoring.")
            }
            next.records.removeValue(forKey: book.id)
        case (.bookmark, .bookmark(let bookmark)):
            try validateRestoredPosition(bookmark.position, format: book.format)
            var items = next.bookmarks[book.id] ?? []
            items.removeAll { $0.id == bookmark.id }; items.append(bookmark); next.bookmarks[book.id] = items
        case (.bookmark, nil):
            next.bookmarks[book.id]?.removeAll { $0.id == key.itemID }
        case (.annotation, .annotation(let annotation)):
            var items = next.annotations[book.id] ?? []
            items.removeAll { $0.id == annotation.id }; items.append(annotation); next.annotations[book.id] = items
        case (.annotation, nil):
            next.annotations[book.id]?.removeAll { $0.id == key.itemID }
        default:
            throw ReaderError.message("The restored reading data is invalid.")
        }
    }

    private static func validateRestoredPosition(_ position: ReadingPosition, format: BookFormat) throws {
        guard position.validatedTicks(for: format) != nil else {
            throw ReaderError.message("The restored position is invalid.")
        }
        if let cfi = position.cfi, !(cfi.hasPrefix("epubcfi(") && cfi.hasSuffix(")") && cfi.count <= 8192 && format == .epub) {
            throw ReaderError.message("The restored position is invalid.")
        }
    }
    /// Writes the whole local snapshot and all corresponding changes together.
    func replace(records: [String: ReadingRecord], bookmarks: [String: [Bookmark]], annotations: [String: [ReadingAnnotation]]) throws {
        var next = archive
        for id in Set(archive.records.keys).union(records.keys) {
            let before = archive.records[id], after = records[id]
            if before?.position != after?.position || before?.contentFingerprint != after?.contentFingerprint {
                let payload = after.map { CloudReadingPayload.position(CloudPrecisePosition(position: $0.position, contentFingerprint: $0.contentFingerprint, acknowledgedServerTicks: $0.acknowledgedTicks)) }
                try Self.enqueue(&next, bookID: id, kind: .position, itemID: nil, payload: payload, editionFingerprint: activeEditions[id])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for id in Set(archive.bookmarks.keys).union(bookmarks.keys) {
            let old = archive.bookmarks[id] ?? [], new = bookmarks[id] ?? []
            guard Set(new.map(\.id)).count == new.count else { throw ReaderError.message("Duplicate bookmark identities require recovery before syncing.") }
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }), newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            for itemID in Set(oldByID.keys).union(newByID.keys) {
                if try encoder.encode(oldByID[itemID]) != encoder.encode(newByID[itemID]) {
                    try Self.enqueue(&next, bookID: id, kind: .bookmark, itemID: itemID, payload: newByID[itemID].map(CloudReadingPayload.bookmark), editionFingerprint: activeEditions[id])
                }
            }
        }
        for id in Set(archive.annotations.keys).union(annotations.keys) {
            let old = archive.annotations[id] ?? [], new = annotations[id] ?? []
            guard Set(new.map(\.id)).count == new.count else { throw ReaderError.message("Duplicate annotation identities require recovery before syncing.") }
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }), newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            for itemID in Set(oldByID.keys).union(newByID.keys) where oldByID[itemID] != newByID[itemID] {
                try Self.enqueue(&next, bookID: id, kind: .annotation, itemID: itemID, payload: newByID[itemID].map(CloudReadingPayload.annotation), editionFingerprint: activeEditions[id])
            }
        }
        next.records = records; next.bookmarks = bookmarks; next.annotations = annotations
        try commit(next)
    }
    func set(_ record: ReadingRecord, bookID: String) throws {
        var next = archive; next.records[bookID] = record
        try Self.enqueue(&next, bookID: bookID, kind: .position, itemID: nil,
                         payload: .position(CloudPrecisePosition(position: record.position, contentFingerprint: record.contentFingerprint, acknowledgedServerTicks: record.acknowledgedTicks)), editionFingerprint: activeEditions[bookID])
        try commit(next)
    }
    func set(_ bookmark: Bookmark, bookID: String) throws {
        var next = archive; var items = next.bookmarks[bookID] ?? []
        items.removeAll { $0.id == bookmark.id }; items.append(bookmark); next.bookmarks[bookID] = items
        try Self.enqueue(&next, bookID: bookID, kind: .bookmark, itemID: bookmark.id, payload: .bookmark(bookmark), editionFingerprint: activeEditions[bookID]); try commit(next)
    }
    func remove(_ bookmark: Bookmark, bookID: String) throws {
        var next = archive; next.bookmarks[bookID]?.removeAll { $0.id == bookmark.id }
        try Self.enqueue(&next, bookID: bookID, kind: .bookmark, itemID: bookmark.id, payload: nil, editionFingerprint: activeEditions[bookID]); try commit(next)
    }
    func set(_ annotation: ReadingAnnotation, bookID: String) throws {
        var next = archive; var items = next.annotations[bookID] ?? []
        items.removeAll { $0.id == annotation.id }; items.append(annotation); next.annotations[bookID] = items
        try Self.enqueue(&next, bookID: bookID, kind: .annotation, itemID: annotation.id, payload: .annotation(annotation), editionFingerprint: activeEditions[bookID]); try commit(next)
    }
    func remove(_ annotation: ReadingAnnotation, bookID: String) throws {
        var next = archive; next.annotations[bookID]?.removeAll { $0.id == annotation.id }
        try Self.enqueue(&next, bookID: bookID, kind: .annotation, itemID: annotation.id, payload: nil, editionFingerprint: activeEditions[bookID]); try commit(next)
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

@MainActor protocol CloudReadingRecordDatabase {
    func fetch(_ id: CKRecord.ID) async throws -> CKRecord?
    func saveIfUnchanged(_ record: CKRecord) async throws -> CloudReadingRecordSaveResult
}

enum CloudReadingRecordSaveResult {
    case saved
    case conflict(CKRecord)
}

/// Thin private-database adapter. Zone creation and account lifecycle belong to
/// the caller; a missing zone is an error, never an empty reading record.
@MainActor final class CloudKitReadingRecordDatabase: CloudReadingRecordDatabase {
    private let database: CKDatabase
    init(database: CKDatabase) { self.database = database }

    func fetch(_ id: CKRecord.ID) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    func saveIfUnchanged(_ record: CKRecord) async throws -> CloudReadingRecordSaveResult {
        do {
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[record.recordID] else { throw ReaderError.message("iCloud did not confirm the reading change.") }
            _ = try saved.get()
            return .saved
        } catch {
            if let server = Self.conflictRecord(from: error, recordID: record.recordID) { return .conflict(server) }
            throw error
        }
    }

    static func conflictRecord(from error: Error, recordID: CKRecord.ID) -> CKRecord? {
        guard let cloudError = error as? CKError else { return nil }
        let itemError: CKError
        if cloudError.code == .partialFailure {
            guard let nested = cloudError.partialErrorsByItemID?[recordID] as? CKError else { return nil }
            itemError = nested
        } else { itemError = cloudError }
        guard itemError.code == .serverRecordChanged else { return nil }
        return itemError.serverRecord
    }
}

/// Performs conditional writes for one source/book. The caller must supply an
/// account check that revalidates the actual CloudKit identity. Account changes
/// during an in-flight CloudKit operation still require device verification.
/// The experimental recovery flow uses this adapter.
@MainActor final class CloudKitReadingTransport: CloudReadingTransport {
    private let scope: CloudReadingScope
    private let bookID: String
    private let zoneID: CKRecordZone.ID
    private let database: any CloudReadingRecordDatabase
    private let accountIsCurrent: @MainActor () async throws -> Bool

    init(scope: CloudReadingScope, bookID: String, zoneID: CKRecordZone.ID,
         database: any CloudReadingRecordDatabase, accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard scope.isValid, !bookID.isEmpty else { throw ReaderError.message("The iCloud reading identity is invalid.") }
        self.scope = scope; self.bookID = bookID; self.zoneID = zoneID
        self.database = database; self.accountIsCurrent = accountIsCurrent
    }

    private func checkAccount() async throws {
        try Task.checkCancellation()
        guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Sync is paused.") }
        try Task.checkCancellation()
    }

    private func validate(_ key: CloudReadingKey) throws {
        guard key.sourceKey == scope.sourceKey, key.bookKey == stableKey(bookID),
              (key.kind == .position) == (key.itemID == nil) else {
            throw ReaderError.message("The reading change belongs to a different source or item.")
        }
    }

    private func read(_ key: CloudReadingKey) async throws -> (CKRecord, CloudReadingVersion)? {
        try validate(key)
        try await checkAccount()
        let record = try await database.fetch(CKRecord.ID(recordName: key.recordName, zoneID: zoneID))
        try await checkAccount()
        guard let record else { return nil }
        let (decodedKey, decodedBookID, version) = try CloudReadingRecordCodec.decode(record, expectedSource: scope.sourceKey)
        guard decodedKey == key, decodedBookID == bookID, record.recordID.zoneID == zoneID else {
            throw ReaderError.message("The iCloud reading record belongs to a different source or item.")
        }
        return (record, version)
    }

    func fetch(_ key: CloudReadingKey) async throws -> CloudReadingVersion? {
        try await read(key)?.1
    }

    func upload(_ entry: CloudReadingEntry, expected: UUID?) async throws -> CloudReadingUploadResult {
        try validate(entry.key)
        guard entry.pending, entry.current.editionFingerprint != nil, entry.current.hasValidEditionFingerprint else {
            throw ReaderError.message("The reading change needs edition verification before upload.")
        }
        let existing = try await read(entry.key)
        if let existing, existing.1.revision != expected { return .conflict(existing.1) }
        if existing == nil, expected != nil { throw ReaderError.message("The iCloud reading record is missing; recovery is required.") }
        let record = try CloudReadingRecordCodec.record(entry: entry, bookID: bookID, zoneID: zoneID, existing: existing?.0)
        try await checkAccount()
        let result = try await database.saveIfUnchanged(record)
        try await checkAccount()
        switch result {
        case .saved: return .saved
        case .conflict(let server):
            let (key, serverBookID, version) = try CloudReadingRecordCodec.decode(server, expectedSource: scope.sourceKey)
            guard key == entry.key, serverBookID == bookID, server.recordID.zoneID == zoneID else {
                throw ReaderError.message("The iCloud reading record belongs to a different source or item.")
            }
            return .conflict(version)
        }
    }
}

/// Reconciles the same atomic archive used by the reader. Incoming values stay
/// staged until the separate, edition-verified application step runs.
@MainActor final class CloudAtomicReadingSyncCoordinator {
    enum Status: Equatable { case idle, pending, syncing, needsApplication, needsEditionVerification, conflict, accountChanged, failed(String) }
    private let store: CloudAtomicReadingStore
    private let transport: any CloudReadingTransport
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private(set) var status: Status = .idle
    private var running = false

    init(store: CloudAtomicReadingStore, transport: any CloudReadingTransport,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) {
        self.store = store; self.transport = transport; self.accountIsCurrent = accountIsCurrent
    }

    private func currentAccount() async throws -> Bool {
        try Task.checkCancellation()
        let current = try await accountIsCurrent()
        try Task.checkCancellation()
        return current
    }

    func sync(_ key: CloudReadingKey, bookID: String) async {
        guard !running else { return }
        running = true; status = .syncing
        defer { running = false }
        do {
            guard key.sourceKey == store.scope.sourceKey, !bookID.isEmpty,
                  stableKey(bookID) == key.bookKey else {
                throw ReaderError.message("The reading change belongs to a different source or item.")
            }
            guard try await currentAccount() else { status = .accountChanged; return }
            let remote = try await transport.fetch(key)
            guard try await currentAccount() else { status = .accountChanged; return }
            if let remote { try store.observe(key, bookID: bookID, remote: remote) }
            guard let item = store.outbox[key.recordName] else { status = .idle; return }
            guard item.entry.conflicts.isEmpty else { status = .conflict; return }
            guard item.pendingApplication != true else { status = .needsApplication; return }
            guard item.entry.pending else { status = .idle; return }
            guard store.canUploadVerifiedEdition(key, bookID: bookID) else { status = .needsEditionVerification; return }
            guard remote != nil || item.entry.baseRevision == nil else {
                throw ReaderError.message("The iCloud reading record is missing; recovery is required.")
            }
            guard try await currentAccount() else { status = .accountChanged; return }
            try store.requireCurrentRevision()
            guard let latest = store.outbox[key.recordName], latest.bookID == bookID, latest.entry.key == key,
                  latest.entry.current.revision == item.entry.current.revision,
                  latest.entry.baseRevision == item.entry.baseRevision, latest.entry.pending,
                  latest.entry.conflicts.isEmpty, latest.pendingApplication != true,
                  store.canUploadVerifiedEdition(key, bookID: bookID) else { status = .pending; return }
            let result = try await transport.upload(item.entry, expected: item.entry.baseRevision)
            guard try await currentAccount() else { status = .accountChanged; return }
            switch result {
            case .saved:
                try store.acknowledge(key, revision: item.entry.current.revision)
                status = store.outbox[key.recordName]?.entry.pending == true ? .pending : .idle
            case .conflict(let version):
                try store.observe(key, bookID: bookID, remote: version)
                if let updated = store.outbox[key.recordName] {
                    if !updated.entry.conflicts.isEmpty { status = .conflict }
                    else if updated.pendingApplication == true { status = .needsApplication }
                    else { status = updated.entry.pending ? .pending : .idle }
                } else { status = .idle }
            }
        } catch { status = .failed(error.localizedDescription) }
    }
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

    private func currentAccount() async throws -> Bool {
        try Task.checkCancellation()
        let current = try await accountIsCurrent()
        try Task.checkCancellation()
        return current
    }

    func sync(_ key: CloudReadingKey) async {
        guard !running else { return }
        running = true; status = .syncing
        defer { running = false }
        do {
            guard key.sourceKey == journal.scope.sourceKey else {
                throw ReaderError.message("The reading change belongs to a different source.")
            }
            guard try await currentAccount() else { status = .accountChanged; return }
            let remote = try await transport.fetch(key)
            guard try await currentAccount() else { status = .accountChanged; return }
            if let remote { try journal.observe(key, remote: remote) }
            guard let entry = journal.entries[key.recordName] else { status = .idle; return }
            guard entry.conflicts.isEmpty else { status = .conflict; return }
            guard entry.pending else { status = .idle; return }
            // A previously observed remote record disappearing is ambiguous:
            // preserve the local edit until deletion recovery is resolved.
            if remote == nil, entry.baseRevision != nil {
                throw ReaderError.message("The iCloud reading record is missing; recovery is required.")
            }
            guard try await currentAccount() else { status = .accountChanged; return }
            let result = try await transport.upload(entry, expected: entry.baseRevision)
            guard try await currentAccount() else { status = .accountChanged; return }
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
    private let container: CKContainer?
    private let accountAvailable: @MainActor () async throws -> Bool
    private let accountName: @MainActor () async throws -> String
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private(set) var token: Token?

    init(container: CKContainer? = nil,
         accountAvailable: (@MainActor () async throws -> Bool)? = nil,
         accountName: (@MainActor () async throws -> String)? = nil) {
        let resolved = container ?? ((accountAvailable != nil && accountName != nil) ? nil : CKContainer.default())
        self.container = resolved
        self.accountAvailable = accountAvailable ?? {
            guard let resolved else { throw ReaderError.message("The iCloud container is unavailable.") }
            return try await resolved.accountStatus() == .available
        }
        self.accountName = accountName ?? {
            guard let resolved else { throw ReaderError.message("The iCloud container is unavailable.") }
            return try await resolved.userRecordID().recordName
        }
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func invalidate() { generation = UUID(); token = nil }
    func refresh() async throws -> Token? {
        try Task.checkCancellation()
        invalidate()
        let expected = generation
        let available = try await accountAvailable()
        try Task.checkCancellation()
        guard available else { return nil }
        guard generation == expected else { throw CancellationError() }
        let user = try await accountName()
        try Task.checkCancellation()
        guard generation == expected, !user.isEmpty else { throw CancellationError() }
        let result = Token(accountKey: stableKey(user), generation: expected)
        token = result; return result
    }
    func accepts(_ candidate: Token) -> Bool { token == candidate && generation == candidate.generation }
    func validate(_ candidate: Token) async throws -> Bool {
        // An older suspended request must never invalidate a newer session.
        guard !Task.isCancelled, accepts(candidate) else { return false }
        do {
            let available = try await accountAvailable()
            guard !Task.isCancelled, accepts(candidate) else { return false }
            guard available else { invalidate(); return false }
            let user = try await accountName()
            guard !Task.isCancelled, accepts(candidate) else { return false }
            guard !user.isEmpty, stableKey(user) == candidate.accountKey else { invalidate(); return false }
            return true
        } catch {
            if !Task.isCancelled && accepts(candidate) { invalidate() }
            throw error
        }
    }
    func scope(for candidate: Token, source: CloudReadingSource) throws -> CloudReadingScope {
        guard accepts(candidate) else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
        return try CloudReadingScope(accountKey: candidate.accountKey, source: source)
    }
    var privateDatabase: CKDatabase? { container?.privateCloudDatabase }
}

/// A page is processed completely before requesting the next one. Tokens are
/// intentionally kept only for this scan: an interrupted scan starts again,
/// and idempotent journals preserve already staged records.
struct CloudRecoveryPage {
    let records: [CKRecord]
    let deletedRecordCount: Int
    let nextToken: Data
    let moreComing: Bool
}

@MainActor protocol CloudRecoveryPageSource {
    func page(after token: Data?) async throws -> CloudRecoveryPage
}

@MainActor final class CloudKitRecoveryPageSource: CloudRecoveryPageSource {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    init(database: CKDatabase, zoneID: CKRecordZone.ID) { self.database = database; self.zoneID = zoneID }

    func page(after token: Data?) async throws -> CloudRecoveryPage {
        let previous: CKServerChangeToken?
        if let token {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) else {
                throw ReaderError.message("The iCloud recovery cursor is invalid.")
            }
            previous = decoded
        } else { previous = nil }
        let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: previous, desiredKeys: nil, resultsLimit: 50)
        var records: [CKRecord] = []
        for (id, result) in page.modificationResultsByID {
            let record = try result.get().record
            guard id == record.recordID, id.zoneID == zoneID else {
                throw ReaderError.message("An iCloud recovery record has an invalid identity.")
            }
            records.append(record)
        }
        return CloudRecoveryPage(records: records, deletedRecordCount: page.deletions.count,
                                 nextToken: try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true),
                                 moreComing: page.moreComing)
    }
}

/// Discovery is scoped to one account and source-specific zone. The receiver
/// must durably stage each record and must tolerate replay after interruption.
@MainActor final class CloudRecoveryDiscovery {
    private let source: any CloudRecoveryPageSource
    private let zoneID: CKRecordZone.ID
    private let accountIsCurrent: @MainActor () async throws -> Bool
    private let receive: @MainActor (CKRecord) async throws -> Void
    private var running = false

    init(source: any CloudRecoveryPageSource, zoneID: CKRecordZone.ID,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool,
         receive: @escaping @MainActor (CKRecord) async throws -> Void) {
        self.source = source; self.zoneID = zoneID; self.accountIsCurrent = accountIsCurrent; self.receive = receive
    }

    func scan() async throws {
        guard !running else { throw ReaderError.message("An iCloud recovery scan is already running.") }
        running = true; defer { running = false }
        var token: Data?
        repeat {
            try Task.checkCancellation()
            guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
            let page = try await source.page(after: token)
            guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
            // LibraVia uses retained tombstone records. A physical deletion has
            // no revision or source identity and must never imply local deletion.
            guard page.deletedRecordCount == 0 else { throw ReaderError.message("An iCloud recovery record is missing and needs review.") }
            for record in page.records {
                try Task.checkCancellation()
                guard record.recordID.zoneID == zoneID, try await accountIsCurrent() else {
                    throw ReaderError.message("The iCloud recovery record or account changed.")
                }
                try await receive(record)
                guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
            }
            guard !page.nextToken.isEmpty, !page.moreComing || page.nextToken != token else {
                throw ReaderError.message("The iCloud recovery cursor did not advance.")
            }
            token = page.moreComing ? page.nextToken : nil
        } while token != nil
    }
}

/// Missing zones are never treated as empty libraries. A user-visible recovery
/// decision must precede creation, since absence can also mean a reset.
enum CloudRecoveryZoneState: Equatable { case present, missing, deletedByUser }

@MainActor protocol CloudRecoveryZoneDatabase {
    func state(of id: CKRecordZone.ID) async throws -> CloudRecoveryZoneState
    func create(_ id: CKRecordZone.ID) async throws
}

@MainActor final class CloudKitRecoveryZoneDatabase: CloudRecoveryZoneDatabase {
    private let database: CKDatabase
    init(database: CKDatabase) { self.database = database }
    func state(of id: CKRecordZone.ID) async throws -> CloudRecoveryZoneState {
        do {
            let zone = try await database.recordZone(for: id)
            guard zone.zoneID == id else { throw ReaderError.message("The iCloud recovery zone is invalid.") }
            return .present
        } catch let error as CKError where error.code == .userDeletedZone {
            return .deletedByUser
        } catch let error as CKError where error.code == .zoneNotFound {
            return (error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?.boolValue == true ? .deletedByUser : .missing
        }
    }
    func create(_ id: CKRecordZone.ID) async throws {
        let zone = try await database.save(CKRecordZone(zoneID: id))
        guard zone.zoneID == id else { throw ReaderError.message("The iCloud recovery zone is invalid.") }
    }
}

@MainActor final class CloudRecoveryZoneAccess {
    private let scope: CloudReadingScope
    private let database: any CloudRecoveryZoneDatabase
    private let accountIsCurrent: @MainActor () async throws -> Bool
    init(scope: CloudReadingScope, database: any CloudRecoveryZoneDatabase,
         accountIsCurrent: @escaping @MainActor () async throws -> Bool) throws {
        guard scope.isValid else { throw ReaderError.message("The iCloud recovery scope is invalid.") }
        self.scope = scope; self.database = database; self.accountIsCurrent = accountIsCurrent
    }
    private func checkAccount() async throws {
        try Task.checkCancellation()
        guard try await accountIsCurrent() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
        try Task.checkCancellation()
    }
    func inspect() async throws -> CloudRecoveryZoneState {
        try await checkAccount()
        let state = try await database.state(of: scope.recoveryZoneID)
        try await checkAccount()
        return state
    }
    /// This method is for a separately reviewed start-over decision, not a
    /// retry or the normal sync path. It never deletes a zone or its records.
    func createAfterReviewedDecision() async throws {
        guard try await inspect() == .missing else {
            throw ReaderError.message("The iCloud recovery zone needs review before it can be created.")
        }
        try await checkAccount()
        try await database.create(scope.recoveryZoneID)
        try await checkAccount()
    }
}
