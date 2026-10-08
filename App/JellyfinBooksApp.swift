import SwiftUI

@main struct JellyfinBooksApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView().environment(model)
                .frame(minWidth: 320, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 780)

        Window("Reader", id: MacReaderWindow.sceneID) {
            MacReaderWindow().environment(model)
        }
        .defaultSize(width: 1000, height: 800)
        .windowResizability(.automatic)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { ReaderCommands() }
        #else
        WindowGroup {
            RootView().environment(model)
                .frame(minWidth: 320, minHeight: 480)
        }
        .commands { ReaderCommands() }
        #endif
    }
}
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Namespace private var readerNamespace
    @State private var showingSyncReview = false
    @State private var checkedUnavailableID: String?
    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil { LoginView() }
            else {
                TabView {
                    Tab("Home", systemImage: "house") { NavigationStack { CatalogView(resume: true) } }
                    Tab("Library", systemImage: "books.vertical") { NavigationStack { LibraryLandingView() } }
                    Tab("Search", systemImage: "magnifyingglass", role: .search) { NavigationStack { SearchView() } }
                }
                .tabViewStyle(.sidebarAdaptable)
                .id(model.sessionID)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                      if let issue = model.syncIssue {
                        HStack(spacing: 12) {
                            Label(issue.message, systemImage: "arrow.triangle.2.circlepath").font(.callout)
                            Spacer(minLength: 0)
                            if model.canRetryProgress {
                                Button(model.syncRunning ? "Syncing…" : "Retry Sync") { Task { await model.flushProgress() } }
                                    .disabled(model.syncRunning)
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.regularMaterial)
                        .accessibilityElement(children: .contain)
                      }
                      if !model.blockedProgress.isEmpty {
                        HStack(spacing: 12) {
                            Label("\(model.blockedProgress.count) saved book position\(model.blockedProgress.count == 1 ? "" : "s") need attention", systemImage: "books.vertical")
                                .font(.callout)
                            Spacer(minLength: 0)
                            Button("Review") { showingSyncReview = true }.buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.regularMaterial)
                        .accessibilityElement(children: .contain)
                      }
                    }
                }
            }
        }
        .task(id: "\(model.sessionID)|\(model.account != nil)") {
            if model.account != nil {
                await model.loadLibrariesIfNeeded()
                await model.flushProgress()
            }
        }
        .alert("LibraVia", isPresented: Binding(get: { model.readerLaunchBook == nil && model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showingSyncReview) {
            NavigationStack {
                List(model.blockedProgress) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.title).font(.headline)
                        Text(entry.reason == .conflict
                             ? "The server has a different reading position. Choose which one to keep."
                             : "This book is not available on Jellyfin. Its local reading position is retained.")
                            .font(.callout).foregroundStyle(.secondary)
                        if entry.reason == .conflict {
                            Button("Choose Position") { showingSyncReview = false; model.openBlockedProgress(entry) }
                        } else {
                            HStack {
                                NavigationLink("Find Matching Book") { ProgressRematchView(entry: entry) }
                                Button("Check Again") {
                                    Task {
                                        checkedUnavailableID = nil
                                        await model.retryBlockedProgress(entry.id)
                                        if model.blockedProgress.contains(where: { $0.id == entry.id && $0.reason == .unavailable }) {
                                            checkedUnavailableID = entry.id
                                        }
                                    }
                                }
                                .disabled(model.syncRunning)
                            }
                            if checkedUnavailableID == entry.id {
                                Text("Still unavailable on Jellyfin. Your local position is safe.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 4)
                }
                .navigationTitle("Saved Positions")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSyncReview = false } } }
            }
            .frame(minWidth: 320, idealWidth: 440, minHeight: 300)
        }
        .sheet(item: Binding(get: { model.readerLaunchBook == nil ? model.conflict : nil }, set: { model.conflict = $0 })) { conflict in
            ReadingConflictChoice(conflict: conflict) { model.conflict = nil }
        }
        #if os(macOS)
        .onChange(of: model.readerLaunchBook?.id, initial: true) { _, bookID in
            if bookID != nil { openWindow(id: MacReaderWindow.sceneID) }
        }
        #else
        .fullScreenCover(item: $model.readerLaunchBook, onDismiss: { model.closeReader() }) { book in
            BookOpeningView(book: book).environment(model)
                .navigationTransition(.zoom(sourceID: book.id, in: readerNamespace))
        }
        #endif
        .environment(\.readerTransitionNamespace, readerNamespace)
        .onChange(of: scenePhase) { _, value in if value != .active { Task { await model.flushProgress() } } else { Task { await model.refreshCache() } } }
    }
}
