import XCTest
import JellyfinAPI
@testable import BookCore

private final class CatalogURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class CatalogProviderTests: XCTestCase {
    private let library = Library(id: "books", name: "Books")
    private func provider() -> JellyfinProvider {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogURLProtocol.self]
        return JellyfinProvider(account: .init(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "reader", token: "fixture"), configuration: config)
    }
    override func tearDown() { CatalogURLProtocol.handler = nil; super.tearDown() }
    func testSimilarBooksAreBoundedAndExcludeOtherMediaAndSeed() async throws {
        CatalogURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/Items/seed/Similar")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains { $0.name == "limit" && $0.value == "12" })
            XCTAssertTrue(query.contains { $0.name == "userId" && $0.value == "user" })
            return Data(#"{"Items":[{"Id":"seed","Type":"Book"},{"Id":"movie","Type":"Movie"},{"Id":"next","Type":"Book","Path":"next.epub"}]}"#.utf8)
        }
        let seed = Book(id: "seed", title: "Seed", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        let results = try await provider().similar(to: seed)
        XCTAssertEqual(results.map(\.id), ["next"])
    }
    func testSuggestionsUseServerRandomSortAndStayWithinBookScope() async throws {
        CatalogURLProtocol.handler = { request in
            let q = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $0 + "," + $1 })
            XCTAssertEqual(q["parentId"], "books")
            XCTAssertEqual(q["sortBy"], "Random")
            XCTAssertEqual(q["includeItemTypes"], "Book")
            XCTAssertEqual(q["recursive"], "true")
            XCTAssertEqual(q["limit"], "4")
            return Data(#"{"Items":[{"Id":"one","Name":"One","Type":"Book","Path":"one.epub"},{"Id":"bad","Name":"Bad","Type":"Book","Path":"bad.mobi"}],"TotalRecordCount":2}"#.utf8)
        }
        let result = try await provider().suggestedBooks(scope: .init(libraries: [library]), limit: 4)
        XCTAssertEqual(result.map(\.id), ["one"])
        XCTAssertEqual(result.first?.libraryName, "Books")
    }
    func testDiscoveryUsesScopedPeopleGenresAndBookCollections() async throws {
        CatalogURLProtocol.handler = { request in
            let q = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $0 + "," + $1 })
            if request.url!.path.hasSuffix("Persons") {
                XCTAssertEqual(q["parentId"], "books")
                XCTAssertEqual(q["personTypes"], "Author,Writer")
                return Data(#"{"Items":[{"Id":"writer","Name":"Writer","ImageTags":{"Primary":"portrait-tag"}}],"TotalRecordCount":1}"#.utf8)
            }
            if request.url!.path.hasSuffix("Filters") {
                XCTAssertEqual(q["parentId"], "books")
                return Data(#"{"Genres":["Fantasy"],"Tags":[]}"#.utf8)
            }
            if q["includeItemTypes"] == "Book,Folder" {
                XCTAssertEqual(q["parentId"], "books")
                XCTAssertEqual(q["recursive"], "false")
                XCTAssertEqual(q["enableImages"], "true")
                XCTAssertEqual(q["searchTerm"], "series")
                return Data(#"{"Items":[{"Id":"book","Name":"Series Book","Type":"Book","IsFolder":false},{"Id":"folder","Name":"Series","Type":"Folder","IsFolder":true,"ImageTags":{"Primary":"cover-tag"}}],"TotalRecordCount":2}"#.utf8)
            }
            XCTFail("Unexpected collection request"); return Data()
        }
        let provider = provider(), scope = CatalogScope(libraries: [library])
        let authors = try await provider.discoveryAuthors(scope: scope, query: "", start: 0)
        let genres = try await provider.discoveryGenres(scope: scope)
        XCTAssertEqual(authors.items.map(\.name), ["Writer"])
        XCTAssertEqual(authors.items.first?.imageTag, "portrait-tag")
        XCTAssertEqual(genres.map(\.name), ["Fantasy"])
        let collections = try await provider.discoveryCollections(scope: scope, query: "series", start: 0)
        XCTAssertEqual(collections.items.map(\.name), ["Series"])
        XCTAssertEqual(collections.items.first?.imageTag, "cover-tag")
        XCTAssertEqual(collections.consumed, 2)
    }
    func testAuthorPortraitFallsBackToPersonMetadataWhenBookOmitsTag() async throws {
        CatalogURLProtocol.handler = { request in
            if request.url!.path == "/Persons/Writer" {
                return Data(#"{"Id":"writer","Name":"Writer","ImageTags":{"Primary":"portrait-tag"}}"#.utf8)
            }
            XCTAssertEqual(request.url!.path, "/Items/writer/Images/Primary")
            XCTAssertTrue(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "tag" && $0.value == "portrait-tag" })
            return Data([0x89, 0x50, 0x4E, 0x47])
        }
        let portrait = try await provider().authorImage(.init(name: "Writer", imageTag: nil))
        XCTAssertEqual(portrait, Data([0x89, 0x50, 0x4E, 0x47]))
    }
    func testAuthorPortraitUsesPersonIDWithoutNameLookup() async throws {
        CatalogURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/Items/author-id/Images/Primary")
            return Data([1, 2, 3])
        }
        let portrait = try await provider().authorImage(.init(name: "Writer / Name", imageTag: nil, id: "author-id"))
        XCTAssertEqual(portrait, Data([1, 2, 3]))
    }
    func testMarkUnreadUsesSDKDeleteEndpoint() async throws {
        CatalogURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url!.path, "/UserPlayedItems/book")
            return Data(#"{"Key":"book","PlaybackPositionTicks":0,"Played":false}"#.utf8)
        }
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .epub, isFolder: false, ticks: 123)
        let ticks = try await provider().setFinished(book, finished: false)
        XCTAssertEqual(ticks, 0)
    }
    func testRecentlyAddedRequestsBooksOnlyEvenInsideCollection() {
        let request = CatalogRequest(scope: .init(libraries: [library], parentID: "collection"), sort: .recentlyAdded)
        let parameters = JellyfinProvider.catalogParameters(request, parent: "collection", userID: "user")
        XCTAssertEqual(parameters.includeItemTypes, [.book]); XCTAssertEqual(parameters.isRecursive, true)
    }
    func testMarkReadUsesUserPlayedEndpointAndReturnsServerPosition() async throws {
        CatalogURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/UserPlayedItems/book"))
            XCTAssertFalse(request.url!.path.contains("Delete"))
            return Data(#"{"Key":"book","PlaybackPositionTicks":123,"Played":true}"#.utf8)
        }
        let book = Book(id: "book", title: "Book", author: "", summary: "", format: .epub, isFolder: false, ticks: 0)
        let ticks = try await provider().markFinished(book)
        XCTAssertEqual(ticks, 123)
    }
    func testFolderScopeOnlyRecursesWhenSearchingOrFiltering() {
        var request = CatalogRequest(scope: .init(libraries: [library], parentID: "folder"))
        var p = JellyfinProvider.catalogParameters(request, parent: "folder", userID: "user")
        XCTAssertEqual(p.includeItemTypes, [.book, .folder]); XCTAssertEqual(p.isRecursive, false)
        request.filters.genre = .init(id: "Fiction", name: "Fiction")
        p = JellyfinProvider.catalogParameters(request, parent: "folder", userID: "user")
        XCTAssertEqual(p.includeItemTypes, [.book]); XCTAssertEqual(p.isRecursive, true)
    }
    func testSDKQueryCombinesCategoriesWithoutLocalFormatFiltering() {
        let filters = CatalogFilters(author: .init(id: "author", name: "Author"), genre: .init(id: "genre", name: "Fiction"), tag: .init(id: "tag", name: "Short"), status: .inProgress)
        let request = CatalogRequest(scope: .init(libraries: [library]), query: "river", filters: filters, sort: .recentlyAdded)
        let p = JellyfinProvider.catalogParameters(request, parent: "books", userID: "user")
        let q = Dictionary(p.asQuery.compactMap { key, value in value.map { (key, $0) } }, uniquingKeysWith: { $0 + "," + $1 })
        XCTAssertEqual(q["parentId"], "books"); XCTAssertEqual(q["includeItemTypes"], "Book")
        XCTAssertEqual(q["personIds"], "author"); XCTAssertEqual(q["personTypes"], "Author,Writer")
        XCTAssertEqual(q["genres"], "Fiction"); XCTAssertEqual(q["tags"], "Short")
        XCTAssertEqual(q["filters"], "IsResumable"); XCTAssertNil(q["isPlayed"])
        XCTAssertEqual(q["searchTerm"], "river"); XCTAssertEqual(q["sortBy"], "DateCreated,SortName")
    }
    func testNotFinishedAndFinishedAreServerPlayedFlag() {
        var request = CatalogRequest(scope: .init(libraries: [library]))
        request.filters.status = .notFinished
        XCTAssertEqual(JellyfinProvider.catalogParameters(request, parent: "books", userID: "user").isPlayed, false)
        request.filters.status = .finished
        XCTAssertEqual(JellyfinProvider.catalogParameters(request, parent: "books", userID: "user").isPlayed, true)
    }
    func testGlobalMergeRetainsBuffersAndDoesNotRereadPrefixes() async throws {
        var requests: [(String, Int)] = []
        CatalogURLProtocol.handler = { request in
            let q = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $0 + "," + $1 })
            let parent = q["parentId"]!, offset = Int(q["startIndex"]!)!
            requests.append((parent, offset))
            let parity = parent == "a" ? 0 : 1
            let items: [[String: Any]] = (offset..<min(offset + 60, 65)).map { n in
                let title = String(format: "%03d", n * 2 + parity)
                return ["Id": "\(parent)-\(n)", "Name": title, "SortName": title, "Path": "book.epub", "Type": "Book"]
            }
            return try JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": 65])
        }
        let provider = provider()
        var request = CatalogRequest(scope: .init(libraries: [.init(id: "a", name: "A"), .init(id: "b", name: "B")]), query: "x")
        let first = try await provider.catalog(request)
        XCTAssertEqual(first.items.map(\.title), (0..<60).map { String(format: "%03d", $0) })
        XCTAssertEqual(first.total, 130); XCTAssertEqual(requests.count, 2)
        request.cursor = first.nextCursor
        let second = try await provider.catalog(request)
        XCTAssertEqual(second.items.map(\.title), (60..<120).map { String(format: "%03d", $0) })
        XCTAssertEqual(requests.count, 3) // Refills the exhausted A stream to compare its next head.
        request.cursor = second.nextCursor
        let third = try await provider.catalog(request)
        XCTAssertEqual(third.items.count, 10); XCTAssertNil(third.nextCursor)
        XCTAssertEqual(requests.map { $0.1 }, [0, 0, 60, 60])
        XCTAssertEqual(first.items.first?.libraryName, "A")
    }
    func testMetadataUsesScopedFacetsWithoutPerValueProbesAndCachesScope() async throws {
        var requests = 0
        CatalogURLProtocol.handler = { request in
            requests += 1
            if request.url!.path.hasSuffix("Filters") { return Data(#"{"Genres":["Shared","Useful"],"Tags":[]}"#.utf8) }
            if request.url!.path.hasSuffix("Persons") { return Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8) }
            let q = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $0 + "," + $1 })
            XCTAssertNil(q["genres"]); XCTAssertNil(q["tags"]); XCTAssertNil(q["personIds"])
            let count = q["isPlayed"] == "true" || q["filters"] != nil ? 0 : 3
            XCTAssertEqual(q["limit"], "0"); XCTAssertEqual(q["recursive"], "true")
            return Data("{\"Items\":[],\"TotalRecordCount\":\(count)}".utf8)
        }
        let provider = provider(), scope = CatalogScope(libraries: [library])
        let options = try await provider.filterOptions(scope: scope)
        XCTAssertEqual(options.genres.map(\.name), ["Shared", "Useful"]); XCTAssertTrue(options.statuses.isEmpty); XCTAssertFalse(options.authorsAvailable)
        XCTAssertLessThanOrEqual(requests, 6)
        let before = requests
        _ = try await provider.filterOptions(scope: scope)
        XCTAssertEqual(requests, before)
        await provider.invalidateCatalogMetadata()
        _ = try await provider.filterOptions(scope: scope)
        XCTAssertGreaterThan(requests, before)
    }
    func testCursorCannotCrossAccountOrQueryAndRefreshInvalidatesIt() async throws {
        var requests = 0
        CatalogURLProtocol.handler = { _ in
            requests += 1
            let items = (0..<60).map { ["Id": "\($0)", "Name": "\($0)"] }
            return try JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": 61])
        }
        let firstProvider = provider()
        var request = CatalogRequest(scope: .init(libraries: [library]), query: "first")
        request.cursor = try await firstProvider.catalog(request).nextCursor
        let before = requests
        do { _ = try await provider().catalog(request); XCTFail("Cursor crossed provider/account boundary") } catch {}
        var changed = request; changed.query = "different"
        do { _ = try await firstProvider.catalog(changed); XCTFail("Cursor survived query change") } catch {}
        await firstProvider.invalidateCatalogMetadata()
        do { _ = try await firstProvider.catalog(request); XCTFail("Cursor survived refresh") } catch {}
        XCTAssertEqual(requests, before)
    }
    func testSparseScopeSkipsFacetEnumeration() async throws {
        var requests = 0
        CatalogURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/Items")
            return Data(#"{"Items":[],"TotalRecordCount":1}"#.utf8)
        }
        let options = try await provider().filterOptions(scope: .init(libraries: [library]))
        XCTAssertTrue(options.genres.isEmpty); XCTAssertTrue(options.tags.isEmpty)
        XCTAssertFalse(options.authorsAvailable); XCTAssertEqual(requests, 1)
    }

    func testRefreshDuringRequestPreventsStaleCursorPublication() async throws {
        let entered = expectation(description: "Catalog request entered transport")
        let release = DispatchSemaphore(value: 0)
        CatalogURLProtocol.handler = { _ in
            entered.fulfill()
            release.wait()
            let items = (0..<60).map { ["Id": "\($0)", "Name": "\($0)"] }
            return try JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": 61])
        }
        let provider = provider()
        let request = CatalogRequest(scope: .init(libraries: [library]), query: "book")
        let task = Task { try await provider.catalog(request) }
        await fulfillment(of: [entered], timeout: 5)
        await provider.invalidateCatalogMetadata()
        release.signal()
        do { _ = try await task.value; XCTFail("Stale page survived refresh") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

}
