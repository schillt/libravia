import Foundation
import JellyfinAPI
import Get

enum JellyfinAuthenticationError: LocalizedError {
    case unauthorized
    var errorDescription: String? { "Your login was rejected or has expired. Sign out and reconnect." }
}

enum JellyfinContentError: LocalizedError {
    case notFound
    var errorDescription: String? { "This item is no longer available on the server." }
}

final class DownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 512 * 1024 * 1024 { downloadTask.cancel(); return }
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class ResponsePolicy: APIClientDelegate {
    func client(_ client: APIClient, validateResponse response: HTTPURLResponse, data: Data, task: URLSessionTask) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw JellyfinAuthenticationError.unauthorized
        case 403: throw ReaderError.message("This account does not have permission to access this content.")
        case 404: throw JellyfinContentError.notFound
        default: throw ReaderError.message("The server could not complete the request. Try again.")
        }
    }
}
final class JellyfinProvider: AuthenticationProvider, CatalogProvider, ContentProvider, ProgressProvider, @unchecked Sendable {
    private let metadataCache = CatalogMetadataCache()
    private let cursorStore = JellyfinCatalogCursors()
    let account: Account?
    private let configuration: URLSessionConfiguration
    private var authenticatedClient: JellyfinClient?
    init(account: Account? = nil, configuration: URLSessionConfiguration? = nil) {
        self.account = account
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.configuration = config
        if let account, (try? Self.serverURL(account.server.absoluteString)) != nil {
            authenticatedClient = makeClient(server: account.server, token: account.token)
        }
    }
    private func makeClient(server: URL, token: String? = nil) -> JellyfinClient {
        JellyfinClient(configuration: .init(url: server, accessToken: token, client: "LibraVia", deviceName: "Apple", deviceID: Self.deviceID(for: server), version: "0.1.0"), delegate: ResponsePolicy(), sessionConfiguration: configuration, sessionDelegate: NoRedirect())
    }
    private var client: JellyfinClient {
        get throws { guard let authenticatedClient else { throw ReaderError.message("Connect to a server first.") }; return authenticatedClient }
    }
    static func serverURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ReaderError.message("Enter a complete HTTPS server URL, including any base path.") }
        return url
    }
    // A separate pseudonymous identifier per server avoids linking accounts across servers.
    private static func deviceID(for server: URL) -> String {
        let key = "jellyfin-device-\(stableKey(server.absoluteString))"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
    func login(server: URL, username: String, password: String) async throws -> Account {
        let server = try Self.serverURL(server.absoluteString)
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReaderError.message("Enter your Jellyfin username.") }
        let client = makeClient(server: server)
        let info = try await client.send(Paths.getPublicSystemInfo).value
        guard info.version?.split(separator: ".").first == "12" else { throw ReaderError.message("This app requires Jellyfin 12.") }
        let auth = try await client.signIn(username: username, password: password)
        guard let token = auth.accessToken, let user = auth.user, let id = user.id, let serverID = auth.serverID, !token.isEmpty, !id.isEmpty, !serverID.isEmpty else {
            try? await client.signOut()
            throw ReaderError.message("The server returned an incomplete login.")
        }
        return Account(server: server, userID: id, serverID: serverID, username: user.name ?? username, token: token)
    }
    /// Revokes this Jellyfin session. Local cleanup remains the caller's responsibility even if offline.
    func signOut() async throws { try await client.signOut() }
    func profileImage() async throws -> Data? {
        let user = try await client.send(Paths.getCurrentUser).value
        guard let tag = user.primaryImageTag, !tag.isEmpty else { return nil }
        do { return try await client.data(for: Paths.getUserImage(parameters: .init(userID: account?.userID, tag: tag))).value }
        catch JellyfinContentError.notFound { return nil }
    }
    func validate() async throws { _ = try await client.send(Paths.getCurrentUser) }
    func libraries() async throws -> [Library] {
        let response = try await client.send(Paths.getUserViews(parameters: .init(userID: account?.userID))).value
        return (response.items ?? []).filter { $0.collectionType == .books }.compactMap { item in item.id.map { Library(id: $0, name: item.name ?? "Books") } }
    }
    func browse(parent: String?, query: String = "", start: Int = 0, resume: Bool = false) async throws -> CatalogPage {
        let result: BaseItemDtoQueryResult
        if resume {
            result = try await client.send(Paths.getResumeItems(parameters: .init(userID: account?.userID, startIndex: start, limit: 60, searchTerm: query.isEmpty ? nil : query, parentID: parent, fields: [.path, .overview, .people], enableUserData: true, includeItemTypes: [.book]))).value
        } else {
            var parameters = Paths.GetItemsParameters()
            parameters.userID = account?.userID; parameters.startIndex = start; parameters.limit = 60
            parameters.parentID = parent; parameters.fields = [.path, .overview, .people]; parameters.enableUserData = true
            parameters.sortBy = [.sortName]; parameters.sortOrder = [.ascending]
            parameters.includeItemTypes = query.isEmpty ? [.book, .folder] : [.book]
            if !query.isEmpty { parameters.searchTerm = query; parameters.isRecursive = true }
            result = try await client.send(Paths.getItems(parameters: parameters)).value
        }
        return CatalogPage(items: (result.items ?? []).compactMap(Self.model), total: result.totalRecordCount ?? 0)
    }
    private static func model(_ item: BaseItemDto) -> Book? {
        guard let id = item.id else { return nil }
        let authors = (item.people ?? []).filter { $0.type == .author || $0.type == .writer }.compactMap { person -> BookAuthor? in
            guard let name = person.name, !name.isEmpty else { return nil }
            return BookAuthor(name: name, imageTag: person.primaryImageTag, id: person.id)
        }
        return Book(id: id, title: item.name ?? "Untitled", author: authors.map(\.name).joined(separator: ", "), summary: item.overview ?? "", format: BookFormat(path: item.path), isFolder: item.isFolder ?? false, imageTag: item.imageTags?["Primary"], ticks: Int64(item.userData?.playbackPositionTicks ?? 0), readingStatus: item.userData?.isPlayed == true ? .finished : ((item.userData?.playbackPositionTicks ?? 0) > 0 ? .inProgress : .notFinished), authors: authors)
    }
    func book(id: String) async throws -> Book {
        let item = try await client.send(Paths.getItem(itemID: id, userID: account?.userID)).value
        guard let book = Self.model(item) else { throw ReaderError.message("The server returned an incomplete book.") }; return book
    }
    func similar(to book: Book) async throws -> [Book] {
        let result = try await client.send(Paths.getSimilarItems(itemID: book.id, parameters: .init(userID: account?.userID, limit: 12, fields: [.path, .overview, .people]))).value
        return (result.items ?? []).filter { $0.type == .book && $0.id != book.id }.compactMap(Self.model)
    }
    func markFinished(_ book: Book) async throws -> Int64 {
        try await setFinished(book, finished: true)
    }
    func setFinished(_ book: Book, finished: Bool) async throws -> Int64 {
        let request = finished ? Paths.markPlayedItem(itemID: book.id, userID: account?.userID) : Paths.markUnplayedItem(itemID: book.id, userID: account?.userID)
        let result = try await client.send(request).value
        return Int64(result.playbackPositionTicks ?? 0)
    }
    func remoteTicks(id: String) async throws -> Int64 { try await book(id: id).ticks }
    func report(id: String, ticks: Int64) async throws {
        var state = PlaybackStateInfo(); state.itemID = id; state.positionTicks = Int(ticks); state.isPaused = true; state.canSeek = true; state.playMethod = .directPlay
        try await client.send(Paths.reportPlaybackProgress(state))
    }
    func download(_ book: Book, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await client.download(for: Paths.getDownload(itemID: book.id), delegate: DownloadObserver(progress)).value
    }
    func cover(_ book: Book, fullSize: Bool = false) async throws -> Data {
        try await client.data(for: Paths.getItemImage(itemID: book.id, imageType: "Primary", parameters: .init(maxWidth: fullSize ? nil : 360, tag: book.imageTag))).value
    }
    func authorImage(_ author: BookAuthor) async throws -> Data? {
        do {
            var personID = author.id
            var tag = author.imageTag
            if personID == nil {
                let person = try await client.send(Paths.getPerson(name: author.name, userID: account?.userID)).value
                personID = person.id; tag = person.imageTags?["Primary"] ?? tag
            }
            if let personID {
                return try await client.data(for: Paths.getItemImage(itemID: personID, imageType: "Primary", parameters: .init(maxWidth: 160, tag: tag))).value
            }
            return try await client.data(for: Paths.getPersonImage(name: author.name, imageType: "Primary", parameters: .init(tag: tag, maxWidth: 160))).value
        } catch JellyfinContentError.notFound { return nil }
    }
}

private struct JellyfinCatalogBuffer: Sendable {
    var library: Library
    var parent: String
    var items: [BaseItemDto] = []
    var offset = 0
    var total = 0
}
private struct JellyfinCatalogCursor: Sendable {
    var request: CatalogRequest
    var buffers: [JellyfinCatalogBuffer]
}
private actor JellyfinCatalogCursors {
    private var values: [String: JellyfinCatalogCursor] = [:]
    private var order: [String] = []
    private var generation = 0
    func currentGeneration() -> Int { generation }
    func validate(_ expected: Int) throws { if expected != generation { throw CancellationError() } }
    func get(_ id: String) -> JellyfinCatalogCursor? { values[id] }
    func put(_ value: JellyfinCatalogCursor, generation expected: Int) throws -> String {
        try validate(expected)
        let id = UUID().uuidString
        values[id] = value; order.append(id)
        // Cursors retain only a bounded set of recent page buffers, never a catalog index.
        while order.count > 8 { values.removeValue(forKey: order.removeFirst()) }
        return id
    }
    func clear() { generation += 1; values.removeAll(); order.removeAll() }
}

extension JellyfinProvider {
    private func catalogParents(_ scope: CatalogScope) -> [(Library, String)] {
        if let parent = scope.parentID, let library = scope.libraries.first { return [(library, parent)] }
        return scope.libraries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { ($0, $0.id) }
    }
    /// Kept internal so request mapping is tested without duplicating SDK transport.
    static func catalogParameters(_ request: CatalogRequest, parent: String, userID: String?, start: Int = 0, limit: Int = 60, countOnly: Bool = false) -> Paths.GetItemsParameters {
        var p = Paths.GetItemsParameters()
        p.userID = userID; p.parentID = parent; p.startIndex = start; p.limit = limit
        p.enableTotalRecordCount = true; p.enableUserData = !countOnly
        p.fields = countOnly ? [] : [.path, .overview, .people, .sortName, .dateCreated]
        p.enableImages = !countOnly
        p.isRecursive = request.sort == .recentlyAdded || countOnly || !request.query.isEmpty || !request.filters.isEmpty || request.scope.parentID == nil
        p.includeItemTypes = p.isRecursive == true ? [.book] : [.book, .folder]
        p.searchTerm = request.query.isEmpty ? nil : request.query
        p.sortBy = request.sort == .recentlyAdded ? [.dateCreated, .sortName] : [.sortName]
        p.sortOrder = [request.sort == .titleAscending ? .ascending : .descending]
        p.personIDs = request.filters.author.map { [$0.id] }
        p.personTypes = request.filters.author == nil ? nil : ["Author", "Writer"]
        p.genres = request.filters.genre.map { [$0.name] }; p.tags = request.filters.tag.map { [$0.name] }
        switch request.filters.status {
        case .finished: p.isPlayed = true
        case .notFinished: p.isPlayed = false
        case .inProgress: p.filters = [.isResumable]
        case nil: break
        }
        return p
    }
    func catalog(_ request: CatalogRequest) async throws -> CatalogPage {
        try Task.checkCancellation()
        let generation = await cursorStore.currentGeneration()
        var identity = request; identity.cursor = nil; identity.start = 0
        var state: JellyfinCatalogCursor
        if let cursor = request.cursor {
            guard let saved = await cursorStore.get(cursor), saved.request == identity else {
                throw ReaderError.message("These results have expired. Refresh to search again.")
            }
            state = saved
        } else {
            var buffers: [JellyfinCatalogBuffer] = []
            // Sequential initial pages bound in-flight catalog requests to one.
            for (library, parent) in catalogParents(request.scope) {
                try Task.checkCancellation()
                let result = try await client.send(Paths.getItems(parameters: Self.catalogParameters(request, parent: parent, userID: account?.userID))).value
                let items = result.items ?? []
                buffers.append(.init(library: library, parent: parent, items: items, offset: items.count, total: result.totalRecordCount ?? items.count))
            }
            state = .init(request: identity, buffers: buffers)
        }
        var output: [Book] = []
        while output.count < 60 {
            try Task.checkCancellation()
            for index in state.buffers.indices where state.buffers[index].items.isEmpty && state.buffers[index].offset < state.buffers[index].total {
                let buffer = state.buffers[index]
                let result = try await client.send(Paths.getItems(parameters: Self.catalogParameters(request, parent: buffer.parent, userID: account?.userID, start: buffer.offset))).value
                let items = result.items ?? []
                state.buffers[index].items = items
                state.buffers[index].offset += items.count
                state.buffers[index].total = items.isEmpty ? buffer.offset : (result.totalRecordCount ?? buffer.total)
            }
            let available = state.buffers.indices.filter { !state.buffers[$0].items.isEmpty }
            guard let selected = available.min(by: { lhs, rhs in
                let a = state.buffers[lhs].items[0], b = state.buffers[rhs].items[0]
                if request.sort == .recentlyAdded, a.dateCreated != b.dateCreated { return (a.dateCreated ?? .distantPast) > (b.dateCreated ?? .distantPast) }
                let comparison = (a.sortName ?? a.name ?? "").localizedStandardCompare(b.sortName ?? b.name ?? "")
                // Preserve server order for equal keys, choosing the library order across streams.
                // The SDK exposes no ID sort key to stabilize server-side offset paging.
                if comparison == .orderedSame { return lhs < rhs }
                return request.sort == .titleAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }) else { break }
            let item = state.buffers[selected].items.removeFirst()
            if var book = Self.model(item) {
                book.libraryID = state.buffers[selected].library.id; book.libraryName = state.buffers[selected].library.name
                output.append(book)
            }
        }
        try Task.checkCancellation()
        let hasMore = state.buffers.contains { !$0.items.isEmpty || $0.offset < $0.total }
        try await cursorStore.validate(generation)
        let cursor = hasMore ? try await cursorStore.put(state, generation: generation) : nil
        return CatalogPage(items: output, total: state.buffers.reduce(0) { $0 + $1.total }, nextCursor: cursor)
    }
    private func count(scope: CatalogScope, filters: CatalogFilters = .init()) async throws -> Int {
        var total = 0
        for (_, parent) in catalogParents(scope) {
            try Task.checkCancellation()
            let request = CatalogRequest(scope: scope, filters: filters)
            let value = try await client.send(Paths.getItems(parameters: Self.catalogParameters(request, parent: parent, userID: account?.userID, limit: 0, countOnly: true))).value
            guard let count = value.totalRecordCount else { throw ReaderError.message("The server did not provide filter counts.") }
            total += count
        }
        return total
    }
    func filterOptions(scope: CatalogScope) async throws -> CatalogFilterOptions {
        let (cached, generation) = await metadataCache.snapshot(scope)
        if let cached { return cached }
        let total = try await count(scope: scope)
        var options = CatalogFilterOptions()
        guard total > 1 else {
            await metadataCache.insert(options, scope: scope, generation: generation); return options
        }
        var genres = Set<String>(), tags = Set<String>()
        for (_, parent) in catalogParents(scope) {
            try Task.checkCancellation()
            let value = try await client.send(Paths.getQueryFiltersLegacy(parameters: .init(userID: account?.userID, parentID: parent, includeItemTypes: [.book]))).value
            genres.formUnion(value.genres ?? []); tags.formUnion(value.tags ?? [])
        }
        // The scoped filter endpoint already supplies available values. Avoid one
        // round-trip per value, which made large libraries unusably slow.
        if genres.count > 1 { options.genres = genres.filter { !$0.isEmpty }.sorted().map { .init(id: $0, name: $0) } }
        if tags.count > 1 { options.tags = tags.filter { !$0.isEmpty }.sorted().map { .init(id: $0, name: $0) } }
        for status in CatalogReadingStatus.allCases {
            let matches = try await count(scope: scope, filters: .init(status: status))
            if matches > 0 && matches < total { options.statuses.append(status) }
        }
        let authorPage = try await authors(scope: scope, query: "", start: 0)
        options.authorsAvailable = authorPage.total > 1
        try Task.checkCancellation()
        await metadataCache.insert(options, scope: scope, generation: generation)
        return options
    }
    func authors(scope: CatalogScope, query: String, start: Int) async throws -> CatalogAuthorPage {
        var skip = max(0, start), total = 0, consumed = 0, candidates: [CatalogOption] = []
        for (_, parent) in catalogParents(scope) {
            try Task.checkCancellation()
            let p = Paths.GetPersonsParameters(startIndex: skip, limit: max(0, 20 - consumed), searchTerm: query.isEmpty ? nil : query, enableUserData: false, personTypes: ["Author", "Writer"], parentID: parent, userID: account?.userID, enableImages: false)
            let result = try await client.send(Paths.getPersons(parameters: p)).value
            let count = result.totalRecordCount ?? 0; total += count
            if skip >= count { skip -= count; continue }
            skip = 0
            let items = result.items ?? []; consumed += items.count
            candidates += items.compactMap { item in item.id.map { CatalogOption(id: $0, name: item.name ?? "Unknown author", imageTag: item.imageTags?["Primary"]) } }
        }
        return .init(items: Array(Dictionary(grouping: candidates, by: \.id).values.compactMap(\.first)), total: total, consumed: consumed)
    }
    func discoveryAuthors(scope: CatalogScope, query: String, start: Int) async throws -> CatalogAuthorPage {
        var skip = max(0, start), total = 0, consumed = 0, candidates: [CatalogOption] = []
        for (_, parent) in catalogParents(scope) {
            try Task.checkCancellation()
            let parameters = Paths.GetPersonsParameters(startIndex: skip, limit: max(0, 20 - consumed), searchTerm: query.isEmpty ? nil : query, enableUserData: false, personTypes: ["Author", "Writer"], parentID: parent, userID: account?.userID, enableImages: true)
            let page = try await client.send(Paths.getPersons(parameters: parameters)).value
            let count = page.totalRecordCount ?? 0; total += count
            if skip >= count { skip -= count; continue }
            skip = 0
            let items = page.items ?? []; consumed += items.count
            candidates += items.compactMap { item in item.id.map { CatalogOption(id: $0, name: item.name ?? "Unknown author", imageTag: item.imageTags?["Primary"]) } }
        }
        return .init(items: Array(Set(candidates)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, total: total, consumed: consumed)
    }
    func discoveryGenres(scope: CatalogScope) async throws -> [CatalogOption] {
        var names = Set<String>()
        for (_, parent) in catalogParents(scope) {
            try Task.checkCancellation()
            let value = try await client.send(Paths.getQueryFiltersLegacy(parameters: .init(userID: account?.userID, parentID: parent, includeItemTypes: [.book]))).value
            names.formUnion(value.genres ?? [])
        }
        return names.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { CatalogOption(id: $0, name: $0) }
    }
    func discoveryCollections(scope: CatalogScope, query: String, start: Int) async throws -> CatalogCollectionPage {
        try Task.checkCancellation()
        var skip = max(0, start), total = 0, consumed = 0, options: [CatalogOption] = []
        for (_, parent) in catalogParents(scope) {
            try Task.checkCancellation()
            var parameters = Paths.GetItemsParameters()
            parameters.userID = account?.userID; parameters.parentID = parent
            parameters.startIndex = skip; parameters.limit = max(0, 20 - consumed)
            // Jellyfin 12's book library returns its folders in the mixed
            // Book+Folder listing, including servers that omit them from a
            // Folder-only query. Keep paging the server's raw result set.
            parameters.includeItemTypes = [.book, .folder]; parameters.isRecursive = false
            parameters.searchTerm = query.isEmpty ? nil : query
            parameters.enableTotalRecordCount = true; parameters.enableImages = true
            parameters.sortBy = [.sortName]; parameters.sortOrder = [.ascending]
            let result = try await client.send(Paths.getItems(parameters: parameters)).value
            let count = result.totalRecordCount ?? 0; total += count
            if skip >= count { skip -= count; continue }
            skip = 0
            let entries = result.items ?? []; consumed += entries.count
            options += entries.filter { $0.isFolder == true }.compactMap { item in item.id.map { CatalogOption(id: $0, name: item.name ?? "Untitled collection", imageTag: item.imageTags?["Primary"]) } }
        }
        return .init(items: options, total: total, consumed: consumed)
    }
    func suggestedBooks(scope: CatalogScope, limit: Int) async throws -> [Book] {
        guard limit > 0 else { return [] }
        var suggestions: [Book] = []
        for (library, parent) in catalogParents(scope) {
            try Task.checkCancellation()
            var parameters = Self.catalogParameters(.init(scope: scope), parent: parent, userID: account?.userID, limit: min(limit, 12))
            parameters.isRecursive = true; parameters.includeItemTypes = [.book]
            parameters.sortBy = [.random]; parameters.sortOrder = nil
            let result = try await client.send(Paths.getItems(parameters: parameters)).value
            for item in result.items ?? [] {
                if var book = Self.model(item), book.format != .unsupported {
                    book.libraryID = library.id; book.libraryName = library.name
                    suggestions.append(book)
                }
            }
        }
        return Array(Dictionary(grouping: suggestions, by: \.id).values.compactMap(\.first).shuffled().prefix(limit))
    }
    func invalidateCatalogMetadata() async {
        await metadataCache.clear()
        await cursorStore.clear()
    }
}
