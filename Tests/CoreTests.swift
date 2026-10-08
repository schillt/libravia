import XCTest
@testable import BookCore

final class CoreTests: XCTestCase {
    @MainActor func testOverviewUsesNativeTextWithoutExternalResources() {
        XCTAssertEqual(BookOverview.plainText("<p>A <b>book</b> &amp; a story.</p><p>Next chapter &quot;two&quot;.</p>"), "A book & a story.\nNext chapter \"two\".")
        XCTAssertEqual(BookOverview.plainText("<script>bad()</script><style>body{}</style><p>Safe<img src='https://invalid.example/image'><iframe src='https://invalid.example'>hidden</iframe></p>"), "Safe")
        XCTAssertEqual(BookOverview.plainText("Plain text — unchanged."), "Plain text — unchanged.")
        XCTAssertEqual(BookOverview.plainText("<p>Caf&#233;&nbsp;reading</p>"), "Café reading")
    }

    func testLegacyReaderPreferencesKeepTypographyWhenPageTurnsAreAdded() throws {
        let saved = Data(#"{"theme":"sepia","font":"Palatino","fontSize":23,"lineHeight":1.7,"margin":32,"scrolling":false}"#.utf8)
        let preferences = try JSONDecoder().decode(ReaderPreferences.self, from: saved)
        XCTAssertEqual(preferences.theme, "sepia")
        XCTAssertEqual(preferences.fontSize, 23)
        XCTAssertEqual(preferences.pageTransition, "slide")
        XCTAssertEqual(try JSONDecoder().decode(ReaderPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }
    func testPaginationLabelsDistinguishExactPagesEstimatesAndScrolling() {
        XCTAssertEqual(ReaderPagination.bookLabel(at: 0, total: 20, estimated: false), "Page 1 of 20")
        XCTAssertEqual(ReaderPagination.bookLabel(at: 1, total: 20, estimated: false), "Page 20 of 20")
        XCTAssertEqual(ReaderPagination.bookLabel(at: 0.5, total: 20, estimated: true), "About page 11 of 20")
        XCTAssertEqual(ReaderPagination.bookLabel(at: 0.5, total: 20, estimated: true, scrolling: true), "50% through book")
        XCTAssertEqual(ReaderPagination.bookLabel(at: 0.5, total: 0, estimated: true), "Book page estimate unavailable")
        XCTAssertEqual(ReaderPagination.page(at: 0.7, total: 1), 1)
        XCTAssertEqual(ReaderPagination.page(at: 2, total: 20), 20)
        XCTAssertEqual(ReaderPagination.page(at: .nan, total: 20), 1)
        // Scrub previews and destination indices share the same one-based page mapping.
        XCTAssertEqual(ReaderPagination.page(at: 0.25, total: 9) - 1, 2)
    }
    func testProgressInteroperabilityUnits() {
        XCTAssertEqual(ReadingPosition(fraction: 0.42).ticks(for: .epub), 4_200_000)
        XCTAssertEqual(ReadingPosition(page: 7).ticks(for: .pdf), 70_000)
        XCTAssertEqual(ReadingPosition(page: 7).ticks(for: .cbz), 70_000)
        XCTAssertEqual(ReadingPosition.from(ticks: 4_200_000, format: .epub).fraction, 0.42)
        XCTAssertEqual(ReadingPosition.from(ticks: 70_000, format: .pdf).page, 7)
        XCTAssertEqual(ReadingPosition(fraction: 2).ticks(for: .epub), 10_000_000)
        XCTAssertEqual(ReadingPosition.from(ticks: -100, format: .cbz).page, 0)
    }
    func testOfflineConflictRequiresAnIndependentRemoteChange() {
        let local = ReadingRecord(position: ReadingPosition(fraction: 0.8), acknowledgedTicks: 2_000_000, dirty: true, updated: Date(), title: "Fixture", format: .epub)
        XCTAssertFalse(local.conflicts(with: 2_000_000))
        XCTAssertFalse(local.conflicts(with: 8_000_000))
        XCTAssertTrue(local.conflicts(with: 5_000_000))
        var clean = local; clean.dirty = false
        XCTAssertFalse(clean.conflicts(with: 5_000_000))
    }
    func testUnsafeArchiveEntriesRejected() throws {
        for path in ["../escape", "/absolute", "nested/../../escape", "C:/file", "nested\\escape"] {
            XCTAssertThrowsError(try BookCache.validateEntry(path: path, size: 1, total: 1, count: 1))
        }
        XCTAssertThrowsError(try BookCache.validateEntry(path: "safe", size: 129 * 1024 * 1024, total: 0, count: 1))
        XCTAssertThrowsError(try BookCache.validateEntry(path: "safe", size: 1, total: 769 * 1024 * 1024, count: 1))
        XCTAssertThrowsError(try BookCache.validateEntry(path: "safe", size: 1, total: 1, count: 10_001))
        XCTAssertNoThrow(try BookCache.validateEntry(path: "OPS/chapter.xhtml", size: 1024, total: 2048, count: 2))
    }
    func testServerURLValidationPreservesBasePath() throws {
        XCTAssertEqual(try JellyfinProvider.serverURL("https://example.com/jellyfin").path, "/jellyfin")
        for value in ["example.com", "http://example.com", "https://user:secret@example.com", "https://example.com?token=secret"] { XCTAssertThrowsError(try JellyfinProvider.serverURL(value)) }
    }
    @MainActor func testBookmarksAndExactPositionSurviveReopen() throws {
        let namespace = "test-\(UUID())"
        let store = try ReadingStore(namespace: namespace)
        defer { try? store.delete() }
        let position = ReadingPosition(fraction: 0.3, cfi: "epubcfi(/6/2!/4/2:10)")
        try store.set(ReadingRecord(position: position, acknowledgedTicks: 0, dirty: true, updated: Date(), title: "Fixture", format: .epub), id: "book")
        try store.add(Bookmark(name: "Saved", position: position), id: "book")
        let restored = try ReadingStore(namespace: namespace)
        XCTAssertEqual(restored.records["book"]?.position, position)
        XCTAssertTrue(restored.records["book"]?.dirty == true)
        XCTAssertEqual(restored.bookmarks["book"]?.first?.position, position)
    }
    @MainActor func testSignOutStillClearsLocalStateWhenCredentialDeletionFails() async throws {
        let model = AppModel(restoreLogin: false, deleteCredentials: { throw ReaderError.message("Injected deletion failure") })
        let namespace = "test-\(UUID())"
        let store = try ReadingStore(namespace: namespace)
        let cache = try BookCache(namespace: namespace)
        model.store = store; model.cache = cache
        model.account = Account(server: URL(string: "https://example.com")!, userID: "fixture", serverID: "fixture", username: "Fixture", token: "fixture-token")
        try store.add(Bookmark(name: "Fixture", position: ReadingPosition()), id: "fixture")
        let root = await cache.root
        await model.signOut()
        XCTAssertNil(model.account)
        XCTAssertNil(model.store)
        XCTAssertNil(model.cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(model.error?.contains("Keychain") == true)
        XCTAssertFalse(model.connecting)
    }
    func testCacheEvictionProtectsOpenBookAndClearPreservesIt() async throws {
        let cache = try BookCache(namespace: "test-\(UUID())", budget: 20)
        let root = await cache.root
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent(stableKey("old")), active = root.appendingPathComponent(stableKey("active"))
        for directory in [old, active] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try Data(repeating: 1, count: 16).write(to: directory.appendingPathComponent("complete")) }
        await cache.protect("active"); try await cache.evict()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        try await cache.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        await cache.protect(nil); try await cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }
    func testCBZUsesNaturalPageOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["10.png", "2.png", "1.png"] { try Data().write(to: root.appendingPathComponent(name)) }
        let (_, pages) = try BookCache.contents(root, format: .cbz)
        XCTAssertEqual(pages.map(\.lastPathComponent), ["1.png", "2.png", "10.png"])
    }
    func testUnsupportedAndEmptyBooks() throws {
        XCTAssertEqual(BookFormat(path: "/library/Novel.EPUB"), .epub)
        XCTAssertEqual(BookFormat(path: "/library/Novel.mobi"), .unsupported)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try BookCache.contents(root, format: .epub))
        XCTAssertThrowsError(try BookCache.contents(root, format: .cbz))
    }
}
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (status, data) = try Self.handler!(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class ProviderTests: XCTestCase {
    private func provider() -> JellyfinProvider {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return JellyfinProvider(account: Account(server: URL(string: "https://example.com/base")!, userID: "user", serverID: "server", username: "reader", token: "test-token"), configuration: config)
    }
    func testLibraryFilteringAndHeaderAuthentication() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/base/UserViews")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=test-token") == true)
            XCTAssertFalse(request.url!.absoluteString.contains("test-token"))
            return (200, Data(#"{"Items":[{"Id":"books","Name":"Books","CollectionType":"books"},{"Id":"music","Name":"Music","CollectionType":"music"}]}"#.utf8))
        }
        let libraries = try await provider().libraries()
        XCTAssertEqual(libraries.map(\.id), ["books"])
    }
    func testSearchPaginationIsBoundedAndScoped() async throws {
        StubURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "parentId", value: "library")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "startIndex", value: "60")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "60")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "searchTerm", value: "a & b")))
            return (200, Data(#"{"Items":[],"TotalRecordCount":60}"#.utf8))
        }
        let result = try await provider().browse(parent: "library", query: "a & b", start: 60)
        XCTAssertEqual(result.total, 60)
    }
    func testExpiredLoginProducesActionableError() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await provider().libraries(); XCTFail("Expected authentication failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("expired")) }
    }
    func testOldServerRejectedBeforePasswordSubmission() async {
        var count = 0
        StubURLProtocol.handler = { request in count += 1; XCTAssertTrue(request.url!.path.hasSuffix("System/Info/Public")); return (200, Data(#"{"Version":"10.11.0","Id":"server"}"#.utf8)) }
        do { _ = try await provider().login(server: URL(string: "https://example.com")!, username: "reader", password: "secret"); XCTFail("Expected version failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Jellyfin 12")) }
        XCTAssertEqual(count, 1)
    }
    @MainActor func testOpeningPresentationStartsBeforeContentAndCancelsCleanly() async {
        let model = AppModel(restoreLogin: false)
        let book = Book(id: "book", title: "Fixture", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        model.open(book)
        XCTAssertEqual(model.readerLaunchBook?.id, "book")
        XCTAssertNil(model.reader)
        model.cancelOpen()
        await Task.yield()
        XCTAssertNil(model.readerLaunchBook); XCTAssertNil(model.openingID); XCTAssertNil(model.reader)
    }
    @MainActor func testUnsupportedBookDoesNotBeginOpeningPresentation() {
        let model = AppModel(restoreLogin: false)
        model.open(Book(id: "book", title: "Fixture", author: "", summary: "", format: .unsupported, isFolder: false, ticks: 0))
        XCTAssertNil(model.readerLaunchBook); XCTAssertNotNil(model.error)
    }
    @MainActor func testProfileImageCoalescesRequestsAndKeepsResultInSession() async {
        let model = AppModel(restoreLogin: false); model.provider = provider()
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            if request.url!.path.hasSuffix("/Users/Me") { return (200, Data(#"{"Id":"user","PrimaryImageTag":"portrait"}"#.utf8)) }
            return (200, Data([1, 2, 3]))
        }
        defer { StubURLProtocol.handler = nil }
        async let first: Void = model.loadProfileImage()
        async let second: Void = model.loadProfileImage()
        _ = await (first, second)
        XCTAssertEqual(calls, 2); XCTAssertEqual(model.profileImageData, Data([1, 2, 3]))
        await model.loadProfileImage(); XCTAssertEqual(calls, 2)
    }
    @MainActor func testStartupLoadsLibrariesOnceAndManualRefreshClearsSnapshots() async {
        let model = AppModel(restoreLogin: false)
        model.provider = provider()
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            if request.url!.path.hasSuffix("/Users/Me") { return (200, Data(#"{"Id":"user"}"#.utf8)) }
            return (200, Data(#"{"Items":[{"Id":"library","Name":"Books","CollectionType":"books"}],"TotalRecordCount":1}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        await model.loadLibrariesIfNeeded()
        XCTAssertEqual(calls, 2)
        model.catalogSnapshots["loaded"] = .init(books: [], total: 0, offset: 0, cursor: nil, reachedEnd: true)
        await model.loadLibrariesIfNeeded()
        XCTAssertEqual(calls, 2); XCTAssertNotNil(model.catalogSnapshots["loaded"])
        await model.loadLibraries()
        XCTAssertEqual(calls, 4); XCTAssertTrue(model.catalogSnapshots.isEmpty)
    }
    @MainActor func testLocalProgressUpdatesPresentationWithoutInvalidatingCatalog() throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete() }
        model.store = store
        let book = Book(id: "book", title: "Fixture", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        model.catalogSnapshots["fixture"] = .init(books: [book], total: 1, offset: 1, cursor: nil, reachedEnd: true)
        let revision = model.catalogRevision
        model.savePosition(.init(fraction: 0.4), book: book)
        XCTAssertEqual(model.displayedBook(book).ticks, 4_000_000)
        XCTAssertEqual(model.displayedBook(book).readingStatus, .inProgress)
        XCTAssertEqual(model.locallyReadingBooks.map(\.id), ["book"])
        XCTAssertNotNil(model.catalogSnapshots["fixture"])
        XCTAssertEqual(model.catalogRevision, revision)
    }
    @MainActor func testMarkUnreadUpdatesLocalStatusWithoutReloadingCatalog() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        let book = Book(id: "book", title: "Fixture", author: "", summary: "", format: .epub, isFolder: false, ticks: 0, readingStatus: .finished)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (200, Data(#"{"Key":"book","PlaybackPositionTicks":0,"Played":false}"#.utf8))
        }
        model.catalogSnapshots["fixture"] = .init(books: [book], total: 1, offset: 1, cursor: nil, reachedEnd: true)
        await model.markFinished(book, finished: false)
        XCTAssertEqual(model.displayedBook(book).readingStatus, .notFinished)
        XCTAssertNotNil(model.catalogSnapshots["fixture"])
        XCTAssertEqual(model.catalogRevision, 0)
    }
    @MainActor func testNewPositionSurvivesAnInFlightProgressWrite() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        let book = Book(id: "book", title: "Fixture", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        let started = expectation(description: "First progress write reached transport")
        let release = DispatchSemaphore(value: 0)
        var remote: Int64 = 0
        var writes = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                writes += 1
                if writes == 1 { started.fulfill(); release.wait() }
                remote = writes == 1 ? 3_000_000 : 8_000_000
                return (204, Data())
            }
            return (200, try JSONSerialization.data(withJSONObject: ["Id":"book", "UserData":["Key":"book", "PlaybackPositionTicks":remote]]))
        }
        model.savePosition(ReadingPosition(fraction: 0.3), book: book)
        let first = Task { await model.flushProgress() }
        await fulfillment(of: [started], timeout: 5)
        model.savePosition(ReadingPosition(fraction: 0.8), book: book)
        release.signal()
        await first.value
        XCTAssertEqual(store.records["book"]?.position.fraction, 0.8)
        XCTAssertEqual(store.records["book"]?.acknowledgedTicks, 8_000_000)
        XCTAssertEqual(store.records["book"]?.dirty, false)
        XCTAssertEqual(writes, 2)
    }
    @MainActor func testFailedProgressStaysLocalUntilExplicitRetry() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        let book = Book(id: "book", title: "Fixture", author: "", summary: "", format: .pdf, isFolder: false, ticks: 0)
        var attempts = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                attempts += 1
                return (attempts == 1 ? 503 : 204, Data())
            }
            return (200, Data(#"{"Id":"book","UserData":{"Key":"book","PlaybackPositionTicks":0}}"#.utf8))
        }
        model.savePosition(ReadingPosition(page: 4), book: book)
        await model.flushProgress()
        XCTAssertTrue(store.records["book"]?.dirty == true)
        XCTAssertTrue(model.canRetryProgress)
        XCTAssertEqual(attempts, 1)
        await model.flushProgress()
        XCTAssertFalse(store.records["book"]?.dirty == true)
        XCTAssertNil(model.syncIssue)
        XCTAssertEqual(attempts, 2)
    }
    @MainActor func testAlreadyAppliedRemotePositionDoesNotSendDuplicateReport() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        let book = Book(id: "book", title: "Fixture", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        var reports = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { reports += 1; return (204, Data()) }
            return (200, Data(#"{"Id":"book","UserData":{"Key":"book","PlaybackPositionTicks":4000000}}"#.utf8))
        }
        model.savePosition(ReadingPosition(fraction: 0.4), book: book)
        await model.flushProgress()
        XCTAssertEqual(reports, 0)
        XCTAssertFalse(store.records["book"]?.dirty == true)
        XCTAssertEqual(store.records["book"]?.acknowledgedTicks, 4_000_000)
    }
    @MainActor func testMissingOldBookDoesNotMakeNewBookSyncFail() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        let missing = Book(id: "missing", title: "Older Book", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        let current = Book(id: "current", title: "Current Book", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        var missingLookups = 0
        var writes = 0
        var remote: Int64 = 0
        StubURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "missing" { missingLookups += 1; return (404, Data()) }
            if request.httpMethod == "POST" { writes += 1; remote = writes == 1 ? 3_000_000 : 4_000_000; return (204, Data()) }
            return (200, try JSONSerialization.data(withJSONObject: ["Id":"current", "UserData":["Key":"current", "PlaybackPositionTicks":remote]]))
        }
        model.savePosition(ReadingPosition(fraction: 0.2), book: missing)
        model.savePosition(ReadingPosition(fraction: 0.3), book: current)
        await model.flushProgress()
        XCTAssertEqual(store.records["missing"]?.syncBlock, .unavailable)
        XCTAssertTrue(store.records["missing"]?.dirty == true)
        XCTAssertFalse(store.records["current"]?.dirty == true)
        XCTAssertNil(model.syncIssue)
        XCTAssertEqual(model.blockedProgress.count, 1)
        model.savePosition(ReadingPosition(fraction: 0.4), book: current)
        await model.flushProgress()
        XCTAssertEqual(missingLookups, 1)
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(store.records["current"]?.dirty == true)
        await model.retryBlockedProgress("missing")
        XCTAssertEqual(missingLookups, 2)
        XCTAssertEqual(store.records["missing"]?.syncBlock, .unavailable)
    }
    @MainActor func testRemotePositionConflictNeedsReviewInsteadOfRetry() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        let book = Book(id: "book", title: "Fixture", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        var writes = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { writes += 1; return (204, Data()) }
            return (200, Data(#"{"Id":"book","UserData":{"Key":"book","PlaybackPositionTicks":5000000}}"#.utf8))
        }
        model.savePosition(ReadingPosition(fraction: 0.3), book: book)
        await model.flushProgress()
        XCTAssertEqual(store.records["book"]?.syncBlock, .conflict)
        XCTAssertTrue(store.records["book"]?.dirty == true)
        XCTAssertNil(model.syncIssue)
        XCTAssertFalse(model.canRetryProgress)
        XCTAssertEqual(writes, 0)
    }
    @MainActor func testRematchTransfersPositionAndBookmarksToReplacementID() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        let oldPosition = ReadingPosition(fraction: 0.3, cfi: "epubcfi(/6/2!/4/2:10)")
        try store.set(ReadingRecord(position: oldPosition, acknowledgedTicks: 0, dirty: true, updated: Date(), title: "Old ID", format: .epub, syncBlock: .unavailable), id: "old")
        try store.add(Bookmark(name: "Saved", position: oldPosition), id: "old")
        var remote: Int64 = 0
        var reports = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { reports += 1; remote = 3_000_000; return (204, Data()) }
            return (200, try JSONSerialization.data(withJSONObject: ["Id":"new", "Name":"Same Book", "Path":"/books/same.epub", "UserData":["Key":"new", "PlaybackPositionTicks":remote]]))
        }
        let candidate = Book(id: "new", title: "Same Book", author: "Author", summary: "", format: .epub, isFolder: false, ticks: 0)
        await model.rematchProgress(model.blockedProgress[0], to: candidate)
        XCTAssertNil(store.records["old"])
        XCTAssertEqual(store.records["new"]?.position, oldPosition)
        XCTAssertFalse(store.records["new"]?.dirty == true)
        XCTAssertEqual(store.bookmarks["new"]?.first?.position, oldPosition)
        XCTAssertNil(store.bookmarks["old"])
        XCTAssertEqual(reports, 1)
    }
    @MainActor func testRematchToFinishedBookRequiresPositionChoice() async throws {
        let model = AppModel(restoreLogin: false)
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete(); StubURLProtocol.handler = nil }
        model.store = store; model.provider = provider()
        try store.set(ReadingRecord(position: ReadingPosition(fraction: 0.3), acknowledgedTicks: 0, dirty: true, updated: Date(), title: "Old ID", format: .epub, syncBlock: .unavailable), id: "old")
        var reports = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { reports += 1; return (204, Data()) }
            return (200, Data(#"{"Id":"new","Name":"Same Book","Path":"/books/same.epub","UserData":{"Key":"new","PlaybackPositionTicks":0,"Played":true}}"#.utf8))
        }
        let candidate = Book(id: "new", title: "Same Book", author: "Author", summary: "", format: .epub, isFolder: false, ticks: 0)
        await model.rematchProgress(model.blockedProgress[0], to: candidate)
        XCTAssertTrue(model.conflict?.serverFinished == true)
        XCTAssertEqual(store.records["new"]?.syncBlock, .conflict)
        XCTAssertEqual(reports, 0)
    }
    @MainActor func testInterruptedBookmarkCopyCanCompleteRematch() throws {
        let store = try ReadingStore(namespace: "test-\(UUID())")
        defer { try? store.delete() }
        let position = ReadingPosition(fraction: 0.3, cfi: "epubcfi(/6/2!/4/2:10)")
        let record = ReadingRecord(position: position, acknowledgedTicks: 0, dirty: true,
                                   updated: Date(), title: "Same Book", format: .epub,
                                   syncBlock: .unavailable)
        let bookmark = Bookmark(name: "Saved", position: position)
        try store.set(record, id: "old")
        try store.add(bookmark, id: "old")
        // A prior attempt may have copied bookmarks but stopped before moving
        // the position. The identical copy must not permanently block retry.
        try store.add(bookmark, id: "new")
        let replacement = Book(id: "new", title: "Same Book", author: "", summary: "",
                               format: .epub, isFolder: false, ticks: 0)
        try store.movePosition(from: "old", to: replacement, record: record)
        XCTAssertNil(store.records["old"])
        XCTAssertEqual(store.records["new"]?.position, position)
        XCTAssertEqual(store.bookmarks["new"]?.map(\.id), [bookmark.id])
        XCTAssertNil(store.bookmarks["old"])
    }

}

final class ArchiveTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    func testJellyfinJSZipExtractsEPUBAndCBZFixtures() async throws {
        for format in [BookFormat.epub, .cbz] {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: destination) }
            try await ArchiveExtractor.extract(root.appendingPathComponent("Fixtures/Harbor.\(format.rawValue)"), to: destination, scriptURL: root.appendingPathComponent("App/Resources/Archive/jszip.min.js"))
            let (document, pages) = try BookCache.contents(destination, format: format)
            XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
            if format == .cbz { XCTAssertEqual(pages.map(\.lastPathComponent), ["1.png", "2.png", "10.png"]) }
        }
    }
}
