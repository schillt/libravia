import SwiftUI
#if os(macOS)
import AppKit
#endif

@main struct JellyfinBooksApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView().environment(model)
                .frame(minWidth: 320, minHeight: 480)
                .background(MacWindowPaper(theme: model.preferences.theme))
                .preferredColorScheme(AppAppearance.scheme(model.preferences.theme))
        }
        .defaultSize(width: 1100, height: 780)

        Window("Reader", id: MacReaderWindow.sceneID) {
            MacReaderWindow().environment(model)
                .background(MacWindowPaper(theme: model.preferences.theme))
                .preferredColorScheme(AppAppearance.scheme(model.preferences.theme))
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
                .preferredColorScheme(AppAppearance.scheme(model.preferences.theme))
        }
        .commands { ReaderCommands() }
        #endif
    }
}
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("automaticStandaloneRecovery") private var automaticRecovery = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @AppStorage("librarySidebarWidth") private var sidebarWidth = 0.0
    #endif
    @Namespace private var readerNamespace
    @State private var showingSyncReview = false
    @State private var checkedUnavailableID: String?
    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil { NavigationStack { LoginView() } }
            else {
                TabView {
                    Tab("Home", systemImage: "house") { NavigationStack { CatalogView(resume: true) } }
                    Tab("Library", systemImage: "books.vertical") { NavigationStack { LibraryLandingView() } }
                    Tab("Search", systemImage: "magnifyingglass", role: .search) { NavigationStack { SearchView() } }
                }
                .tabViewStyle(.sidebarAdaptable)
                #if os(macOS)
                .tabViewSidebarBottomBar {
                    ProfileButton(inSidebar: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(MacSidebarWidthFallback(savedWidth: $sidebarWidth))
                }
                #endif
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
                             : entry.reason == .edition ? "This book's edition needs review. Its earlier saved place has been kept."
                             : "This book is not available on Jellyfin. Its local reading position is retained.")
                            .font(.callout).foregroundStyle(.secondary)
                        if entry.reason != .unavailable {
                            Button(entry.reason == .edition ? "Review Saved Place" : "Choose Position") { showingSyncReview = false; model.openBlockedProgress(entry) }
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
        .appSurface()
        .task(id: "\(scenePhase)|\(automaticRecovery)") {
            guard scenePhase == .active, automaticRecovery else { return }
            while !Task.isCancelled {
                await model.retryAutomaticStandaloneRecovery()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .environment(\.readerTransitionNamespace, readerNamespace)
        .onChange(of: scenePhase) { _, value in if value != .active { Task { await model.flushProgress() } } else { Task { await model.refreshCache() } } }
    }
}

/// One persisted appearance choice colors both browsing and reading surfaces.
/// Keep these values in step with the trusted EPUB shell's paper palette.
enum AppAppearance {
    static func background(_ theme: String) -> Color {
        switch theme {
        case "sepia": Color(red: 244.0 / 255, green: 236.0 / 255, blue: 216.0 / 255)
        case "dark": Color(red: 23.0 / 255, green: 23.0 / 255, blue: 23.0 / 255)
        default: .white
        }
    }
    static func scheme(_ theme: String) -> ColorScheme { theme == "dark" ? .dark : .light }
}
/// Keep the native window's backing paper in sync with SwiftUI and WebKit.
/// AppKit may expose it while resizing, before hosted content fills new space.
#if os(macOS)
private struct MacWindowPaper: NSViewRepresentable {
    let theme: String
    func makeNSView(context: Context) -> PaperView { PaperView() }
    func updateNSView(_ view: PaperView, context: Context) { view.setPaper(NSColor(AppAppearance.background(theme))) }
    static func dismantleNSView(_ view: PaperView, coordinator: ()) { view.detach() }

    final class PaperView: NSView {
        private weak var configuredWindow: NSWindow?
        private var original: NSColor?
        private var applied: NSColor?
        private var paper: NSColor = .white
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if configuredWindow !== window { detach() }
            guard let window else { return }
            if configuredWindow == nil { configuredWindow = window; original = window.backgroundColor }
            apply()
        }
        func setPaper(_ value: NSColor) { paper = value; apply() }
        private func apply() {
            guard let window = configuredWindow else { return }
            window.backgroundColor = paper; applied = paper
        }
        func detach() {
            if let window = configuredWindow, let original, window.backgroundColor == applied { window.backgroundColor = original }
            configuredWindow = nil; original = nil; applied = nil
        }
    }
}
#endif

private struct ProfileToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content.toolbar {
            #if os(macOS)
            // Standalone reading can be reached from Login without a sidebar.
            if model.account == nil {
                ToolbarItem(placement: .primaryAction) { ProfileButton() }
            }
            #else
            ToolbarItem(placement: .topBarPinnedTrailing) { ProfileButton() }
                .sharedBackgroundVisibility(.hidden)
            #endif
        }
    }
}
extension View {
    func profileToolbar() -> some View { modifier(ProfileToolbar()) }
    func appSheetSurface() -> some View { modifier(AppSheetSurface()) }
}

private struct AppSheetSurface: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(AppAppearance.scheme(model.preferences.theme))
            .presentationBackground(AppAppearance.background(model.preferences.theme))
            #if os(macOS)
            .background(MacWindowPaper(theme: model.preferences.theme))
            .toolbarBackground(AppAppearance.background(model.preferences.theme), for: .automatic)
            .toolbarBackgroundVisibility(.visible, for: .automatic)
            #else
            .toolbarBackground(AppAppearance.background(model.preferences.theme), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            #endif
    }
}

private struct AppSurfaceBackground: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AppAppearance.background(model.preferences.theme).ignoresSafeArea())
            #if os(iOS)
            .containerBackground(AppAppearance.background(model.preferences.theme), for: .navigation)
            #else
            .containerBackground(AppAppearance.background(model.preferences.theme), for: .window)
            #endif
    }
}
extension View {
    func appSurface() -> some View { modifier(AppSurfaceBackground()) }
}

#if os(macOS)

/// TabView has no public sidebar-width preference. This passive anchor uses
/// only public AppKit split-view APIs, scoped to its own sidebar, to apply the
/// initial width once per window and remember subsequent divider adjustments.
private struct MacSidebarWidthFallback: NSViewRepresentable {
    @Binding var savedWidth: Double
    var defaultWidth: CGFloat = 280
    var minimumWidth: CGFloat = 256

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        configure(view)
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) { configure(view) }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

    private func configure(_ view: Anchor) {
        let value = savedWidth
        let binding = _savedWidth
        view.minimum = minimumWidth
        view.preferred = value.isFinite && value > 0 ? max(minimumWidth, CGFloat(value)) : max(minimumWidth, defaultWidth)
        view.persist = { binding.wrappedValue = Double($0) }
        view.scheduleDiscovery()
    }

    final class Anchor: NSView {
        var preferred: CGFloat = 280
        var minimum: CGFloat = 256
        private var minimumConstraint: NSLayoutConstraint?
        var persist: ((CGFloat) -> Void)?
        private weak var observedSplit: NSSplitView?
        private weak var appliedWindow: NSWindow?
        private var observer: NSObjectProtocol?
        private var scheduledGeneration: Int?
        private var generation = 0
        private var pendingWidth: CGFloat?
        private var widthDeliveryScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            generation += 1; scheduledGeneration = nil; widthDeliveryScheduled = false; pendingWidth = nil
            if let window, window !== appliedWindow { appliedWindow = nil }
            scheduleDiscovery()
        }
        override func layout() {
            super.layout()
            scheduleDiscovery()
        }
        func scheduleDiscovery() {
            guard window != nil, scheduledGeneration == nil, observedSplit == nil else { return }
            let epoch = generation
            scheduledGeneration = epoch
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.scheduledGeneration == epoch else { return }
                self.scheduledGeneration = nil
                guard epoch == self.generation, self.window != nil else { return }
                self.attachIfReady()
            }
        }
        private func attachIfReady() {
            guard let window else { return }
            var child: NSView = self
            var parent = child.superview
            while let view = parent {
                if let split = view as? NSSplitView, split.isVertical,
                   split.arrangedSubviews.count >= 2, split.arrangedSubviews.first === child {
                    guard split.bounds.width > 0, child.frame.width > 1,
                          !split.isSubviewCollapsed(child) else { return }
                    // Never install while a user is actively resizing a window.
                    guard !window.inLiveResize else { return }
                    // Don't impose an initial width while a mouse gesture is in
                    // progress; defer until the next layout/update instead.
                    if let event = NSApp.currentEvent, event.window === window,
                       [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) { return }
                    // SwiftUI may reset NSSplitViewItem.minimumThickness during
                    // layout. Constrain the actual sidebar pane instead, while
                    // retaining the native sidebar's normal collapse behavior.
                    if minimumConstraint == nil {
                        let constraint = child.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum)
                        constraint.isActive = true
                        minimumConstraint = constraint
                    }
                    if appliedWindow !== window {
                        let lower = split.minPossiblePositionOfDivider(at: 0)
                        let upper = split.maxPossiblePositionOfDivider(at: 0)
                        guard lower.isFinite, upper.isFinite, upper > lower,
                              preferred.isFinite, preferred > 0 else { return }
                        split.setPosition(min(upper, max(lower, preferred)), ofDividerAt: 0)
                        appliedWindow = window
                    }
                    observedSplit = split
                    observer = NotificationCenter.default.addObserver(
                        forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
                    ) { [weak self] note in
                        MainActor.assumeIsolated { self?.captureResize(note) }
                    }
                    return
                }
                child = view; parent = view.superview
            }
        }
        private func captureResize(_ note: Notification) {
            guard let split = observedSplit, !split.arrangedSubviews.isEmpty,
                  !split.isSubviewCollapsed(split.arrangedSubviews[0]) else { return }
            let width = split.arrangedSubviews[0].frame.width
            guard width.isFinite, width >= minimum - 0.5, abs(width - preferred) >= 0.5 else { return }
            preferred = width
            pendingWidth = width
            // Do not mutate SwiftUI state in the middle of AppKit layout.
            guard !widthDeliveryScheduled else { return }
            widthDeliveryScheduled = true
            let epoch = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, epoch == self.generation else { return }
                self.widthDeliveryScheduled = false
                if let width = self.pendingWidth { self.pendingWidth = nil; self.persist?(width) }
            }
        }
        private func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil; observedSplit = nil
            minimumConstraint?.isActive = false; minimumConstraint = nil
        }
        func stop() {
            generation += 1; scheduledGeneration = nil; widthDeliveryScheduled = false; pendingWidth = nil; stopObserving(); persist = nil; appliedWindow = nil
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
#endif
