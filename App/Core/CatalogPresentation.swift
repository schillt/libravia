import Foundation

/// The presentation intent is independent of the catalog's grid or row layout.
enum CatalogPresentation {
    static func scope(libraries: [Library], selectedID: String?, folderID: String?, search: Bool) -> CatalogScope {
        CatalogScope(libraries: libraries.filter { selectedID == nil || $0.id == selectedID }, parentID: folderID ?? (search ? nil : selectedID))
    }
    static func canLoad(search: Bool, query: String, filters: CatalogFilters) -> Bool {
        !search || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !filters.isEmpty
    }
}

/// Rejects completed work from an older request, session, or departed presentation.
struct CatalogRequestGate {
    private var token = UUID()
    private var request: CatalogRequest?
    private var session: UUID?
    mutating func begin(request: CatalogRequest, session: UUID) -> UUID {
        token = UUID(); self.request = request; self.session = session
        return token
    }
    mutating func invalidate() { token = UUID(); request = nil; session = nil }
    func accepts(_ token: UUID, request: CatalogRequest, session: UUID) -> Bool {
        self.token == token && self.request == request && self.session == session
    }
}
