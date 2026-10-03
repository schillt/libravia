import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "books.vertical.fill").font(.system(size: 52)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Your library.\nYour next chapter.").font(.largeTitle.bold())
                Text("Connect to your Jellyfin 12 server to read your books.").foregroundStyle(.secondary)
                VStack(spacing: 16) {
                    TextField("https://your-server.example", text: $server).textContentType(.URL)
                    Text("Enter your Jellyfin HTTPS address, including any base path.").font(.caption).foregroundStyle(.secondary)
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }.textFieldStyle(.roundedBorder).autocorrectionDisabled().disabled(model.connecting)
                Button {
                    let secret = password; password = ""
                    Task { await model.login(server: server, username: username, password: secret) }
                } label: { HStack { if model.connecting { ProgressView().controlSize(.small) }; Text(model.connecting ? "Connecting…" : "Connect").frame(maxWidth: .infinity) } }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.connecting || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #if DEBUG
                Menu("Preview a Sample Book") { ForEach([BookFormat.epub, .pdf, .cbz], id: \.self) { format in Button(format.rawValue.uppercased()) { Task { await model.openSample(format) } } } }
                #endif
                Text("Your password is used only to sign in. The resulting access token is stored in Keychain.").font(.footnote).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 460).frame(maxWidth: .infinity)
        }.defaultScrollAnchor(.center)
    }
}
struct SearchView: View {
    @State private var query = ""
    var body: some View {
        CatalogView(searchQuery: query)
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search books")
            #else
            .searchable(text: $query, placement: .toolbar, prompt: "Search books")
            #endif
    }
}

struct CatalogView: View {
    @Environment(AppModel.self) private var model
    var parent: Library? = nil
    var resume = false
    var searchQuery: String? = nil
    init(parent: Library? = nil, resume: Bool = false, searchQuery: String? = nil, initialFilters: CatalogFilters = .init(), initialSort: CatalogSort = .titleAscending) {
        self.parent = parent; self.resume = resume; self.searchQuery = searchQuery
        self._filters = State(initialValue: initialFilters)
        self._sort = State(initialValue: initialSort)
    }
    @AppStorage("catalogListLayout") private var listLayout = false
    @State private var similarBooks: [Book] = []
    @State private var suggestedBooks: [Book] = []
    @State private var recentBooks: [Book] = []
    @State private var homeCollections: [CatalogOption] = []
    @State private var homeDiscoveryFailure = false
    @State private var suggestionsFailed = false
    @State private var suggestionsLoading = false
    @State private var suggestionRevision = UUID()
    @State private var similarFailure = false
    @State private var similarRetry = 0
    @State private var searchLibrary: String?
    @State private var filters = CatalogFilters()
    @State private var sort = CatalogSort.titleAscending
    @State private var showingFilters = false
    @State private var storedBooks: [Book] = []
    private var books: [Book] {
        let updated = storedBooks.map { model.displayedBook($0) }
        guard resume else { return updated }
        let local = model.locallyReadingBooks
        let localIDs = Set(local.map(\.id))
        return local + updated.filter { !localIDs.contains($0.id) && $0.readingStatus == .inProgress }
    }
    private var snapshotKey: String { "\(model.sessionID)|\(model.catalogRevision)|\(request)|\(resume)" }
    private var suggestionCacheKey: String { "suggestions|\(model.sessionID)|\(model.catalogRevision)" }
    private var discoveryCacheKey: String { "home|\(model.sessionID)|\(model.catalogRevision)|\(homeCollectionScope)" }
    private var similarCacheKey: String { "similar|\(model.sessionID)|\(model.catalogRevision)|\(storedBooks.first?.id ?? "")" }

    @State private var total = 0
    @State private var nextOffset = 0
    @State private var nextCursor: String?
    @State private var reachedEnd = false
    @State private var loading = false
    @State private var failure: String?
    @State private var expired = false
    @State private var revision = UUID()
    @State private var generation = UUID()
    @State private var requestGate = CatalogRequestGate()
    @State private var pageTask: Task<Void, Never>?
    private var query: String { (searchQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearch: Bool { searchQuery != nil }
    private var selectedID: String? { resume ? nil : (isSearch ? searchLibrary : model.selectedLibrary) }
    private var scope: CatalogScope {
        CatalogPresentation.scope(libraries: model.libraries, selectedID: selectedID, folderID: parent?.id, search: isSearch)
    }
    private var canLoad: Bool { CatalogPresentation.canLoad(search: isSearch, query: query, filters: filters) }
    private var request: CatalogRequest { CatalogRequest(scope: scope, query: query, start: 0, filters: filters, sort: sort) }
    private var requestKey: String { "\(model.sessionID)|\(model.catalogRevision)|\(request)|\(resume)|\(revision)" }
    private var suggestionKey: String { "\(model.sessionID)|\(model.catalogRevision)|\(suggestionRevision)" }
    private var homeDiscoveryKey: String { "\(model.sessionID)|\(model.catalogRevision)|\(model.selectedLibrary ?? "")|\(suggestionRevision)" }
    private let homeColumns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]
    private var homeCollectionScope: CatalogScope {
        CatalogPresentation.scope(libraries: model.libraries, selectedID: model.selectedLibrary ?? model.libraries.first?.id, folderID: nil, search: false)
    }
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !resume { activeFilters }
                if let status = model.status { Label(status, systemImage: "info.circle").foregroundStyle(.secondary) }
                if resume { Text("Continue Reading").font(.headline) }
                if !canLoad {
                    ContentUnavailableView("Find your next book", systemImage: "magnifyingglass", description: Text("Search book titles across your libraries. Use Filters to find an author."))
                } else if let failure, books.isEmpty {
                    ContentUnavailableView { Label(expired ? "Session expired" : "Couldn’t load books", systemImage: expired ? "person.crop.circle.badge.exclamationmark" : "wifi.exclamationmark") } description: { Text(failure) } actions: { Button("Try Again") { model.catalogSnapshots.removeValue(forKey: snapshotKey); revision = UUID() } }
                } else if books.isEmpty && !loading {
                    ContentUnavailableView(isSearch ? "No matching books" : resume ? "No books in progress" : "No books here", systemImage: isSearch ? "magnifyingglass" : "books.vertical", description: Text(isSearch ? "Try another title, library, or filter." : resume ? "Open a book from Library to begin reading." : "Choose another library or adjust your filters."))
                }
                if resume {
                    if let first = books.first {
                        Button { model.open(first) } label: { ContinueReadingCard(book: first) }
                            .buttonStyle(.plain).modifier(BookActions(book: first))
                    }
                    if books.count > 1 {
                        Text("Also in Progress").font(.headline)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(books.dropFirst())) { book in
                                NavigationLink { BookDetailView(book: book) } label: { SearchBookRow(book: book) }
                                    .buttonStyle(.plain).modifier(BookActions(book: book))
                                Divider()
                            }
                        }
                    }
                } else if isSearch || listLayout {
                    LazyVStack(spacing: 0) {
                        ForEach(books) { book in
                            NavigationLink { if book.isFolder { CatalogView(parent: Library(id: book.id, name: book.title)) } else { BookDetailView(book: book) } } label: { SearchBookRow(book: book) }.buttonStyle(.plain).modifier(BookActions(book: book))
                            Divider()
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
                        ForEach(books) { book in
                            NavigationLink { if book.isFolder { CatalogView(parent: Library(id: book.id, name: book.title)) } else { BookDetailView(book: book) } } label: { BookCard(book: book) }.buttonStyle(.plain).modifier(BookActions(book: book))
                        }
                    }
                }
                if loading { ProgressView(isSearch ? "Searching…" : "Loading…").frame(maxWidth: .infinity).padding() }
                if let failure, !books.isEmpty {
                    Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Button("Retry Loading More") { loadMore() }.buttonStyle(.bordered)
                } else if nextOffset < total && !reachedEnd && !loading {
                    Button("Load More") { loadMore() }.frame(maxWidth: .infinity).buttonStyle(.bordered)
                }
                if resume, let first = storedBooks.first {
                    if !similarBooks.isEmpty {
                        Text("More like \(first.title)").font(.headline)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(similarBooks) { book in
                                    NavigationLink { BookDetailView(book: book) } label: { BookCard(book: book).frame(width: 120) }
                                        .buttonStyle(.plain).modifier(BookActions(book: book))
                                }
                            }
                        }
                    } else if similarFailure {
                        Button("Retry Similar Books") { similarRetry += 1 }.font(.callout)
                    }
                }
                if resume {
                    HStack {
                        Text("Your Next Read").font(.headline)
                        Spacer()
                        Button { model.discoveryBooks.removeValue(forKey: suggestionCacheKey); suggestionRevision = UUID() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh suggested books")
                    }
                    if !suggestedBooks.isEmpty {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(suggestedBooks) { book in
                                    NavigationLink { BookDetailView(book: book) } label: { BookCard(book: book).frame(width: 108) }
                                        .buttonStyle(.plain).modifier(BookActions(book: book))
                                }
                            }
                        }.scrollIndicators(.hidden)
                    } else if suggestionsLoading {
                        ProgressView("Finding books…").frame(maxWidth: .infinity).padding()
                    } else if suggestionsFailed {
                        Button("Retry Suggestions") { suggestionRevision = UUID() }.font(.callout)
                    } else {
                        Text("No supported books to suggest yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    if !homeCollections.isEmpty {
                        HStack {
                            Text("Explore Collections").font(.headline)
                            Spacer()
                            NavigationLink("See All") { LibraryCollectionsView(scope: homeCollectionScope) }.font(.callout)
                        }
                        LazyVGrid(columns: homeColumns, spacing: 12) {
                            ForEach(homeCollections.prefix(4)) { collection in
                                NavigationLink { CatalogView(parent: Library(id: collection.id, name: collection.name)) } label: { CollectionCard(collection: collection) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if !recentBooks.isEmpty {
                        HStack {
                            Text("Recently Added").font(.headline)
                            Spacer()
                            NavigationLink("See All") { CatalogView(initialSort: .recentlyAdded) }.font(.callout)
                        }
                        LazyVGrid(columns: homeColumns, alignment: .leading, spacing: 18) {
                            ForEach(recentBooks.prefix(6)) { book in
                                NavigationLink { BookDetailView(book: book) } label: { BookCard(book: book, coverWidth: 112) }
                                    .buttonStyle(.plain).modifier(BookActions(book: book))
                            }
                        }
                    } else if homeDiscoveryFailure {
                        Button("Retry Home Sections") { suggestionRevision = UUID() }.font(.callout)
                    }
                }
            }.padding(20)
        }
        .task(id: "\(model.sessionID)|\(model.catalogRevision)|\(storedBooks.first?.id ?? "")|\(similarRetry)") {
            let cacheKey = similarCacheKey
            if resume, let cached = model.discoveryBooks[cacheKey] { similarBooks = cached; return }
            similarBooks = []; similarFailure = false
            guard resume, let first = storedBooks.first, let provider = model.provider else { return }
            do {
                let result = try await provider.similar(to: first)
                guard !Task.isCancelled else { return }
                let currentIDs = Set(books.map(\.id))
                similarBooks = result.filter { !currentIDs.contains($0.id) }; model.discoveryBooks[cacheKey] = similarBooks
            } catch { if !Task.isCancelled { similarFailure = true } }
        }
        .task(id: suggestionKey) {
            let key = suggestionKey
            if resume, let cached = model.discoveryBooks[suggestionCacheKey] { suggestedBooks = cached; return }
            suggestedBooks = []; suggestionsFailed = false; suggestionsLoading = true
            defer { if key == suggestionKey { suggestionsLoading = false } }
            guard resume, let provider = model.provider, !model.libraries.isEmpty else { return }
            do {
                let scope = CatalogScope(libraries: model.libraries)
                var items = try await provider.suggestedBooks(scope: scope, limit: 8)
                if items.isEmpty {
                    let page = try await provider.catalog(.init(scope: scope, sort: .recentlyAdded))
                    items = Array(page.items.filter { $0.format != .unsupported && !$0.isFolder }.shuffled().prefix(8))
                }
                guard key == suggestionKey, !Task.isCancelled else { return }
                let readingIDs = Set(books.map(\.id))
                let unreadSuggestions = items.filter { !readingIDs.contains($0.id) }
                suggestedBooks = unreadSuggestions.isEmpty ? items : unreadSuggestions
                model.discoveryBooks[suggestionCacheKey] = suggestedBooks
            } catch { if key == suggestionKey, !Task.isCancelled { suggestionsFailed = true } }
        }
        .task(id: homeDiscoveryKey) {
            if resume, let cached = model.discoveryBooks[discoveryCacheKey], let collections = model.discoveryCollections[discoveryCacheKey] {
                recentBooks = cached; homeCollections = collections; return
            }
            recentBooks = []; homeCollections = []; homeDiscoveryFailure = false
            guard resume, let provider = model.provider, !model.libraries.isEmpty else { return }
            let key = homeDiscoveryKey
            do {
                let page = try await provider.catalog(.init(scope: .init(libraries: model.libraries), sort: .recentlyAdded))
                guard key == homeDiscoveryKey, !Task.isCancelled else { return }
                recentBooks = Array(page.items.filter { !$0.isFolder }.prefix(6))
                let collections = try await provider.discoveryCollections(scope: homeCollectionScope, query: "", start: 0)
                guard key == homeDiscoveryKey, !Task.isCancelled else { return }
                homeCollections = Array(collections.items.shuffled().prefix(4))
                model.discoveryBooks[discoveryCacheKey] = recentBooks; model.discoveryCollections[discoveryCacheKey] = homeCollections
            } catch { if key == homeDiscoveryKey, !Task.isCancelled { homeDiscoveryFailure = true } }
        }
        .navigationTitle(parent?.name ?? (isSearch ? "Search" : resume ? "Home" : "Library"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !resume && parent == nil && model.libraries.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if isSearch {
                            Picker("Search in", selection: $searchLibrary) {
                                Text("All book libraries").tag(String?.none)
                                ForEach(model.libraries) { Text($0.name).tag(Optional($0.id)) }
                            }
                        } else {
                            Picker("Book library", selection: $model.selectedLibrary) {
                                ForEach(model.libraries) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    } label: { Label("Libraries", systemImage: "books.vertical") }
                    .accessibilityLabel("Library scope")
                    .accessibilityValue(scope.libraries.map(\.name).joined(separator: ", "))
                    .help(isSearch && searchLibrary == nil ? "All book libraries" : scope.libraries.first?.name ?? "Choose library")
                }
            }
            if !resume && !isSearch {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("View", selection: $listLayout) {
                            Label("Covers", systemImage: "square.grid.2x2").tag(false)
                            Label("List", systemImage: "list.bullet").tag(true)
                        }
                    } label: { Label("View options", systemImage: listLayout ? "list.bullet" : "square.grid.2x2") }
                }
            }
            if !resume {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingFilters = true } label: { Label("Filters", systemImage: filters.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                        .popover(isPresented: $showingFilters) {
                            CatalogFilterEditor(scope: scope, selection: filters) { filters = $0; showingFilters = false }
                                .environment(model)
                                .presentationCompactAdaptation(.sheet)
                        }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu { Picker("Sort books", selection: $sort) { ForEach(CatalogSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } } } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                }
            }
            ToolbarItem(placement: .primaryAction) { ProfileButton() }
        }
        .refreshable { await model.loadLibraries(); revision = UUID() }
        .task(id: requestKey) {
            pageTask?.cancel()
            let token = requestGate.begin(request: request, session: model.sessionID); generation = token
            if !isSearch, let snapshot = model.catalogSnapshots[snapshotKey] {
                storedBooks = snapshot.books; total = snapshot.total; nextOffset = snapshot.offset
                nextCursor = snapshot.cursor; reachedEnd = snapshot.reachedEnd; loading = false; failure = nil; return
            }
            storedBooks = []; total = 0; nextOffset = 0; nextCursor = nil; reachedEnd = false; failure = nil; loading = false; expired = false
            guard canLoad else { return }
            loading = true
            if isSearch {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            loading = false
            await load(reset: true, token: token)
        }
        .onDisappear { pageTask?.cancel(); loading = false }
    }
    private var activeFilters: some View {
        ViewThatFits(in: .horizontal) {
            HStack { filterChips }
            VStack(alignment: .leading) { filterChips }
        }
    }
    @ViewBuilder private var filterChips: some View {
        if let author = filters.author { chip(author.name) { filters.author = nil } }
        if let genre = filters.genre { chip(genre.name) { filters.genre = nil } }
        if let tag = filters.tag { chip(tag.name) { filters.tag = nil } }
        if let status = filters.status { chip(status.rawValue) { filters.status = nil } }
    }
    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { Label(title, systemImage: "xmark.circle.fill").font(.caption) }.buttonStyle(.bordered).accessibilityLabel("Remove filter: \(title)")
    }
    private func loadMore() { let token = generation; pageTask = Task { await load(reset: false, token: token) } }
    private func load(reset: Bool, token: UUID) async {
        guard token == generation, !loading, !Task.isCancelled, let provider = model.provider, !scope.libraries.isEmpty,
              canLoad else { return }
        let key = requestKey
        let offset = reset ? 0 : nextOffset
        loading = true
        defer { if token == generation { loading = false } }
        do {
            let result: CatalogPage
            if resume { result = try await provider.browse(parent: selectedID, query: "", start: offset, resume: true) }
            else { var pageRequest = request; pageRequest.start = offset; pageRequest.cursor = reset ? nil : nextCursor; result = try await provider.catalog(pageRequest) }
            guard token == generation, requestGate.accepts(token, request: request, session: model.sessionID), key == requestKey, !Task.isCancelled else { return }
            var seen = Set(reset ? [] : books.map(\.id))
            let newBooks = result.items.filter { seen.insert($0.id).inserted }
            storedBooks = reset ? newBooks : storedBooks + newBooks
            nextOffset = offset + result.items.count
            nextCursor = result.nextCursor
            total = result.total; reachedEnd = resume ? result.items.isEmpty : result.nextCursor == nil; failure = nil
            if !isSearch { model.catalogSnapshots[snapshotKey] = .init(books: storedBooks, total: total, offset: nextOffset, cursor: nextCursor, reachedEnd: reachedEnd) }
        } catch {
            if token == generation, requestGate.accepts(token, request: request, session: model.sessionID), key == requestKey, !Task.isCancelled {
                expired = error is JellyfinAuthenticationError
                failure = UserFacingError.message(error)
            }
        }
    }
}

struct SearchBookRow: View {
    @Environment(AppModel.self) private var model
    var book: Book
    var body: some View {
        HStack(spacing: 14) {
            CoverView(book: book).frame(width: 52, height: 78)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                if let name = book.libraryName { Text(name).font(.caption).foregroundStyle(.secondary) }
                if !book.isFolder { HStack { Text(model.displayedBook(book).readingStatus.rawValue); DeviceBookIndicator(book: book) }.font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 10).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct CatalogFilterEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var scope: CatalogScope
    @State var selection: CatalogFilters
    var apply: (CatalogFilters) -> Void
    @State private var options: CatalogFilterOptions?
    @State private var failure: String?
    @State private var revision = UUID()
    var body: some View {
        NavigationStack {
            Form {
                if let options {
                    if options.authorsAvailable || selection.author != nil {
                        NavigationLink { CatalogAuthorPicker(scope: scope, selection: $selection.author) } label: {
                            LabeledContent("Author", value: selection.author?.name ?? "Any")
                        }
                    }
                    optionPicker("Genre", values: options.genres, selection: $selection.genre)
                    optionPicker("Tag", values: options.tags, selection: $selection.tag)
                    if !options.statuses.isEmpty || selection.status != nil {
                        Picker("Reading status", selection: $selection.status) {
                            Text("Any").tag(CatalogReadingStatus?.none)
                            ForEach(statuses(options), id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                        }
                    }
                    if !options.authorsAvailable && options.genres.isEmpty && options.tags.isEmpty && options.statuses.isEmpty && selection.isEmpty {
                        Text("No useful filters are available in this library or folder.").foregroundStyle(.secondary)
                    }
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Try Again") { revision = UUID() }
                    // Existing selections remain removable even when metadata is unavailable.
                    if !selection.isEmpty { selectedSummary }
                } else { ProgressView("Finding available filters…") }
                Button("Clear All") { selection = CatalogFilters() }.disabled(selection.isEmpty)
            }
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply(selection) } }
            }
        }
        .frame(idealWidth: 400, idealHeight: 440)
        .task(id: "\(scope)|\(model.sessionID)|\(model.catalogRevision)|\(revision)") {
            options = nil; failure = nil
            do {
                let result = try await model.provider?.filterOptions(scope: scope)
                guard !Task.isCancelled else { return }; options = result
            } catch { if !Task.isCancelled { failure = UserFacingError.message(error) } }
        }
    }
    @ViewBuilder private var selectedSummary: some View {
        if let value = selection.author { Button("Remove author: \(value.name)") { selection.author = nil } }
        if let value = selection.genre { Button("Remove genre: \(value.name)") { selection.genre = nil } }
        if let value = selection.tag { Button("Remove tag: \(value.name)") { selection.tag = nil } }
        if let value = selection.status { Button("Remove status: \(value.rawValue)") { selection.status = nil } }
    }
    @ViewBuilder private func optionPicker(_ title: String, values: [CatalogOption], selection: Binding<CatalogOption?>) -> some View {
        if !values.isEmpty || selection.wrappedValue != nil {
            Picker(title, selection: selection) {
                Text("Any").tag(CatalogOption?.none)
                if let selected = selection.wrappedValue, !values.contains(selected) { Text(selected.name).tag(Optional(selected)) }
                ForEach(values) { Text($0.name).tag(Optional($0)) }
            }
        }
    }
    private func statuses(_ options: CatalogFilterOptions) -> [CatalogReadingStatus] {
        var values = options.statuses
        if let selected = selection.status, !values.contains(selected) { values.append(selected) }
        return values
    }
}

struct CatalogAuthorPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var scope: CatalogScope
    @Binding var selection: CatalogOption?
    @State private var query = ""
    @State private var authors: [CatalogOption] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var revision = UUID()
    @State private var generation = UUID()
    @State private var pageTask: Task<Void, Never>?
    var body: some View {
        List {
            Button("Any author") { selection = nil; dismiss() }
            if let selection, !authors.contains(selection) { authorButton(selection) }
            ForEach(authors) { authorButton($0) }
            if loading { ProgressView("Finding authors…") }
            if let failure { Text(failure).foregroundStyle(.secondary); Button("Try Again") { if authors.isEmpty { revision = UUID() } else { more() } } }
            else if !loading && offset < total { Button("Load More Authors") { more() } }
            else if !loading && authors.isEmpty { Text("No matching authors").foregroundStyle(.secondary) }
        }
        .navigationTitle("Author")
        .searchable(text: $query, prompt: "Find an author")
        .task(id: "\(query)|\(scope)|\(model.sessionID)|\(revision)") {
            pageTask?.cancel(); let token = UUID(); generation = token
            authors = []; offset = 0; total = 0; failure = nil; loading = true
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }; loading = false
            await load(token)
        }
        .onDisappear { pageTask?.cancel(); generation = UUID() }
    }
    private func authorButton(_ author: CatalogOption) -> some View {
        Button { selection = author; dismiss() } label: {
            HStack { Text(author.name); Spacer(); if selection == author { Image(systemName: "checkmark").accessibilityLabel("Selected") } }
        }
    }
    private func more() { let token = generation; pageTask = Task { await load(token) } }
    private func load(_ token: UUID) async {
        guard token == generation, !loading, let provider = model.provider else { return }
        loading = true; failure = nil
        defer { if token == generation { loading = false } }
        do {
            let result = try await provider.authors(scope: scope, query: query, start: offset)
            guard token == generation, !Task.isCancelled else { return }
            var seen = Set(authors.map(\.id)); authors += result.items.filter { seen.insert($0.id).inserted }
            offset += result.consumed; total = result.consumed == 0 ? offset : result.total
        } catch { if token == generation, !Task.isCancelled { failure = UserFacingError.message(error) } }
    }
}

struct ProfileButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false
    var body: some View {
        Button { showingSettings = true } label: {
            Group {
                if let imageData = model.profileImageData, let image = platformImage(imageData) { image.resizable().scaledToFill() }
                else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
            }.frame(width: 30, height: 30).clipShape(Circle())
        }
        .accessibilityLabel("Profile and Settings")
        .help("Profile and Settings")
        .task(id: model.sessionID) {
            await model.loadProfileImage()
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 500)
            #endif
        }
    }
}
struct CoverView: View {
    @Environment(AppModel.self) private var model
    var book: Book
    var fullSize = false
    @State private var data: Data?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let data = data ?? model.cachedCoverImage(book, fullSize: fullSize) ?? model.cachedCoverImage(book), let image = platformImage(data) {
                    image.resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: book.isFolder ? "books.vertical.fill" : "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipShape(RoundedRectangle(cornerRadius: 8))
        }.aspectRatio(2.0 / 3.0, contentMode: .fit)
        .task(id: "\(model.sessionID)|\(book.id)|\(book.imageTag ?? "")") {
            data = nil
            guard book.imageTag != nil else { return }
            let image = await model.coverImage(book, fullSize: fullSize)
            guard !Task.isCancelled else { return }
            data = image
        }
        .accessibilityHidden(true)
    }
}
func platformImage(_ data: Data) -> Image? {
    #if os(macOS)
    guard let native = NSImage(data: data) else { return nil }; return Image(nsImage: native)
    #else
    guard let native = UIImage(data: data) else { return nil }; return Image(uiImage: native)
    #endif
}
struct BookCard: View {
    var book: Book
    var coverWidth: CGFloat? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(book: book).frame(maxWidth: coverWidth)
                .overlay(alignment: .bottomTrailing) {
                    if !book.isFolder { DeviceBookIndicator(book: book).labelStyle(.iconOnly).padding(5).background(.regularMaterial, in: Circle()).padding(5) }
                }
            Text(book.title).font(.headline).lineLimit(2)
            Text(book.isFolder ? "Collection" : book.author.isEmpty ? book.format.rawValue.uppercased() : book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}
struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    var book: Book
    @State private var detail: Book?
    @State private var authorImages: [String: Data] = [:]
    @State private var confirmingRemoval = false
    @State private var overview = ""
    private var displayed: Book { model.displayedBook(detail ?? book) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoverView(book: displayed, fullSize: true).modifier(ReaderCoverSource(book: displayed)).frame(width: 170).frame(maxWidth: .infinity)
                Text(displayed.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if !displayed.authors.isEmpty {
                    ForEach(displayed.authors, id: \.name) { author in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(.quaternary)
                                if let data = authorImages[author.name], let image = platformImage(data) { image.resizable().scaledToFill() }
                                else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                            }.frame(width: 38, height: 38).clipShape(Circle()).accessibilityHidden(true)
                            Text(author.name).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } else if !displayed.author.isEmpty { Text(displayed.author).font(.subheadline).foregroundStyle(.secondary) }
                Text(displayed.format == .unsupported ? "Unsupported format" : displayed.format.rawValue.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                DeviceBookIndicator(book: book).font(.caption)
                if model.openingID == book.id {
                    ProgressView(value: model.downloadProgress).accessibilityLabel("Preparing book")
                    Text(model.downloadProgress == nil ? "Checking reading position…" : "Preparing your book…").foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelOpen() }
                } else { Button { model.open(displayed) } label: { Label("Read", systemImage: "book").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(book.format == .unsupported) }
                if !overview.isEmpty { Text(overview).font(.body).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .task(id: displayed.summary) { overview = BookOverview.plainText(displayed.summary) }
        .navigationTitle("Book Details")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if model.openingID == book.id { Button("Cancel Download", systemImage: "xmark.circle") { model.cancelOpen() } }
                    else if model.isCached(book) {
                        Button("Remove from Device…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                            .disabled(model.reader?.id == book.id || model.openingID != nil)
                    } else {
                        Button("Download to Device", systemImage: "arrow.down.circle") { model.downloadToDevice(book) }
                            .disabled(book.format == .unsupported || model.reader != nil || model.openingID != nil || model.markingID != nil)
                    }
                    Button(displayed.readingStatus == .finished ? "Mark as Unread" : "Mark as Read", systemImage: displayed.readingStatus == .finished ? "circle" : "checkmark.circle") {
                        Task { await model.markFinished(displayed, finished: displayed.readingStatus != .finished) }
                    }.disabled(model.reader != nil || model.openingID != nil || model.markingID != nil)
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Book actions") }
            }
        }
        .alert("Remove device copy?", isPresented: $confirmingRemoval) {
            Button("Remove from Device", role: .destructive) { Task { await model.removeDeviceCopy(book) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the cached copy from this device only. The book stays on your Jellyfin server. Your bookmarks and reading position are kept.") }
        .task(id: "\(model.sessionID)|\(book.id)") {
            guard let provider = model.provider else { return }
            let fetched: Book
            if let detail { fetched = detail }
            else {
                guard let item = try? await provider.book(id: book.id), !Task.isCancelled else { return }
                fetched = item; detail = item
            }
            for author in fetched.authors where authorImages[author.name] == nil {
                if let image = await model.authorImage(author), !Task.isCancelled { authorImages[author.name] = image }
            }
        }
    }
}
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cleared = false
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Account", value: model.account?.username ?? "")
                LabeledContent("Server", value: model.account?.server.host ?? "")
                Text("Jellyfin 12 · One active account").foregroundStyle(.secondary)
                Button("Refresh Libraries") { Task { await model.loadLibraries() } }
                Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            }
            Section("Storage") {
                Text("Books are cached automatically, up to 1 GB. The open book is protected. Clearing the cache keeps your bookmarks and reading positions.")
                Button(cleared ? "Cache Cleared" : "Clear Cache") { Task { do { try await model.cache?.clear(); await model.refreshCache(); cleared = true } catch { model.error = UserFacingError.message(error) } } }
            }
            Section("About") {
                Text("LibraVia · 0.1.0")
                Text("EPUB, PDF, and CBZ · DRM-free books")
                NavigationLink("Open-source licenses") { ScrollView { VStack(alignment: .leading, spacing: 20) { ForEach(["EPUBjs-LICENSE", "Get-LICENSE", "JSZip-LICENSE", "JellyfinAPI-LICENSE", "SwiftAtomics-LICENSE", "SwiftCollections-LICENSE", "SwiftNIO-LICENSE", "SwiftNIO-NOTICE", "SwiftNIO-llhttp-LICENSE", "SwiftNIOTransportServices-LICENSE", "SwiftSystem-LICENSE"], id: \.self) { name in Text(name).font(.headline); Text(license(name)).font(.caption).textSelection(.enabled) } }.padding() }.navigationTitle("Licenses") }
            }
        }.formStyle(.grouped).navigationTitle("Settings")
    }
    private func license(_ name: String) -> String { guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Licenses") else { return "License included with source distribution." }; return (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

struct DeviceBookIndicator: View {
    @Environment(AppModel.self) private var model
    var book: Book
    var body: some View {
        if model.openingID == book.id {
            ProgressView(value: model.downloadProgress).controlSize(.mini).frame(width: 20).accessibilityLabel("Preparing device copy")
        } else {
            Label(model.isCached(book) ? "On device" : "On server", systemImage: model.isCached(book) ? "checkmark.circle.fill" : "cloud")
                .foregroundStyle(model.isCached(book) ? Color.green : Color.secondary)
        }
    }
}
struct BookActions: ViewModifier {
    @Environment(AppModel.self) private var model
    private var displayed: Book { model.displayedBook(book) }
    var book: Book
    @State private var confirmingRemoval = false
    func body(content: Content) -> some View {
        content.contextMenu {
            if !book.isFolder {
                if model.openingID == book.id { Button("Cancel Download", role: .cancel) { model.cancelOpen() } }
                else if model.isCached(book) {
                    Button("Remove from Device…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                        .disabled(model.reader?.id == book.id || model.openingID != nil)
                } else {
                    Button("Download to Device", systemImage: "arrow.down.circle") { model.downloadToDevice(book) }
                        .disabled(book.format == .unsupported || model.reader != nil || model.openingID != nil || model.markingID != nil)
                }
                Button(displayed.readingStatus == .finished ? "Mark as Unread" : "Mark as Read", systemImage: displayed.readingStatus == .finished ? "circle" : "checkmark.circle") {
                    Task { await model.markFinished(displayed, finished: displayed.readingStatus != .finished) }
                }.disabled(model.reader != nil || model.openingID != nil || model.markingID != nil)
            }
        }.alert("Remove device copy?", isPresented: $confirmingRemoval) {
            Button("Remove from Device", role: .destructive) { Task { await model.removeDeviceCopy(book) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the cached copy from this device only. The book stays on your Jellyfin server. Your bookmarks and reading position are kept.")
        }
    }
}
struct ContinueReadingCard: View {
    @Environment(AppModel.self) private var model
    var book: Book
    private var position: ReadingPosition {
        if let record = model.store?.records[book.id], record.dirty { return record.position }
        return .from(ticks: book.ticks, format: book.format)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            CoverView(book: book).modifier(ReaderCoverSource(book: book)).frame(width: 100)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title).font(.title3.bold()).lineLimit(3)
                if !book.author.isEmpty { Text(book.author).foregroundStyle(.secondary).lineLimit(2) }
                if book.format == .epub {
                    ProgressView(value: position.fraction).accessibilityHidden(true)
                    Text("\(Int(position.fraction * 100))% complete").font(.caption).foregroundStyle(.secondary)
                } else { Text("Page \(position.page + 1)").font(.caption).foregroundStyle(.secondary) }
                DeviceBookIndicator(book: book).font(.caption)
                Label("Continue Reading", systemImage: "book").font(.callout.weight(.semibold)).foregroundStyle(.tint)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}
