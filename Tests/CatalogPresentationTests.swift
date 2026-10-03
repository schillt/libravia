import XCTest
@testable import BookCore

final class CatalogPresentationTests: XCTestCase {
    let libraries = [Library(id: "one", name: "One"), Library(id: "two", name: "Two")]

    func testLibraryPreservesFoldersAndSearchRemainsRecursive() {
        let library = CatalogPresentation.scope(libraries: libraries, selectedID: "one", folderID: nil, search: false)
        XCTAssertEqual(library.parentID, "one")
        XCTAssertEqual(library.libraries.count, 1)
        let search = CatalogPresentation.scope(libraries: libraries, selectedID: "one", folderID: nil, search: true)
        XCTAssertNil(search.parentID)
        XCTAssertEqual(search.libraries.count, 1)
        let all = CatalogPresentation.scope(libraries: libraries, selectedID: nil, folderID: nil, search: true)
        XCTAssertEqual(all.libraries.count, 2)
        let folder = CatalogPresentation.scope(libraries: libraries, selectedID: "one", folderID: "folder", search: false)
        XCTAssertEqual(folder.parentID, "folder")
    }

    func testEmptySearchRequiresNarrowingFilters() {
        XCTAssertFalse(CatalogPresentation.canLoad(search: true, query: "  \n", filters: .init()))
        XCTAssertTrue(CatalogPresentation.canLoad(search: true, query: "", filters: .init(author: .init(id: "author", name: "Author"))))
        XCTAssertTrue(CatalogPresentation.canLoad(search: true, query: "Title", filters: .init()))
        XCTAssertTrue(CatalogPresentation.canLoad(search: false, query: "", filters: .init()))
    }

    func testSupersededQueryFilterScopeAndAccountCannotApplyResults() {
        var gate = CatalogRequestGate()
        let session = UUID()
        var request = CatalogRequest(scope: .init(libraries: libraries), query: "first")
        let token = gate.begin(request: request, session: session)
        XCTAssertTrue(gate.accepts(token, request: request, session: session))
        XCTAssertFalse(gate.accepts(token, request: request, session: UUID()))
        request.query = "second"
        XCTAssertFalse(gate.accepts(token, request: request, session: session))
        let second = gate.begin(request: request, session: session)
        XCTAssertFalse(gate.accepts(token, request: request, session: session))
        request.filters.status = .finished
        XCTAssertFalse(gate.accepts(second, request: request, session: session))
        let filtered = gate.begin(request: request, session: session)
        request.scope.parentID = "different"
        XCTAssertFalse(gate.accepts(filtered, request: request, session: session))
    }

    func testLeavingRejectsPendingPageAndReturningAllowsFreshLoad() {
        var gate = CatalogRequestGate()
        let request = CatalogRequest(scope: .init(libraries: libraries))
        let session = UUID()
        let pending = gate.begin(request: request, session: session)
        gate.invalidate()
        XCTAssertFalse(gate.accepts(pending, request: request, session: session))
        let returned = gate.begin(request: request, session: session)
        XCTAssertTrue(gate.accepts(returned, request: request, session: session))
        XCTAssertFalse(gate.accepts(pending, request: request, session: session))
    }
}
