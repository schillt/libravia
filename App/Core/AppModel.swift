import SwiftUI
import Observation
import PDFKit
import CloudKit

@MainActor @Observable final class AppModel {
    var account: Account?
    var provider: JellyfinProvider?
    var store: ReadingStore?
    var cache: BookCache?
    private var savedBooks: DurableBookStore?
    private var downloadJournal: OfflineDownloadJournal?
    private var downloadTask: Task<Void, Never>?
    private var activeDownloadID: String?
    private var activeDownloadToken: UUID?
    private let offlineReservations = OfflineOperationReservations()
    private(set) var downloads: [OfflineDownload] = []
    private var onDeviceLibrary: LocalLibrary?
    private var localFolderLibrary: LocalFolderLibrary?
    private var onDeviceReadingStore: ReadingStore?
    private var readingOnDevice = false
    private(set) var onDeviceBooks: [LocalBookEntry] = []
    private(set) var folderBooks: [FolderBookEntry] = []
    private(set) var folderName: String?
    private(set) var folderProblem: String?
    private(set) var savedCatalog: [Book] = []
    private(set) var storageUsage: StorageUsageSnapshot?
    private var storageRequestID = UUID()
    var libraries: [Library] = []
    var selectedLibrary: String? { didSet { if let account { UserDefaults.standard.set(selectedLibrary, forKey: "library-\(stableKey(account.namespace))") } } }
    var error: String?
    var status: String?
    var connecting = false
    var downloadProgress: Double?
    var openingID: String?
    var reader: PreparedBook?
    private(set) var positionEditionReview: PositionEditionReview?
    private var positionEditionStore: ReadingStore?
    private var editionPositionHolds: Set<String> = []
    private func editionHoldKey(_ reading: ReadingStore, bookID: String) -> String { reading.root.path + "\u{0}" + bookID }
    var readerLaunchBook: Book?
    var conflict: ProgressConflict?
    var syncIssue: ProgressSyncIssue?
    var blockedProgress: [BlockedProgress] {
        (store?.records ?? [:]).compactMap { id, record in
            record.dirty ? record.syncBlock.map { BlockedProgress(id: id, title: record.title, format: record.format, acknowledgedTicks: record.acknowledgedTicks, reason: $0) } : nil
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var catalogSnapshots: [String: CatalogSnapshot] = [:]
    var discoveryBooks: [String: [Book]] = [:]
    var discoveryCollections: [String: [CatalogOption]] = [:]
    private var localBooks: [String: Book] = [:]
    private let artwork = NSCache<NSString, NSData>()
    var profileImageData: Data?
    private var profileImageTask: Task<Data?, Never>?
    func loadProfileImage() async {
        guard profileImageData == nil else { return }
        let current = generation
        let flight: Task<Data?, Never>
        if let existing = profileImageTask { flight = existing }
        else {
            let currentProvider = provider
            flight = Task { try? await currentProvider?.profileImage() }
            profileImageTask = flight
        }
        let image = await flight.value
        guard current == generation else { return }
        profileImageData = image; profileImageTask = nil
    }
    var locallyReadingBooks: [Book] {
        localBooks.values.filter { $0.readingStatus == .inProgress }.sorted {
            (store?.records[$0.id]?.updated ?? .distantPast) > (store?.records[$1.id]?.updated ?? .distantPast)
        }
    }
    func displayedBook(_ book: Book) -> Book {
        guard let local = localBooks[book.id] else { return book }
        var result = book; result.ticks = local.ticks; result.readingStatus = local.readingStatus
        return result
    }
    func cachedCoverImage(_ book: Book, fullSize: Bool = false) -> Data? {
        if book.imageTag == "local", onDeviceBooks.contains(where: { $0.id == book.id && $0.hasCover == true }) { return nil }
        return artwork.object(forKey: "\(fullSize ? "original" : "cover")|\(book.id)|\(book.imageTag ?? "")" as NSString).map { $0 as Data }
    }
    func coverImage(_ book: Book, fullSize: Bool = false) async -> Data? {
        if book.imageTag == "local", onDeviceBooks.contains(where: { $0.id == book.id && $0.hasCover == true }) {
            return await onDeviceLibrary?.cover(for: book.id)
        }
        let key = "\(fullSize ? "original" : "cover")|\(book.id)|\(book.imageTag ?? "")" as NSString
        if let value = artwork.object(forKey: key) { return value as Data }
        let current = generation
        if let value = await savedBooks?.cover(book), current == generation, !Task.isCancelled {
            artwork.setObject(value as NSData, forKey: key, cost: value.count); return value
        }
        guard let value = try? await provider?.cover(book, fullSize: fullSize), current == generation, !Task.isCancelled else { return nil }
        artwork.setObject(value as NSData, forKey: key, cost: value.count); return value
    }
    func authorImage(_ author: BookAuthor) async -> Data? {
        let key = "author|\(author.id ?? author.name)|\(author.imageTag ?? "")" as NSString
        if let value = artwork.object(forKey: key) { return value as Data }
        let current = generation
        guard let value = try? await provider?.authorImage(author), current == generation, !Task.isCancelled else { return nil }
        artwork.setObject(value as NSData, forKey: key, cost: value.count); return value
    }
    var bookmarksRevision = 0
    func readingStore(for book: Book) -> ReadingStore? {
        if readingOnDevice { return readerLaunchBook?.id == book.id ? onDeviceReadingStore : nil }
        if onDeviceBooks.contains(where: { $0.id == book.id }), readerLaunchBook?.id != book.id { return nil }
        return store
    }
    func exportReadingData(for book: Book, asJSON: Bool) throws -> Data {
        guard let reading = readingStore(for: book) else { throw ReaderError.message("The reading data is unavailable.") }
        let source: AnnotationExportSource = readingOnDevice ? .onMyDevice : .jellyfin
        let annotations = reading.annotations[book.id] ?? []
        let bookmarks = reading.bookmarks[book.id] ?? []
        return try asJSON
            ? AnnotationExport.json(title: book.title, author: book.author, source: source, format: book.format, annotations: annotations, bookmarks: bookmarks)
            : AnnotationExport.markdown(title: book.title, author: book.author, source: source, format: book.format, annotations: annotations, bookmarks: bookmarks)
    }
    /// A presentation can be recreated while its original PreparedBook is
    /// still alive. Seed a new reader from the latest durable position rather
    /// than the snapshot captured when this session first opened.
    func currentReaderPreparation(_ prepared: PreparedBook) -> PreparedBook {
        guard reader?.id == prepared.id, readerLaunchBook?.id == prepared.id,
              let record = readingStore(for: prepared.book)?.records[prepared.id],
              record.format == prepared.book.format,
              prepared.contentFingerprint == nil || record.contentFingerprint == prepared.contentFingerprint else { return prepared }
        var current = prepared; current.position = record.position
        return current
    }
    /// Hash before constructing the reader, so an old CFI/page cannot navigate
    /// or emit a save in a replacement edition before the user has reviewed it.
    func finishPreparingReader(_ candidate: PreparedBook, sessionID: UUID, serverSeed: ReadingRecord? = nil) async throws {
        guard sessionID == generation, readerLaunchBook?.id == candidate.id,
              let reading = readingStore(for: candidate.book) else { throw CancellationError() }
        let previous = reading.records[candidate.id]
        reading.invalidateCloudVerification()
        let fingerprint = try await BookFingerprint.prepared(candidate)
        try Task.checkCancellation()
        guard sessionID == generation, readerLaunchBook?.id == candidate.id,
              readingStore(for: candidate.book) === reading,
              reading.records[candidate.id] == previous else { throw ReaderError.message("The book or saved position changed while opening. Close and reopen it.") }
        var prepared = candidate; prepared.contentFingerprint = fingerprint
        var suggested = serverSeed ?? previous ?? ReadingRecord(position: candidate.position, acknowledgedTicks: candidate.book.ticks,
                                                               dirty: false, updated: Date(), title: candidate.book.title, format: candidate.book.format)
        suggested.contentFingerprint = fingerprint
        if let previous, previous.format != candidate.book.format {
            editionPositionHolds.insert(editionHoldKey(reading, bookID: candidate.id))
            var held = previous; held.syncBlock = .edition
            try reading.set(held, id: candidate.id)
            throw ReaderError.message("This item changed book format. Its earlier reading data was kept. Import the replacement separately to read it without mixing locations.")
        }
        let count = candidate.book.format == .pdf ? (PDFDocument(url: candidate.document)?.pageCount ?? 0) : candidate.images.count
        if let previous,
           previous.position.validatedTicks(for: candidate.book.format) == nil ||
           !Bookmark(name: "", position: previous.position).hasValidLocation(format: candidate.book.format, pageCount: count) ||
           (previous.contentFingerprint != fingerprint && (previous.position != ReadingPosition() || previous.dirty)) {
            editionPositionHolds.insert(editionHoldKey(reading, bookID: candidate.id))
            var held = previous; held.syncBlock = .edition
            try reading.set(held, id: candidate.id)
            positionEditionStore = reading
            positionEditionReview = PositionEditionReview(prepared: prepared, previous: held, suggestedRecord: suggested, sessionID: sessionID, pageCount: count)
            reader = nil
            return
        }
        if suggested.syncBlock == .edition { suggested.syncBlock = nil }
        prepared.position = suggested.position
        try reading.set(suggested, id: candidate.id)
        editionPositionHolds.remove(editionHoldKey(reading, bookID: candidate.id))
        reader = prepared
    }
    func resolvePositionEditionReview(_ id: UUID, choice: PositionEditionReview.Choice) {
        guard let review = positionEditionReview, review.id == id,
              review.sessionID == generation, readerLaunchBook?.id == review.prepared.id,
              let reading = readingStore(for: review.prepared.book), reading === positionEditionStore else { return }
        guard choice != .saved || review.canTrySaved else { return }
        guard choice != .suggested || review.canUseSuggested else { return }
        var record = review.suggestedRecord
        switch choice {
        case .saved: record.position = review.previous.position
        case .suggested: break
        case .beginning: record.position = ReadingPosition()
        }
        record.contentFingerprint = review.prepared.contentFingerprint
        record.updated = Date()
        record.syncBlock = nil
        record.dirty = !readingOnDevice && record.position.ticks(for: record.format) != record.acknowledgedTicks
        do {
            try reading.replaceReviewedPosition(record, id: review.prepared.id, expected: review.previous, backupID: review.backupID)
            var prepared = review.prepared; prepared.position = record.position
            positionEditionReview = nil; positionEditionStore = nil; error = nil
            editionPositionHolds.remove(editionHoldKey(reading, bookID: review.prepared.id))
            bookmarksRevision += 1; reader = prepared
        } catch { self.error = UserFacingError.message(error) }
    }
    func loadOnDeviceLibrary() async {
        do {
            if onDeviceLibrary == nil { onDeviceLibrary = try LocalLibrary() }
            if onDeviceReadingStore == nil { onDeviceReadingStore = try ReadingStore(namespace: LocalLibrary.namespace) }
            if localFolderLibrary == nil { localFolderLibrary = try LocalFolderLibrary() }
            onDeviceBooks = await onDeviceLibrary?.catalog() ?? []
            folderName = await localFolderLibrary?.folderName
            folderBooks = await localFolderLibrary?.books ?? []
        } catch { self.error = "Could not open the On My Device library." }
    }
    /// Runs a recovery pass against the same local stores used by the app.
    /// CloudKit configuration and the user-facing trigger are separate; callers
    /// must supply an account fence and a source-specific zone.
    private(set) var standaloneRecoveryRunning = false
    private(set) var automaticRecoveryStatus: String?
    private var automaticRecoverySchedule = AutomaticRecoveryRetryPolicy()
    private var automaticRecoveryAttempt = false
    private var standaloneRecoveryEpoch = UUID()
    func runStandaloneRecovery(scope: CloudReadingScope, zoneID: CKRecordZone.ID,
                               pages: any CloudRecoveryPageSource, database: any CloudReadingRecordDatabase,
                               accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws -> StandaloneRecoveryCycle.Report {
        guard !standaloneRecoveryRunning, reader == nil, openingID == nil else {
            throw ReaderError.message("Close the reader before starting recovery.")
        }
        guard let reservation = offlineReservations.beginLocalImport() else {
            throw ReaderError.message("Wait for the current import or removal to finish.")
        }
        standaloneRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch
        defer { standaloneRecoveryRunning = false; offlineReservations.endLocalImport(reservation) }
        await loadOnDeviceLibrary()
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              reader == nil, openingID == nil else {
            throw ReaderError.message("The device library is unavailable for recovery.")
        }
        let fence: @MainActor () async throws -> Bool = { [weak self] in
            guard let self, self.standaloneRecoveryRunning, self.reader == nil, self.openingID == nil,
                  self.standaloneRecoveryEpoch == epoch,
                  self.onDeviceReadingStore === reading, self.onDeviceLibrary === library else { return false }
            let valid = try await accountIsCurrent()
            return valid && self.standaloneRecoveryRunning && self.reader == nil && self.openingID == nil &&
                self.standaloneRecoveryEpoch == epoch && self.onDeviceReadingStore === reading && self.onDeviceLibrary === library
        }
        let stager = try CloudBookStager(scope: scope)
        let journal = try CloudBookJournal(scope: scope, stager: stager)
        let cycle = try StandaloneRecoveryCycle(scope: scope, library: library, reading: reading, journal: journal,
                                                 zoneID: zoneID, pages: pages, database: database,
                                                 accountIsCurrent: fence)
        do {
            let result = try await cycle.run()
            onDeviceBooks = await library.catalog()
            bookmarksRevision &+= 1
            return result
        } catch {
            onDeviceBooks = await library.catalog()
            bookmarksRevision &+= 1
            throw error
        }
    }

    /// Integrates a Jellyfin reading-data pass with the active reader. Incoming
    /// positions remain staged while the book is open, avoiding an unexpected
    /// jump or a subsequent reader callback overwriting the recovered position.
    private(set) var jellyfinRecoveryRunning = false
    private(set) var automaticJellyfinRecoveryStatus: String?
    private var automaticJellyfinRecoverySchedule = AutomaticRecoveryRetryPolicy()
    private var automaticJellyfinRecoveryAttempt = false
    private var automaticJellyfinRecoveryBook: String?

    func configureAutomaticJellyfinRecovery(enabled: Bool, scope: CloudReadingScope? = nil, defaults: UserDefaults = .standard) {
        guard !enabled || scope != nil else { return }
        defaults.set(enabled, forKey: "automaticJellyfinRecovery")
        if enabled, let scope {
            defaults.set(scope.cloudAccountKey, forKey: "automaticJellyfinRecoveryAccount")
            defaults.set(scope.sourceKey, forKey: "automaticJellyfinRecoverySource")
        } else {
            defaults.removeObject(forKey: "automaticJellyfinRecoveryAccount")
            defaults.removeObject(forKey: "automaticJellyfinRecoverySource")
        }
        automaticJellyfinRecoverySchedule.reset(); automaticJellyfinRecoveryStatus = nil
    }

    /// Foreground only, while the same Jellyfin book remains open. A new or
    /// removed zone is never created or reset by an automatic attempt.
    func retryAutomaticJellyfinRecovery(defaults: UserDefaults = .standard,
        makeService: (@MainActor () throws -> StandaloneCloudRecoveryService)? = nil) async {
        guard defaults.bool(forKey: "automaticJellyfinRecovery"), let account,
              let cloudAccount = defaults.string(forKey: "automaticJellyfinRecoveryAccount"),
              let sourceKey = defaults.string(forKey: "automaticJellyfinRecoverySource"),
              let currentSource = try? CloudReadingSource.scopedJellyfin(account).key(),
              sourceKey == currentSource, canRecoverOpenJellyfinBook, let bookID = reader?.id,
              !automaticJellyfinRecoveryAttempt, !jellyfinRecoveryRunning else { return }
        if automaticJellyfinRecoveryBook != bookID {
            automaticJellyfinRecoveryBook = bookID; automaticJellyfinRecoverySchedule.reset()
        }
        guard automaticJellyfinRecoverySchedule.isDue(at: Date()) else { return }
        automaticJellyfinRecoveryAttempt = true
        defer { automaticJellyfinRecoveryAttempt = false }
        func enabledForSameSession() -> Bool {
            defaults.bool(forKey: "automaticJellyfinRecovery") &&
                defaults.string(forKey: "automaticJellyfinRecoveryAccount") == cloudAccount &&
                defaults.string(forKey: "automaticJellyfinRecoverySource") == sourceKey &&
                !Task.isCancelled && canRecoverOpenJellyfinBook && reader?.id == bookID &&
                account.namespace == self.account?.namespace
        }
        do {
            let service = try makeService?() ?? makeJellyfinCloudRecoveryService()
            let inspection = try await service.inspect()
            guard enabledForSameSession(), inspection.scope.cloudAccountKey == cloudAccount,
                  inspection.scope.sourceKey == sourceKey, inspection.zoneState == .present else {
                if enabledForSameSession() {
                    automaticJellyfinRecoveryStatus = "Reading recovery is paused. Check your accounts and recovery settings."
                    automaticJellyfinRecoverySchedule.recordFailure(at: Date())
                }
                return
            }
            let result = try await service.run(inspection, ifEnabled: enabledForSameSession)
            guard enabledForSameSession() else { return }
            if !result.failures.isEmpty {
                automaticJellyfinRecoveryStatus = "Some reading changes are waiting for iCloud. LibraVia will try again."
                automaticJellyfinRecoverySchedule.recordFailure(at: Date())
            } else {
                automaticJellyfinRecoveryStatus = result.pendingItems > 0 || result.needsReview > 0
                    ? "Some reading changes need review." : nil
                automaticJellyfinRecoverySchedule.recordSuccess(at: Date())
            }
        } catch {
            guard enabledForSameSession() else { return }
            automaticJellyfinRecoveryStatus = "Reading recovery is waiting. Your local reading data is kept."
            automaticJellyfinRecoverySchedule.recordFailure(at: Date())
        }
    }

    func runJellyfinReadingRecovery(scope: CloudReadingScope, zoneID: CKRecordZone.ID,
                                    pages: any CloudRecoveryPageSource, database: any CloudReadingRecordDatabase,
                                    accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws -> JellyfinReadingRecoveryCycle.Report {
        guard !jellyfinRecoveryRunning, !readingOnDevice, let account, let provider, let reading = store,
              let prepared = reader, readerLaunchBook?.id == prepared.id else {
            throw ReaderError.message("Open a Jellyfin book before recovering its reading data.")
        }
        let source = try CloudReadingSource.scopedJellyfin(account)
        guard scope.isValid, scope.sourceKey == (try source.key()) else {
            throw ReaderError.message("The iCloud recovery account or Jellyfin source changed.")
        }
        jellyfinRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch, session = generation
        defer { jellyfinRecoveryRunning = false }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.jellyfinRecoveryRunning, self.generation == session,
                  self.standaloneRecoveryEpoch == epoch, !self.readingOnDevice, self.store === reading,
                  self.provider === provider, self.account?.namespace == account.namespace, self.readerLaunchBook?.id == prepared.id,
                  let active = self.reader else { return false }
            return active.id == prepared.id && active.book.format == prepared.book.format &&
                active.directory == prepared.directory && active.document == prepared.document && active.images == prepared.images
        }
        let fence: @MainActor () async throws -> Bool = {
            guard current(), try await accountIsCurrent(), current() else { return false }
            return true
        }
        guard try await fence() else { throw CancellationError() }
        if let atomic = reading.cloudReadingStore {
            guard atomic.scope == scope, atomic.localToCloudBookIDs == nil else {
                throw ReaderError.message("This reading data belongs to another iCloud account. Review it before syncing.")
            }
        } else { try reading.prepareAtomicReading(scope: scope) }
        guard try await fence() else { throw CancellationError() }
        let cycle = try JellyfinReadingRecoveryCycle(scope: scope, source: source, reading: reading, zoneID: zoneID,
                                                     pages: pages, database: database, accountIsCurrent: fence,
                                                     stillCurrent: current, mayApplyPosition: { false },
                                                     freshBook: { try await provider.book(id: prepared.id) })
        do {
            let result = try await cycle.run(prepared: prepared)
            guard current() else { throw CancellationError() }
            bookmarksRevision &+= 1
            return result
        } catch {
            if current() { bookmarksRevision &+= 1 }
            throw error
        }
    }

    func pendingJellyfinReadingReviews(scope: CloudReadingScope) -> [JellyfinReadingReviewItem] {
        guard canRecoverOpenJellyfinBook, let reading = store, let prepared = reader,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else { return [] }
        return JellyfinReadingReviewItem.collect(store: atomic, book: prepared.book)
    }

    func pendingJellyfinIncomingReading(scope: CloudReadingScope) -> [JellyfinIncomingReadingItem] {
        guard canRecoverOpenJellyfinBook, let reading = store, let prepared = reader,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else { return [] }
        return JellyfinIncomingReadingItem.collect(store: atomic, book: prepared.book)
    }

    func confirmJellyfinIncomingReading(_ item: JellyfinIncomingReadingItem, scope: CloudReadingScope,
                                        accountIsCurrent: @escaping @MainActor () async throws -> Bool,
                                        stillReadingSamePosition: @escaping @MainActor () -> Bool = { true },
                                        refreshBook: (@MainActor () async throws -> Book)? = nil) async throws {
        let positionDeletion = item.key.kind == .position && item.payload == nil
        guard (positionDeletion || (item.key.kind != .position && item.editionFingerprint == nil)),
              !jellyfinRecoveryRunning, canRecoverOpenJellyfinBook, let account, let provider, let reading = store,
              let prepared = reader, item.bookID == prepared.id,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("The reading session changed. Review the item again.")
        }
        let source = try CloudReadingSource.scopedJellyfin(account)
        guard scope.sourceKey == (try source.key()) else { throw ReaderError.message("The Jellyfin account changed.") }
        jellyfinRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch, session = generation
        defer { jellyfinRecoveryRunning = false }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.jellyfinRecoveryRunning, self.generation == session,
                  self.standaloneRecoveryEpoch == epoch, self.canRecoverOpenJellyfinBook,
                  self.store === reading, reading.cloudReadingStore === atomic, self.provider === provider,
                  self.account?.namespace == account.namespace,
                  let active = self.reader else { return false }
            return active.id == prepared.id && active.book.format == prepared.book.format &&
                active.directory == prepared.directory && active.document == prepared.document && active.images == prepared.images &&
                (!positionDeletion || stillReadingSamePosition())
        }
        func check() async throws {
            guard current(), try await accountIsCurrent(), current() else {
                throw ReaderError.message("The account or book changed. Review the item again.")
            }
        }
        try await check()
        let fingerprint = try await reading.verifyJellyfinEdition(prepared, source: source, stillCurrent: current)
        try await check()
        guard let currentItem = atomic.outbox[item.key.recordName],
              currentItem.entry.current.revision == item.revision,
              currentItem.entry.current.editionFingerprint == item.editionFingerprint,
              !positionDeletion || currentItem.entry.current.payload == nil else {
            throw ReaderError.message("The reading change changed. Review it again.")
        }
        var checkedBook = prepared.book
        if positionDeletion {
            if let refreshBook { checkedBook = try await refreshBook() }
            else { checkedBook = try await provider.book(id: prepared.id) }
            try await check()
            guard checkedBook.id == prepared.id, checkedBook.format == prepared.book.format else {
                throw ReaderError.message("The book changed. Review the position again.")
            }
        }
        try reading.applyObservedCloudVersion(item.key, book: checkedBook, verifiedEditionFingerprint: fingerprint,
                                              expectedRevision: item.revision, confirmLegacyEdition: item.editionFingerprint == nil,
                                              confirmedJellyfinDeletionTicks: positionDeletion ? prepared.book.ticks : nil)
        bookmarksRevision &+= 1
    }

    @discardableResult func reviewJellyfinReadingItem(_ item: JellyfinReadingReviewItem, scope: CloudReadingScope,
                                   choice: CloudAtomicReadingStore.ConflictChoice?,
                                   accountIsCurrent: @escaping @MainActor () async throws -> Bool,
                                   confirmUnverifiedEdition: Bool = false,
                                   stillReadingSamePosition: @escaping @MainActor () -> Bool = { true },
                                   refreshBook: (@MainActor () async throws -> Book)? = nil) async throws -> ReadingPosition? {
        guard !jellyfinRecoveryRunning, canRecoverOpenJellyfinBook, let account, let provider, let reading = store,
              let prepared = reader, let atomic = reading.cloudReadingStore, atomic.scope == scope,
              item.bookID == prepared.id else { throw ReaderError.message("The reading session changed. Review the item again.") }
        let source = try CloudReadingSource.scopedJellyfin(account)
        guard scope.sourceKey == (try source.key()) else { throw ReaderError.message("The Jellyfin account changed.") }
        jellyfinRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch, session = generation
        defer { jellyfinRecoveryRunning = false }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.jellyfinRecoveryRunning, self.generation == session,
                  self.standaloneRecoveryEpoch == epoch, self.canRecoverOpenJellyfinBook,
                  self.store === reading, reading.cloudReadingStore === atomic, self.provider === provider,
                  self.account?.namespace == account.namespace,
                  let active = self.reader else { return false }
            return active.id == prepared.id && active.book.format == prepared.book.format &&
                active.directory == prepared.directory && active.document == prepared.document && active.images == prepared.images &&
                (item.key.kind != .position || item.remote == nil || stillReadingSamePosition())
        }
        func check() async throws {
            guard current(), try await accountIsCurrent(), current() else {
                throw ReaderError.message("The account or book changed. Review the item again.")
            }
        }
        try await check()
        let fingerprint = try await reading.verifyJellyfinEdition(prepared, source: source, stillCurrent: current)
        try await check()
        var selectedPosition: ReadingPosition?
        if let remote = item.remote, let choice {
            var checkedBook = prepared.book
            if item.key.kind == .position {
                let selected = choice == .local ? item.current : remote
                if case .position(let value) = selected.payload {
                    try validateRecoveredJellyfinPosition(value.position, prepared: prepared)
                    selectedPosition = value.position
                } else if selected.payload != nil {
                    throw ReaderError.message("This reading position is invalid.")
                }
                if let refreshBook { checkedBook = try await refreshBook() }
                else { checkedBook = try await provider.book(id: prepared.id) }
                try await check()
                guard checkedBook.id == prepared.id, checkedBook.format == prepared.book.format else {
                    throw ReaderError.message("The book changed. Review the position again.")
                }
            }
            let selected = choice == .local ? item.current : remote
            try reading.resolveCloudConflict(item.key, book: checkedBook, verifiedEditionFingerprint: fingerprint,
                                             expectedLocalRevision: item.current.revision, remoteRevision: remote.revision, choice: choice,
                                             confirmUnverifiedEdition: confirmUnverifiedEdition,
                                             confirmedJellyfinDeletionTicks: item.key.kind == .position && selected.payload == nil ? prepared.book.ticks : nil)
        } else {
            guard item.remote == nil, choice == nil else {
                throw ReaderError.message("This change needs further review.")
            }
            if item.key.kind == .position && item.current.payload == nil {
                let fresh: Book
                if let refreshBook { fresh = try await refreshBook() }
                else { fresh = try await provider.book(id: prepared.id) }
                try await check()
                guard stillReadingSamePosition(), fresh.id == prepared.id, fresh.format == prepared.book.format,
                      fresh.ticks == prepared.book.ticks,
                      reading.records[prepared.id].map({ !$0.dirty && $0.acknowledgedTicks == fresh.ticks }) ?? true else {
                    throw ReaderError.message("The server position changed or has unsynced edits. Review the deletion again.")
                }
            }
            try reading.certifyReviewedLocalVersion(item.key, book: prepared.book, expectedRevision: item.current.revision,
                                                    verifiedEditionFingerprint: fingerprint)
        }
        bookmarksRevision &+= 1
        return selectedPosition
    }

    func stagedJellyfinPosition(scope: CloudReadingScope) -> JellyfinPositionCandidate? {
        guard canRecoverOpenJellyfinBook, let reading = store, let prepared = reader,
              let atomic = reading.cloudReadingStore, atomic.scope == scope,
              let key = try? CloudReadingKey(scope: scope, bookID: prepared.id, kind: .position),
              let item = atomic.outbox[key.recordName], item.pendingApplication == true,
              item.entry.conflicts.isEmpty,
              case .position(let value) = item.entry.current.payload else { return nil }
        return JellyfinPositionCandidate(key: key, revision: item.entry.current.revision, position: value.position,
                                         editionFingerprint: item.entry.current.editionFingerprint)
    }

    func applyStagedJellyfinPosition(_ candidate: JellyfinPositionCandidate, scope: CloudReadingScope,
                                     stillReadingSamePosition: @escaping @MainActor () -> Bool,
                                     accountIsCurrent: @escaping @MainActor () async throws -> Bool,
                                     confirmLegacyEdition: Bool = false,
                                     refreshBook: (@MainActor () async throws -> Book)? = nil) async throws -> ReadingPosition {
        guard !jellyfinRecoveryRunning, canRecoverOpenJellyfinBook, let account, let provider, let reading = store,
              let prepared = reader, let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("The reading session changed. Check the position again.")
        }
        let source = try CloudReadingSource.scopedJellyfin(account)
        guard scope.sourceKey == (try source.key()) else { throw ReaderError.message("The Jellyfin account changed.") }
        jellyfinRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch, session = generation
        defer { jellyfinRecoveryRunning = false }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.jellyfinRecoveryRunning, self.generation == session,
                  self.standaloneRecoveryEpoch == epoch, self.canRecoverOpenJellyfinBook,
                  self.store === reading, reading.cloudReadingStore === atomic, self.provider === provider,
                  self.account?.namespace == account.namespace,
                  let active = self.reader, active.id == prepared.id, active.book.format == prepared.book.format,
                  active.directory == prepared.directory, active.document == prepared.document,
                  active.images == prepared.images else { return false }
            return stillReadingSamePosition()
        }
        func check() async throws {
            guard current(), try await accountIsCurrent(), current() else {
                throw ReaderError.message("The account or reading position changed. Check it again.")
            }
        }
        try await check()
        let fingerprint = try await reading.verifyJellyfinEdition(prepared, source: source, stillCurrent: current)
        try await check()
        try validateRecoveredJellyfinPosition(candidate.position, prepared: prepared)
        let fresh: Book
        if let refreshBook { fresh = try await refreshBook() }
        else { fresh = try await provider.book(id: prepared.id) }
        try await check()
        guard fresh.id == prepared.id, fresh.format == prepared.book.format,
              let item = atomic.outbox[candidate.key.recordName], item.entry.current.revision == candidate.revision,
              item.entry.current.editionFingerprint == candidate.editionFingerprint,
              case .position(let value) = item.entry.current.payload, value.position == candidate.position else {
            throw ReaderError.message("The book or saved position changed. Review it again.")
        }
        try reading.applyObservedCloudVersion(candidate.key, book: fresh, verifiedEditionFingerprint: fingerprint,
                                              expectedRevision: candidate.revision, confirmLegacyEdition: confirmLegacyEdition)
        return candidate.position
    }

    private func validateRecoveredJellyfinPosition(_ position: ReadingPosition, prepared: PreparedBook) throws {
        switch prepared.book.format {
        case .epub:
            guard ReaderPositionValidation.epub(cfi: position.cfi, fraction: position.fraction) != nil else {
                throw ReaderError.message("The saved position is invalid for this book.")
            }
        case .pdf:
            guard let pdf = PDFDocument(url: prepared.document), !pdf.isLocked,
                  position.page >= 0, position.page < pdf.pageCount else {
                throw ReaderError.message("The saved page is unavailable in this book.")
            }
        case .cbz:
            guard position.page >= 0, position.page < prepared.images.count else {
                throw ReaderError.message("The saved page is unavailable in this book.")
            }
        case .unsupported:
            throw ReaderError.message("This book format is unavailable for recovery.")
        }
    }

    func configureAutomaticRecovery(enabled: Bool, scope: CloudReadingScope) {
        UserDefaults.standard.set(enabled, forKey: "automaticStandaloneRecovery")
        if enabled { UserDefaults.standard.set(scope.cloudAccountKey, forKey: "automaticStandaloneRecoveryAccount") }
        else { UserDefaults.standard.removeObject(forKey: "automaticStandaloneRecoveryAccount") }
        automaticRecoverySchedule.reset(); automaticRecoveryStatus = nil
    }

    func disableAutomaticRecovery() {
        UserDefaults.standard.set(false, forKey: "automaticStandaloneRecovery")
        UserDefaults.standard.removeObject(forKey: "automaticStandaloneRecoveryAccount")
        automaticRecoverySchedule.reset(); automaticRecoveryStatus = nil
    }

    /// Called only while the browsing scene is active. Retry remains paused
    /// during reading, after account changes, and when the user disables it.
    func retryAutomaticStandaloneRecovery() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "automaticStandaloneRecovery"),
              let account = defaults.string(forKey: "automaticStandaloneRecoveryAccount"),
              !automaticRecoveryAttempt, !standaloneRecoveryRunning, reader == nil, openingID == nil,
              automaticRecoverySchedule.isDue(at: Date()) else { return }
        automaticRecoveryAttempt = true
        defer { automaticRecoveryAttempt = false }
        func enabledForSameAccount() -> Bool {
            defaults.bool(forKey: "automaticStandaloneRecovery") &&
                defaults.string(forKey: "automaticStandaloneRecoveryAccount") == account && !Task.isCancelled
        }
        do {
            let service = try makeStandaloneCloudRecoveryService()
            let inspection = try await service.inspect()
            guard enabledForSameAccount(), inspection.scope.cloudAccountKey == account,
                  inspection.zoneState == .present else {
                automaticRecoveryStatus = "Private recovery is paused. Check your iCloud account and recovery settings."
                automaticRecoverySchedule.recordFailure(at: Date()); return
            }
            let result = try await service.run(inspection, ifEnabled: enabledForSameAccount)
            guard enabledForSameAccount() else { return }
            if !result.failures.isEmpty {
                automaticRecoveryStatus = "Some changes are waiting for iCloud. LibraVia will try again."
                automaticRecoverySchedule.recordFailure(at: Date())
            } else {
                automaticRecoveryStatus = result.pendingItems > 0 || result.needsReview > 0
                    ? "Some private recovery changes need attention." : nil
                automaticRecoverySchedule.recordSuccess(at: Date())
            }
        } catch {
            guard enabledForSameAccount() else { return }
            automaticRecoveryStatus = "Private recovery is waiting. Your local books remain available."
            automaticRecoverySchedule.recordFailure(at: Date())
        }
    }

    func pendingStandaloneReadingReviews(scope: CloudReadingScope) async throws -> [StandaloneReadingReviewItem] {
        await loadOnDeviceLibrary()
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("Reading data is unavailable for this iCloud account.")
        }
        let books = await library.catalog()
        guard onDeviceReadingStore === reading, reading.cloudReadingStore === atomic else { throw CancellationError() }
        return StandaloneReadingReviewItem.collect(store: atomic, books: books)
    }

    func pendingStandaloneIncomingReading(scope: CloudReadingScope) async throws -> [StandaloneIncomingReadingItem] {
        await loadOnDeviceLibrary()
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("Reading data is unavailable for this iCloud account.")
        }
        let books = await library.catalog()
        guard onDeviceReadingStore === reading, reading.cloudReadingStore === atomic else { throw CancellationError() }
        return StandaloneIncomingReadingItem.collect(store: atomic, books: books)
    }

    func confirmStandaloneIncomingReading(_ item: StandaloneIncomingReadingItem, scope: CloudReadingScope,
                                          accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws {
        guard item.editionFingerprint == nil, !standaloneRecoveryRunning, reader == nil, openingID == nil,
              let reservation = offlineReservations.beginLocalImport() else {
            throw ReaderError.message("Close the reader and review this change again.")
        }
        standaloneRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch
        defer { standaloneRecoveryRunning = false; offlineReservations.endLocalImport(reservation) }
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("Reading data is unavailable for this iCloud account.")
        }
        func check() async throws {
            guard !Task.isCancelled, standaloneRecoveryEpoch == epoch, reader == nil, openingID == nil,
                  onDeviceLibrary === library, onDeviceReadingStore === reading, reading.cloudReadingStore === atomic,
                  try await accountIsCurrent(), standaloneRecoveryEpoch == epoch, reader == nil, openingID == nil else {
                throw ReaderError.message("The account or book changed. Review the item again.")
            }
        }
        try await check()
        guard let book = await library.catalog().first(where: { $0.id == item.book.id }),
              book.cloudIdentities?[scope.cloudAccountKey]?.readingBookID == item.cloudBookID else {
            throw ReaderError.message("The book identity changed. Review the item again.")
        }
        try await check()
        let fingerprint = try await reading.verifyStandaloneEdition(book, library: library, scope: scope)
        try await check()
        guard atomic.outbox[item.key.recordName]?.entry.current.editionFingerprint == nil else {
            throw ReaderError.message("The reading change changed. Review it again.")
        }
        try reading.applyObservedCloudVersion(item.key, book: book.book, verifiedEditionFingerprint: fingerprint,
                                              expectedRevision: item.revision, confirmLegacyEdition: true)
        bookmarksRevision &+= 1
    }

    func checkStandaloneRecoveryScope(_ scope: CloudReadingScope) async throws {
        await loadOnDeviceLibrary()
        guard let reading = onDeviceReadingStore else { throw ReaderError.message("The device library is unavailable for recovery.") }
        try reading.requireRecoveryScope(scope)
    }

    func canSwitchStandaloneRecoveryAccount(scope: CloudReadingScope) -> Bool {
        guard let reading = onDeviceReadingStore, let old = reading.cloudReadingStore,
              old.localToCloudBookIDs != nil, scope.isValid,
              scope.sourceKey == (try? CloudReadingSource.imported.key()),
              old.scope.sourceKey == scope.sourceKey, old.scope.cloudAccountKey != scope.cloudAccountKey else { return false }
        return (try? reading.requireRecoveryScope(old.scope)) != nil
    }

    func switchStandaloneRecoveryAccount(scope: CloudReadingScope, database: CKDatabase,
                                         accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws {
        guard !standaloneRecoveryRunning, reader == nil, openingID == nil,
              let reservation = offlineReservations.beginLocalImport() else {
            throw ReaderError.message("Close the reader and wait for other book operations to finish.")
        }
        standaloneRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch
        defer { standaloneRecoveryRunning = false; offlineReservations.endLocalImport(reservation) }
        await loadOnDeviceLibrary()
        guard canSwitchStandaloneRecoveryAccount(scope: scope), let library = onDeviceLibrary,
              let reading = onDeviceReadingStore, let old = reading.cloudReadingStore else {
            throw ReaderError.message("The recovery account or library changed. Review it again.")
        }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.standaloneRecoveryRunning, self.reader == nil, self.openingID == nil,
                  self.standaloneRecoveryEpoch == epoch, self.onDeviceLibrary === library,
                  self.onDeviceReadingStore === reading, reading.cloudReadingStore === old else { return false }
            return true
        }
        let stager = try CloudBookStager(scope: scope)
        let journal = try CloudBookJournal(scope: scope, stager: stager)
        let switcher = try StandaloneRecoveryAccountSwitch(target: scope, reading: reading, library: library, journal: journal,
            pages: CloudKitRecoveryPageSource(database: database, zoneID: scope.recoveryZoneID),
            zones: CloudKitRecoveryZoneDatabase(database: database), accountIsCurrent: accountIsCurrent, stillCurrent: current)
        do {
            // The confirmation explains that source-only cloud items remain in the earlier account.
            try await switcher.runAfterConfirmation(allowSourceOnlyItems: true)
            onDeviceBooks = await library.catalog(); bookmarksRevision &+= 1
        } catch {
            onDeviceBooks = await library.catalog(); bookmarksRevision &+= 1
            throw error
        }
    }

    func checkJellyfinRecoveryScope(_ scope: CloudReadingScope) throws {
        guard canRecoverOpenJellyfinBook, let account, let reading = store,
              scope.sourceKey == (try CloudReadingSource.scopedJellyfin(account).key()) else {
            throw ReaderError.message("The Jellyfin account or book changed. Open the book and try again.")
        }
        try reading.requireRecoveryScope(scope)
    }

    func canReviewEarlierJellyfinRecovery(scope: CloudReadingScope) -> Bool {
        guard canRecoverOpenJellyfinBook, let account, let reading = store, reading.belongs(to: account),
              let old = reading.cloudReadingStore, old.localToCloudBookIDs == nil,
              old.scope.cloudAccountKey == scope.cloudAccountKey,
              scope.sourceKey == (try? CloudReadingSource.scopedJellyfin(account).key()),
              old.scope.sourceKey == (try? CloudReadingSource.jellyfin(serverID: account.serverID, userID: account.userID).key()) else { return false }
        return (try? reading.requireRecoveryScope(old.scope)) != nil
    }

    func canSwitchJellyfinRecoveryAccount(scope: CloudReadingScope) -> Bool {
        guard canRecoverOpenJellyfinBook, let account, let reading = store, reading.belongs(to: account),
              let old = reading.cloudReadingStore, old.localToCloudBookIDs == nil, scope.isValid,
              scope.sourceKey == (try? CloudReadingSource.scopedJellyfin(account).key()),
              old.scope.sourceKey == scope.sourceKey, old.scope.cloudAccountKey != scope.cloudAccountKey else { return false }
        return (try? reading.requireRecoveryScope(old.scope)) != nil
    }

    func switchJellyfinRecoveryAccount(scope: CloudReadingScope, database: CKDatabase,
                                       accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws {
        guard !jellyfinRecoveryRunning, canSwitchJellyfinRecoveryAccount(scope: scope),
              let account, let reading = store, let prepared = reader, readerLaunchBook?.id == prepared.id else {
            throw ReaderError.message("The Jellyfin account or book changed. Open the book and try again.")
        }
        jellyfinRecoveryRunning = true
        let session = generation, epoch = standaloneRecoveryEpoch
        defer { jellyfinRecoveryRunning = false }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.jellyfinRecoveryRunning, self.generation == session,
                  self.standaloneRecoveryEpoch == epoch, self.store === reading,
                  self.account?.namespace == account.namespace, self.readerLaunchBook?.id == prepared.id,
                  let active = self.reader, !self.readingOnDevice else { return false }
            return active.id == prepared.id && active.book.format == prepared.book.format &&
                active.directory == prepared.directory && active.document == prepared.document && active.images == prepared.images
        }
        let switcher = try JellyfinRecoveryAccountSwitch(account: account, target: scope, reading: reading,
            pages: CloudKitRecoveryPageSource(database: database, zoneID: scope.recoveryZoneID),
            zones: CloudKitRecoveryZoneDatabase(database: database), accountIsCurrent: accountIsCurrent, stillCurrent: current)
        try await switcher.runAfterConfirmation()
        bookmarksRevision &+= 1
    }

    func migrateEarlierJellyfinRecovery(scope: CloudReadingScope, database: CKDatabase,
                                        accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws {
        guard !jellyfinRecoveryRunning, canReviewEarlierJellyfinRecovery(scope: scope),
              let account, let reading = store, let old = reading.cloudReadingStore,
              let prepared = reader, readerLaunchBook?.id == prepared.id else {
            throw ReaderError.message("The Jellyfin account or book changed. Open the book and try again.")
        }
        jellyfinRecoveryRunning = true
        let session = generation, epoch = standaloneRecoveryEpoch
        defer { jellyfinRecoveryRunning = false }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.jellyfinRecoveryRunning, self.generation == session,
                  self.standaloneRecoveryEpoch == epoch, self.store === reading,
                  self.account?.namespace == account.namespace, self.readerLaunchBook?.id == prepared.id,
                  let active = self.reader, !self.readingOnDevice else { return false }
            return active.id == prepared.id && active.book.format == prepared.book.format &&
                active.directory == prepared.directory && active.document == prepared.document && active.images == prepared.images
        }
        let migration = try LegacyJellyfinMigration(account: account, target: scope, reading: reading,
            pages: CloudKitRecoveryPageSource(database: database, zoneID: old.scope.recoveryZoneID),
            zones: CloudKitRecoveryZoneDatabase(database: database), accountIsCurrent: accountIsCurrent, stillCurrent: current)
        try await migration.runAfterLibraryConfirmation()
        bookmarksRevision &+= 1
    }

    func pendingStandaloneBookConflicts(scope: CloudReadingScope) async throws -> [StandaloneBookConflictItem] {
        await loadOnDeviceLibrary()
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("The device library is unavailable for this iCloud account.")
        }
        let stager = try CloudBookStager(scope: scope)
        let journal = try CloudBookJournal(scope: scope, stager: stager)
        let books = await library.catalog()
        guard onDeviceLibrary === library, onDeviceReadingStore === reading, reading.cloudReadingStore === atomic else { throw CancellationError() }
        return StandaloneBookConflictItem.collect(journal: journal, books: books)
    }

    func standaloneDeletedBackups(scope: CloudReadingScope) async throws -> [StandaloneDeletedBackupItem] {
        await loadOnDeviceLibrary()
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("The device library is unavailable for this iCloud account.")
        }
        let stager = try CloudBookStager(scope: scope)
        let journal = try CloudBookJournal(scope: scope, stager: stager)
        let books = await library.catalog()
        guard onDeviceLibrary === library, onDeviceReadingStore === reading, reading.cloudReadingStore === atomic else { throw CancellationError() }
        return StandaloneDeletedBackupItem.collect(journal: journal, books: books)
    }

    func reviewStandaloneDeletedBackup(_ item: StandaloneDeletedBackupItem, scope: CloudReadingScope, restoreBackup: Bool,
                                       accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws {
        guard !standaloneRecoveryRunning, reader == nil, openingID == nil,
              let reservation = offlineReservations.beginLocalImport() else {
            throw ReaderError.message("Close the reader and wait for other book operations to finish.")
        }
        standaloneRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch
        defer { standaloneRecoveryRunning = false; offlineReservations.endLocalImport(reservation) }
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("The device library is unavailable for this iCloud account.")
        }
        let fence: @MainActor () async throws -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.standaloneRecoveryRunning, self.standaloneRecoveryEpoch == epoch,
                  self.reader == nil, self.openingID == nil, self.onDeviceLibrary === library,
                  self.onDeviceReadingStore === reading, reading.cloudReadingStore === atomic else { return false }
            let valid = try await accountIsCurrent()
            return valid && !Task.isCancelled && self.standaloneRecoveryEpoch == epoch && self.reader == nil && self.openingID == nil &&
                self.onDeviceLibrary === library && self.onDeviceReadingStore === reading && reading.cloudReadingStore === atomic
        }
        guard try await fence() else { throw ReaderError.message("The account or book changed. Review the deletion again.") }
        let stager = try CloudBookStager(scope: scope)
        let journal = try CloudBookJournal(scope: scope, stager: stager)
        let reviewer = StandaloneBookDeletionReview(scope: scope, library: library, journal: journal, accountIsCurrent: fence)
        try await reviewer.resolve(bookID: item.bookID, localID: item.book.id, revision: item.revision, restoreBackup: restoreBackup)
    }

    func resolveStandaloneBookConflict(_ item: StandaloneBookConflictItem, scope: CloudReadingScope,
                                       choice: CloudBookJournal.ConflictChoice,
                                       accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws {
        guard !standaloneRecoveryRunning, reader == nil, openingID == nil,
              let reservation = offlineReservations.beginLocalImport() else {
            throw ReaderError.message("Close the reader and wait for other book operations to finish.")
        }
        standaloneRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch
        defer { standaloneRecoveryRunning = false; offlineReservations.endLocalImport(reservation) }
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("The device library is unavailable for this iCloud account.")
        }
        let fence: @MainActor () async throws -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.standaloneRecoveryRunning, self.standaloneRecoveryEpoch == epoch,
                  self.reader == nil, self.openingID == nil, self.onDeviceLibrary === library,
                  self.onDeviceReadingStore === reading, reading.cloudReadingStore === atomic else { return false }
            let valid = try await accountIsCurrent()
            return valid && !Task.isCancelled && self.standaloneRecoveryEpoch == epoch && self.reader == nil && self.openingID == nil &&
                self.onDeviceLibrary === library && self.onDeviceReadingStore === reading && reading.cloudReadingStore === atomic
        }
        guard try await fence() else { throw ReaderError.message("The account or book changed. Review the conflict again.") }
        let stager = try CloudBookStager(scope: scope)
        let journal = try CloudBookJournal(scope: scope, stager: stager)
        let resolver = try StandaloneBookConflictResolution(scope: scope, library: library, reading: reading,
                                                            journal: journal, accountIsCurrent: fence)
        do {
            try await resolver.resolve(bookID: item.bookID, expectedCurrent: item.current.revision,
                                       remoteRevision: item.remote.revision, choice: choice)
            onDeviceBooks = await library.catalog(); bookmarksRevision &+= 1
        } catch {
            onDeviceBooks = await library.catalog(); bookmarksRevision &+= 1
            throw error
        }
    }

    func pendingStandaloneReadingConflicts(scope: CloudReadingScope) async throws -> [StandaloneReadingConflictItem] {
        await loadOnDeviceLibrary()
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("Reading data is unavailable for this iCloud account.")
        }
        let books = await library.catalog()
        guard onDeviceReadingStore === reading, reading.cloudReadingStore === atomic else { throw CancellationError() }
        return StandaloneReadingConflictItem.collect(store: atomic, books: books)
    }

    func resolveStandaloneReadingConflict(_ item: StandaloneReadingConflictItem, scope: CloudReadingScope,
                                          choice: CloudAtomicReadingStore.ConflictChoice,
                                          accountIsCurrent: @escaping @MainActor () async throws -> Bool,
                                          confirmUnverifiedEdition: Bool = false) async throws {
        guard !standaloneRecoveryRunning, reader == nil, openingID == nil,
              let reservation = offlineReservations.beginLocalImport() else {
            throw ReaderError.message("Close the reader and wait for other book operations to finish.")
        }
        standaloneRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch
        defer { standaloneRecoveryRunning = false; offlineReservations.endLocalImport(reservation) }
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("Reading data is unavailable for this iCloud account.")
        }
        func check() async throws {
            guard !Task.isCancelled, standaloneRecoveryEpoch == epoch, reader == nil, openingID == nil,
                  onDeviceLibrary === library, onDeviceReadingStore === reading, reading.cloudReadingStore === atomic,
                  try await accountIsCurrent(), standaloneRecoveryEpoch == epoch, reader == nil, openingID == nil else {
                throw ReaderError.message("The account or book changed. Review the conflict again.")
            }
        }
        try await check()
        guard let book = await library.catalog().first(where: { $0.id == item.book.id }),
              book.cloudIdentities?[scope.cloudAccountKey]?.readingBookID == item.cloudBookID else {
            throw ReaderError.message("The book identity changed. Review the conflict again.")
        }
        try await check()
        let fingerprint = try await reading.verifyStandaloneEdition(book, library: library, scope: scope)
        try await check()
        try reading.resolveCloudConflict(item.key, book: book.book, verifiedEditionFingerprint: fingerprint,
                                         expectedLocalRevision: item.local.revision, remoteRevision: item.remote.revision, choice: choice,
                                         confirmUnverifiedEdition: confirmUnverifiedEdition)
        bookmarksRevision &+= 1
    }

    func confirmStandaloneReadingReview(_ item: StandaloneReadingReviewItem, scope: CloudReadingScope,
                                        accountIsCurrent: @escaping @MainActor () async throws -> Bool) async throws {
        guard !standaloneRecoveryRunning, reader == nil, openingID == nil,
              let reservation = offlineReservations.beginLocalImport() else {
            throw ReaderError.message("Close the reader and wait for other book operations to finish.")
        }
        standaloneRecoveryRunning = true
        let epoch = standaloneRecoveryEpoch
        defer { standaloneRecoveryRunning = false; offlineReservations.endLocalImport(reservation) }
        guard let library = onDeviceLibrary, let reading = onDeviceReadingStore,
              let atomic = reading.cloudReadingStore, atomic.scope == scope else {
            throw ReaderError.message("This change needs further recovery review.")
        }
        func check() async throws {
            guard !Task.isCancelled, standaloneRecoveryEpoch == epoch, reader == nil, openingID == nil,
                  onDeviceLibrary === library, onDeviceReadingStore === reading, reading.cloudReadingStore === atomic,
                  try await accountIsCurrent(), standaloneRecoveryEpoch == epoch, reader == nil, openingID == nil else {
                throw ReaderError.message("The account or book changed. Review the item again.")
            }
        }
        try await check()
        guard let book = await library.catalog().first(where: { $0.id == item.book.id }),
              book.cloudIdentities?[scope.cloudAccountKey]?.readingBookID == item.cloudBookID else {
            throw ReaderError.message("The book identity changed. Review the item again.")
        }
        try await check()
        let fingerprint = try await reading.verifyStandaloneEdition(book, library: library, scope: scope)
        try await check()
        try reading.certifyReviewedLocalVersion(item.key, book: book.book, expectedRevision: item.revision,
                                                verifiedEditionFingerprint: fingerprint)
    }

    func selectLocalFolder(_ url: URL) async {
        await loadOnDeviceLibrary()
        do {
            guard let localFolderLibrary else { return }
            try await localFolderLibrary.select(url)
            folderName = await localFolderLibrary.folderName
            folderBooks = await localFolderLibrary.books
            await refreshLocalFolder()
        } catch { folderProblem = "Could not access that folder. Select it again to reconnect." }
    }
    func refreshLocalFolder() async {
        guard let localFolderLibrary, folderName != nil else { return }
        do { folderBooks = try await localFolderLibrary.refresh(); folderProblem = nil }
        catch { folderProblem = "The selected folder is unavailable. Select it again to reconnect." }
    }
    func openFolderBook(_ entry: FolderBookEntry) async {
        await loadOnDeviceLibrary()
        guard let localFolderLibrary, let onDeviceLibrary else { return }
        if (!entry.available || folderProblem != nil), let copy = onDeviceBooks.first(where: { $0.id == entry.id }) {
            openOnDevice(copy); return
        }
        guard let token = offlineReservations.beginLocalImport() else { error = "Wait for the current import or removal to finish."; return }
        let current = generation
        do {
            let imported = try await localFolderLibrary.importBook(entry, into: onDeviceLibrary)
            onDeviceBooks = await onDeviceLibrary.catalog()
            folderBooks = await localFolderLibrary.books
            offlineReservations.endLocalImport(token)
            guard current == generation else { return }
            openOnDevice(imported)
        } catch {
            offlineReservations.endLocalImport(token)
            if current == generation { self.error = UserFacingError.message(error) }
        }
    }
    func refreshStorageUsage() async {
        let current = generation, request = UUID()
        storageRequestID = request
        do { if onDeviceLibrary == nil { onDeviceLibrary = try LocalLibrary() } }
        catch { if current == generation { self.error = "Could not calculate storage use." }; return }
        let library = onDeviceLibrary, currentSaved = savedBooks, currentCache = cache
        let importedBytes = try? await library?.storageBytes()
        let savedBytes = try? await currentSaved?.storageBytes()
        let cacheBytes = try? await currentCache?.storageBytes()
        guard current == generation, request == storageRequestID else { return }
        storageUsage = StorageUsageSnapshot(importedBytes: importedBytes, savedBytes: savedBytes, cacheBytes: cacheBytes)
    }
    func clearDeviceCache() async {
        guard openingID == nil, let currentCache = cache else { return }
        let current = generation
        do {
            try await currentCache.clear()
            guard current == generation else { return }
            await refreshCache()
            guard current == generation else { return }
            await refreshStorageUsage()
        } catch { if current == generation { self.error = "The cache could not be cleared." } }
    }
    func importOnDevice(_ url: URL) async {
        guard let token = offlineReservations.beginLocalImport() else { error = "Wait for the current import or removal to finish."; return }
        defer { offlineReservations.endLocalImport(token) }
        await loadOnDeviceLibrary()
        guard let onDeviceLibrary else { return }
        do {
            _ = try await onDeviceLibrary.importFile(url)
            onDeviceBooks = await onDeviceLibrary.catalog()
        } catch { self.error = UserFacingError.message(error) }
    }
    func removeOnDevice(_ entry: LocalBookEntry) async {
        guard reader?.id != entry.id, openingID != entry.id else {
            error = "Close this book before removing it from this device."
            return
        }
        guard let token = offlineReservations.beginRemoval(entry.id, scope: .local) else { error = "Wait for the current import or removal to finish."; return }
        defer { offlineReservations.endRemoval(entry.id, scope: .local, token: token) }
        do {
            try await onDeviceLibrary?.remove(entry)
            onDeviceBooks = await onDeviceLibrary?.catalog() ?? []
        } catch { self.error = UserFacingError.message(error) }
    }
    func openOnDevice(_ entry: LocalBookEntry) {
        guard openingID == nil, markingID == nil else { return }
        guard offlineReservations.permitsAccess(entry.id, scope: .local) else { error = "Wait for this book to finish being removed."; return }
        let book = entry.book
        cancelOpen(); readingOnDevice = true; error = nil; openingID = book.id; readerLaunchBook = book
        let current = generation
        openTask = Task {
            do {
                await loadOnDeviceLibrary()
                guard let onDeviceLibrary, let onDeviceReadingStore,
                      let directory = await onDeviceLibrary.directory(for: entry) else {
                    throw ReaderError.message("The local copy is missing or damaged. Remove it from On My Device, then import the original file again. Your reading data will be kept.")
                }
                let content = try BookCache.contents(directory, format: book.format)
                try Task.checkCancellation()
                guard generation == current, readerLaunchBook?.id == book.id else { return }
                try await finishPreparingReader(PreparedBook(book: book, directory: directory, document: content.0, images: content.1,
                                      position: onDeviceReadingStore.records[book.id]?.position ?? ReadingPosition(), hasDurableSidecars: true), sessionID: current)
            } catch { if generation == current, !Task.isCancelled { self.error = UserFacingError.message(error) } }
            if generation == current, !Task.isCancelled { openingID = nil }
        }
    }
    private(set) var cachedKeys: Set<String> = []
    private(set) var savedKeys: Set<String> = []
    private(set) var markingID: String?
    private var cacheRefreshID = UUID()
    func isCached(_ book: Book) -> Bool { cachedKeys.contains(stableKey(book.id)) }
    func isSaved(_ book: Book) -> Bool { savedKeys.contains(stableKey(book.id)) }
    func hasSavedCopy(_ book: Book) -> Bool { savedCatalog.contains(where: { $0.id == book.id }) }
    func refreshCache() async {
        let current = generation, request = UUID()
        let currentSavedBooks = savedBooks, currentJournal = downloadJournal
        cacheRefreshID = request
        let keys = (try? await cache?.availableKeys()) ?? []
        let saved = (try? await currentSavedBooks?.availableKeys()) ?? []
        let catalog = try? await currentSavedBooks?.catalog()
        if current == generation, request == cacheRefreshID {
            cachedKeys = keys; savedKeys = saved
            if let catalog { savedCatalog = catalog }
            if let journal = currentJournal, let currentSavedBooks {
                do {
                    try await journal.reconcileAvailable(isAvailable: { book in await currentSavedBooks.saved(book) != nil },
                                                         stillCurrent: { self.generation == current && self.cacheRefreshID == request })
                    guard current == generation, request == cacheRefreshID else { return }
                    downloads = journal.entries
                } catch { self.error = "Could not update the download queue." }
            }
        }
    }
    func removeDeviceCopy(_ book: Book) async {
        guard openingID == nil, reader?.id != book.id, activeDownloadID != book.id,
              !downloads.contains(where: { $0.id == book.id && $0.state == .queued }) else { error = "Close the book or cancel its download before removing its device copy."; return }
        guard let token = offlineReservations.beginRemoval(book.id, scope: .server) else { error = "This device copy is already being removed."; return }
        defer { offlineReservations.endRemoval(book.id, scope: .server, token: token) }
        let current = generation
        let currentSavedBooks = savedBooks, currentCache = cache, currentJournal = downloadJournal
        do {
            let completed = try await removeAccountDeviceCopy(stillCurrent: { self.generation == current },
                                                             removeSaved: { try await currentSavedBooks?.remove(book) },
                                                             removeCached: { try await currentCache?.remove(book) },
                                                             removeJournal: { try currentJournal?.remove(book.id) })
            guard completed, current == generation else { return }
            downloads = currentJournal?.entries ?? []
            await refreshCache()
        }
        catch { if current == generation { self.error = UserFacingError.message(error) } }
    }
    func markFinished(_ book: Book, finished: Bool = true) async {
        guard let provider, let store, markingID == nil, reader == nil, openingID == nil else { return }
        guard !syncRunning else { error = "Reading progress is still syncing. Try marking this book as read in a moment."; return }
        let current = generation
        markingID = book.id
        defer { if current == generation { markingID = nil } }
        do {
            if store.records[book.id]?.dirty == true { await flushProgress() }
            guard current == generation else { return }
            guard store.records[book.id]?.dirty != true else { throw ReaderError.message("Sync or resolve this book’s reading position before marking it as read.") }
            let ticks = try await provider.setFinished(book, finished: finished)
            guard current == generation else { return }
            if var record = store.records[book.id] {
                record.acknowledgedTicks = ticks; record.dirty = false
                if !finished { record.position = ReadingPosition.from(ticks: ticks, format: book.format) }
                try store.set(record, id: book.id)
            }
            var updated = book; updated.ticks = ticks
            updated.readingStatus = finished ? .finished : (ticks > 0 ? .inProgress : .notFinished)
            localBooks[book.id] = updated
        } catch { if current == generation { self.error = UserFacingError.message(error) } }
    }
    func downloadToDevice(_ book: Book) {
        guard offlineReservations.permitsAccess(book.id, scope: .server) else { error = "Wait for this device copy to finish being removed."; return }
        guard account != nil, let journal = downloadJournal else { error = "The download queue is unavailable."; return }
        do { try journal.enqueue(book); downloads = journal.entries; resumeDownloads() }
        catch { self.error = UserFacingError.message(error) }
    }
    func download(for book: Book) -> OfflineDownload? { downloads.first { $0.id == book.id } }
    func cancelDownload(_ id: String) {
        guard let journal = downloadJournal, let entry = downloads.first(where: { $0.id == id }),
              entry.state == .queued || entry.state == .downloading else { return }
        do {
            try journal.set(id, state: .cancelled); downloads = journal.entries
            if activeDownloadID == id { downloadTask?.cancel() }
        } catch { self.error = "Could not update the download queue." }
    }
    func retryDownload(_ entry: OfflineDownload) { downloadToDevice(entry.book) }
    private func resumeDownloads() {
        guard downloadTask == nil, let provider, let savedBooks, let journal = downloadJournal,
              let next = journal.entries.first(where: { $0.state == .queued }) else { return }
        let current = generation
        do { try journal.set(next.id, state: .downloading, progress: 0); downloads = journal.entries }
        catch { self.error = "Could not update the download queue."; return }
        activeDownloadID = next.id
        let token = UUID(); activeDownloadToken = token
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if await savedBooks.saved(next.book) == nil {
                    let file = try await provider.download(next.book) { [weak self] value in
                        Task { @MainActor in self?.recordDownloadProgress(value, id: next.id, token: token, generation: current) }
                    }
                    defer { try? FileManager.default.removeItem(at: file) }
                    try Task.checkCancellation()
                    guard self.generation == current, journal.entries.first(where: { $0.id == next.id })?.state == .downloading else { throw CancellationError() }
                    let cover = try? await provider.cover(next.book, fullSize: false)
                    try Task.checkCancellation()
                    guard self.generation == current, journal.entries.first(where: { $0.id == next.id })?.state == .downloading else { throw CancellationError() }
                    _ = try await savedBooks.install(file, book: next.book, cover: cover)
                }
                guard self.generation == current else { return }
                try journal.set(next.id, state: .available, progress: 1)
            } catch {
                guard self.generation == current else { return }
                // Installation may have finished just before cancellation. Report
                // the real durable copy, rather than claiming it is incomplete.
                let saved = await savedBooks.saved(next.book) != nil
                guard self.generation == current else { return }
                do {
                    if saved { try journal.set(next.id, state: .available, progress: 1) }
                    else if journal.entries.first(where: { $0.id == next.id })?.state == .downloading {
                        try journal.set(next.id, state: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                                        failure: error is CancellationError || Task.isCancelled ? nil : UserFacingError.message(error))
                    }
                } catch { self.error = "Could not update the download queue." }
            }
            guard self.generation == current else { return }
            self.downloads = journal.entries; self.activeDownloadID = nil; self.activeDownloadToken = nil; self.downloadTask = nil
            await self.refreshCache()
            guard self.generation == current else { return }
            self.resumeDownloads()
        }
    }
    private func recordDownloadProgress(_ progress: Double, id: String, token: UUID, generation current: UUID) {
        guard generation == current, let journal = downloadJournal, activeDownloadID == id, activeDownloadToken == token,
              let item = journal.entries.first(where: { $0.id == id }), item.state == .downloading,
              progress.isFinite, progress >= (item.progress ?? 0) + 0.02 else { return }
        do { try journal.set(id, state: .downloading, progress: progress); downloads = journal.entries }
        catch { self.error = "Could not update download progress on this device."; downloadTask?.cancel() }
    }
    var preferences = ReaderPreferences() { didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "readerPreferences") } } }
    private var openTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var syncFlight: Task<Void, Never>?
    private(set) var syncRunning = false
    private var progressRevision = 0
    var canRetryProgress: Bool { syncIssue == .unavailable && store?.records.values.contains(where: { $0.dirty && $0.syncBlock == nil }) == true }
    private var generation = UUID()
    var sessionID: UUID { generation }
    private(set) var catalogRevision = 0
    private let deleteCredentials: () throws -> Void
    init(restoreLogin: Bool = true, deleteCredentials: @escaping () throws -> Void = CredentialStore.delete) {
        self.deleteCredentials = deleteCredentials
        artwork.totalCostLimit = 32 * 1024 * 1024
        if let data = UserDefaults.standard.data(forKey: "readerPreferences"), let prefs = try? JSONDecoder().decode(ReaderPreferences.self, from: data) { preferences = prefs }
        guard restoreLogin else { return }
        do { if let account = try CredentialStore.load() { try configure(account) } } catch { self.error = UserFacingError.message(error) }
    }
    private func configure(_ account: Account) throws {
        let store = try ReadingStore(namespace: account.namespace)
        let cache = try BookCache(namespace: account.namespace)
        let savedBooks = try DurableBookStore(namespace: account.namespace)
        self.store = store; self.cache = cache; self.savedBooks = savedBooks; self.account = account; provider = JellyfinProvider(account: account)
        do { downloadJournal = try OfflineDownloadJournal(namespace: account.namespace); downloads = downloadJournal?.entries ?? [] }
        catch { downloadJournal = nil; downloads = []; self.error = "The download queue could not be opened on this device." }
        selectedLibrary = UserDefaults.standard.string(forKey: "library-\(stableKey(account.namespace))")
        resumeDownloads()
    }
    #if DEBUG
    func openSample(_ format: BookFormat) async {
        guard account == nil, let source = Bundle.main.url(forResource: "Harbor", withExtension: format.rawValue, subdirectory: "Fixtures") else { return }
        readingOnDevice = false
        do {
            store = try ReadingStore(namespace: "local-fixtures")
            let cache = try BookCache(namespace: "local-fixtures"); self.cache = cache
            let book = Book(id: "fixture-\(format.rawValue)", title: "The Harbor", author: "CC0 Reader Fixtures", summary: "", format: format, isFolder: false, ticks: 0)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            let directory = try await cache.install(temp, book: book)
            let content = try BookCache.contents(directory, format: format)
            readerLaunchBook = book
            reader = PreparedBook(book: book, directory: directory, document: content.0, images: content.1, position: store?.records[book.id]?.position ?? ReadingPosition())
        } catch { self.error = UserFacingError.message(error) }
    }
    #endif
    func login(server: String, username: String, password: String) async {
        guard !connecting, account == nil else { return }
        let current = UUID(); generation = current
        connecting = true; error = nil
        defer { if current == generation { connecting = false } }
        do {
            let account = try await JellyfinProvider().login(server: JellyfinProvider.serverURL(server), username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            guard current == generation, !Task.isCancelled else {
                try? await JellyfinProvider(account: account).signOut()
                return
            }
            do { try CredentialStore.save(account); try configure(account) }
            catch {
                try? deleteCredentials()
                try? await JellyfinProvider(account: account).signOut()
                throw ReaderError.message("Could not save this login securely. Please try again.")
            }
        } catch { if current == generation { self.error = UserFacingError.message(error) } }
    }
    private var librariesLoaded = false
    private var librariesLoading = false
    func loadLibrariesIfNeeded() async {
        guard !librariesLoaded, !librariesLoading else { return }
        librariesLoading = true
        defer { librariesLoading = false }
        await loadLibraries()
    }
    func loadLibraries() async {
        guard let provider else { return }
        let current = generation
        await refreshCache()
        do {
            try await provider.validate()
            let items = try await provider.libraries()
            guard current == generation else { return }
            await provider.invalidateCatalogMetadata()
            guard current == generation, !Task.isCancelled else { return }
            libraries = items; librariesLoaded = true
            catalogSnapshots.removeAll(); discoveryBooks.removeAll(); discoveryCollections.removeAll()
            localBooks = localBooks.filter { store?.records[$0.key]?.dirty == true }; artwork.removeAllObjects()
            catalogRevision += 1
            if !items.contains(where: { $0.id == selectedLibrary }) { selectedLibrary = items.first?.id }
            status = items.isEmpty ? "No book libraries are available to this account." : nil
        } catch { if current == generation { status = UserFacingError.message(error) } }
    }
    func signOut() async {
        guard !connecting else { return }
        connecting = true
        cancelOpen(); syncTask?.cancel(); syncFlight?.cancel(); downloadTask?.cancel()
        generation = UUID(); offlineReservations.clearServer(); syncFlight = nil; syncRunning = false; downloadTask = nil; activeDownloadID = nil; activeDownloadToken = nil
        let oldProvider = provider, oldCache = cache, oldSavedBooks = savedBooks, oldJournal = downloadJournal, oldStore = store, oldAccount = account
        // Release account-bound UI immediately, even if one cleanup operation fails.
        account = nil; provider = nil; store = nil; cache = nil; savedBooks = nil; downloadJournal = nil; downloads = []; libraries = []
        cachedKeys = []; savedKeys = []; savedCatalog = []; storageUsage = nil; markingID = nil; librariesLoaded = false; librariesLoading = false
        profileImageTask?.cancel(); profileImageTask = nil; profileImageData = nil
        catalogSnapshots.removeAll(); discoveryBooks.removeAll(); discoveryCollections.removeAll(); localBooks.removeAll(); artwork.removeAllObjects()
        selectedLibrary = nil; reader = nil; conflict = nil; syncIssue = nil; status = nil; error = nil
        await oldProvider?.invalidateCatalogMetadata()
        var failures: [String] = []
        do { try deleteCredentials() } catch { failures.append("The saved login could not be removed from Keychain.") }
        if oldStore?.hasUnsyncedCloudChanges == true {
            failures.append("Reading data with pending iCloud recovery changes was kept on this device.")
        } else {
            do { try oldStore?.delete() } catch { failures.append("Some reading data could not be removed from this device.") }
        }
        do { try await oldCache?.delete() } catch { failures.append("Some cached books could not be removed from this device.") }
        do { try await oldSavedBooks?.delete() } catch { failures.append("Some saved books could not be removed from this device.") }
        do { try oldJournal?.delete() } catch { failures.append("The download queue could not be removed from this device.") }
        if let oldAccount { UserDefaults.standard.removeObject(forKey: "library-\(stableKey(oldAccount.namespace))") }
        do { try await oldProvider?.signOut() } catch { failures.append("The server session could not be revoked. You can revoke it from your Jellyfin server.") }
        connecting = false
        if !failures.isEmpty { error = failures.joined(separator: " ") }
    }
    func cancelOpen() { standaloneRecoveryEpoch = UUID(); openTask?.cancel(); openTask = nil; openingID = nil; downloadProgress = nil; readerLaunchBook = nil; positionEditionReview = nil; positionEditionStore = nil }
    /// Explicit offline-library opens do not wait on a server lookup.
    func openSaved(_ book: Book) {
        guard markingID == nil, let savedBooks else { return }
        guard offlineReservations.permitsAccess(book.id, scope: .server) else { error = "Wait for this device copy to finish being removed."; return }
        cancelOpen(); readingOnDevice = false; error = nil; openingID = book.id; readerLaunchBook = book
        let current = generation
        openTask = Task {
            do {
                guard let directory = await savedBooks.saved(book) else {
                    throw ReaderError.message("The saved copy is missing or damaged. Remove the device copy, then save the book again when the server is available.")
                }
                let content = try BookCache.contents(directory, format: book.format)
                if book.format == .pdf {
                    guard let document = PDFDocument(url: content.0), !document.isLocked, document.pageCount > 0 else {
                        throw ReaderError.message("The saved PDF is missing, damaged, or locked. Remove the device copy, then save it again when the server is available.")
                    }
                }
                try Task.checkCancellation()
                guard current == generation, readerLaunchBook?.id == book.id else { return }
                let position = store?.records[book.id]?.position ?? ReadingPosition.from(ticks: book.ticks, format: book.format)
                try await finishPreparingReader(PreparedBook(book: book, directory: directory, document: content.0, images: content.1, position: position, hasDurableSidecars: true), sessionID: current)
            } catch { if current == generation, !Task.isCancelled { self.error = UserFacingError.message(error) } }
            if current == generation, !Task.isCancelled { openingID = nil }
        }
    }
    func open(_ book: Book) {
        guard markingID == nil else { return }
        guard offlineReservations.permitsAccess(book.id, scope: .server) else { error = "Wait for this device copy to finish being removed."; return }
        guard book.format != .unsupported else { error = "This format is not supported. Choose an EPUB, PDF, or CBZ book."; return }
        cancelOpen(); readingOnDevice = false; error = nil; openingID = book.id; readerLaunchBook = book
        let current = generation
        openTask = Task { [weak self] in
            guard let self, let provider = self.provider, let cache = self.cache else { return }
            do {
                var position = self.store?.records[book.id]?.position ?? ReadingPosition.from(ticks: book.ticks, format: book.format)
                var serverSeed: ReadingRecord?
                do {
                    let remoteBook = try await provider.book(id: book.id)
                    let ticks = remoteBook.ticks
                    try Task.checkCancellation()
                    guard current == self.generation else { throw CancellationError() }
                    if let reading = self.store, let local = reading.records[book.id], local.syncBlock != .edition,
                       !self.editionPositionHolds.contains(self.editionHoldKey(reading, bookID: book.id)), local.conflicts(with: ticks) {
                        self.blockProgress(book.id, reason: .conflict)
                        self.conflict = ProgressConflict(book: book, local: local.position, remote: .from(ticks: ticks, format: book.format), remoteTicks: ticks, serverFinished: remoteBook.readingStatus == .finished)
                        self.openingID = nil; return
                    }
                    if self.store?.records[book.id]?.syncBlock != nil, self.store?.records[book.id]?.syncBlock != .edition, var local = self.store?.records[book.id] {
                        local.syncBlock = nil
                        try self.store?.set(local, id: book.id)
                    }
                    if self.store?.records[book.id]?.dirty != true {
                        let local = self.store?.records[book.id]
                        position = local?.acknowledgedTicks == ticks ? local!.position : .from(ticks: ticks, format: book.format)
                        serverSeed = ReadingRecord(position: position, acknowledgedTicks: ticks, dirty: false, updated: Date(), title: book.title, format: book.format,
                                                   contentFingerprint: local?.position == position ? local?.contentFingerprint : nil)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard current == self.generation, !Task.isCancelled else { return }
                    self.syncIssue = self.store?.records[book.id]?.dirty == true ? .unavailable : .lookupUnavailable
                }
                guard current == self.generation, !Task.isCancelled else { return }
                try await self.prepare(book, position: position, provider: provider, cache: cache, generation: current, serverSeed: serverSeed)
                if self.positionEditionReview == nil, self.store?.records[book.id]?.dirty == true { Task { await self.flushProgress() } }
            } catch { if !Task.isCancelled && current == self.generation { self.error = UserFacingError.message(error) } }
            if !Task.isCancelled && current == self.generation { self.openingID = nil; self.downloadProgress = nil }
        }
    }
    func resolveConflict(useLocal: Bool) {
        guard let conflict, let provider, let cache else { return }
        readingOnDevice = false
        self.conflict = nil
        let position = useLocal ? conflict.local : conflict.remote
        let seed = ReadingRecord(position: position, acknowledgedTicks: conflict.remoteTicks, dirty: useLocal, updated: Date(), title: conflict.book.title, format: conflict.book.format,
                                 contentFingerprint: useLocal ? store?.records[conflict.book.id]?.contentFingerprint : nil)
        openingID = conflict.book.id; readerLaunchBook = conflict.book
        let current = generation
        openTask = Task {
            do { try await prepare(conflict.book, position: position, provider: provider, cache: cache, generation: current, serverSeed: seed) }
            catch { if current == generation, !Task.isCancelled { self.error = UserFacingError.message(error) } }
            if current == generation { openingID = nil; downloadProgress = nil }
        }
    }
    private func prepare(_ book: Book, position: ReadingPosition, provider: JellyfinProvider, cache: BookCache, generation current: UUID, serverSeed: ReadingRecord? = nil) async throws {
        await cache.protect(book.id)
        let directory: URL
        let hasDurableSidecars: Bool
        if let saved = await savedBooks?.saved(book) { directory = saved; hasDurableSidecars = true }
        else if let cached = await cache.cached(book) { directory = cached; hasDurableSidecars = false }
        else {
            downloadProgress = 0
            let file = try await provider.download(book) { [weak self] value in Task { @MainActor in if self?.generation == current, self?.openingID == book.id { self?.downloadProgress = value } } }
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            guard current == generation else { throw CancellationError() }
            directory = try await cache.install(file, book: book)
            hasDurableSidecars = false
        }
        let content = try BookCache.contents(directory, format: book.format)
        try Task.checkCancellation()
        guard current == generation else { return }
        await refreshCache()
        guard current == generation, !Task.isCancelled, readerLaunchBook?.id == book.id else { return }
        try await finishPreparingReader(PreparedBook(book: book, directory: directory, document: content.0, images: content.1, position: position, hasDurableSidecars: hasDurableSidecars), sessionID: current, serverSeed: serverSeed)
    }
    func savePosition(_ position: ReadingPosition, book: Book) {
        guard positionEditionReview == nil else { return }
        guard position.validatedTicks(for: book.format) != nil else {
            error = "The reader returned an invalid position. Your earlier saved place was kept."
            return
        }
        guard let store = readingStore(for: book) else { return }
        let previous = store.records[book.id]
        if previous?.position == position { return }
        let acknowledged = previous?.acknowledgedTicks ?? book.ticks
        let dirty = readingOnDevice ? false : (position.ticks(for: book.format) != acknowledged || (syncRunning && previous?.dirty == true))
        let fingerprint = reader?.id == book.id ? reader?.contentFingerprint : previous?.contentFingerprint
        do { try store.set(ReadingRecord(position: position, acknowledgedTicks: acknowledged, dirty: dirty, updated: Date(), title: book.title, format: book.format, syncBlock: previous?.syncBlock, contentFingerprint: fingerprint), id: book.id) }
        catch { self.error = "Could not save your reading position on this device."; return }
        if readingOnDevice { return }
        var updated = book; updated.ticks = position.ticks(for: book.format)
        updated.readingStatus = book.format == .epub && position.fraction >= 1 ? .finished : (updated.ticks > 0 ? .inProgress : .notFinished)
        localBooks[book.id] = updated
        guard dirty, previous?.syncBlock == nil else { return }
        progressRevision += 1
        syncTask?.cancel()
        syncTask = Task { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { await flushProgress() } }
    }
    func flushProgress() async {
        syncTask?.cancel(); syncTask = nil
        if let syncFlight { await syncFlight.value; return }
        guard provider != nil, store != nil else { return }
        let current = generation
        syncRunning = true
        let flight = Task { await drainProgress() }
        syncFlight = flight
        await flight.value
        if current == generation { syncFlight = nil; syncRunning = false }
    }
    private func drainProgress() async {
        let current = generation
        guard let provider, let store else { return }
        repeat {
            let revision = progressRevision
            var issue: ProgressSyncIssue?
            for (id, record) in store.records where record.dirty && record.syncBlock == nil {
                guard current == generation, !Task.isCancelled else { return }
                guard openingID != id, positionEditionReview?.prepared.id != id,
                      !editionPositionHolds.contains(editionHoldKey(store, bookID: id)) else { continue }
                guard let ticks = record.position.validatedTicks(for: record.format) else {
                    self.error = "An invalid saved position was kept on this device and was not sent to Jellyfin. Reopen the book to choose a valid place."
                    continue
                }
                var itemLookupComplete = false
                do {
                    let remote = try await provider.remoteTicks(id: id)
                    itemLookupComplete = true
                    guard current == generation, !Task.isCancelled else { return }
                    guard remote == record.acknowledgedTicks || remote == ticks else { blockProgress(id, reason: .conflict); continue }
                    // A timed-out report may already have reached Jellyfin. The
                    // readback is authoritative, so avoid sending it twice.
                    if remote != ticks { try await provider.report(id: id, ticks: ticks) }
                    guard current == generation, !Task.isCancelled else { return }
                    if var latest = store.records[id] {
                        latest.acknowledgedTicks = ticks
                        latest.dirty = latest.position.ticks(for: latest.format) != ticks
                        try store.set(latest, id: id)
                    }
                } catch is JellyfinAuthenticationError { issue = .expired }
                catch JellyfinContentError.notFound {
                    if itemLookupComplete { issue = .unavailable }
                    else { blockProgress(id, reason: .unavailable) }
                }
                catch { if issue != .expired { issue = .unavailable } }
            }
            guard current == generation else { return }
            syncIssue = issue
            // A page saved during the request needs one more pass. A failed request
            // waits for a later close, reopen, or explicit retry.
            if issue != nil || progressRevision == revision { return }
        } while true
    }
    private func blockProgress(_ id: String, reason: ProgressSyncBlock) {
        guard let store, var record = store.records[id] else { return }
        record.syncBlock = reason
        do { try store.set(record, id: id) }
        catch { self.error = "Could not save this book’s sync status on this device." }
    }
    func retryBlockedProgress(_ id: String) async {
        guard let store, var record = store.records[id], record.dirty, record.syncBlock != nil else { return }
        guard record.syncBlock != .edition, !editionPositionHolds.contains(editionHoldKey(store, bookID: id)) else {
            error = "Open this book and review its saved place before syncing this edition."
            return
        }
        record.syncBlock = nil
        do { try store.set(record, id: id) }
        catch { self.error = "Could not update this book’s sync status on this device."; return }
        progressRevision += 1
        await flushProgress()
    }
    func openBlockedProgress(_ entry: BlockedProgress) {
        open(Book(id: entry.id, title: entry.title, author: "", summary: "", format: entry.format, isFolder: false, ticks: entry.acknowledgedTicks))
    }
    func rematchProgress(_ entry: BlockedProgress, to candidate: Book) async {
        guard let provider, let store, let old = store.records[entry.id], old.dirty, old.syncBlock == .unavailable,
              candidate.id != entry.id, candidate.format == old.format else { return }
        guard let localTicks = old.position.validatedTicks(for: old.format) else {
            error = "This saved position is invalid and was kept on this device. Open the book to choose a valid place before matching it."
            return
        }
        let current = generation
        do {
            let remoteBook = try await provider.book(id: candidate.id)
            guard current == generation else { return }
            let needsChoice = remoteBook.ticks != localTicks && (remoteBook.ticks != 0 || remoteBook.readingStatus == .finished)
            var transferred = old
            transferred.title = candidate.title
            transferred.acknowledgedTicks = remoteBook.ticks
            transferred.dirty = localTicks != remoteBook.ticks || needsChoice
            transferred.syncBlock = needsChoice ? .conflict : nil
            transferred.updated = Date()
            try store.movePosition(from: entry.id, to: candidate, record: transferred)
            bookmarksRevision += 1
            progressRevision += 1
            if needsChoice {
                conflict = ProgressConflict(book: candidate, local: old.position,
                                            remote: .from(ticks: remoteBook.ticks, format: candidate.format),
                                            remoteTicks: remoteBook.ticks,
                                            serverFinished: remoteBook.readingStatus == .finished)
            } else if transferred.dirty { await flushProgress() }
        } catch { if current == generation { self.error = UserFacingError.message(error) } }
    }
    func closeReader() {
        cancelOpen(); reader = nil
        let closingCache = cache, current = generation
        Task {
            await flushProgress()
            guard current == generation, reader == nil, openingID == nil else { return }
            await closingCache?.protect(nil)
            try? await closingCache?.evict()
            await refreshCache()
        }
    }
    @discardableResult func addBookmark(book: Book, position: ReadingPosition, fingerprint: String? = nil) -> Bool {
        let name = book.format == .epub ? "\(Int(position.fraction * 100))% · \(Date().formatted(date: .abbreviated, time: .shortened))" : "Page \(position.page + 1)"
        do {
            guard let store = readingStore(for: book) else { return false }
            let added = try store.addIfAbsent(Bookmark(name: name, position: position, contentFingerprint: fingerprint), id: book.id, format: book.format)
            if added { bookmarksRevision += 1 }
            return added
        } catch { self.error = UserFacingError.message(error); return false }
    }
}
struct StorageUsageSnapshot {
    var importedBytes: Int64?
    var savedBytes: Int64?
    var cacheBytes: Int64?
}
struct ProgressConflict: Identifiable { var id: String { book.id }; var book: Book; var local: ReadingPosition; var remote: ReadingPosition; var remoteTicks: Int64; var serverFinished = false }
struct BlockedProgress: Identifiable {
    var id: String
    var title: String
    var format: BookFormat
    var acknowledgedTicks: Int64
    var reason: ProgressSyncBlock
}
enum ProgressSyncIssue {
    case unavailable, lookupUnavailable, expired
    var message: String {
        switch self {
        case .unavailable: "Reading position saved on this device. Jellyfin sync failed."
        case .lookupUnavailable: "Reading locally. Server progress is unavailable."
        case .expired: "Reading position saved on this device. Your Jellyfin login has expired; sign out and reconnect."
        }
    }
}

/// Binds a recovery request to the iCloud session and zone that were inspected.
/// Creating a missing zone is a separate, explicitly reviewed action.
@MainActor final class StandaloneCloudRecoveryService {
    struct Inspection {
        fileprivate let serviceID: UUID
        fileprivate let token: CloudReadingAccountMonitor.Token
        let scope: CloudReadingScope
        let zoneState: CloudRecoveryZoneState
    }
    typealias Runner = @MainActor (CloudReadingScope, CKRecordZone.ID, @escaping @MainActor () async throws -> Bool) async throws -> StandaloneRecoveryCycle.Report
    typealias LegacyRunner = @MainActor (CloudReadingScope, @escaping @MainActor () async throws -> Bool) async throws -> Void
    private let id = UUID()
    private let monitor: CloudReadingAccountMonitor
    private let zones: any CloudRecoveryZoneDatabase
    private let source: CloudReadingSource
    private let runner: Runner
    private let legacyRunner: LegacyRunner?
    private let accountSwitchRunner: LegacyRunner?

    init(monitor: CloudReadingAccountMonitor, zones: any CloudRecoveryZoneDatabase,
         source: CloudReadingSource = .imported, legacyRunner: LegacyRunner? = nil,
         accountSwitchRunner: LegacyRunner? = nil, runner: @escaping Runner) {
        self.monitor = monitor; self.zones = zones; self.source = source; self.runner = runner
        self.legacyRunner = legacyRunner; self.accountSwitchRunner = accountSwitchRunner
    }
    private func fence(_ token: CloudReadingAccountMonitor.Token) -> @MainActor () async throws -> Bool {
        { [monitor] in try await monitor.validate(token) }
    }
    private func access(_ inspection: Inspection) throws -> CloudRecoveryZoneAccess {
        guard inspection.serviceID == id, monitor.accepts(inspection.token),
              inspection.scope.cloudAccountKey == inspection.token.accountKey else {
            throw ReaderError.message("The iCloud account changed. Recovery is paused.")
        }
        return try CloudRecoveryZoneAccess(scope: inspection.scope, database: zones, accountIsCurrent: fence(inspection.token))
    }
    func inspect() async throws -> Inspection {
        guard let token = try await monitor.refresh(), try await monitor.validate(token) else {
            throw ReaderError.message("iCloud is unavailable. Your books remain on this device.")
        }
        let scope = try monitor.scope(for: token, source: source)
        let access = try CloudRecoveryZoneAccess(scope: scope, database: zones, accountIsCurrent: fence(token))
        let state = try await access.inspect()
        return Inspection(serviceID: id, token: token, scope: scope, zoneState: state)
    }
    func createAfterReviewedDecision(_ inspection: Inspection) async throws -> Inspection {
        guard inspection.zoneState == .missing else { throw ReaderError.message("The iCloud recovery zone needs review.") }
        let zone = try access(inspection)
        try await zone.createAfterReviewedDecision()
        guard try await zone.inspect() == .present else { throw ReaderError.message("The iCloud recovery zone is unavailable.") }
        return Inspection(serviceID: id, token: inspection.token, scope: inspection.scope, zoneState: .present)
    }
    func validate(_ inspection: Inspection) async throws -> Bool {
        guard inspection.zoneState == .present else { return false }
        _ = try access(inspection)
        return try await monitor.validate(inspection.token)
    }
    func migrateEarlierLibrary(_ inspection: Inspection) async throws {
        _ = try access(inspection)
        guard let legacyRunner, try await monitor.validate(inspection.token) else {
            throw ReaderError.message("The iCloud account changed. Recovery is paused.")
        }
        try await legacyRunner(inspection.scope, fence(inspection.token))
    }
    func switchRecoveryAccount(_ inspection: Inspection) async throws {
        guard inspection.zoneState == .present, let accountSwitchRunner else {
            throw ReaderError.message("The destination recovery area needs review.")
        }
        let zone = try access(inspection)
        guard try await zone.inspect() == .present else { throw ReaderError.message("The destination recovery area is unavailable.") }
        try await accountSwitchRunner(inspection.scope, fence(inspection.token))
    }
    func run(_ inspection: Inspection, ifEnabled allowed: @escaping @MainActor () -> Bool = { true }) async throws -> StandaloneRecoveryCycle.Report {
        guard allowed(), inspection.zoneState == .present else { throw ReaderError.message("The iCloud recovery zone needs review.") }
        let zone = try access(inspection)
        guard try await zone.inspect() == .present, allowed() else { throw ReaderError.message("The iCloud recovery zone needs review.") }
        let accountFence = fence(inspection.token)
        let combined: @MainActor () async throws -> Bool = {
            guard allowed(), try await accountFence(), allowed() else { return false }
            return true
        }
        let result = try await runner(inspection.scope, inspection.scope.recoveryZoneID, combined)
        guard try await combined() else { throw ReaderError.message("The iCloud account changed. Recovery is paused.") }
        return result
    }
}

extension AppModel {
    /// The caller controls when to inspect, create a new zone, and run. No
    /// CloudKit request occurs merely by constructing this service.
    var canRecoverOpenJellyfinBook: Bool {
        !readingOnDevice && account != nil && reader != nil && readerLaunchBook?.id == reader?.id
    }

    func makeJellyfinCloudRecoveryService() throws -> StandaloneCloudRecoveryService {
        guard canRecoverOpenJellyfinBook, let account else { throw ReaderError.message("Open a Jellyfin book first.") }
        let monitor = CloudReadingAccountMonitor()
        guard let database = monitor.privateDatabase else { throw ReaderError.message("iCloud is unavailable.") }
        let zones = CloudKitRecoveryZoneDatabase(database: database)
        let source = try CloudReadingSource.scopedJellyfin(account)
        return StandaloneCloudRecoveryService(monitor: monitor, zones: zones, source: source, legacyRunner: { [weak self] scope, fence in
            guard let self else { throw CancellationError() }
            try await self.migrateEarlierJellyfinRecovery(scope: scope, database: database, accountIsCurrent: fence)
        }, accountSwitchRunner: { [weak self] scope, fence in
            guard let self else { throw CancellationError() }
            try await self.switchJellyfinRecoveryAccount(scope: scope, database: database, accountIsCurrent: fence)
        }) { [weak self] scope, zoneID, fence in
            guard let self else { throw CancellationError() }
            let pages = CloudKitRecoveryPageSource(database: database, zoneID: zoneID)
            let records = CloudKitReadingRecordDatabase(database: database)
            let result = try await self.runJellyfinReadingRecovery(scope: scope, zoneID: zoneID, pages: pages,
                                                                   database: records, accountIsCurrent: fence)
            var report = StandaloneRecoveryCycle.Report()
            report.appliedReadingItems = result.applied; report.needsReview = result.needsReview
            report.pendingItems = result.pendingItems; report.failures = result.failures
            return report
        }
    }

    func makeStandaloneCloudRecoveryService() throws -> StandaloneCloudRecoveryService {
        let monitor = CloudReadingAccountMonitor()
        guard let database = monitor.privateDatabase else { throw ReaderError.message("iCloud is unavailable.") }
        let zones = CloudKitRecoveryZoneDatabase(database: database)
        return StandaloneCloudRecoveryService(monitor: monitor, zones: zones, accountSwitchRunner: { [weak self] scope, fence in
            guard let self else { throw CancellationError() }
            try await self.switchStandaloneRecoveryAccount(scope: scope, database: database, accountIsCurrent: fence)
        }) { [weak self] scope, zoneID, fence in
            guard let self else { throw CancellationError() }
            let pages = CloudKitRecoveryPageSource(database: database, zoneID: zoneID)
            let records = CloudKitReadingRecordDatabase(database: database)
            return try await self.runStandaloneRecovery(scope: scope, zoneID: zoneID, pages: pages,
                                                        database: records, accountIsCurrent: fence)
        }
    }
}

/// A local pending item whose edition must be confirmed by a reader.
struct StandaloneReadingReviewItem: Identifiable {
    let book: LocalBookEntry
    let cloudBookID: String
    let key: CloudReadingKey
    let revision: UUID
    let payload: CloudReadingPayload?
    let hasConflict: Bool
    var id: String { "\(key.recordName)-\(revision.uuidString)" }

    @MainActor static func collect(store: CloudAtomicReadingStore, books: [LocalBookEntry]) -> [Self] {
        guard let bindings = store.localToCloudBookIDs else { return [] }
        let byID = Dictionary(grouping: books, by: \.id)
        return store.outbox.values.compactMap { item in
            guard item.entry.pending, item.pendingApplication != true, item.entry.current.editionFingerprint == nil,
                  let local = bindings.first(where: { $0.value == item.bookID })?.key,
                  let matches = byID[local], matches.count == 1, let book = matches.first,
                  book.cloudIdentities?[store.scope.cloudAccountKey]?.readingBookID == item.bookID else { return nil }
            return Self(book: book, cloudBookID: item.bookID, key: item.entry.key,
                        revision: item.entry.current.revision, payload: item.entry.current.payload,
                        hasConflict: !item.entry.conflicts.isEmpty)
        }.sorted { ($0.book.title, $0.id) < ($1.book.title, $1.id) }
    }
}

struct StandaloneIncomingReadingItem: Identifiable {
    let book: LocalBookEntry
    let cloudBookID: String
    let key: CloudReadingKey
    let revision: UUID
    let payload: CloudReadingPayload?
    let editionFingerprint: String?
    var id: String { "\(key.recordName)-\(revision.uuidString)" }

    @MainActor static func collect(store: CloudAtomicReadingStore, books: [LocalBookEntry]) -> [Self] {
        guard let bindings = store.localToCloudBookIDs else { return [] }
        let byID = Dictionary(grouping: books, by: \.id)
        return store.outbox.values.compactMap { item in
            guard item.pendingApplication == true, item.entry.conflicts.isEmpty,
                  let local = bindings.first(where: { $0.value == item.bookID })?.key,
                  let matches = byID[local], matches.count == 1, let book = matches.first,
                  book.cloudIdentities?[store.scope.cloudAccountKey]?.readingBookID == item.bookID else { return nil }
            return Self(book: book, cloudBookID: item.bookID, key: item.entry.key,
                        revision: item.entry.current.revision, payload: item.entry.current.payload,
                        editionFingerprint: item.entry.current.editionFingerprint)
        }.sorted { ($0.book.title, $0.id) < ($1.book.title, $1.id) }
    }
}

/// Both versions are retained until a specific alternative is chosen.
struct StandaloneReadingConflictItem: Identifiable {
    let book: LocalBookEntry
    let cloudBookID: String
    let key: CloudReadingKey
    let local: CloudReadingVersion
    let remote: CloudReadingVersion
    let currentIsStaged: Bool
    var id: String { "\(key.recordName)-\(local.revision.uuidString)-\(remote.revision.uuidString)" }

    @MainActor static func collect(store: CloudAtomicReadingStore, books: [LocalBookEntry]) -> [Self] {
        guard let bindings = store.localToCloudBookIDs else { return [] }
        let byID = Dictionary(grouping: books, by: \.id)
        return store.outbox.values.flatMap { item -> [Self] in
            guard let localID = bindings.first(where: { $0.value == item.bookID })?.key,
                  let matches = byID[localID], matches.count == 1, let book = matches.first,
                  book.cloudIdentities?[store.scope.cloudAccountKey]?.readingBookID == item.bookID else { return [] }
            return item.entry.conflicts.map { remote in
                Self(book: book, cloudBookID: item.bookID, key: item.entry.key, local: item.entry.current, remote: remote,
                     currentIsStaged: item.pendingApplication == true)
            }
        }.sorted { ($0.book.title, $0.id) < ($1.book.title, $1.id) }
    }
}

struct StandaloneDeletedBackupItem: Identifiable {
    let bookID: CloudStandaloneBookID
    let book: LocalBookEntry
    let revision: UUID
    let needsReview: Bool
    var id: String { "\(bookID.readingBookID)-\(revision.uuidString)" }

    @MainActor static func collect(journal: CloudBookJournal, books: [LocalBookEntry]) -> [Self] {
        let grouped = Dictionary(grouping: books.compactMap { book -> (CloudStandaloneBookID, LocalBookEntry)? in
            guard let id = book.cloudIdentities?[journal.scope.cloudAccountKey] else { return nil }
            return (id, book)
        }, by: { $0.0 })
        return journal.entries.values.compactMap { entry in
            guard case .tombstone = entry.current, !entry.pending, entry.conflicts.isEmpty,
                  entry.baseRevision == entry.current.revision,
                  let matches = grouped[entry.bookID], matches.count == 1, let book = matches.first?.1 else { return nil }
            return Self(bookID: entry.bookID, book: book, revision: entry.current.revision, needsReview: entry.pendingApplication)
        }.sorted { ($0.book.title, $0.id) < ($1.book.title, $1.id) }
    }
}

struct StandaloneBookConflictItem: Identifiable {
    let bookID: CloudStandaloneBookID
    let title: String
    let current: CloudBookJournalVersion
    let remote: CloudBookJournalVersion
    let currentIsStaged: Bool
    var id: String { "\(bookID.readingBookID)-\(current.revision.uuidString)-\(remote.revision.uuidString)" }

    @MainActor static func collect(journal: CloudBookJournal, books: [LocalBookEntry]) -> [Self] {
        let grouped = Dictionary(grouping: books.compactMap { book -> (CloudStandaloneBookID, LocalBookEntry)? in
            guard let identity = book.cloudIdentities?[journal.scope.cloudAccountKey] else { return nil }
            return (identity, book)
        }, by: { $0.0 })
        return journal.entries.values.flatMap { entry -> [Self] in
            let matches = grouped[entry.bookID] ?? []
            guard matches.count <= 1 else { return [] }
            let title: String
            if let book = matches.first?.1 { title = book.title }
            else if case .book(let metadata) = entry.current { title = metadata.title }
            else if let metadata = entry.conflicts.compactMap({ version -> CloudBookMetadata? in
                if case .book(let book) = version { return book }; return nil
            }).first { title = metadata.title }
            else { title = "Book" }
            return entry.conflicts.map { remote in
                Self(bookID: entry.bookID, title: title, current: entry.current, remote: remote,
                     currentIsStaged: entry.pendingApplication)
            }
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
}

/// Bounded foreground retries; reopening the app starts a fresh schedule.
struct AutomaticRecoveryRetryPolicy {
    private(set) var failures = 0
    private(set) var nextAttempt = Date.distantPast
    func isDue(at now: Date) -> Bool { now >= nextAttempt }
    mutating func reset() { failures = 0; nextAttempt = .distantPast }
    mutating func recordSuccess(at now: Date) { failures = 0; nextAttempt = now.addingTimeInterval(300) }
    mutating func recordFailure(at now: Date) {
        failures = min(failures + 1, 6)
        let delay = min(900.0, 30.0 * pow(2.0, Double(failures - 1)))
        nextAttempt = now.addingTimeInterval(delay)
    }
}

struct JellyfinPositionCandidate {
    let key: CloudReadingKey
    let revision: UUID
    let position: ReadingPosition
    var editionFingerprint: String? = nil
}

struct JellyfinIncomingReadingItem: Identifiable {
    let bookID: String
    let key: CloudReadingKey
    let revision: UUID
    let payload: CloudReadingPayload?
    let editionFingerprint: String?
    var id: String { "\(key.recordName)-\(revision.uuidString)" }

    @MainActor static func collect(store: CloudAtomicReadingStore, book: Book) -> [Self] {
        guard store.localToCloudBookIDs == nil else { return [] }
        return store.outbox.values.compactMap { item in
            guard item.bookID == book.id, (item.entry.key.kind != .position || item.entry.current.payload == nil),
                  item.pendingApplication == true, item.entry.conflicts.isEmpty else { return nil }
            return Self(bookID: book.id, key: item.entry.key, revision: item.entry.current.revision,
                        payload: item.entry.current.payload, editionFingerprint: item.entry.current.editionFingerprint)
        }.sorted { $0.id < $1.id }
    }
}

struct JellyfinReadingReviewItem: Identifiable {
    let bookID: String
    let key: CloudReadingKey
    let current: CloudReadingVersion
    let remote: CloudReadingVersion?
    let currentIsStaged: Bool
    var id: String { "\(key.recordName)-\(current.revision.uuidString)-\(remote?.revision.uuidString ?? "local")" }

    @MainActor static func collect(store: CloudAtomicReadingStore, book: Book) -> [Self] {
        guard store.localToCloudBookIDs == nil else { return [] }
        return store.outbox.values.filter { $0.bookID == book.id }.flatMap { item -> [Self] in
            var result: [Self] = []
            if item.entry.pending, item.pendingApplication != true, item.entry.current.editionFingerprint == nil {
                result.append(Self(bookID: book.id, key: item.entry.key, current: item.entry.current, remote: nil, currentIsStaged: false))
            }
            result += item.entry.conflicts.map { remote in
                Self(bookID: book.id, key: item.entry.key, current: item.entry.current, remote: remote,
                     currentIsStaged: item.pendingApplication == true)
            }
            return result
        }.sorted { $0.id < $1.id }
    }
}
