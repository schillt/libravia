import SwiftUI

struct LibraryLandingView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var minimumCardWidth = 140.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var columns: [GridItem] {
        [GridItem(dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: minimumCardWidth, maximum: minimumCardWidth * 1.5), spacing: 14, alignment: .top)]
    }
    @State private var recent: [Book] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var revision = UUID()
    private var requestKey: String { "\(model.sessionID)|\(model.catalogRevision)|\(model.selectedLibrary ?? "")|\(revision)" }
    private var cacheKey: String { "library|\(model.sessionID)|\(model.catalogRevision)|\(scope)" }
    private var scope: CatalogScope {
        CatalogPresentation.scope(libraries: model.libraries, selectedID: model.selectedLibrary, folderID: nil, search: false)
    }
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let status = model.status { Label(status, systemImage: "info.circle").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 240), spacing: 14)], spacing: 14) {
                    destination("Authors", icon: "person.2") { LibraryDirectoryView(kind: .authors, scope: scope) }
                    destination("Collections", icon: "square.stack") { LibraryDirectoryView(kind: .collections, scope: scope) }
                    destination("Genres", icon: "tag") { LibraryDirectoryView(kind: .genres, scope: scope) }
                    destination("All Books", icon: "books.vertical") { CatalogView() }
                }
                HStack {
                    Text("Recently Added").font(.headline)
                    Spacer()
                    NavigationLink("See All") { CatalogView(initialSort: .recentlyAdded) }.font(.callout)
                }
                if loading { ProgressView("Loading recent books…").frame(maxWidth: .infinity).padding() }
                else if let failure {
                    Label(failure, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                    Button("Try Again") { revision = UUID() }
                } else if recent.isEmpty {
                    ContentUnavailableView("No books yet", systemImage: "books.vertical", description: Text("Books added to this library will appear here."))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(recent.prefix(12)) { book in
                            NavigationLink { BookDetailView(book: book) } label: { BookCard(book: book) }
                                .buttonStyle(.plain).modifier(BookActions(book: book))
                        }
                    }
                }
            }.padding(20)
        }
        .appSurface().navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if model.libraries.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Book library", selection: $model.selectedLibrary) {
                            ForEach(model.libraries) { Text($0.name).tag(Optional($0.id)) }
                        }
                    } label: { Label("Libraries", systemImage: "books.vertical") }
                    .accessibilityLabel("Library scope")
                    .accessibilityValue(scope.libraries.map(\.name).joined(separator: ", "))
                }
            }
            ToolbarItem(placement: .primaryAction) { ProfileButton() }
        }
        .refreshable { await model.loadLibraries(); revision = UUID() }
        .task(id: requestKey) {
            let key = requestKey
            if let cached = model.discoveryBooks[cacheKey] { recent = cached; return }
            recent = []; failure = nil; loading = true
            defer { if key == requestKey { loading = false } }
            guard let provider = model.provider, !scope.libraries.isEmpty else { return }
            do {
                let page = try await provider.catalog(.init(scope: scope, sort: .recentlyAdded))
                guard key == requestKey, !Task.isCancelled else { return }
                recent = Array(page.items.filter { !$0.isFolder }.prefix(12)); model.discoveryBooks[cacheKey] = recent
            } catch { if key == requestKey, !Task.isCancelled { failure = UserFacingError.message(error) } }
        }
    }
    private func destination<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink(destination: content) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: icon).font(.title2).foregroundStyle(.tint)
                HStack { Text(title).font(.headline); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

private enum LibraryDirectoryKind: String {
    case authors = "Authors", collections = "Collections", genres = "Genres"
}

struct LibraryCollectionsView: View {
    let scope: CatalogScope
    var body: some View { LibraryDirectoryView(kind: .collections, scope: scope) }
}

struct CollectionCard: View {
    let collection: CatalogOption
    private var artworkBook: Book {
        Book(id: collection.id, title: collection.name, author: "", summary: "", format: .unsupported,
             isFolder: true, imageTag: collection.imageTag, ticks: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(book: artworkBook)
            Text(collection.name).font(.headline).lineLimit(2, reservesSpace: true).accessibilityLabel(collection.name)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryDirectoryView: View {
    @Environment(AppModel.self) private var model
    let kind: LibraryDirectoryKind
    let scope: CatalogScope
    @ScaledMetric(relativeTo: .body) private var minimumCardWidth = 140.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var columns: [GridItem] {
        [GridItem(dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: minimumCardWidth, maximum: minimumCardWidth * 1.5), spacing: 14, alignment: .top)]
    }
    @State private var query = ""
    @State private var items: [CatalogOption] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var revision = UUID()
    @State private var pageTask: Task<Void, Never>?
    private var pageKey: String { "\(model.sessionID)|\(model.catalogRevision)|\(scope)|\(kind)|\(kind == .genres ? "" : query)|\(revision)" }
    private var visibleItems: [CatalogOption] {
        kind == .genres && !query.isEmpty ? items.filter { $0.name.localizedStandardContains(query) } : items
    }
    var body: some View {
        Group {
            if kind == .collections {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(visibleItems) { option in
                            NavigationLink { destination(for: option) } label: { CollectionCard(collection: option) }
                                .buttonStyle(.plain)
                        }
                    }
                    directoryStatus
                }
                .padding(20)
            } else {
                List {
                    ForEach(visibleItems) { option in
                        NavigationLink { destination(for: option) } label: {
                            if kind == .authors {
                                HStack(spacing: 12) {
                                    AuthorPortraitView(option: option)
                                    Text(option.name)
                                }
                            } else { Text(option.name) }
                        }
                    }
                    directoryStatus
                }
            }
        }
        .appSurface().navigationTitle(kind.rawValue)
        .searchable(text: $query, prompt: "Find \(kind.rawValue.lowercased())")
        .task(id: pageKey) {
            pageTask?.cancel(); items = []; offset = 0; total = 0; failure = nil; loading = false
            if kind != .genres {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await load()
        }
        .onDisappear { pageTask?.cancel() }
    }
    @ViewBuilder private var directoryStatus: some View {
        if loading { ProgressView("Loading \(kind.rawValue.lowercased())…") }
        if let failure {
            Label(failure, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
            Button("Try Again") { if items.isEmpty { revision = UUID() } else { loadMore() } }
        } else if !loading && offset < total {
            if items.isEmpty { Text("No book collections in these results. Load more to keep looking.").foregroundStyle(.secondary) }
            Button("Load More") { loadMore() }
        } else if !loading && visibleItems.isEmpty {
            ContentUnavailableView("No \(kind.rawValue.lowercased()) found", systemImage: kind == .authors ? "person.2" : kind == .genres ? "tag" : "square.stack")
        }
    }
    @ViewBuilder private func destination(for option: CatalogOption) -> some View {
        switch kind {
        case .authors: CatalogView(initialFilters: .init(author: option))
        case .genres: CatalogView(initialFilters: .init(genre: option))
        case .collections: CatalogView(parent: Library(id: option.id, name: option.name))
        }
    }
    private func loadMore() { pageTask = Task { await load() } }
    private func load() async {
        guard !loading, let provider = model.provider else { return }
        let key = pageKey
        loading = true; failure = nil
        defer { if key == pageKey { loading = false } }
        do {
            switch kind {
            case .authors:
                let page = try await provider.discoveryAuthors(scope: scope, query: query, start: offset)
                guard key == pageKey, !Task.isCancelled else { return }
                items += page.items.filter { !items.contains($0) }; offset += page.consumed; total = page.total
            case .collections:
                let page = try await provider.discoveryCollections(scope: scope, query: query, start: offset)
                guard key == pageKey, !Task.isCancelled else { return }
                items += page.items.filter { !items.contains($0) }; offset += page.consumed; total = page.total
            case .genres:
                let options = try await provider.discoveryGenres(scope: scope)
                guard key == pageKey, !Task.isCancelled else { return }
                items = options; offset = options.count; total = options.count
            }
        } catch { if key == pageKey, !Task.isCancelled { failure = UserFacingError.message(error) } }
    }
}

private struct AuthorPortraitView: View {
    @Environment(AppModel.self) private var model
    let option: CatalogOption
    @State private var data: Data?
    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let data, let image = platformImage(data) { image.resizable().scaledToFill() }
            else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
        }
        .frame(width: 40, height: 40).clipShape(Circle()).accessibilityHidden(true)
        .task(id: "\(model.sessionID)|\(option.name)|\(option.imageTag ?? "")") {
            data = nil
            guard model.provider != nil else { return }
            let portrait = await model.authorImage(BookAuthor(name: option.name, imageTag: option.imageTag, id: option.id))
            guard !Task.isCancelled else { return }
            data = portrait
        }
    }
}
