import SwiftUI
import Observation

@MainActor @Observable final class AppModel {
    var account: Account?
    var provider: JellyfinProvider?
    var store: ReadingStore?
    var cache: BookCache?
    var libraries: [Library] = []
    var selectedLibrary: String? { didSet { if let account { UserDefaults.standard.set(selectedLibrary, forKey: "library-\(stableKey(account.namespace))") } } }
    var error: String?
    var status: String?
    var connecting = false
    var downloadProgress: Double?
    var openingID: String?
    var reader: PreparedBook?
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
        artwork.object(forKey: "\(fullSize ? "original" : "cover")|\(book.id)|\(book.imageTag ?? "")" as NSString).map { $0 as Data }
    }
    func coverImage(_ book: Book, fullSize: Bool = false) async -> Data? {
        let key = "\(fullSize ? "original" : "cover")|\(book.id)|\(book.imageTag ?? "")" as NSString
        if let value = artwork.object(forKey: key) { return value as Data }
        let current = generation
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
    private(set) var cachedKeys: Set<String> = []
    private(set) var markingID: String?
    private var cacheRefreshID = UUID()
    func isCached(_ book: Book) -> Bool { cachedKeys.contains(stableKey(book.id)) }
    func refreshCache() async {
        let current = generation, request = UUID()
        cacheRefreshID = request
        let keys = (try? await cache?.availableKeys()) ?? []
        if current == generation, request == cacheRefreshID { cachedKeys = keys }
    }
    func removeDeviceCopy(_ book: Book) async {
        guard openingID == nil, reader?.id != book.id else { error = "Close the book or wait for the download before removing its device copy."; return }
        let current = generation
        do { try await cache?.remove(book); await refreshCache() }
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
        guard reader == nil, openingID == nil, markingID == nil, book.format != .unsupported else { return }
        openingID = book.id
        let current = generation
        openTask = Task {
            guard let provider, let cache else { openingID = nil; return }
            do {
                if await cache.cached(book) == nil {
                    downloadProgress = 0
                    let file = try await provider.download(book) { [weak self] value in
                        Task { @MainActor in if self?.generation == current, self?.openingID == book.id { self?.downloadProgress = value } }
                    }
                    defer { try? FileManager.default.removeItem(at: file) }
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    _ = try await cache.install(file, book: book, protectInstalled: false)
                }
                guard generation == current, !Task.isCancelled else { return }
                try await cache.evict()
                await refreshCache()
            } catch { if current == generation, !Task.isCancelled { self.error = UserFacingError.message(error) } }
            if current == generation, !Task.isCancelled { openingID = nil; downloadProgress = nil }
        }
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
        self.store = store; self.cache = cache; self.account = account; provider = JellyfinProvider(account: account)
        selectedLibrary = UserDefaults.standard.string(forKey: "library-\(stableKey(account.namespace))")
    }
    #if DEBUG
    func openSample(_ format: BookFormat) async {
        guard account == nil, let source = Bundle.main.url(forResource: "Harbor", withExtension: format.rawValue, subdirectory: "Fixtures") else { return }
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
        cancelOpen(); syncTask?.cancel(); syncFlight?.cancel(); generation = UUID(); syncFlight = nil; syncRunning = false
        let oldProvider = provider, oldCache = cache, oldStore = store, oldAccount = account
        // Release account-bound UI immediately, even if one cleanup operation fails.
        account = nil; provider = nil; store = nil; cache = nil; libraries = []
        cachedKeys = []; markingID = nil; librariesLoaded = false; librariesLoading = false
        profileImageTask?.cancel(); profileImageTask = nil; profileImageData = nil
        catalogSnapshots.removeAll(); discoveryBooks.removeAll(); discoveryCollections.removeAll(); localBooks.removeAll(); artwork.removeAllObjects()
        selectedLibrary = nil; reader = nil; conflict = nil; syncIssue = nil; status = nil; error = nil
        await oldProvider?.invalidateCatalogMetadata()
        var failures: [String] = []
        do { try deleteCredentials() } catch { failures.append("The saved login could not be removed from Keychain.") }
        do { try oldStore?.delete() } catch { failures.append("Some reading data could not be removed from this device.") }
        do { try await oldCache?.delete() } catch { failures.append("Some cached books could not be removed from this device.") }
        if let oldAccount { UserDefaults.standard.removeObject(forKey: "library-\(stableKey(oldAccount.namespace))") }
        do { try await oldProvider?.signOut() } catch { failures.append("The server session could not be revoked. You can revoke it from your Jellyfin server.") }
        connecting = false
        if !failures.isEmpty { error = failures.joined(separator: " ") }
    }
    func cancelOpen() { openTask?.cancel(); openTask = nil; openingID = nil; downloadProgress = nil; readerLaunchBook = nil }
    func open(_ book: Book) {
        guard markingID == nil else { return }
        guard book.format != .unsupported else { error = "This format is not supported. Choose an EPUB, PDF, or CBZ book."; return }
        cancelOpen(); error = nil; openingID = book.id; readerLaunchBook = book
        let current = generation
        openTask = Task { [weak self] in
            guard let self, let provider = self.provider, let cache = self.cache else { return }
            do {
                var position = self.store?.records[book.id]?.position ?? ReadingPosition.from(ticks: book.ticks, format: book.format)
                do {
                    let remoteBook = try await provider.book(id: book.id)
                    let ticks = remoteBook.ticks
                    try Task.checkCancellation()
                    guard current == self.generation else { throw CancellationError() }
                    if let local = self.store?.records[book.id], local.conflicts(with: ticks) {
                        self.blockProgress(book.id, reason: .conflict)
                        self.conflict = ProgressConflict(book: book, local: local.position, remote: .from(ticks: ticks, format: book.format), remoteTicks: ticks, serverFinished: remoteBook.readingStatus == .finished)
                        self.openingID = nil; return
                    }
                    if self.store?.records[book.id]?.syncBlock != nil, var local = self.store?.records[book.id] {
                        local.syncBlock = nil
                        try self.store?.set(local, id: book.id)
                    }
                    if self.store?.records[book.id]?.dirty != true {
                        let local = self.store?.records[book.id]
                        position = local?.acknowledgedTicks == ticks ? local!.position : .from(ticks: ticks, format: book.format)
                        try self.store?.set(ReadingRecord(position: position, acknowledgedTicks: ticks, dirty: false, updated: Date(), title: book.title, format: book.format), id: book.id)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard current == self.generation, !Task.isCancelled else { return }
                    self.syncIssue = self.store?.records[book.id]?.dirty == true ? .unavailable : .lookupUnavailable
                }
                guard current == self.generation, !Task.isCancelled else { return }
                try await self.prepare(book, position: position, provider: provider, cache: cache, generation: current)
                if self.store?.records[book.id]?.dirty == true { Task { await self.flushProgress() } }
            } catch { if !Task.isCancelled && current == self.generation { self.error = UserFacingError.message(error) } }
            if !Task.isCancelled && current == self.generation { self.openingID = nil; self.downloadProgress = nil }
        }
    }
    func resolveConflict(useLocal: Bool) {
        guard let conflict, let provider, let cache else { return }
        self.conflict = nil
        let position = useLocal ? conflict.local : conflict.remote
        do { try store?.set(ReadingRecord(position: position, acknowledgedTicks: conflict.remoteTicks, dirty: useLocal, updated: Date(), title: conflict.book.title, format: conflict.book.format), id: conflict.book.id) } catch { self.error = UserFacingError.message(error); return }
        openingID = conflict.book.id; readerLaunchBook = conflict.book
        let current = generation
        openTask = Task {
            do { try await prepare(conflict.book, position: position, provider: provider, cache: cache, generation: current) }
            catch { if current == generation, !Task.isCancelled { self.error = UserFacingError.message(error) } }
            if current == generation { openingID = nil; downloadProgress = nil }
        }
    }
    private func prepare(_ book: Book, position: ReadingPosition, provider: JellyfinProvider, cache: BookCache, generation current: UUID) async throws {
        await cache.protect(book.id)
        let directory: URL
        if let cached = await cache.cached(book) { directory = cached }
        else {
            downloadProgress = 0
            let file = try await provider.download(book) { [weak self] value in Task { @MainActor in if self?.generation == current, self?.openingID == book.id { self?.downloadProgress = value } } }
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            guard current == generation else { throw CancellationError() }
            directory = try await cache.install(file, book: book)
        }
        let content = try BookCache.contents(directory, format: book.format)
        try Task.checkCancellation()
        guard current == generation else { return }
        await refreshCache()
        guard current == generation, !Task.isCancelled, readerLaunchBook?.id == book.id else { return }
        reader = PreparedBook(book: book, directory: directory, document: content.0, images: content.1, position: position)
    }
    func savePosition(_ position: ReadingPosition, book: Book) {
        guard let store else { return }
        let previous = store.records[book.id]
        if previous?.position == position { return }
        let acknowledged = previous?.acknowledgedTicks ?? book.ticks
        let dirty = position.ticks(for: book.format) != acknowledged || (syncRunning && previous?.dirty == true)
        do { try store.set(ReadingRecord(position: position, acknowledgedTicks: acknowledged, dirty: dirty, updated: Date(), title: book.title, format: book.format, syncBlock: previous?.syncBlock), id: book.id) }
        catch { self.error = "Could not save your reading position on this device."; return }
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
                var itemLookupComplete = false
                do {
                    let remote = try await provider.remoteTicks(id: id)
                    itemLookupComplete = true
                    guard current == generation, !Task.isCancelled else { return }
                    let ticks = record.position.ticks(for: record.format)
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
        let current = generation
        do {
            let remoteBook = try await provider.book(id: candidate.id)
            guard current == generation else { return }
            let localTicks = old.position.ticks(for: old.format)
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
    @discardableResult func addBookmark(book: Book, position: ReadingPosition) -> Bool {
        let name = book.format == .epub ? "\(Int(position.fraction * 100))% · \(Date().formatted(date: .abbreviated, time: .shortened))" : "Page \(position.page + 1)"
        do {
            guard let store else { return false }
            let added = try store.addIfAbsent(Bookmark(name: name, position: position), id: book.id, format: book.format)
            if added { bookmarksRevision += 1 }
            return added
        } catch { self.error = UserFacingError.message(error); return false }
    }
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
