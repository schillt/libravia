import SwiftUI
import Observation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct ReaderCapabilities { let textSearch: Bool; let reflow: Bool; init(format: BookFormat) { textSearch = format == .epub || format == .pdf; reflow = format == .epub } }
enum ReaderAdjustment: String, CaseIterable, Identifiable {
    case textSize = "Text size", lineSpacing = "Line spacing", margins = "Margins", edgeWidth = "Edge width"
    var id: String { rawValue }
}
enum ReaderSearchState { case idle, searching, results, empty, failed }
struct EPUBSelection: Equatable, Sendable { var cfi: String; var text: String; var context: String? = nil }
struct ReaderLink: Identifiable { var id: String; var title: String; var context: String? = nil }
struct ReaderChapter: Identifiable {
    var id: Int { number }
    let number: Int
    let title: String
    var href: String? = nil
    let start: Double
    let end: Double
    func contains(_ fraction: Double) -> Bool { fraction >= start && (fraction < end || end >= 1 && fraction >= start) }
    func progress(at fraction: Double) -> Double { min(1, max(0, (fraction - start) / max(0.000_001, end - start))) }
}
@MainActor @Observable final class ReaderController {
    var position: ReadingPosition
    var viewportInsets = EdgeInsets()
    var pageCount = 0
    var currentChapter: String?
    var chapterTitle = ""
    var chapterPage = 0
    var chapterPageCount = 0
    var bookPage = 0
    var bookPageCount = 0
    var paginationFailed = false
    var pageChapters: [ReaderChapter] = []
    var chapters: [ReaderChapter] = []
    var chapterSnippets: [Int: String] = [:]
    var toc: [ReaderLink] = []
    var results: [ReaderLink] = []
    var searching = false
    var searchState: ReaderSearchState = .idle
    var searchID = UUID().uuidString
    var controlsVisible = false
    var returnPosition: ReadingPosition?
    var navigationError = false
    var epubSelection: EPUBSelection?
    var epubSelectionActive = false
    var highlighterColor: String? = nil
    #if os(macOS)
    var sidebarPaperWidth: Double?
    var reflowSoftening = false
    var reflowCovering = false
    #endif
    var selectionMenuAction: ((Bool, EPUBSelection) -> Void)?
    var annotationAction: ((UUID) -> Void)?
    var highlighterAction: ((EPUBSelection) -> Void)?
    var pdfSelection: PDFTextSelection?
    func cancelSearch() { searchID = UUID().uuidString; command?("cancelSearch", nil); searching = false; if searchState == .searching { searchState = .idle } }
    func completeSearch(_ links: [ReaderLink], id: String) { guard id == searchID else { return }; results = links; searching = false; searchState = links.isEmpty ? .empty : .results }
    var pageTapZoneFraction = 0.2
    func tapped(at fraction: Double, canTurn: Bool = true) {
        switch ReaderTapAction.action(at: fraction, edge: pageTapZoneFraction, canTurn: canTurn && ready) {
        case .previous: command?("previous", nil)
        case .next: command?("next", nil)
        case .controls: controlsVisible.toggle()
        }
    }
    var fixedLayout = false
    var ready = false
    var loadingStatus = "Opening book…"
    var error: String?
    var command: ((String, Any?) -> Void)?
    var changed: ((ReadingPosition) -> Void)?
    init(position: ReadingPosition) { self.position = position }
    func update(_ position: ReadingPosition) { self.position = position; changed?(position) }
}
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.closeReaderWindow) private var closeReaderWindow
    #endif
    let prepared: PreparedBook
    private let onContentReady: (Bool) -> Void
    @State private var controller: ReaderController
    @State private var originalFormatting = false
    @State private var panel: ReaderPanel?
    @State private var adjustment: ReaderAdjustment?
    @State private var appearanceDetent: PresentationDetent = .medium
    @State private var expandedAppearanceDetent: PresentationDetent = .medium
    @Namespace private var appearanceNamespace
    @ScaledMetric(relativeTo: .body) private var compactPanelHeight = 150.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchVisible = false
    @State private var searchKeyboardVisible = false
    @State private var searchRevealTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    #if os(macOS)
    @FocusState private var highlighterToolbarFocused: Bool
    // Preserve the outgoing pane while the native inspector animates closed.
    @State private var macSidebarDestination: ReaderPanel = .contents
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @Namespace private var glassNamespace
    @State private var navigationTab = 0
    @State private var bookmarkFeedback = ""
    @State private var editingBookmark: Bookmark?
    @State private var bookmarkName = ""
    @State private var editingNote: ReadingAnnotation?
    @State private var newHighlightNote: ReadingAnnotation?
    @State private var noteToDelete: ReadingAnnotation?
    @State private var annotationSearch = ""
    #if os(macOS)
    @State private var lastHighlighterColor = "yellow"
    @State private var showingHighlighterPalette = false
    #endif
    // WebKit can clear selection as a native toolbar receives the tap. Keep
    // the captured passage briefly so that same tap can complete its action.
    @State private var recentEPUBSelection = false
    @State private var selectionExpiryTask: Task<Void, Never>?
    @State private var bookFingerprint: String?
    @State private var fingerprintSourceKey: String?
    @State private var fingerprintAttempt = 0
    @State private var fingerprintFailed = false
    @State private var exportDocument: ReadingDataDocument?
    @State private var exportType: UTType = .json
    @State private var showingExport = false
    private var currentFingerprintSourceKey: String { prepared.id + "\u{0}" + prepared.directory.path }
    private var verifiedFingerprint: String? { fingerprintSourceKey == currentFingerprintSourceKey ? bookFingerprint : nil }
    private var canHighlightEPUBSelection: Bool {
        controller.epubSelection != nil && (controller.epubSelectionActive || recentEPUBSelection)
    }
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var search = ""
    @State private var pageNumber = 1
    @State private var scrubFraction = 0.0
    @State private var controlsActivity = UUID()
    @State private var scrubbing = false
    @AppStorage("readerKeepTitleVisible") private var keepTitleVisible = true
    @AppStorage("readerKeepProgressVisible") private var keepProgressVisible = true
    @AppStorage("readerKeepScreenAwake") private var keepScreenAwake = true
    @ScaledMetric(relativeTo: .caption) private var headerLineHeight = 18.0
    @ScaledMetric(relativeTo: .caption2) private var progressLineHeight = 16.0
    private var headerGutter: Double { isDesktop ? max(44, headerLineHeight * 2 + 8) : max(76, headerLineHeight * 3 + 20) }
    private var footerGutter: Double { 64 + progressLineHeight }
    private var isDesktop: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    private var readerChromeVisible: Bool { controller.controlsVisible || voiceOver }
    private var macSidebarVisible: Bool { isDesktop && (searchVisible || panel != nil) }
    private var pageContainsInfo: Bool { prepared.book.format == .epub && !model.preferences.scrolling }
    private func pageChrome(safeInsets: EdgeInsets) -> ReaderPageChrome {
        ReaderPageChrome(enabled: pageContainsInfo, showChapter: keepTitleVisible, showProgress: keepProgressVisible,
                         top: headerGutter + safeInsets.top, bottom: isDesktop ? 32 : max(68, progressLineHeight + 44) + safeInsets.bottom,
                         safeTop: safeInsets.top, safeBottom: safeInsets.bottom,
                         textSize: max(12, progressLineHeight - 4),
                         softEdges: !isDesktop && model.preferences.pageTransition == "curl" && !reduceTransparency && contrast != .increased)
    }
    private var readerControlHeight: Double { isDesktop ? 44 : 56 }
    private func closeReader() {
        #if os(macOS)
        if let closeReaderWindow { closeReaderWindow(); return }
        #endif
        dismiss()
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var wideContents = false
    @State private var requestedChapterSnippets: Set<Int> = []
    @State private var lastScrubChapter: Int?
    @State private var scrubChapterHaptic = 0
    init(prepared: PreparedBook, onContentReady: @escaping (Bool) -> Void = { _ in }) { self.prepared = prepared; self.onContentReady = onContentReady; _controller = State(initialValue: ReaderController(position: prepared.position)) }
    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
          let pageInsets = !isDesktop && pageContainsInfo ? controller.viewportInsets : EdgeInsets()
          let usesSidebar = (isDesktop || geometry.size.width >= 900) && !dynamicTypeSize.isAccessibilitySize
          HStack(spacing: 0) {
          readerContainer {
            readerSurface(chrome: pageChrome(safeInsets: pageInsets))
                #if os(macOS)
                .background(MacReaderInput(chromeVisible: readerChromeVisible, paper: readerBackground, inspectorVisible: macSidebarVisible, canTurn: { controller.ready && showsPageTurnButtons },
                                           turn: { controller.command?($0, nil) },
                                           trackpad: prepared.book.format == .epub ? { controller.command?("trackpad", $0) } : nil))
                .overlay {
                    GeometryReader { viewport in
                        if !controller.reflowCovering, let heldWidth = controller.sidebarPaperWidth, viewport.size.width > heldWidth {
                            // The native viewport can expand before WebKit's
                            // composited page does. Cover only that new strip.
                            readerBackground
                                .frame(width: viewport.size.width - heldWidth, height: viewport.size.height)
                                .offset(x: heldWidth)
                        }
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .transaction { $0.animation = nil }
                }
                #endif
                #if os(iOS)
                .mask {
                    if prepared.book.format == .epub && model.preferences.scrolling && !reduceTransparency && contrast != .increased {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 12)
                            Rectangle().fill(.white)
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                        }
                    } else { Rectangle().fill(.white) }
                }
                #endif
                // Keep the document viewport identical when chrome appears or hides.
                // Side panels and text-size changes deliberately reflow; visibility does not.
                .padding(.top, pageContainsInfo ? 0 : headerGutter)
                .padding(.bottom, pageContainsInfo ? (isDesktop ? 64 : 0) : footerGutter)
                .background(readerBackground.ignoresSafeArea())
                .overlay {
                    if searchVisible && !isDesktop {
                        searchResults
                            .background(readerBackground.ignoresSafeArea())
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                    GlassEffectContainer(spacing: 0) { HStack {
                        if searchVisible && !isDesktop {
                            searchField
                                .transition(.opacity)
                        } else {
                        if readerChromeVisible && !isDesktop {
                            Button { closeReader() } label: { Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }
                                .accessibilityLabel("Back to library").buttonStyle(.plain).glassEffect(readerGlass.interactive(), in: Circle())
                        }
                        Button {
                            toggleReaderControls()
                            controlsActivity = UUID()
                        } label: {
                            VStack(spacing: 2) {
                                if !isDesktop && (controller.controlsVisible || voiceOver) && chapterHeaderLabel != prepared.book.title {
                                    Text(prepared.book.title).font(.caption).foregroundStyle(readerForeground.opacity(0.85))
                                        .lineLimit(1).transition(.opacity)
                                }
                                Text(chapterHeaderLabel).font(.caption.weight(.semibold))
                                    .lineLimit(!isDesktop && readerChromeVisible ? 2 : 1)
                                    .multilineTextAlignment(.center)
                                    .opacity(pageContainsInfo && keepTitleVisible && (isDesktop || !readerChromeVisible) ? 0 : 1)
                                if controller.controlsVisible, !bookmarkFeedback.isEmpty {
                                    Text(bookmarkFeedback).font(.caption2).foregroundStyle(readerSecondaryForeground).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel([chapterHeaderLabel, prepared.book.title].filter { !$0.isEmpty }.joined(separator: ", "))
                        .accessibilityHint("Show or hide reader controls")
                        .opacity(readerChromeVisible || (!isDesktop && !pageContainsInfo && keepTitleVisible) ? 1 : 0)
                        .allowsHitTesting(readerChromeVisible || (!isDesktop && !pageContainsInfo && keepTitleVisible))
                        .accessibilityHidden(!(readerChromeVisible || (!isDesktop && !pageContainsInfo && keepTitleVisible)))
                        if !isDesktop && readerChromeVisible, ReaderCapabilities(format: prepared.book.format).textSearch {
                            Button { openSearch() } label: { Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }
                                .accessibilityLabel("Search book").buttonStyle(.plain).glassEffect(readerGlass.interactive(), in: Circle())
                                .glassEffectID("readerSearch", in: glassNamespace)
                        }
                        }
                    }}.foregroundStyle(readerForeground).padding(.horizontal, 16).frame(height: headerGutter).padding(.top, pageInsets.top)
                    .background(pageContainsInfo && (isDesktop || !readerChromeVisible) ? .clear : readerBackground)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Keep the native Menu's source mounted while the chrome fades.
                    // Removing it would dismiss an open system menu on the hide timer.
                    ZStack(alignment: .bottom) {
                        if !isDesktop && !pageContainsInfo && !searchVisible && readerChromeVisible {
                            bottomChromeFade.frame(height: footerGutter).ignoresSafeArea(edges: .bottom)
                        }
                        readerControls.frame(maxWidth: 540)
                            .background(readerChromeVisible && (isDesktop || pageContainsInfo) ? readerBackground : .clear, in: RoundedRectangle(cornerRadius: 28))
                            .padding(.horizontal, isDesktop ? 24 : 16).padding(.bottom, (isDesktop ? 18 : 10) + pageInsets.bottom)
                            .opacity((!searchVisible || isDesktop) && readerChromeVisible ? 1 : 0)
                            .allowsHitTesting((!searchVisible || isDesktop) && readerChromeVisible)
                            .accessibilityHidden((searchVisible && !isDesktop) || !readerChromeVisible)
                        restingProgress.frame(maxWidth: 320).padding(.horizontal, 40).offset(y: 6)
                            .opacity(!isDesktop && !pageContainsInfo && !searchVisible && keepProgressVisible && !(readerChromeVisible) ? 1 : 0)
                            .allowsHitTesting(!isDesktop && !pageContainsInfo && !searchVisible && keepProgressVisible && !(readerChromeVisible))
                            .accessibilityHidden(pageContainsInfo || searchVisible || !keepProgressVisible || readerChromeVisible)
                    }
                }
            .animation(isDesktop || reduceMotion ? nil : .easeInOut(duration: 0.25), value: controller.controlsVisible)
            .navigationTitle(prepared.book.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .sheet(isPresented: Binding(get: { !isDesktop && panel != nil && !(usesSidebar && panel == .contents) }, set: { if !$0 { panel = nil } })) {
                Group {
                    if let adjustment {
                        compactAdjustment(adjustment)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                    }
                    else {
                        NavigationStack {
                            Group {
                                if panel == .appearance { appearance }
                                else { contents }
                            }.navigationTitle(panel == .appearance ? "Appearance" : (navigationTab == 2 ? "Notes & Highlights" : "Contents"))
                            #if os(macOS)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { panel = nil } } }
                            #endif
                        }
                        .transition(.opacity)
                    }
                }
                .frame(minWidth: 320, idealWidth: 420)
                #if os(macOS)
                .frame(minHeight: adjustment == nil ? 380 : compactPanelHeight)
                #endif
                .animation(appearanceAnimation, value: adjustment)
                // Keep the expanded detents available while the same sheet
                // shrinks; never dismiss and present a second editor sheet.
                .presentationDetents(adjustment == nil ? [.medium, .large] : [.height(compactPanelHeight), .medium, .large], selection: $appearanceDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(compactPanelHeight)))
            }
            .sheet(item: $newHighlightNote) { note in
                PageNoteEditor(note: note, supportsUnderline: prepared.book.format == .epub, delete: annotationRemoval(for: note)) { updated in
                    guard let store = model.readingStore(for: prepared.book) else { return false }
                    do { try store.saveAnnotation(updated, id: prepared.id); model.bookmarksRevision += 1; return true }
                    catch { model.error = UserFacingError.message(error); return false }
                }
            }
          }
          #if os(iOS)
          .frame(width: geometry.size.width, height: geometry.size.height)
          .ignoresSafeArea(.container, edges: pageContainsInfo ? .vertical : [])
          .statusBarHidden(pageContainsInfo && (!controller.controlsVisible || model.preferences.pageTransition == "curl") && !voiceOver)
          #endif
          #if os(macOS)
          .frame(minWidth: 0, maxWidth: .infinity)
          .toolbarVisibility(readerChromeVisible ? .visible : .hidden, for: .windowToolbar)
          .toolbarBackground(readerBackground, for: .windowToolbar)
          .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
          .toolbar {
              if prepared.book.format == .epub {
                  ToolbarItem(placement: .primaryAction) {
                      macHighlighterToggle.disabled(!controller.ready || verifiedFingerprint == nil)
                  }
                  ToolbarItem(placement: .primaryAction) {
                      macHighlighterPaletteButton.disabled(!controller.ready || verifiedFingerprint == nil)
                  }
                  ToolbarSpacer(.fixed, placement: .primaryAction)
              }
              if prepared.book.format == .pdf, controller.pdfSelection != nil {
                  ToolbarItem(placement: .primaryAction) {
                      Button("Highlight selection", systemImage: "highlighter", action: highlightPDFSelection)
                          .disabled(verifiedFingerprint == nil)
                  }
                  ToolbarSpacer(.fixed, placement: .primaryAction)
              }
              ToolbarItemGroup(placement: .primaryAction) {
                  macSidebarToggle("Appearance", systemImage: "textformat.size", target: .appearance)
                  macSidebarToggle("Highlights", systemImage: "note.text", target: .contents, navigation: 2)
                  macSidebarToggle("Contents", systemImage: "list.bullet", target: .contents)
                  if ReaderCapabilities(format: prepared.book.format).textSearch {
                      macSidebarToggle("Search book", systemImage: "magnifyingglass", target: .search)
                          .disabled(!controller.ready)
                  }
              }
          }
          .inspector(isPresented: Binding(
              get: { macSidebarVisible },
              set: { visible in
                  guard !visible, macSidebarVisible else { return }
                  animateSidebarChange {
                      if searchVisible { closeSearch(sidebarWillRemainVisible: true) }
                      panel = nil
                  }
              })) {
                  macSidebar
                      .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
              }
          #endif
          if !isDesktop && usesSidebar && panel == .contents {
              Divider()
              VStack(spacing: 0) {
                  HStack {
                      Text("Book navigation").font(.headline).accessibilityAddTraits(.isHeader)
                      Spacer()
                      Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                          .buttonStyle(.plain).accessibilityLabel("Close book navigation")
                  }.padding(.horizontal, 16)
                  contents
              }
              .frame(width: 320)
              .background(.background)
          }
          }
          .onChange(of: usesSidebar, initial: true) { _, value in wideContents = value }
        }
        .background(readerBackground.ignoresSafeArea())
        .readerScreenAwake(keepScreenAwake && controller.ready && controller.error == nil)
        #if os(macOS)
        .containerBackground(readerBackground, for: .window)
        #endif
        #if os(iOS)
        .ignoresSafeArea(.container, edges: pageContainsInfo ? .vertical : [])
        #endif
        .focusedSceneValue(\.readerActions, ReaderSceneActions(
            hasPanel: searchVisible || panel != nil,
            canTurn: controller.ready && showsPageTurnButtons && (isDesktop || (panel == nil && !searchVisible)),
            canSearch: controller.ready && ReaderCapabilities(format: prepared.book.format).textSearch,
            canBookmark: controller.ready,
            canIncreaseText: prepared.book.format == .epub && !originalFormatting && !controller.fixedLayout && model.preferences.fontSize < 36,
            canDecreaseText: prepared.book.format == .epub && !originalFormatting && !controller.fixedLayout && model.preferences.fontSize > 14,
            controls: { toggleReaderControls() },
            previous: { controller.command?("previous", nil) },
            next: { controller.command?("next", nil) },
            contents: { if isDesktop { toggleMacSidebar(.contents) } else { controller.controlsVisible = true; navigationTab = 0; panel = panel == .contents ? nil : .contents } },
            appearance: { if isDesktop { toggleMacSidebar(.appearance) } else { controller.controlsVisible = true; panel = .appearance } },
            search: { if isDesktop { toggleMacSidebar(.search) } else { openSearch() } },
            increaseText: { model.preferences.fontSize = min(36, model.preferences.fontSize + 1) },
            decreaseText: { model.preferences.fontSize = max(14, model.preferences.fontSize - 1) },
            bookmark: { if let bookmark = currentBookmark { removeBookmark(bookmark) } else { addBookmark() } },
            close: { closeReaderContext() }
        ))
        #if os(macOS)
        .onExitCommand(perform: closeReaderContext)
        #endif
        .alert("Chapter unavailable", isPresented: Binding(get: { controller.navigationError }, set: { controller.navigationError = $0 })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This chapter could not be opened. Your current reading position is unchanged.")
        }
        .preferredColorScheme(darkReader ? .dark : .light)
        .onAppear { originalFormatting = model.readingStore(for: prepared.book)?.usesOriginalFormatting(bookID: prepared.id) ?? false; controller.changed = { model.savePosition($0, book: prepared.book) }; configureAnnotationActions(); scrubFraction = progressFraction; controller.pageTapZoneFraction = model.preferences.pageTapZoneFraction }
        .onChange(of: model.preferences.pageTapZoneFraction) { _, width in controller.pageTapZoneFraction = width }
        .onChange(of: controller.ready) { _, ready in if ready { onContentReady(true) } }
        .onChange(of: controller.ready) { _, ready in if !ready { controller.highlighterColor = nil } }
        .onChange(of: controller.ready) { _, ready in if ready { updateEPUBHighlights() } }
        .onChange(of: verifiedFingerprint) { _, _ in configureAnnotationActions(); updateEPUBHighlights() }
        .onChange(of: model.bookmarksRevision) { _, _ in updateEPUBHighlights() }
        .onChange(of: controller.error) { _, error in if error != nil { onContentReady(false) } }
        .onChange(of: controller.controlsVisible) { _, visible in
            controlsActivity = UUID()
        }
        .onChange(of: controller.pdfSelection) { _, _ in controlsActivity = UUID() }
        .onChange(of: controller.epubSelectionActive) { _, active in
            controlsActivity = UUID(); selectionExpiryTask?.cancel()
            if active { recentEPUBSelection = true }
            else {
                selectionExpiryTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                    guard !Task.isCancelled else { return }
                    recentEPUBSelection = false
                }
            }
        }
        .onChange(of: controller.bookPage) { _, _ in if !scrubbing { scrubFraction = progressFraction } }
        .onChange(of: controller.bookPageCount) { _, _ in if !scrubbing { scrubFraction = progressFraction } }
        .onChange(of: controller.position) { _, _ in controlsActivity = UUID(); if !scrubbing { scrubFraction = progressFraction } }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: scrubChapterHaptic)
        #endif
        .onChange(of: voiceOver) { _, _ in controlsActivity = UUID() }
        .onChange(of: searchVisible) { _, visible in controlsActivity = UUID(); searchFocused = visible }
        .task(id: "\(currentFingerprintSourceKey)|\(fingerprintAttempt)") {
            if prepared.book.format == .pdf { await verifyBookFingerprint() }
        }
        .task(id: controlsActivity) {
            #if os(iOS)
            guard controller.controlsVisible, !voiceOver, panel == nil, !scrubbing, !searchVisible, controller.pdfSelection == nil, !controller.epubSelectionActive else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, panel == nil, !scrubbing, !voiceOver, !searchVisible, controller.pdfSelection == nil, !controller.epubSelectionActive else { return }
            controller.controlsVisible = false
            #endif
        }
        .onChange(of: panel) { _, value in
            if value != nil { if isDesktop && value != .search { closeSearch() }; adjustment = nil; appearanceDetent = .medium; expandedAppearanceDetent = .medium }
            controlsActivity = UUID(); pageNumber = controller.position.page + 1
        }
        .onChange(of: compactPanelHeight) { _, height in
            if adjustment != nil { appearanceDetent = .height(height) }
        }
        .onDisappear { searchRevealTask?.cancel(); selectionExpiryTask?.cancel(); controller.cancelSearch(); controller.changed = nil; controller.selectionMenuAction = nil; controller.annotationAction = nil; controller.highlighterAction = nil; controller.highlighterColor = nil; Task { await model.flushProgress() } }
        .task(id: "\(currentFingerprintSourceKey)|\(fingerprintAttempt)") {
            guard prepared.book.format == .epub, verifiedFingerprint == nil else { return }
            let sourceKey = currentFingerprintSourceKey
            fingerprintFailed = false
            do {
                let value = try await BookFingerprint.epub(directory: prepared.directory, hasDurableSidecars: prepared.hasDurableSidecars)
                guard !Task.isCancelled, sourceKey == currentFingerprintSourceKey else { return }
                bookFingerprint = value; fingerprintSourceKey = sourceKey
            } catch { if !Task.isCancelled, sourceKey == currentFingerprintSourceKey { fingerprintFailed = true } }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            searchKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            searchKeyboardVisible = false
            searchRevealTask?.cancel(); searchRevealTask = nil
            if !searchVisible { controller.command?("searchPresentation", false) }
        }
        #endif
    }
    private var bottomChromeFade: some View {
        Rectangle().fill(.regularMaterial)
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.8), .black], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
    private var readerControls: some View {
        VStack(spacing: 0) {
            if scrubbing {
                GeometryReader { geometry in
                    VStack(spacing: 2) {
                        Text(scrubChapterNumber).font(.caption.weight(.semibold)).lineLimit(2)
                            .multilineTextAlignment(.center)
                        if let title = scrubChapterTitle {
                            Text(title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(readerForeground)
                        .frame(width: 236)
                        .glassEffect(readerGlass, in: RoundedRectangle(cornerRadius: 18))
                        .position(x: min(max(118, 50 + scrubFraction * max(0, geometry.size.width - 160)),
                                         max(118, geometry.size.width - 118)), y: 30)
                }
                .frame(height: 62)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            HStack(spacing: isDesktop ? 6 : 2) {
                        if showsPageTurnButtons {
                        Button { controller.command?("previous", nil) } label: { Image(systemName: "chevron.left").frame(width: isDesktop ? 40 : 44, height: readerControlHeight) }
                            .accessibilityLabel("Previous page").keyboardShortcut(!isDesktop && panel == nil && !searchVisible ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                        }
                        VStack(spacing: isDesktop ? 8 : 6) {
                            Text(bookPageLabel)
                                .font(.caption).monospacedDigit().foregroundStyle(readerSecondaryForeground)
                                .lineLimit(1)
                            Slider(value: Binding(get: { scrubFraction }, set: { value in
                                scrubFraction = value
                                if scrubbing { updateScrubChapter() }
                            }), in: 0...1) { editing in
                                if editing { lastScrubChapter = chapter(at: scrubFraction)?.number; requestChapterSnippet() }
                                withAnimation(.easeInOut(duration: 0.18)) { scrubbing = editing }
                                controlsActivity = UUID()
                                if !editing { scrubToProgress(); lastScrubChapter = nil }
                            }
                            .disabled(prepared.book.format == .epub && !model.preferences.scrolling && controller.bookPageCount == 0)
                            .accessibilityLabel("Book position")
                            .accessibilityValue(bookPageLabel)
                        }.padding(.horizontal, 4).padding(.vertical, isDesktop ? 6 : 0).frame(maxWidth: .infinity)
                        if showsPageTurnButtons {
                        Button { controller.command?("next", nil) } label: { Image(systemName: "chevron.right").frame(width: isDesktop ? 40 : 44, height: readerControlHeight) }
                            .accessibilityLabel("Next page").keyboardShortcut(!isDesktop && panel == nil && !searchVisible ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
                        }
                        if !isDesktop {
                        Rectangle().fill(readerSecondaryForeground.opacity(0.25)).frame(width: 1, height: 32).padding(.horizontal, 4)
                        Menu {
                            Button("Appearance and page turns", systemImage: "textformat.size") { panel = .appearance }
                            if prepared.book.format == .epub, let selection = controller.epubSelection {
                                Button("Highlight “\(String(selection.text.prefix(48)))”", systemImage: "highlighter") { addEPUBHighlight() }
                                    .disabled(!canHighlightEPUBSelection || verifiedFingerprint == nil)
                            }
                            if currentBookmark == nil {
                                Button("Bookmark this page", systemImage: "bookmark.fill") { addBookmark() }
                            }
                            Button("Bookmarks", systemImage: "bookmark") { navigationTab = 1; panel = .contents }
                            if prepared.book.format == .pdf, controller.pdfSelection != nil {
                                Button("Highlight selection", systemImage: "highlighter", action: highlightPDFSelection).disabled(verifiedFingerprint == nil)
                            }
                            Button("Notes", systemImage: "note.text") { navigationTab = 2; panel = .contents }
                            Button("Contents", systemImage: "list.bullet") { navigationTab = 0; panel = .contents }
                            if let bookmark = currentBookmark {
                                Button("Remove bookmark here", systemImage: "bookmark.slash") { removeBookmark(bookmark) }
                            }
                            if let back = controller.returnPosition {
                                Divider()
                                Button("Back to reading position", systemImage: "arrow.uturn.backward") {
                                    seek(back); controller.returnPosition = nil
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 21, weight: .semibold))
                                .frame(width: isDesktop ? 36 : 54, height: readerControlHeight)
                                .contentShape(Rectangle())
                        }
                        .menuOrder(.fixed)
                        .accessibilityLabel("Reader options")
                        .simultaneousGesture(TapGesture().onEnded { controlsActivity = UUID() })
                        }
            }
            .padding(.horizontal, 6)
            .glassEffect(readerGlass.interactive(), in: RoundedRectangle(cornerRadius: 28))
        }.foregroundStyle(readerForeground).disabled(!controller.ready).buttonStyle(.borderless)
            .simultaneousGesture(TapGesture().onEnded { controlsActivity = UUID() })
    }
    private var restingProgress: some View {
        Button {
            controller.controlsVisible = true
            controlsActivity = UUID()
        } label: {
            Text(chapterPagesRemainingLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(readerSecondaryForeground)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chapterPagesRemainingLabel). Show book navigation")
    }
    private func chapter(at fraction: Double) -> ReaderChapter? {
        let chapters = prepared.book.format == .epub && !model.preferences.scrolling && !controller.pageChapters.isEmpty ? controller.pageChapters : controller.chapters
        return chapters.last(where: { $0.contains(fraction) }) ?? chapters.first
    }
    private var currentChapter: ReaderChapter? {
        let chapters = model.preferences.scrolling ? controller.chapters : controller.pageChapters
        guard let href = controller.currentChapter?.split(separator: "#").first else { return chapter(at: progressFraction) }
        return chapters.first(where: { $0.href?.split(separator: "#").first == href }) ?? chapter(at: progressFraction)
    }
    private var chapterHeaderLabel: String {
        if prepared.book.format == .epub {
            let title = controller.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
            let chapter = currentChapter?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return chapter.isEmpty ? prepared.book.title : chapter
        }
        return "Page \(controller.position.page + 1)"
    }
    private var chapterProgressFraction: Double {
        if prepared.book.format == .epub { return currentChapter?.progress(at: progressFraction) ?? progressFraction }
        return progressFraction
    }
    private var chapterPagesRemainingLabel: String {
        if prepared.book.format == .epub {
            if !model.preferences.scrolling, controller.chapterPageCount > 0, controller.chapterPage > 0 {
                return "\(max(0, controller.chapterPageCount - controller.chapterPage)) pages left in chapter"
            }
            if model.preferences.scrolling, currentChapter != nil {
                return "\(Int((chapterProgressFraction * 100).rounded()))% through chapter"
            }
            return "Chapter pages unavailable"
        }
        return "\(max(0, controller.pageCount - controller.position.page - 1)) pages left in book"
    }
    private var scrubChapterNumber: String {
        if prepared.book.format == .epub, let chapter = chapter(at: scrubFraction) {
            return chapter.title
        }
        return "Page \(ReaderPagination.page(at: scrubFraction, total: controller.pageCount))"
    }
    private var scrubChapterTitle: String? {
        guard prepared.book.format == .epub, let chapter = chapter(at: scrubFraction) else { return nil }
        if let snippet = controller.chapterSnippets[chapter.number], !snippet.isEmpty { return "Opening: \(snippet)" }
        return nil
    }
    private func updateScrubChapter() {
        let number = chapter(at: scrubFraction)?.number
        #if os(iOS)
        if let previous = lastScrubChapter, let number, number != previous {
            scrubChapterHaptic &+= 1
        }
        #endif
        lastScrubChapter = number
        requestChapterSnippet()
    }
    private func requestChapterSnippet() {
        guard prepared.book.format == .epub, let chapter = chapter(at: scrubFraction),
              scrubChapterTitle == nil, model.preferences.scrolling, requestedChapterSnippets.insert(chapter.number).inserted else { return }
        controller.command?("chapterSnippet", ["fraction": scrubFraction, "number": chapter.number])
    }
    private var progressFraction: Double {
        if prepared.book.format == .epub {
            if !model.preferences.scrolling, controller.bookPageCount > 0 {
                return Double(max(0, controller.bookPage - 1)) / Double(max(1, controller.bookPageCount - 1))
            }
            return controller.position.fraction
        }
        return Double(controller.position.page) / Double(max(1, controller.pageCount - 1))
    }
    private var bookPageLabel: String {
        if prepared.book.format == .epub && !model.preferences.scrolling {
            guard controller.bookPageCount > 0 else {
                return controller.paginationFailed ? "Book pages unavailable" : "Counting pages…"
            }
            let page = scrubbing ? ReaderPagination.page(at: scrubFraction, total: controller.bookPageCount) : controller.bookPage
            return "Page \(page) of \(controller.bookPageCount)"
        }
        return ReaderPagination.bookLabel(at: scrubbing ? scrubFraction : progressFraction, total: controller.pageCount,
                                          estimated: false, scrolling: prepared.book.format == .epub && model.preferences.scrolling)
    }
    private func scrubToProgress() {
        controller.returnPosition = controller.position
        if prepared.book.format == .epub {
            if !model.preferences.scrolling, controller.bookPageCount > 0 {
                controller.command?("layoutPage", ReaderPagination.page(at: scrubFraction, total: controller.bookPageCount) - 1)
            } else { seek(ReadingPosition(fraction: scrubFraction)) }
        } else { controller.command?("page", ReaderPagination.page(at: scrubFraction, total: controller.pageCount) - 1) }
    }
    private var currentBookmark: Bookmark? {
        (model.readingStore(for: prepared.book)?.bookmarks[prepared.id] ?? []).first { bookmark in
            if prepared.book.format == .epub { return bookmark.position.cfi != nil && bookmark.position.cfi == controller.position.cfi }
            return bookmark.position.page == controller.position.page
        }
    }
    private func removeBookmark(_ bookmark: Bookmark) {
        do { try model.readingStore(for: prepared.book)?.removeBookmark(bookmark, id: prepared.id); model.bookmarksRevision += 1; bookmarkFeedback = "Bookmark removed" }
        catch { model.error = UserFacingError.message(error); bookmarkFeedback = "Bookmark could not be removed" }
    }
    private var readerBackground: Color {
        switch prepared.book.format {
        case .epub:
            AppAppearance.background(model.preferences.theme)
        case .cbz: .black
        default: Color(white: 0.92)
        }
    }
    private var darkReader: Bool {
        prepared.book.format == .cbz || (prepared.book.format == .epub && model.preferences.theme == "dark")
    }
    private var readerGlass: Glass {
        if darkReader { return .regular.tint(Color(white: 0.16).opacity(0.55)) }
        if prepared.book.format == .epub && model.preferences.theme == "sepia" {
            return .regular.tint(Color(red: 0.86, green: 0.76, blue: 0.57).opacity(0.30))
        }
        return .regular
    }
    private var readerForeground: Color {
        darkReader ? .white : .primary
    }
    private var readerSecondaryForeground: Color {
        darkReader ? .white.opacity(0.7) : .secondary
    }
    @ViewBuilder private func readerContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        NavigationStack {
            content()
                .toolbarBackground(readerBackground, for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        }
        .background(readerBackground)
        #else
        // The full-screen reader supplies its own controls. A navigation host
        // reintroduces system safe areas before the page's own reservations.
        ZStack { content() }
        #endif
    }
    private func readerSurface(chrome: ReaderPageChrome) -> some View {
        ZStack {
            switch prepared.book.format {
            case .epub:
                EPUBSurface(prepared: prepared, controller: controller, preferences: readerPreferences, chrome: chrome)
                    #if os(macOS)
                    .blur(radius: controller.reflowSoftening && !reduceMotion && !reduceTransparency && contrast != .increased ? 0.7 : 0)
                    #endif
            case .pdf: PDFSurface(prepared: prepared, controller: controller, annotations: pdfAnnotations, fingerprint: verifiedFingerprint)
            case .cbz: ComicSurface(prepared: prepared, controller: controller)
            case .unsupported: ContentUnavailableView("Unsupported book", systemImage: "book.closed")
            }
            if panel == .appearance && adjustment == .edgeWidth {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(.tint.opacity(0.12)).frame(width: geometry.size.width * model.preferences.pageTapZoneFraction)
                        Spacer(minLength: 0)
                        Rectangle().fill(.tint.opacity(0.12)).frame(width: geometry.size.width * model.preferences.pageTapZoneFraction)
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            if let error = controller.error {
                ContentUnavailableView { Label("Couldn’t open book", systemImage: "exclamationmark.triangle") }
                    description: { Text(error) }
                    actions: { Button(isDesktop ? "Close book" : "Back to library") { closeReader() } }
                    .background(.background)
            }
        }
    }
    private func addBookmark() {
        let added = model.addBookmark(book: prepared.book, position: controller.position)
        bookmarkFeedback = model.error == nil ? (added ? "Bookmark added" : "Already bookmarked") : "Bookmark could not be saved"

    }
    private var appearance: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { macAppearanceFields }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        #else
        Form { appearanceFields }.formStyle(.grouped)
        #endif
    }
    #if os(macOS)
    @ViewBuilder private var macAppearanceFields: some View {
        @Bindable var model = model
        if prepared.book.format == .epub {
            macAppearanceSection("Reading appearance") {
                Picker("App color", selection: $model.preferences.theme) {
                    Text("Light").tag("light"); Text("Sepia").tag("sepia"); Text("Dark").tag("dark")
                }
                Text("Applies to reading and browsing.").font(.caption).foregroundStyle(.secondary)
                formattingToggle
                Picker("Font", selection: $model.preferences.font) {
                    Text("Georgia").tag("Georgia"); Text("System sans serif").tag("-apple-system"); Text("Palatino").tag("Palatino")
                }.disabled(originalFormatting || controller.fixedLayout)
            }
            macAppearanceSection("Page layout") {
                inlineAdjustment(.textSize)
                inlineAdjustment(.lineSpacing)
                inlineAdjustment(.margins)
            }.disabled(originalFormatting || controller.fixedLayout)
            macAppearanceSection("Navigation") {
                Toggle("Scroll vertically", isOn: $model.preferences.scrolling)
                if !model.preferences.scrolling {
                    Picker("Page turn", selection: $model.preferences.pageTransition) {
                        Text("Instant").tag("instant"); Text("Fade").tag("fade"); Text("Card swipe").tag("slide")
                        if model.preferences.pageTransition == "curl" { Text("Page curl (Fade on Mac)").tag("curl") }
                    }
                    Text("Reduce Motion turns off page animations automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            macAppearanceSection("Page view") {
                HStack {
                    Button("Zoom In") { controller.command?("zoomIn", nil) }
                    Button("Zoom Out") { controller.command?("zoomOut", nil) }
                }
                HStack {
                    Button("Fit Page") { controller.command?("fit", nil) }
                    Button("Fit Width") { controller.command?("fitWidth", nil) }
                }
                TextField("Page number", value: $pageNumber, format: .number)
                Stepper("Page \(pageNumber)", value: $pageNumber, in: 1...max(1, controller.pageCount))
                Button("Go to Page") { controller.returnPosition = controller.position; controller.command?("page", pageNumber - 1); animateSidebarChange { panel = nil } }
                    .disabled(pageNumber < 1 || pageNumber > controller.pageCount)
            }
        }
        macAppearanceSection("While reading") {
            Toggle("Keep chapter visible", isOn: $keepTitleVisible)
            Toggle("Keep progress visible", isOn: $keepProgressVisible)
            Text("Use the Reader menu or toolbar to manage reading controls.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func macAppearanceSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(readerForeground.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
    #endif
    private var readerPreferences: ReaderPreferences {
        var value = model.preferences
        value.originalFormatting = originalFormatting
        return value
    }
    private var originalFormattingBinding: Binding<Bool> {
        Binding(get: { originalFormatting }, set: { value in
            guard let store = model.readingStore(for: prepared.book) else { model.error = "Reading preferences are unavailable."; return }
            do { try store.setOriginalFormatting(value, bookID: prepared.id); originalFormatting = value }
            catch { model.error = UserFacingError.message(error) }
        })
    }
    private var formattingToggle: some View {
        VStack(alignment: .leading) {
            Toggle("Original Formatting", isOn: originalFormattingBinding).disabled(controller.fixedLayout)
            if controller.fixedLayout {
                Text("This fixed-layout book uses its original page design. Typography controls do not apply.").font(.caption).foregroundStyle(.secondary)
            } else if originalFormatting {
                Text("Uses the book's typography and layout. Font, text size, line spacing and margins do not apply.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var appearanceFields: some View {
        @Bindable var model = model
            if !isDesktop { Section("Tap to turn pages") {
                adjustmentButton(.edgeWidth)
                Text("Tap the left edge for the previous page, the right edge for the next page, and the center for controls. While scrolling an EPUB or zoomed in, taps show controls.").font(.caption).foregroundStyle(.secondary)
            }
            }
            if prepared.book.format == .epub {
                Picker("App color", selection: $model.preferences.theme) { Text("Light").tag("light"); Text("Sepia").tag("sepia"); Text("Dark").tag("dark") }
                Text("Applies to reading and browsing.").font(.caption).foregroundStyle(.secondary)
                formattingToggle
                Picker("Font", selection: $model.preferences.font) { Text("Georgia").tag("Georgia"); Text("System sans serif").tag("-apple-system"); Text("Palatino").tag("Palatino") }.disabled(originalFormatting || controller.fixedLayout)
                Group {
                #if os(macOS)
                inlineAdjustment(.textSize)
                inlineAdjustment(.lineSpacing)
                inlineAdjustment(.margins)
                #else
                adjustmentButton(.textSize)
                adjustmentButton(.lineSpacing)
                adjustmentButton(.margins)
                #endif
                }.disabled(originalFormatting || controller.fixedLayout)
                Toggle("Scroll vertically", isOn: $model.preferences.scrolling)
                if !model.preferences.scrolling {
                    Picker("Page turn", selection: $model.preferences.pageTransition) {
                        Text("Instant").tag("instant")
                        Text("Fade").tag("fade")
                        Text("Card swipe").tag("slide")
                        #if os(iOS)
                        Text("Page curl").tag("curl")
                        #else
                        if model.preferences.pageTransition == "curl" { Text("Page curl (Fade on Mac)").tag("curl") }
                        #endif
                    }
                    Text("Reduce Motion turns off page animations automatically.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Zoom In") { controller.command?("zoomIn", nil) }
                Button("Zoom Out") { controller.command?("zoomOut", nil) }
                Button("Fit Page") { controller.command?("fit", nil) }
                Button("Fit Width") { controller.command?("fitWidth", nil) }
                TextField("Page number", value: $pageNumber, format: .number)
                Stepper("Page \(pageNumber)", value: $pageNumber, in: 1...max(1, controller.pageCount))
                Button("Go to Page") { controller.returnPosition = controller.position; controller.command?("page", pageNumber - 1); panel = nil }.disabled(pageNumber < 1 || pageNumber > controller.pageCount)
            }
            Section("While reading") {
                #if os(iOS)
                Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
                Text("Prevents Auto-Lock while reading. Turn off to use system Auto-Lock and Attention Aware settings.").font(.caption).foregroundStyle(.secondary)
                #endif
                Toggle("Keep chapter visible", isOn: $keepTitleVisible)
                Toggle("Keep progress visible", isOn: $keepProgressVisible)
                Text(isDesktop ? "Use the Reader menu or toolbar to manage reading controls." : "Show controls with a tap in the center of the page.").font(.caption).foregroundStyle(.secondary)
            }
    }
    private var showsPageTurnButtons: Bool {
        prepared.book.format != .epub || !model.preferences.scrolling
    }
    private var appearanceAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9)
    }
    private func selectAdjustment(_ setting: ReaderAdjustment?) {
        if setting != nil && adjustment == nil { expandedAppearanceDetent = appearanceDetent }
        withAnimation(appearanceAnimation) {
            adjustment = setting
            appearanceDetent = setting == nil ? expandedAppearanceDetent : .height(compactPanelHeight)
        }
    }
    private func adjustmentButton(_ setting: ReaderAdjustment) -> some View {
        Button { selectAdjustment(setting) } label: {
            HStack(spacing: 12) {
                Text(setting.rawValue).foregroundStyle(.primary)
                    .matchedGeometryEffect(id: "title-" + setting.id, in: appearanceNamespace)
                Spacer(minLength: 8)
                Text(adjustmentValue(setting)).foregroundStyle(.secondary).monospacedDigit()
                    .matchedGeometryEffect(id: "value-" + setting.id, in: appearanceNamespace)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(setting.rawValue)
        .accessibilityValue(adjustmentValue(setting))
        .accessibilityHint("Opens a compact slider while keeping the book visible")
    }
    private func adjustmentValue(_ setting: ReaderAdjustment) -> String {
        switch setting {
        case .textSize: return "\(Int(model.preferences.fontSize))"
        case .lineSpacing: return model.preferences.lineHeight.formatted(.number.precision(.fractionLength(1)))
        case .margins: return "\(Int(model.preferences.margin))"
        case .edgeWidth: return "\(Int((model.preferences.pageTapZoneFraction * 100).rounded()))% per side"
        }
    }
    #if os(macOS)
    private func inlineAdjustment(_ setting: ReaderAdjustment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(setting.rawValue).font(.subheadline.weight(.medium))
                Spacer()
                Text(adjustmentValue(setting)).monospacedDigit().foregroundStyle(.secondary)
            }
            adjustmentSlider(setting)
        }
    }
    #endif
    @ViewBuilder private func adjustmentSlider(_ setting: ReaderAdjustment) -> some View {
        @Bindable var model = model
        Group {
            switch setting {
            case .textSize: Slider(value: $model.preferences.fontSize, in: 14...36, step: 1)
            case .lineSpacing: Slider(value: $model.preferences.lineHeight, in: 1.2...2.2, step: 0.1)
            case .margins: Slider(value: $model.preferences.margin, in: 8...64, step: 4)
            case .edgeWidth: Slider(value: $model.preferences.pageTapZoneFraction, in: 0.1...0.3, step: 0.05)
            }
        }
        .accessibilityLabel(setting.rawValue)
        .accessibilityValue(adjustmentValue(setting))
    }
    private func compactAdjustment(_ setting: ReaderAdjustment) -> some View {
        return VStack(spacing: 12) {
            HStack {
                Button { selectAdjustment(nil) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("All appearance settings")
                Menu {
                    ForEach(ReaderAdjustment.allCases.filter { prepared.book.format == .epub || $0 == .edgeWidth }) { option in
                        Button(option.rawValue) { selectAdjustment(option) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(setting.rawValue).font(.headline)
                            .matchedGeometryEffect(id: "title-" + setting.id, in: appearanceNamespace)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }.foregroundStyle(.primary)
                }
                .accessibilityHint("Choose a different appearance setting")
                Spacer()
                Text(adjustmentValue(setting)).monospacedDigit().foregroundStyle(.secondary)
                    .matchedGeometryEffect(id: "value-" + setting.id, in: appearanceNamespace)
                    .contentTransition(.numericText())
                #if os(macOS)
                Button { animateSidebarChange { panel = nil } } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close appearance")
                #endif
            }
            adjustmentSlider(setting)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
    #if os(macOS)
    private var macSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(macSidebarDestination == .search ? "Search" : macSidebarDestination == .appearance ? "Appearance" : "Book navigation")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16)
            Divider()
            if macSidebarDestination == .search {
                HStack {
                    MacReaderSearchField(text: $search, onSubmit: { runSearch() }, onCancel: { closeSearch() })
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .onChange(of: search) { _, _ in
                            controller.cancelSearch(); controller.results = []; controller.searchState = .idle
                        }
                    Button("Search", action: runSearch)
                        .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12)
                searchResults
            } else if macSidebarDestination == .appearance {
                appearance.scrollContentBackground(.hidden)
            } else { contents.scrollContentBackground(.hidden) }
        }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, darkReader ? .dark : .light)
    }
    #endif
    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button { runSearch() } label: {
                    Image(systemName: "magnifyingglass").frame(width: 40, height: 48)
                }
                .accessibilityLabel("Search book text")
                .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #if os(macOS)
                MacReaderSearchField(text: $search, onSubmit: { runSearch() }, onCancel: { closeSearch() })
                    .onChange(of: search) { _, _ in
                        controller.cancelSearch(); controller.results = []; controller.searchState = .idle
                    }
                #else
                TextField("Search in book", text: $search)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .focused($searchFocused)
                .task { await Task.yield(); searchFocused = false; await Task.yield(); searchFocused = true }
                    .onSubmit { runSearch() }
                    .onChange(of: search) { _, _ in
                        controller.cancelSearch(); controller.results = []; controller.searchState = .idle
                    }
                #endif
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .glassEffect(readerGlass.interactive(), in: Capsule())
            .glassEffectID("readerSearch", in: glassNamespace)
            Button { closeSearch() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(readerGlass.interactive(), in: Circle())
            .glassEffectID("closeSearch", in: glassNamespace)
            .accessibilityLabel("Close book search")
        }
        .frame(maxWidth: .infinity)
    }
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search results").font(.headline)
                Spacer()
                if controller.searchState == .results {
                    Text("\(controller.results.count) matches").font(.caption).foregroundStyle(readerSecondaryForeground)
                }
            }
            switch controller.searchState {
            case .idle:
                Text("Search text in this book.").foregroundStyle(readerSecondaryForeground)
            case .searching:
                ProgressView("Searching book…")
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search could not finish.")
                    Button("Try Again", action: runSearch).buttonStyle(.bordered)
                }
            case .empty:
                Text(prepared.book.format == .pdf ? "No matches. Image-only PDFs have no searchable text." : "No matching text.")
                    .foregroundStyle(readerSecondaryForeground)
            case .results:
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.results) { result in
                            Button {
                                controller.returnPosition = controller.position
                                closeSearch()
                                controller.command?("location", result.id)
                            } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let context = result.context {
                                            Text(context).font(.caption.weight(.semibold)).foregroundStyle(readerSecondaryForeground)
                                        }
                                        Text(result.title).font(.body).multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                        .foregroundStyle(readerSecondaryForeground)
                                        .padding(.top, 4)
                                }
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .padding(.vertical, 18)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(readerForeground.opacity(darkReader ? 0.28 : 0.20)).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                if controller.results.count == 200 {
                    Text("Showing the first 200 matches.").font(.caption).foregroundStyle(readerSecondaryForeground)
                }
            }
        }
        .foregroundStyle(readerForeground)
        .padding(.horizontal, 22)
        .padding(.top, isDesktop ? 12 : 78)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    #if os(macOS)
    private func macSidebarToggle(_ title: String, systemImage: String, target: ReaderPanel, navigation: Int = 0) -> some View {
        Toggle(title, systemImage: systemImage, isOn: Binding(
            get: { macSidebarShows(target, navigation: navigation) },
            set: { _ in toggleMacSidebar(target, navigation: navigation) }
        ))
        .toggleStyle(.button)
        .help(title)
    }
    private var macHighlighterToggle: some View {
        let armed = controller.highlighterColor != nil
        return Toggle(isOn: Binding(
            get: { controller.highlighterColor != nil },
            set: { on in
                controller.highlighterColor = on ? lastHighlighterColor : nil
                showingHighlighterPalette = false
                if on { highlighterToolbarFocused = true }
            }
        )) {
            Label("Highlighter", systemImage: "highlighter")
                .overlay(alignment: .bottom) {
                    Capsule().fill(highlighterTint(lastHighlighterColor))
                        .frame(width: 16, height: 3).offset(y: 3)
                        .opacity(controlActiveState == .inactive ? 0.4 : 1)
                        .accessibilityHidden(true)
                }
        }
        .toggleStyle(.button)
        .focused($highlighterToolbarFocused)
        .onExitCommand(perform: armed ? { controller.highlighterColor = nil } : nil)
        .accessibilityLabel("Highlighter")
        .accessibilityValue(armed ? "On, \(lastHighlighterColor.capitalized)" : "Off")
        .help(armed ? "\(lastHighlighterColor.capitalized) highlighter on. Click or press Escape to turn it off." : "Turn on the \(lastHighlighterColor) highlighter, then drag across text.")
    }
    private var macHighlighterPaletteButton: some View {
        Button { showingHighlighterPalette.toggle() } label: {
            Label("Choose highlight color", systemImage: "chevron.down")
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
        }
        .help("Choose highlight color · \(lastHighlighterColor.capitalized)")
        .popover(isPresented: $showingHighlighterPalette, arrowEdge: .bottom) {
            HStack(spacing: 10) {
                ForEach(["yellow", "green", "blue", "pink", "purple"], id: \.self) { color in
                    Button {
                        lastHighlighterColor = color; controller.highlighterColor = color
                        showingHighlighterPalette = false
                        highlighterToolbarFocused = true
                    } label: {
                        Circle().fill(highlighterTint(color))
                            .frame(width: 26, height: 26)
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(color == lastHighlighterColor ? Color.primary : .clear, lineWidth: 2) }
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(color.capitalized) highlighter")
                    .accessibilityAddTraits(color == lastHighlighterColor ? .isSelected : [])
                    .help(color.capitalized)
                }
            }.padding(12).fixedSize()
        }
    }
    private func highlighterTint(_ name: String) -> Color {
        switch name {
        case "green": Color(red: 101 / 255, green: 184 / 255, blue: 121 / 255)
        case "blue": Color(red: 105 / 255, green: 166 / 255, blue: 223 / 255)
        case "pink": Color(red: 232 / 255, green: 138 / 255, blue: 175 / 255)
        case "purple": Color(red: 175 / 255, green: 138 / 255, blue: 221 / 255)
        default: Color(red: 230 / 255, green: 184 / 255, blue: 74 / 255)
        }
    }
    #endif
    private func closeReaderContext() {
        if controller.highlighterColor != nil { controller.highlighterColor = nil }
        else if searchVisible { closeSearch() }
        else if panel != nil {
            if macSidebarVisible { animateSidebarChange { panel = nil } }
            else { panel = nil }
        } else { closeReader() }
    }
    private func animateSidebarChange(_ change: () -> Void) {
        #if os(macOS)
        guard isDesktop else { change(); return }
        let request = UUID().uuidString
        let hold = prepared.book.format == .epub && controller.ready
        if hold { controller.command?("sidebarTransition", ["phase": "begin", "request": request, "mode": "live"]) }
        if reduceMotion {
            change()
            if hold { controller.command?("sidebarTransition", ["phase": "end", "request": request]) }
            return
        }
        withAnimation(.smooth(duration: 0.26), completionCriteria: .logicallyComplete) {
            change()
        } completion: {
            if hold { controller.command?("sidebarTransition", ["phase": "end", "request": request]) }
        }
        #else
        change()
        #endif
    }
    private func toggleReaderControls() {
        // Reader chrome visibility never changes the inspector's presentation,
        // destination or width. Its controls own that independent state.
        controller.controlsVisible.toggle()
    }
    private func macSidebarShows(_ target: ReaderPanel, navigation: Int = 0) -> Bool {
        guard macSidebarVisible else { return false }
        if target == .search { return searchVisible }
        return !searchVisible && panel == target && (target != .contents || navigationTab == navigation)
    }
    private func toggleMacSidebar(_ target: ReaderPanel, navigation: Int = 0) {
        let next: ReaderPanel? = macSidebarShows(target, navigation: navigation) ? nil : target
        let change = {
            if searchVisible { closeSearch(sidebarWillRemainVisible: true) }
            guard let next else { panel = nil; return }
            #if os(macOS)
            macSidebarDestination = next
            #endif
            controller.controlsVisible = true
            if next == .search { openSearch() }
            else {
                if next == .contents { navigationTab = navigation }
                panel = next
            }
        }
        if macSidebarVisible != (next != nil) { animateSidebarChange(change) } else { change() }
    }
    private func openSearch() {
        searchRevealTask?.cancel(); searchRevealTask = nil
        if isDesktop {
            controller.controlsVisible = true
            #if os(macOS)
            macSidebarDestination = .search
            #endif
            panel = .search; adjustment = nil; searchVisible = true
        } else {
            controller.command?("searchPresentation", true)
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88)) { searchVisible = true }
        }
    }
    private func closeSearch(sidebarWillRemainVisible: Bool = false) {
        if isDesktop {
            let change = {
                if panel == .search { panel = nil }
                searchFocused = false; controller.cancelSearch()
                searchVisible = false
            }
            if macSidebarVisible && panel == .search && !sidebarWillRemainVisible { animateSidebarChange(change) }
            else { change() }
            return
        }
        searchFocused = false
        controller.cancelSearch()
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88)) { searchVisible = false }
        // Keep the EPUB box fixed through the keyboard dismissal animation.
        // Hardware-keyboard and Mac searches have no keyboard dismissal to await.
        searchRevealTask?.cancel(); searchRevealTask = nil
        if !searchKeyboardVisible { controller.command?("searchPresentation", false) }
        else {
            // A interrupted keyboard dismissal must not leave the document frozen.
            searchRevealTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, !searchVisible else { return }
                searchKeyboardVisible = false
                controller.command?("searchPresentation", false)
                searchRevealTask = nil
            }
        }
    }
    private func runSearch() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        controller.cancelSearch(); controller.results = []; controller.searching = true; controller.searchState = .searching
        controller.command?("search", ["query": query, "id": controller.searchID])
    }
    private var contents: some View {
        VStack {
        Picker("Navigation", selection: $navigationTab) { Text("Contents").tag(0); Text("Bookmarks").tag(1); Text("Notes").tag(2) }.labelsHidden().pickerStyle(.segmented).padding()
        if navigationTab == 2 {
            TextField("Search notes", text: $annotationSearch)
                .textFieldStyle(.roundedBorder).padding(.horizontal)
        }
        List {
            if navigationTab == 1 { Section("Bookmarks") {
                let bookmarks = model.readingStore(for: prepared.book)?.bookmarks[prepared.id] ?? []
                if let bookmark = currentBookmark {
                    Button("Remove bookmark on this page", systemImage: "bookmark.slash") { removeBookmark(bookmark) }
                } else {
                    Button("Bookmark this page", systemImage: "bookmark.fill") { addBookmark() }
                }
                if bookmarks.isEmpty { Text("No bookmarks yet").foregroundStyle(.secondary) }
                ForEach(bookmarks) { bookmark in
                    HStack {
                        Button(bookmark.name) { controller.returnPosition = controller.position; seek(bookmark.position); closeContentsIfCompact() }
                        Spacer()
                        Button { bookmarkName = bookmark.name; editingBookmark = bookmark } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }.accessibilityLabel("Rename bookmark \(bookmark.name)")
                        Button(role: .destructive) { removeBookmark(bookmark) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("Delete bookmark \(bookmark.name)")
                    }
                    .buttonStyle(.borderless)
                }
            }
            }
            if navigationTab == 0 { Section("Table of contents") {
                if controller.toc.isEmpty { Text("No table of contents").foregroundStyle(.secondary) }
                ForEach(controller.toc) { item in Button { controller.returnPosition = controller.position; controller.command?("location", item.id); closeContentsIfCompact() } label: { HStack { Text(item.title); Spacer(); if controller.currentChapter == item.id { Image(systemName: "checkmark").accessibilityLabel("Current chapter") } } } }
            }
            }
            if navigationTab == 2 { Section("Notes") {
                Menu("Export Reading Data", systemImage: "square.and.arrow.up") {
                    Button("Export as Markdown") { prepareExport(asJSON: false) }
                    Button("Export as JSON") { prepareExport(asJSON: true) }
                }
                if prepared.book.format == .epub {
                    Text("Select text in the book, then choose Highlight or Add Note from the text selection menu. You can use the pencil to edit a note later.")
                        .font(.callout).foregroundStyle(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if prepared.book.format == .pdf || prepared.book.format == .cbz {
                    if prepared.book.format == .pdf {
                        Text("Select text on one page, then choose Highlight selection in the reader controls.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Add note to this page", systemImage: "square.and.pencil") {
                        guard let bookFingerprint = verifiedFingerprint else { return }
                        editingNote = ReadingAnnotation(anchor: .page(controller.position.page), selectedText: nil, context: nil, note: "", color: nil, contentFingerprint: bookFingerprint)
                    }.disabled(!controller.ready || verifiedFingerprint == nil)
                }
                if verifiedFingerprint == nil {
                    Text(fingerprintFailed ? "Could not verify this book's content. Notes remain available below." : "Checking book content…")
                        .font(.caption).foregroundStyle(.secondary)
                    if fingerprintFailed { Button("Retry checking book") { fingerprintAttempt += 1 } }
                }
                let notes = (model.readingStore(for: prepared.book)?.annotations[prepared.id] ?? []).filter { note in
                    let query = annotationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                    return query.isEmpty || note.note.localizedCaseInsensitiveContains(query) || (note.selectedText?.localizedCaseInsensitiveContains(query) ?? false) || (note.context?.localizedCaseInsensitiveContains(query) ?? false)
                }
                if notes.isEmpty { Text(annotationSearch.isEmpty ? "No notes yet" : "No matching notes").foregroundStyle(.secondary) }
                ForEach(notes) { note in
                    let page = note.availablePage(fingerprint: verifiedFingerprint, pageCount: controller.pageCount)
                    let cfi = prepared.book.format == .epub ? note.availableEPUB(fingerprint: verifiedFingerprint) : nil
                    HStack(alignment: .top) {
                        Button {
                            controller.returnPosition = controller.position
                            if let cfi { controller.command?("annotationLocation", cfi) }
                            else if page != nil, case .pdf = note.anchor { controller.command?("pdfHighlight", note) }
                            else if let page { seek(ReadingPosition(page: page)) }
                            closeContentsIfCompact()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let selection = note.selectedText { Text(selection).lineLimit(3) }
                                if !note.note.isEmpty { Text(note.note).lineLimit(3) }
                                if let page { Text("Page \(page + 1)").font(.caption).foregroundStyle(.secondary) }
                                else if cfi != nil { Text("Highlighted passage").font(.caption).foregroundStyle(.secondary) }
                                else { Text("Location unavailable for this book").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(page == nil && cfi == nil)
                        Button { editingNote = note } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }.accessibilityLabel("Edit note")
                        Button(role: .destructive) { noteToDelete = note } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("Delete note")
                    }.buttonStyle(.borderless)
                }
            } }
        }.id(model.bookmarksRevision)
        }
        .task(id: "\(currentFingerprintSourceKey)|\(navigationTab)|\(fingerprintAttempt)") {
            guard navigationTab == 2, verifiedFingerprint == nil, prepared.book.format == .pdf || prepared.book.format == .cbz else { return }
            await verifyBookFingerprint()
        }
        .sheet(item: $editingNote) { note in
            PageNoteEditor(note: note, supportsUnderline: prepared.book.format == .epub, delete: annotationRemoval(for: note)) { updated in
                guard let store = model.readingStore(for: prepared.book) else { return false }
                do { try store.saveAnnotation(updated, id: prepared.id); model.bookmarksRevision += 1; return true }
                catch { model.error = UserFacingError.message(error); return false }
            }
        }
        .fileExporter(isPresented: $showingExport, document: exportDocument, contentType: exportType,
                      defaultFilename: "LibraVia Reading Data") { result in
            if case .failure = result { model.error = "Could not export the reading data." }
            exportDocument = nil
        }
        .alert("Delete annotation?", item: $noteToDelete) { note in
            Button("Delete", role: .destructive) {
                guard let store = model.readingStore(for: prepared.book) else { model.error = "The reading data is unavailable."; return }
                do { try store.removeAnnotation(note, id: prepared.id); model.bookmarksRevision += 1 }
                catch { model.error = UserFacingError.message(error) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { note in Text(note.selectedText == nil ? "This page note will be removed from this device." : "This highlight and its note will be removed from this device.") }
        .alert("Rename bookmark", item: $editingBookmark) { bookmark in
            TextField("Name", text: $bookmarkName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let store = model.readingStore(for: prepared.book) else { return }
                do { try store.renameBookmark(bookmark, id: prepared.id, name: bookmarkName); model.bookmarksRevision += 1 }
                catch { model.error = UserFacingError.message(error) }
            }.disabled(bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { _ in
            Text("Choose a name for this bookmark.")
        }
    }
    private var pdfAnnotations: [ReadingAnnotation] {
        _ = model.bookmarksRevision
        return model.readingStore(for: prepared.book)?.annotations[prepared.id] ?? []
    }
    private func verifyBookFingerprint() async {
        guard verifiedFingerprint == nil else { return }
        let sourceKey = currentFingerprintSourceKey
        fingerprintFailed = false
        do {
            let files = prepared.book.format == .pdf ? [prepared.document] : prepared.images
            let value = try await BookFingerprint.compute(files: files)
            guard !Task.isCancelled, sourceKey == currentFingerprintSourceKey else { return }
            bookFingerprint = value; fingerprintSourceKey = sourceKey
        } catch {
            if !Task.isCancelled, sourceKey == currentFingerprintSourceKey { fingerprintFailed = true }
        }
    }
    private func highlightPDFSelection() {
        guard let selection = controller.pdfSelection, let fingerprint = verifiedFingerprint else { return }
        let annotation = ReadingAnnotation(anchor: .pdf(page: selection.page, selections: selection.rectangles), selectedText: selection.text,
                                           context: nil, note: "", color: "yellow", contentFingerprint: fingerprint)
        newHighlightNote = annotation
    }
    private func closeContentsIfCompact() {
        if !wideContents {
            if macSidebarVisible { animateSidebarChange { panel = nil } }
            else { panel = nil }
        }
    }
    private func prepareExport(asJSON: Bool) {
        guard let store = model.readingStore(for: prepared.book) else { model.error = "The reading data is unavailable."; return }
        let annotations = store.annotations[prepared.id] ?? []
        let bookmarks = store.bookmarks[prepared.id] ?? []
        do {
            let data = try asJSON
                ? AnnotationExport.json(title: prepared.book.title, format: prepared.book.format, annotations: annotations, bookmarks: bookmarks)
                : AnnotationExport.markdown(title: prepared.book.title, format: prepared.book.format, annotations: annotations, bookmarks: bookmarks)
            exportType = asJSON ? .json : (UTType(filenameExtension: "md") ?? .plainText)
            exportDocument = ReadingDataDocument(data: data)
            showingExport = true
        } catch { model.error = "Could not prepare the reading data for export." }
    }
    private func updateEPUBHighlights() {
        guard prepared.book.format == .epub, controller.ready else { return }
        let highlights: [[String: Any]] = (model.readingStore(for: prepared.book)?.annotations[prepared.id] ?? []).compactMap { note in
            guard let cfi = note.availableEPUB(fingerprint: verifiedFingerprint) else { return nil }
            return ["id": note.id.uuidString, "cfi": cfi, "color": note.color ?? "yellow", "style": note.style ?? "highlight", "hasNote": !note.note.isEmpty]
        }
        controller.command?("savedHighlights", highlights)
    }
    private func addEPUBHighlight(addNote: Bool = false, menuSelection: EPUBSelection? = nil, toolColor: String? = nil) {
        guard let selected = controller.epubSelection,
              ((menuSelection?.cfi == selected.cfi && menuSelection?.text == selected.text) || (menuSelection == nil && canHighlightEPUBSelection)) else { return }
        guard let fingerprint = verifiedFingerprint else {
            model.error = fingerprintFailed ? "Could not verify this book for highlighting. Open Notes & Highlights to retry." : "Checking this book for highlighting. Please try again shortly."
            return
        }
        guard
              let store = model.readingStore(for: prepared.book) else { return }
        if var existing = (store.annotations[prepared.id] ?? []).first(where: { $0.availableEPUB(fingerprint: fingerprint) == selected.cfi }) {
            if addNote { newHighlightNote = existing }
            else if let toolColor {
                existing.color = toolColor; existing.style = "highlight"; existing.modified = Date()
                do { try store.saveAnnotation(existing, id: prepared.id); model.bookmarksRevision += 1
                    controller.epubSelection = nil; controller.command?("clearSelection", nil) }
                catch { model.error = UserFacingError.message(error) }
            } else { bookmarkFeedback = "Already highlighted" }
            return
        }
        let annotation = ReadingAnnotation(anchor: .epub(cfi: selected.cfi), selectedText: selected.text, context: selected.context, note: "", color: toolColor ?? "yellow", contentFingerprint: fingerprint)
        if addNote {
            newHighlightNote = annotation
            controller.command?("clearSelection", nil)
            return
        }
        do {
            try store.saveAnnotation(annotation, id: prepared.id)
            model.bookmarksRevision += 1; controller.epubSelection = nil
            controller.command?("clearSelection", nil); bookmarkFeedback = "Highlight added"
        } catch { model.error = UserFacingError.message(error) }
    }
    private func configureAnnotationActions() {
        controller.selectionMenuAction = { addEPUBHighlight(addNote: $0, menuSelection: $1) }
        controller.highlighterAction = { selection in
            guard let color = controller.highlighterColor else { return }
            controller.epubSelection = selection
            addEPUBHighlight(menuSelection: selection, toolColor: color)
        }
        controller.annotationAction = { id in
            guard let note = model.readingStore(for: prepared.book)?.annotations[prepared.id]?.first(where: { $0.id == id }),
                  note.availableEPUB(fingerprint: verifiedFingerprint) != nil else { return }
            newHighlightNote = note
        }
    }
    private func annotationRemoval(for note: ReadingAnnotation) -> (() -> Bool)? {
        guard model.readingStore(for: prepared.book)?.annotations[prepared.id]?.contains(where: { $0.id == note.id }) == true else { return nil }
        return { deleteAnnotation(note) }
    }
    private func deleteAnnotation(_ note: ReadingAnnotation) -> Bool {
        guard let store = model.readingStore(for: prepared.book) else { return false }
        do { try store.removeAnnotation(note, id: prepared.id); model.bookmarksRevision += 1; return true }
        catch { model.error = UserFacingError.message(error); return false }
    }
    private func seek(_ position: ReadingPosition) {
        if prepared.book.format == .epub { controller.command?("seek", ["cfi": position.cfi as Any? ?? NSNull(), "fraction": position.fraction]) }
        else { controller.command?("page", position.page) }
    }
}

private struct ReadingDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct PageNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    let note: ReadingAnnotation
    let save: (ReadingAnnotation) -> Bool
    let delete: (() -> Bool)?
    let supportsUnderline: Bool
    @State private var color: String
    @State private var style: String
    @State private var confirmingDelete = false
    @State private var text: String
    @State private var saveFailed = false
    init(note: ReadingAnnotation, supportsUnderline: Bool = false, delete: (() -> Bool)? = nil, save: @escaping (ReadingAnnotation) -> Bool) {
        self.note = note; self.save = save; self.delete = delete; self.supportsUnderline = supportsUnderline
        _text = State(initialValue: note.note); _color = State(initialValue: note.color ?? "yellow")
        _style = State(initialValue: note.style ?? "highlight")
    }
    private func saveChanges(noteText: String) {
        var updated = note; updated.note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.selectedText != nil { updated.color = color; updated.style = style }
        updated.modified = Date()
        if save(updated) { dismiss() } else { saveFailed = true }
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let selection = note.selectedText { Text(selection).lineLimit(4).padding([.horizontal, .top]) }
                if note.selectedText != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Color", selection: $color) {
                            Text("Yellow").tag("yellow"); Text("Green").tag("green"); Text("Blue").tag("blue")
                            Text("Pink").tag("pink"); Text("Purple").tag("purple")
                        }
                        if supportsUnderline {
                            Picker("Style", selection: $style) { Text("Highlight").tag("highlight"); Text("Underline").tag("underline") }
                        }
                    }.padding(.horizontal)
                }
                Text("Note").font(.headline).padding(.horizontal)
                TextEditor(text: $text).padding().accessibilityLabel("Note text")
                if let delete {
                    HStack {
                        if note.selectedText != nil && !note.note.isEmpty { Button("Remove Note Only") { saveChanges(noteText: "") } }
                        Spacer()
                        Button(note.selectedText == nil ? "Delete Note" : "Remove Highlight & Note", role: .destructive) { confirmingDelete = true }
                    }.padding([.horizontal, .bottom])
                    .confirmationDialog("Remove this annotation?", isPresented: $confirmingDelete) {
                        Button("Remove", role: .destructive) { if delete() { dismiss() } else { saveFailed = true } }
                    }
                }
            }
                .navigationTitle(note.selectedText == nil ? "Page note" : "Highlight note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveChanges(noteText: text)
                        }.disabled(note.selectedText == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.frame(minWidth: 320, minHeight: 240)
        .alert("Could not save note", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: { Text("Your changes are still here. Try saving again.") }
    }
}

private struct ReaderTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
extension EnvironmentValues {
    var readerTransitionNamespace: Namespace.ID? {
        get { self[ReaderTransitionNamespaceKey.self] }
        set { self[ReaderTransitionNamespaceKey.self] = newValue }
    }
}
struct ReaderCoverSource: ViewModifier {
    @Environment(\.readerTransitionNamespace) private var namespace
    let book: Book
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace { content.matchedTransitionSource(id: book.id, in: namespace) }
        else { content }
        #else
        content
        #endif
    }
}

/// One presentation spans download, validation, layout, and first-page reveal.
struct BookOpeningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.closeReaderWindow) private var closeReaderWindow
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: Book
    @State private var cover: Data?
    // Freeze artwork during the handoff so a late image request cannot swap it.
    @State private var openingCover: Data?
    @State private var contentReady: Bool?
    @State private var opening = false
    @State private var revealed = false
    @State private var showDots = false
    @State private var started = Date()
    private var dark: Bool { book.format == .cbz || (book.format == .epub && model.preferences.theme == "dark") }
    private var paper: Color {
        if book.format == .cbz { return .black }
        if book.format != .epub { return Color(white: 0.92) }
        switch model.preferences.theme {
        case "dark": return Color(white: 23.0 / 255)
        case "sepia": return Color(red: 244.0 / 255, green: 236.0 / 255, blue: 216.0 / 255)
        default: return .white
        }
    }
    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            if let prepared = model.reader, prepared.id == book.id {
                ReaderView(prepared: prepared) { contentReady = $0 }
                    .allowsHitTesting(opening)
                    .accessibilityHidden(!opening)
            }
            if !revealed {
                GeometryReader { geometry in
                    let width = min(geometry.size.width - 24, (geometry.size.height - 72) * 2 / 3)
                    ZStack {
                        paper.ignoresSafeArea().opacity(opening ? 0 : 1)
                        ZStack {
                            paper
                            if let cover = opening ? openingCover : availableCover, let image = platformImage(cover) {
                                image.resizable().scaledToFit()
                            } else {
                                VStack(spacing: 24) {
                                    Image(systemName: "book.closed.fill").font(.system(size: 80))
                                    Text(book.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal, 32)
                                }.foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: max(1, width), height: max(1, width * 1.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .scaleEffect(opening && !reduceMotion ? 1.10 : 1)
                        .opacity(opening ? 0 : 1)
                        if showDots && !opening {
                            VStack { Spacer(); BookLoadingDots(reduceMotion: reduceMotion).padding(.bottom, 16) }
                        }
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }.allowsHitTesting(!opening).accessibilityLabel("Opening \(book.title)")
                if !opening {
                    VStack {
                        HStack {
                            Button { close() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                                .accessibilityLabel("Cancel opening book").buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
                            Spacer()
                        }.padding(.horizontal, 16)
                        Spacer()
                    }.padding(.top, 2)
                }
            }
            if let conflict = model.conflict {
                ReadingConflictChoice(conflict: conflict) { model.conflict = nil; close() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(paper.ignoresSafeArea())
            } else if let error = model.error, model.reader == nil {
                ContentUnavailableView {
                    Label("Couldn’t open book", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("Back to library") { close() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(paper.ignoresSafeArea())
            }
        }
        // Search's keyboard must not repaginate the document behind its overlay.
        .ignoresSafeArea(.keyboard)
        .interactiveDismissDisabled()
        .preferredColorScheme(dark ? .dark : .light)
        .task { cover = await model.coverImage(book, fullSize: true) }
        .task {
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            if !opening && !revealed { withAnimation(.easeIn(duration: 0.2)) { showDots = true } }
        }
        .task(id: contentReady) {
            guard contentReady != nil, !revealed, !opening else { return }
            // Let native presentation finish and the renderer's first frame settle.
            let remaining = max(0.18, 0.65 - Date().timeIntervalSince(started))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            // Reveal the settled reader beneath the cover without a page flip.
            openingCover = availableCover
            withAnimation(reduceMotion || contentReady == false ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.38), completionCriteria: .logicallyComplete) {
                opening = true
            } completion: {
                revealed = true
            }
        }
    }
    private var availableCover: Data? {
        cover ?? model.cachedCoverImage(book, fullSize: true) ?? model.cachedCoverImage(book)
    }
    private func close() {
        model.error = nil
        #if os(macOS)
        if let closeReaderWindow { closeReaderWindow(); return }
        #endif
        model.cancelOpen(); dismiss()
    }
}

private struct BookLoadingDots: View {
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.24) % 4
            HStack(spacing: 7) {
                ForEach(0..<4) { index in
                    Circle().fill(.primary.opacity(reduceMotion || index <= phase ? 0.95 : 0.25)).frame(width: 5, height: 5)
                }
            }.padding(.horizontal, 14).padding(.vertical, 10).background(.regularMaterial, in: Capsule())
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading book")
    }
}

struct ReadingConflictChoice: View {
    @Environment(AppModel.self) private var model
    let conflict: ProgressConflict
    var cancel: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.branch").font(.largeTitle)
            Text("Choose where to resume").font(.title2)
            Text(conflict.serverFinished
                 ? "\(conflict.book.title) is marked finished on the server. Your local reading position is still saved."
                 : "\(conflict.book.title) has a different position on the server. Your unsent local progress is still saved.")
            Button("Use this device: \(label(conflict.local))") { model.resolveConflict(useLocal: true) }.buttonStyle(.borderedProminent)
            Button(conflict.serverFinished ? "Keep server: Finished" : "Use server: \(label(conflict.remote))") { model.resolveConflict(useLocal: false) }.buttonStyle(.bordered)
            Button("Cancel", role: .cancel, action: cancel)
        }.padding(32).frame(idealWidth: 440)
    }
    private func label(_ position: ReadingPosition) -> String { conflict.book.format == .epub ? "\(Int(position.fraction * 100))%" : "page \(position.page + 1)" }
}


struct ReaderSceneActions {
    var hasPanel: Bool
    var canTurn: Bool
    var canSearch: Bool
    var canBookmark: Bool
    var canIncreaseText: Bool
    var canDecreaseText: Bool
    var controls: @MainActor @Sendable () -> Void
    var previous: @MainActor @Sendable () -> Void
    var next: @MainActor @Sendable () -> Void
    var contents: @MainActor @Sendable () -> Void
    var appearance: @MainActor @Sendable () -> Void
    var search: @MainActor @Sendable () -> Void
    var increaseText: @MainActor @Sendable () -> Void
    var decreaseText: @MainActor @Sendable () -> Void
    var bookmark: @MainActor @Sendable () -> Void
    var close: @MainActor @Sendable () -> Void
}
private struct ReaderActionsKey: FocusedValueKey { typealias Value = ReaderSceneActions }
extension FocusedValues {
    var readerActions: ReaderSceneActions? {
        get { self[ReaderActionsKey.self] }
        set { self[ReaderActionsKey.self] = newValue }
    }
}
struct ReaderCommands: Commands {
    @FocusedValue(\.readerActions) private var actions
    var body: some Commands {
        CommandMenu("Reader") {
          Group {
            Button("Show or Hide Controls") { actions?.controls() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Previous Page") { actions?.previous() }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(actions?.canTurn != true)
            Button("Next Page") { actions?.next() }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(actions?.canTurn != true)
            Divider()
            Button("Contents") { actions?.contents() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Appearance") { actions?.appearance() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Search Book") { actions?.search() }.keyboardShortcut("f", modifiers: .command).disabled(actions?.canSearch != true)
            Button("Increase Text Size") { actions?.increaseText() }.keyboardShortcut("+", modifiers: .command).disabled(actions?.canIncreaseText != true)
            Button("Decrease Text Size") { actions?.decreaseText() }.keyboardShortcut("-", modifiers: .command).disabled(actions?.canDecreaseText != true)
            Button("Toggle Bookmark") { actions?.bookmark() }.keyboardShortcut("d", modifiers: .command).disabled(actions?.canBookmark != true)
            Divider()
            #if os(macOS)
            Button("Close Sidebar") { actions?.close() }.disabled(actions?.hasPanel != true)
            #endif
            #if os(macOS)
            Button("Close Panel or Book") { actions?.close() }
            #else
            Button("Close Panel or Book") { actions?.close() }.keyboardShortcut(.escape, modifiers: [])
            #endif
          }.disabled(actions == nil)
        }
    }
}
