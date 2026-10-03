import Foundation

struct CatalogScope: Hashable, Sendable {
    var libraries: [Library]
    var parentID: String? = nil
}
enum CatalogSort: String, CaseIterable, Identifiable, Sendable {
    case titleAscending = "Title A–Z", titleDescending = "Title Z–A", recentlyAdded = "Recently Added"
    var id: Self { self }
}
enum CatalogReadingStatus: String, CaseIterable, Identifiable, Sendable {
    case notFinished = "Not finished", inProgress = "In progress", finished = "Finished"
    var id: Self { self }
}
struct CatalogOption: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var imageTag: String? = nil
}
struct CatalogFilters: Hashable, Sendable {
    var author: CatalogOption? = nil
    var genre: CatalogOption? = nil
    var tag: CatalogOption? = nil
    var status: CatalogReadingStatus? = nil
    var isEmpty: Bool { author == nil && genre == nil && tag == nil && status == nil }
}
struct CatalogRequest: Hashable, Sendable {
    var scope: CatalogScope
    var query: String = ""
    var start: Int = 0
    var cursor: String? = nil
    var filters = CatalogFilters()
    var sort: CatalogSort = .titleAscending
}
struct CatalogFilterOptions: Sendable {
    var authorsAvailable = false
    var genres: [CatalogOption] = []
    var tags: [CatalogOption] = []
    var statuses: [CatalogReadingStatus] = []
}
struct CatalogAuthorPage: Sendable {
    var items: [CatalogOption]
    /// Number of raw server matches; start advances by consumed, including non-narrowing entries.
    var total: Int
    var consumed: Int = 0
}
struct CatalogCollectionPage: Sendable {
    var items: [CatalogOption]
    var total: Int
    var consumed: Int
}

/// Provider-owned metadata only; no publications, queries or account data are persisted.
actor CatalogMetadataCache {
    private var values: [CatalogScope: CatalogFilterOptions] = [:]
    private var generation = 0
    func snapshot(_ scope: CatalogScope) -> (CatalogFilterOptions?, Int) { (values[scope], generation) }
    func insert(_ options: CatalogFilterOptions, scope: CatalogScope, generation expected: Int) {
        guard generation == expected else { return }
        values[scope] = options
    }
    func clear() { generation += 1; values.removeAll() }
}

/// Session-held presentation, never written to disk.
struct CatalogSnapshot {
    var books: [Book]
    var total: Int
    var offset: Int
    var cursor: String?
    var reachedEnd: Bool
}
