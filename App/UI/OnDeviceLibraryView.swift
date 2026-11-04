import SwiftUI
import UniformTypeIdentifiers

struct OnDeviceLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingFile = false
    @State private var choosingFolder = false
    @State private var importing = false
    @State private var removing: LocalBookEntry?
    @State private var removingSaved: Book?
    @AppStorage("deviceCatalogLayout") private var storedLayout = CatalogViewLayout.list.rawValue
    @AppStorage("deviceCatalogAscending") private var ascending = true
    @AppStorage("catalogCoverSize") private var storedCoverSize = CatalogCoverSize.medium.rawValue
    @State private var selectedFormat: BookFormat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var layout: CatalogViewLayout { CatalogViewLayout(rawValue: storedLayout) ?? .list }
    private var layoutSelection: Binding<CatalogViewLayout> {
        Binding(get: { layout }, set: { storedLayout = $0.rawValue })
    }
    private var coverSizeSelection: Binding<CatalogCoverSize> {
        Binding(get: { CatalogCoverSize(rawValue: storedCoverSize) ?? .medium }, set: { storedCoverSize = $0.rawValue })
    }
    private var columns: [GridItem] {
        let width = (layout == .gallery ? 210.0 : 140.0) * coverSizeSelection.wrappedValue.scale
        return [GridItem(dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: width, maximum: width * 1.5), spacing: 14, alignment: .top)]
    }
    private func ordered(_ lhs: String, _ lhsID: String, _ rhs: String, _ rhsID: String) -> Bool {
        let result = lhs.localizedStandardCompare(rhs)
        return result == .orderedSame ? lhsID < rhsID : (ascending ? result == .orderedAscending : result == .orderedDescending)
    }
    private func matches(_ format: BookFormat) -> Bool { selectedFormat == nil || selectedFormat == format }

    var body: some View {
        Group {
            if model.onDeviceBooks.isEmpty && model.savedCatalog.isEmpty && model.folderName == nil {
                ContentUnavailableView {
                    Label("On My Device", systemImage: "books.vertical")
                } description: {
                    Text("Import your own EPUB, PDF, and CBZ books to read on this device.")
                } actions: {
                    Button("Import a Book") { choosingFile = true }.disabled(importing)
                    Button("Choose a Book Folder") { choosingFolder = true }.disabled(importing)
                }
            } else {
                List {
                    if let folderName = model.folderName { Section("Book folder · \(folderName)") {
                        if let problem = model.folderProblem { Text(problem).foregroundStyle(.secondary) }
                        if model.folderBooks.isEmpty { Text("No EPUB, PDF, or CBZ books found.").foregroundStyle(.secondary) }
                        rowsOrGrid {
                        ForEach(model.folderBooks.filter { matches($0.format) }.sorted { ordered($0.title, $0.id, $1.title, $1.id) }) { entry in
                            let cached = model.onDeviceBooks.first { $0.id == entry.id }
                            Button {
                                importing = true
                                Task { await model.openFolderBook(entry); importing = false }
                            } label: {
                                bookLabel(title: cached?.title ?? entry.title,
                                          subtitle: (!entry.available || model.folderProblem != nil) ? (cached == nil ? "Source unavailable" : "Source unavailable · Device copy available") : entry.format.rawValue.uppercased(),
                                          book: cached?.book)
                            }.buttonStyle(.plain).disabled(importing || model.openingID != nil)
                                .contextMenu {
                                    if let cached { Button("Remove Device Copy…", systemImage: "trash", role: .destructive) { removing = cached } }
                                }
                        }
                        }
                        Button("Refresh Book Folder", systemImage: "arrow.clockwise") { Task { await model.refreshLocalFolder() } }
                    } }
                    if model.savedCatalog.contains(where: { matches($0.format) }) {
                        Section("Saved from Jellyfin") {
                            rowsOrGrid {
                            ForEach(model.savedCatalog.filter { matches($0.format) }.sorted { ordered($0.title, $0.id, $1.title, $1.id) }) { book in
                                Button { model.openSaved(book) } label: {
                                    bookLabel(title: book.title, subtitle: book.author.isEmpty ? book.format.rawValue.uppercased() : book.author, book: book)
                                }.buttonStyle(.plain).disabled(importing || model.openingID != nil)
                                .contextMenu { Button("Remove from Device…", systemImage: "trash", role: .destructive) { removingSaved = book } }
                            }
                            }
                        }
                    }
                    let importedBooks = model.onDeviceBooks.filter { $0.folderSource != true && matches($0.format) }
                    if !importedBooks.isEmpty { Section("Imported books") {
                    rowsOrGrid {
                    ForEach(importedBooks.sorted { ordered($0.title, $0.id, $1.title, $1.id) }) { entry in
                    Button { model.openOnDevice(entry) } label: {
                        bookLabel(title: entry.title, subtitle: entry.author.flatMap { $0.isEmpty ? nil : "\($0) · \(entry.format.rawValue.uppercased())" } ?? entry.format.rawValue.uppercased(), book: entry.book)
                    }.buttonStyle(.plain).disabled(importing || model.openingID != nil)
                    .contextMenu {
                        Button("Remove from Device…", systemImage: "trash", role: .destructive) { removing = entry }
                    }
                    }
                    }
                    } }
                    if selectedFormat != nil && !model.folderBooks.contains(where: { matches($0.format) }) &&
                        !model.savedCatalog.contains(where: { matches($0.format) }) &&
                        !model.onDeviceBooks.contains(where: { $0.folderSource != true && matches($0.format) }) {
                        Section {
                            Text("No books match this format.").foregroundStyle(.secondary)
                            Button("Clear Format Filter") { selectedFormat = nil }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if importing { ProgressView("Importing book…").padding().background(.regularMaterial, in: Capsule()).padding() }
        }
        .navigationTitle("On My Device")
        .profileToolbar()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("View", selection: layoutSelection) {
                        ForEach(CatalogViewLayout.allCases) { value in Label(value.title, systemImage: value.symbol).tag(value) }
                    }.pickerStyle(.inline)
                    if layout != .list {
                        Divider()
                        Picker("Cover size", selection: coverSizeSelection) {
                            ForEach(CatalogCoverSize.allCases) { size in Text(size.title).tag(size) }
                        }.pickerStyle(.inline)
                    }
                } label: { Label("View options", systemImage: layout.symbol) }
                    .accessibilityValue(layout.title).help("View: \(layout.title)")
                Menu {
                    Picker("Sort by title", selection: $ascending) {
                        Text("Title A–Z").tag(true)
                        Text("Title Z–A").tag(false)
                    }.pickerStyle(.inline)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                    .accessibilityValue(ascending ? "Title A–Z" : "Title Z–A")
                Menu {
                    Picker("Format", selection: $selectedFormat) {
                        Text("All formats").tag(BookFormat?.none)
                        Text("EPUB").tag(Optional(BookFormat.epub))
                        Text("PDF").tag(Optional(BookFormat.pdf))
                        Text("CBZ").tag(Optional(BookFormat.cbz))
                    }.pickerStyle(.inline)
                } label: { Label("Filter by format", systemImage: selectedFormat == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                    .accessibilityValue(selectedFormat?.rawValue.uppercased() ?? "All formats")
                NavigationLink { StorageManagementView(showBookNavigation: false) } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
                Menu("Add books", systemImage: "plus") {
                    Button("Import Book", systemImage: "doc.badge.plus") { choosingFile = true }
                    Button("Choose Book Folder", systemImage: "folder.badge.plus") { choosingFolder = true }
                }.disabled(importing)
            }
        }
        .appSurface()
        .task { await model.loadOnDeviceLibrary(); await model.refreshLocalFolder(); await model.refreshCache() }
        .confirmationDialog("Remove this book from your device?", item: $removing, titleVisibility: .visible) { entry in
            Button("Remove from Device", role: .destructive) { Task { await model.removeOnDevice(entry) } }
        } message: { _ in
            Text("The imported copy is removed. Your original file is unchanged, and your reading position and bookmarks are kept.")
        }
        .confirmationDialog("Remove this saved copy?", item: $removingSaved, titleVisibility: .visible) { book in
            Button("Remove from Device", role: .destructive) { Task { await model.removeDeviceCopy(book) } }
        } message: { _ in
            Text("The device copy is removed. The book stays on your Jellyfin server, and your reading data is kept.")
        }
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: [.pdf, UTType(filenameExtension: "epub") ?? .data, UTType(filenameExtension: "cbz") ?? .data]) { result in
            switch result {
            case .success(let url):
                importing = true
                Task { await model.importOnDevice(url); importing = false }
            case .failure: model.error = "Could not select this book. Please try again."
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                importing = true
                Task { await model.selectLocalFolder(url); importing = false }
            case .failure: model.error = "Could not select this folder. Please try again."
            }
        }
    }
    @ViewBuilder private func rowsOrGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if layout == .list { content() }
        else { LazyVGrid(columns: columns, alignment: .leading, spacing: 16) { content() }.padding(.vertical, 8) }
    }
    @ViewBuilder private func bookLabel(title: String, subtitle: String, book: Book?) -> some View {
        if layout == .list {
            HStack(spacing: 14) {
                localCover(book).frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(.vertical, 4).contentShape(Rectangle())
        } else {
            VStack(alignment: .leading, spacing: 10) {
                localCover(book).frame(maxWidth: .infinity)
                if dynamicTypeSize.isAccessibilitySize {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(title).font(.headline).lineLimit(2, reservesSpace: true)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                }
            }
            .padding(layout == .cards ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(layout == .cards ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private func localCover(_ book: Book?) -> some View {
        if let book { CoverView(book: book) }
        else {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay { Image(systemName: "book.closed").font(.title).foregroundStyle(.secondary) }
                .aspectRatio(2.0 / 3.0, contentMode: .fit).accessibilityHidden(true)
        }
    }
}

struct StorageManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var loaded = false
    @State private var confirmingClear = false
    let showBookNavigation: Bool

    init(showBookNavigation: Bool = true) { self.showBookNavigation = showBookNavigation }

    var body: some View {
        Form {
            Section("Book data") {
                LabeledContent("Imported books", value: display(model.storageUsage?.importedBytes))
                if model.account != nil {
                    LabeledContent("Saved from Jellyfin", value: display(model.storageUsage?.savedBytes))
                    LabeledContent("Temporary cache", value: display(model.storageUsage?.cacheBytes))
                }
                Text("Approximate file sizes include extracted book content and covers. Reading data and in-progress downloads are not included.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Refresh Storage Use", systemImage: "arrow.clockwise") { Task { await refresh() } }
            }
            Section("Manage") {
                if showBookNavigation { NavigationLink("Manage Device Copies") { OnDeviceLibraryView() } }
                if model.account != nil {
                    NavigationLink("Downloads") { DownloadQueueView() }
                    Button("Clear Temporary Cache…", role: .destructive) { confirmingClear = true }
                        .disabled(model.openingID != nil)
                    Text("Saved books and reading data are kept. The book currently open stays in the cache.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped).appSurface().navigationTitle("Storage")
        .task { await refresh() }
        .confirmationDialog("Clear temporary cache?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { Task { await model.clearDeviceCache() } }
        } message: {
            Text("Saved books, reading data, and the book currently open will be kept.")
        }
    }

    private func display(_ bytes: Int64?) -> String {
        guard let bytes else { return loaded ? "Unavailable" : "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func refresh() async { await model.refreshStorageUsage(); loaded = true }
}
