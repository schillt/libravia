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
                NavigationLink { PrivateRecoveryView() } label: {
                    Label("Private Recovery", systemImage: "icloud")
                }.help("Private Recovery")
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

/// Manual recovery remains separate from local reading and requires a fresh
/// account check before any transfer. Review tools are still in development.
private struct PrivateRecoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("automaticStandaloneRecovery") private var automaticRecovery = false
    @AppStorage("automaticStandaloneRecoveryAccount") private var automaticRecoveryAccount = ""
    @State private var service: StandaloneCloudRecoveryService?
    @State private var inspection: StandaloneCloudRecoveryService.Inspection?
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingCreate = false
    @State private var confirmingAccountSwitch = false
    @State private var reviews: [StandaloneReadingReviewItem] = []
    @State private var reviewing: StandaloneReadingReviewItem?
    @State private var incoming: [StandaloneIncomingReadingItem] = []
    @State private var reviewingIncoming: StandaloneIncomingReadingItem?
    @State private var conflicts: [StandaloneReadingConflictItem] = []
    @State private var resolving: StandaloneReadingConflictItem?
    @State private var bookConflicts: [StandaloneBookConflictItem] = []
    @State private var resolvingBook: StandaloneBookConflictItem?
    @State private var deletedBackups: [StandaloneDeletedBackupItem] = []
    @State private var reviewingDeletion: StandaloneDeletedBackupItem?

    var body: some View {
        Form {
            Section("Private iCloud Recovery") {
                Text("Save and restore imported EPUB, PDF, and CBZ books and their reading data using your private iCloud account.")
                Text("Recovery is being tested. Keep your original files until you have verified your restored library.")
                    .foregroundStyle(.secondary)
                if busy { ProgressView("Checking recovery…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                if automaticRecovery, let status = model.automaticRecoveryStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if automaticRecovery && (inspection == nil || automaticRecoveryAccount != inspection?.scope.cloudAccountKey) {
                    Button("Turn Off Automatic Recovery") { model.disableAutomaticRecovery() }.disabled(busy)
                }
                Button("Check iCloud") { checkAccount() }.disabled(busy)
                if let inspection {
                    if model.canSwitchStandaloneRecoveryAccount(scope: inspection.scope) {
                        Text("This device library’s recovery is linked to a different iCloud account.")
                        switch inspection.zoneState {
                        case .present:
                            Button("Review Account Switch…") { confirmingAccountSwitch = true }.disabled(busy)
                        case .missing:
                            Text("The current iCloud account has no recovery area for this library.").foregroundStyle(.secondary)
                            Button("Set Up Recovery…") { confirmingCreate = true }.disabled(busy)
                        case .deletedByUser:
                            Text("The current account’s recovery area was removed or reset and needs review.").foregroundStyle(.secondary)
                        }
                    } else { switch inspection.zoneState {
                    case .present:
                        Button("Sync and Restore") { runRecovery(inspection) }.disabled(busy)
                        Toggle("Sync Automatically", isOn: Binding(
                            get: { automaticRecovery && automaticRecoveryAccount == inspection.scope.cloudAccountKey },
                            set: { model.configureAutomaticRecovery(enabled: $0, scope: inspection.scope) }
                        )).disabled(busy)
                        Text("LibraVia retries while the app is open and no book is being read.")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .missing:
                        Text("No recovery area was found for this account.").foregroundStyle(.secondary)
                        Button("Set Up Recovery…") { confirmingCreate = true }.disabled(busy)
                    case .deletedByUser:
                        Text("This recovery area was removed or reset. Your device copies are unchanged; review your iCloud account before continuing.").foregroundStyle(.secondary)
                    } }
                }
            }
            if !reviews.isEmpty {
                Section("Reading changes to review") {
                    ForEach(reviews) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.book.title).font(.headline)
                            reviewDetails(item.payload, kind: item.key.kind, format: item.book.format)
                            if item.hasConflict {
                                Text("A different cloud version also exists and will be kept for separate review.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button(item.payload == nil ? "Review Deletion…" : "Confirm This Edition…") { reviewing = item }.disabled(busy)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !incoming.isEmpty {
                Section("Incoming reading changes") {
                    ForEach(incoming) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.book.title).font(.headline)
                            reviewDetails(item.payload, kind: item.key.kind, format: item.book.format)
                            if item.editionFingerprint == nil {
                                Text("This older change has no edition information.").font(.footnote).foregroundStyle(.secondary)
                                Button("Review This Change…") { reviewingIncoming = item }.disabled(busy)
                            } else {
                                Text("This change could not be restored automatically. Check the book edition and try recovery again.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !conflicts.isEmpty {
                Section("Conflicting reading changes") {
                    ForEach(conflicts) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.book.title).font(.headline)
                            Text(item.currentIsStaged ? "Earlier iCloud version" : "On this device").font(.subheadline.bold())
                            reviewDetails(item.local.payload, kind: item.key.kind, format: item.book.format)
                            Text("Other iCloud version").font(.subheadline.bold())
                            reviewDetails(item.remote.payload, kind: item.key.kind, format: item.book.format)
                            if item.local.editionFingerprint == nil || item.remote.editionFingerprint == nil {
                                Text("An older version has no edition information. Choose it only if you recognize it as belonging to this book.").font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("Choose a Version…") { resolving = item }.disabled(busy)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !deletedBackups.isEmpty {
                Section("Removed iCloud backups") {
                    ForEach(deletedBackups) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.book.title).font(.headline)
                            Text("The iCloud backup was removed. Your device copy is still available and is not backed up.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(item.needsReview ? "Review Backup…" : "Restore Backup…") { reviewingDeletion = item }.disabled(busy)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !bookConflicts.isEmpty {
                Section("Conflicting book copies") {
                    ForEach(bookConflicts) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            Text(item.currentIsStaged ? "Earlier iCloud version" : "Device recovery change").font(.subheadline.bold())
                            bookVersionDetails(item.current)
                            Text("Other iCloud version").font(.subheadline.bold())
                            bookVersionDetails(item.remote)
                            if case .book(let current) = item.current, case .book(let remote) = item.remote,
                               current.sha256 != remote.sha256 || current.format != remote.format {
                                Text("These are different editions. A device copy will not be replaced by a different edition.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("Choose a Book Version…") { resolvingBook = item }.disabled(busy)
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section("Other libraries") {
                Text("For Jellyfin reading data, open a Jellyfin book and choose Private Reading Recovery in the reader. This recovery pass does not change Jellyfin files.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).appSurface().navigationTitle("Private Recovery")
        .confirmationDialog("Set up a new recovery area?", isPresented: $confirmingCreate, titleVisibility: .visible) {
            Button("Set Up Recovery") { createZone() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("If you previously used recovery, check that you are signed into the same iCloud account. A new recovery area cannot restore data that is missing from iCloud.")
        }
        .confirmationDialog("Use the current iCloud account?", isPresented: $confirmingAccountSwitch, titleVisibility: .visible) {
            Button("Use Current iCloud Account") { switchRecoveryAccount() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("LibraVia will prepare this device’s books and reading changes for the current account and check its existing recovery data. Books only in the earlier account are not transferred. Reading changes not linked to a book on this device remain in the earlier recovery journal. Separate books remain separate even when their files match. Review differences before syncing.")
        }
        .confirmationDialog("Is this change from this book?", item: $reviewing, titleVisibility: .visible) { item in
            Button(item.payload == nil ? "Confirm Deletion" : "Confirm This Edition") { confirmReview(item) }
        } message: { item in
            Text(item.payload == nil
                 ? "This \(item.key.kind.rawValue) deletion has no saved content to display. Confirm only if it belongs to the current copy of \(item.book.title). A different cloud version will remain for review."
                 : "Confirm that this change belongs to the current copy of \(item.book.title). A different cloud version, if present, will be kept for separate review.")
        }
        .confirmationDialog("Restore this older change?", item: $reviewingIncoming, titleVisibility: .visible) { item in
            Button(item.payload == nil ? "Confirm and Apply Deletion" : "Confirm and Restore") { confirmIncoming(item) }
            Button("Cancel", role: .cancel) { }
        } message: { item in
            Text(item.payload == nil
                 ? "This deletion has no saved content to display. Confirm only if it belongs to the current copy of \(item.book.title). It will remove this reading item on this device."
                 : "Confirm that this change belongs to the current copy of \(item.book.title). It will be restored here and queued for the next sync.")
        }
        .confirmationDialog("Choose which version to keep", item: $resolving, titleVisibility: .visible) { item in
            Button(item.local.editionFingerprint == nil ? (item.currentIsStaged ? "Keep Earlier iCloud Version and Confirm Edition" : "Keep Device Version and Confirm Edition") : (item.currentIsStaged ? "Keep Earlier iCloud Version" : "Keep Device Version")) { resolveConflict(item, choice: .local) }
            Button(item.remote.editionFingerprint == nil ? "Keep Other iCloud Version and Confirm Edition" : "Keep Other iCloud Version") { resolveConflict(item, choice: .remote) }
        } message: { item in
            Text("This choice applies to one change in \(item.book.title). For a version without edition information, confirm it belongs to this copy. Any other conflicting versions remain for review.")
        }
        .confirmationDialog("Choose a book version", item: $resolvingBook, titleVisibility: .visible) { item in
            Button(bookChoiceLabel(item.current, source: item.currentIsStaged ? "earlier iCloud" : "device")) { resolveBookConflict(item, choice: .local) }
            Button(bookChoiceLabel(item.remote, source: "other iCloud")) { resolveBookConflict(item, choice: .remote) }
        } message: { item in
            Text("This choice applies to \(item.title). Removing its iCloud backup keeps the copy on this device and your original source file. Other conflicts remain for review.")
        }
        .confirmationDialog("Review removed backup", item: $reviewingDeletion, titleVisibility: .visible) { item in
            Button("Restore iCloud Backup") { reviewDeletion(item, restoreBackup: true) }
            if item.needsReview { Button("Keep Device Copy Without Backup") { reviewDeletion(item, restoreBackup: false) } }
            Button("Cancel", role: .cancel) { }
        } message: { item in
            Text("Your copy of \(item.book.title) and its original source file will be kept. Restoring the backup queues this device copy for the next recovery pass.")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, service != nil || task != nil else { return }
            task?.cancel(); service = nil; inspection = nil
            reviews = []; incoming = []; conflicts = []; bookConflicts = []; deletedBackups = []
            message = "Recovery paused. Check iCloud again to continue."
        }
        .onDisappear { task?.cancel(); task = nil }
    }

    @ViewBuilder private func bookVersionDetails(_ version: CloudBookJournalVersion) -> some View {
        switch version {
        case .book(let metadata):
            Text(metadata.title)
            Text("\(metadata.format.rawValue.uppercased()) · \(ByteCountFormatter.string(fromByteCount: metadata.byteCount, countStyle: .file))")
                .font(.footnote).foregroundStyle(.secondary)
        case .tombstone:
            Text("Remove iCloud backup; keep this device copy and the original file.")
        }
    }
    private func bookChoiceLabel(_ version: CloudBookJournalVersion, source: String) -> String {
        switch version {
        case .book: return "Keep \(source) book"
        case .tombstone: return "Remove iCloud backup (\(source))"
        }
    }

    @ViewBuilder private func reviewDetails(_ payload: CloudReadingPayload?, kind: CloudReadingKind, format: BookFormat) -> some View {
        switch payload {
        case .position(let value):
            Text("Reading position · \(positionDescription(value.position, format: format))")
            if let cfi = value.position.cfi { Text(cfi).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        case .bookmark(let bookmark):
            Text("Bookmark: \(bookmark.name)")
            Text(positionDescription(bookmark.position, format: format)).font(.footnote).foregroundStyle(.secondary)
            if let cfi = bookmark.position.cfi { Text(cfi).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        case .annotation(let annotation):
            Text("Highlight or note")
            if let selected = annotation.selectedText, !selected.isEmpty { Text(selected) }
            if !annotation.note.isEmpty { Text(annotation.note) }
            switch annotation.anchor {
            case .epub(let cfi): Text(cfi).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            case .pdf(let page, _), .page(let page): Text("Page \(page < Int.max ? page + 1 : page)").font(.footnote).foregroundStyle(.secondary)
            }
        case nil:
            Text("Deleted \(kind.rawValue)")
        }
    }
    private func positionDescription(_ position: ReadingPosition, format: BookFormat) -> String {
        if format == .epub {
            let fraction = position.fraction.isFinite ? min(1, max(0, position.fraction)) : 0
            return fraction.formatted(.percent.precision(.fractionLength(1)))
        }
        return "Page \(position.page < Int.max ? position.page + 1 : position.page)"
    }
    private func refreshReviews(service: StandaloneCloudRecoveryService, inspection: StandaloneCloudRecoveryService.Inspection) async throws {
        guard try await service.validate(inspection) else { throw CancellationError() }
        let pending = try await model.pendingStandaloneReadingReviews(scope: inspection.scope)
        let received = try await model.pendingStandaloneIncomingReading(scope: inspection.scope)
        let alternatives = try await model.pendingStandaloneReadingConflicts(scope: inspection.scope)
        let books = try await model.pendingStandaloneBookConflicts(scope: inspection.scope)
        let deleted = try await model.standaloneDeletedBackups(scope: inspection.scope)
        guard try await service.validate(inspection), !Task.isCancelled else { throw CancellationError() }
        reviews = pending; incoming = received; conflicts = alternatives; bookConflicts = books; deletedBackups = deleted
    }
    private func confirmIncoming(_ item: StandaloneIncomingReadingItem) {
        guard let service, let inspection else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await model.confirmStandaloneIncomingReading(item, scope: inspection.scope,
                                                                   accountIsCurrent: { try await service.validate(inspection) })
                try await refreshReviews(service: service, inspection: inspection)
                message = "The change was restored and is ready for the next recovery pass."
            } catch { if !Task.isCancelled { message = UserFacingError.message(error) } }
        }
    }
    private func confirmReview(_ item: StandaloneReadingReviewItem) {
        guard let service, let inspection else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await model.confirmStandaloneReadingReview(item, scope: inspection.scope,
                                                               accountIsCurrent: { try await service.validate(inspection) })
                try await refreshReviews(service: service, inspection: inspection)
                message = "The change is ready for the next recovery pass. Any cloud conflict still needs review."
            } catch { if !Task.isCancelled { message = UserFacingError.message(error) } }
        }
    }

    private func resolveConflict(_ item: StandaloneReadingConflictItem, choice: CloudAtomicReadingStore.ConflictChoice) {
        guard let service, let inspection else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await model.resolveStandaloneReadingConflict(item, scope: inspection.scope, choice: choice,
                                                                 accountIsCurrent: { try await service.validate(inspection) },
                                                                 confirmUnverifiedEdition: (choice == .local ? item.local : item.remote).editionFingerprint == nil)
                try await refreshReviews(service: service, inspection: inspection)
                message = "The selected change is ready for the next recovery pass."
            } catch { if !Task.isCancelled { message = UserFacingError.message(error) } }
        }
    }

    private func resolveBookConflict(_ item: StandaloneBookConflictItem, choice: CloudBookJournal.ConflictChoice) {
        guard let service, let inspection else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await model.resolveStandaloneBookConflict(item, scope: inspection.scope, choice: choice,
                                                              accountIsCurrent: { try await service.validate(inspection) })
                try await refreshReviews(service: service, inspection: inspection)
                message = "The book choice is ready for the next recovery pass."
            } catch { if !Task.isCancelled { message = UserFacingError.message(error) } }
        }
    }

    private func reviewDeletion(_ item: StandaloneDeletedBackupItem, restoreBackup: Bool) {
        guard let service, let inspection else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await model.reviewStandaloneDeletedBackup(item, scope: inspection.scope, restoreBackup: restoreBackup,
                                                               accountIsCurrent: { try await service.validate(inspection) })
                try await refreshReviews(service: service, inspection: inspection)
                message = restoreBackup ? "The device copy is queued for the next recovery pass." : "The device copy is kept without an iCloud backup."
            } catch { if !Task.isCancelled { message = UserFacingError.message(error) } }
        }
    }

    private func checkAccount() {
        busy = true; message = nil; inspection = nil; reviews = []; incoming = []; conflicts = []; bookConflicts = []; deletedBackups = []
        task = Task {
            defer { busy = false; task = nil }
            do {
                let service = try model.makeStandaloneCloudRecoveryService()
                let value = try await service.inspect()
                await model.loadOnDeviceLibrary()
                if !model.canSwitchStandaloneRecoveryAccount(scope: value.scope) {
                    try await model.checkStandaloneRecoveryScope(value.scope)
                }
                try Task.checkCancellation()
                self.service = service; inspection = value
            } catch { if !Task.isCancelled { message = UserFacingError.message(error) } }
        }
    }
    private func createZone() {
        guard let service, let inspection else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let ready = try await service.createAfterReviewedDecision(inspection)
                try Task.checkCancellation()
                self.inspection = ready
                message = model.canSwitchStandaloneRecoveryAccount(scope: ready.scope)
                    ? "Recovery is ready. Review the account switch to continue."
                    : "Recovery is ready. Choose Sync and Restore to begin."
            } catch { if !Task.isCancelled { self.inspection = nil; message = UserFacingError.message(error) } }
        }
    }
    private func switchRecoveryAccount() {
        guard let service, let inspection else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await service.switchRecoveryAccount(inspection)
                try Task.checkCancellation()
                try await model.checkStandaloneRecoveryScope(inspection.scope)
                try await refreshReviews(service: service, inspection: inspection)
                message = "Account changed. Review any differences, then choose Sync and Restore."
            } catch { if !Task.isCancelled { message = UserFacingError.message(error) } }
        }
    }
    private func runRecovery(_ inspection: StandaloneCloudRecoveryService.Inspection) {
        guard let service else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let result = try await service.run(inspection)
                try Task.checkCancellation()
                try await refreshReviews(service: service, inspection: inspection)
                if !result.failures.isEmpty || result.needsReview > 0 || result.pendingItems > 0 {
                    message = "Some items could not be synchronized or need review. Your local data is kept. Some deletions or different editions may need further review. Your changes may not yet be backed up."
                } else {
                    message = "Recovery pass finished. Check your books on each device before relying on recovery."
                }
            } catch { if !Task.isCancelled { self.inspection = nil; message = UserFacingError.message(error) } }
        }
    }
}
