import SwiftUI

struct ProgressRematchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: BlockedProgress
    @State private var query = ""
    @State private var results: [Book] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var failed = false
    @State private var selected: Book?
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Jellyfin book titles", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search for a matching book")
                .padding()
            List {
                if loading && results.isEmpty { ProgressView("Searching Jellyfin…") }
                if failed {
                    ContentUnavailableView {
                        Label("Search unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Try Again") { Task { await search() } }
                    }
                } else if !loading && results.isEmpty {
                    ContentUnavailableView("No matching books", systemImage: "books.vertical",
                                           description: Text("Try another title. Your saved position remains on this device."))
                }
                ForEach(results) { book in
                    Button {
                        selected = book
                        confirming = true
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.title).font(.headline)
                            if !book.author.isEmpty { Text(book.author).font(.callout).foregroundStyle(.secondary) }
                            if let library = book.libraryName { Text(library).font(.caption).foregroundStyle(.secondary) }
                            if model.store?.records[book.id] != nil {
                                Text("Already has saved reading data on this device")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.store?.records[book.id] != nil)
                }
                if let cursor {
                    Button(loadingMore ? "Loading…" : "Load More") { Task { await loadMore(cursor) } }
                        .disabled(loadingMore)
                }
            }
        }
        .navigationTitle("Find \(entry.title)")
        .task {
            if query.isEmpty { query = entry.title }
        }
        .task(id: "\(model.sessionID)|\(query)") {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await search()
        }
        .confirmationDialog("Match this saved position?", isPresented: $confirming, titleVisibility: .visible) {
            if let selected {
                Button("Transfer Position and Bookmarks") {
                    dismiss()
                    Task { await model.rematchProgress(entry, to: selected) }
                }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text("Choose the replacement only if it is the same book. If Jellyfin already has progress, you will choose which position to keep before it is overwritten.")
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; cursor = nil; failed = false
        guard !term.isEmpty, let provider = model.provider else { loading = false; return }
        loading = true
        let session = model.sessionID
        do {
            let page = try await provider.catalog(CatalogRequest(scope: CatalogScope(libraries: model.libraries), query: term))
            guard !Task.isCancelled, session == model.sessionID, term == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = page.items.filter { $0.format == entry.format && $0.id != entry.id }
            cursor = page.nextCursor
            loading = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, session == model.sessionID else { return }
            failed = true; loading = false
        }
    }
    private func loadMore(_ requestedCursor: String) async {
        guard let provider = model.provider, !loadingMore else { return }
        loadingMore = true
        let session = model.sessionID, term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let page = try await provider.catalog(CatalogRequest(scope: CatalogScope(libraries: model.libraries), query: term, cursor: requestedCursor))
            guard session == model.sessionID, term == query.trimmingCharacters(in: .whitespacesAndNewlines), cursor == requestedCursor else { return }
            results += page.items.filter { $0.format == entry.format && $0.id != entry.id }
            cursor = page.nextCursor
            loadingMore = false
        } catch {
            guard session == model.sessionID else { return }
            failed = true; loadingMore = false
        }
    }
}
