import SwiftUI
import Observation
#if os(iOS)
import UIKit
#endif

struct ReaderCapabilities { let textSearch: Bool; let reflow: Bool; init(format: BookFormat) { textSearch = format == .epub || format == .pdf; reflow = format == .epub } }
enum ReaderPanel: String { case contents, appearance, search }
enum ReaderAdjustment: String, CaseIterable, Identifiable {
    case textSize = "Text size", lineSpacing = "Line spacing", margins = "Margins", edgeWidth = "Edge width"
    var id: String { rawValue }
}
enum ReaderSearchState { case idle, searching, results, empty, failed }
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
    var chapterTitle = "Reading"
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
    @Namespace private var glassNamespace
    @State private var navigationTab = 0
    @State private var bookmarkFeedback = ""
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
    @ScaledMetric(relativeTo: .caption) private var headerLineHeight = 18.0
    @ScaledMetric(relativeTo: .caption2) private var progressLineHeight = 16.0
    private var headerGutter: Double { isDesktop ? max(44, headerLineHeight * 2 + 8) : max(52, headerLineHeight * 2 + 8) }
    private var footerGutter: Double { 44 + progressLineHeight }
    private var isDesktop: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    private var readerChromeVisible: Bool { controller.controlsVisible || voiceOver }
    private var pageContainsInfo: Bool { prepared.book.format == .epub && !model.preferences.scrolling }
    private func pageChrome(safeInsets: EdgeInsets) -> ReaderPageChrome {
        ReaderPageChrome(enabled: pageContainsInfo, showChapter: keepTitleVisible, showProgress: keepProgressVisible,
                         top: headerGutter + safeInsets.top, bottom: isDesktop ? 28 : footerGutter + safeInsets.bottom,
                         textSize: max(12, progressLineHeight - 4),
                         softEdges: !isDesktop && model.preferences.pageTransition == "curl" && !reduceTransparency && contrast != .increased)
    }
    private var readerControlHeight: Double { isDesktop ? 36 : 52 }
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
          NavigationStack {
            readerSurface(chrome: pageChrome(safeInsets: pageInsets))
                #if os(macOS)
                .background(MacReaderInput(chromeVisible: readerChromeVisible, canTurn: { controller.ready && showsPageTurnButtons },
                                           turn: { controller.command?($0, nil) },
                                           trackpad: prepared.book.format == .epub ? { controller.command?("trackpad", $0) } : nil))
                #endif
                .mask {
                    if prepared.book.format == .epub && model.preferences.scrolling && !reduceTransparency && contrast != .increased {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 12)
                            Rectangle().fill(.white)
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                        }
                    } else { Rectangle().fill(.white) }
                }
                // Keep the document viewport identical when chrome appears or hides.
                // Side panels and text-size changes deliberately reflow; visibility does not.
                .padding(.top, pageContainsInfo ? 0 : headerGutter)
                .padding(.bottom, pageContainsInfo ? (isDesktop ? 72 : 0) : footerGutter)
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
                            controller.controlsVisible.toggle()
                            controlsActivity = UUID()
                        } label: {
                            VStack(spacing: 2) {
                                if !isDesktop && (controller.controlsVisible || voiceOver) {
                                    Text(prepared.book.title).font(.caption2).foregroundStyle(readerForeground.opacity(0.85))
                                        .lineLimit(1).transition(.opacity)
                                }
                                Text(chapterHeaderLabel).font(.caption.weight(.semibold)).lineLimit(1)
                                    .opacity(pageContainsInfo && !controller.controlsVisible && !voiceOver ? 0 : 1)
                                if controller.controlsVisible, !bookmarkFeedback.isEmpty {
                                    Text(bookmarkFeedback).font(.caption2).foregroundStyle(readerSecondaryForeground).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chapterHeaderLabel), \(prepared.book.title)")
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
                    .background(controller.controlsVisible || voiceOver || !pageContainsInfo ? readerBackground : .clear)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Keep the native Menu's source mounted while the chrome fades.
                    // Removing it would dismiss an open system menu on the hide timer.
                    ZStack(alignment: .bottom) {
                        if !isDesktop && !searchVisible && readerChromeVisible {
                            bottomChromeFade.frame(height: footerGutter).ignoresSafeArea(edges: .bottom)
                        }
                        readerControls.frame(maxWidth: 540)
                            .background(readerChromeVisible ? readerBackground : .clear, in: RoundedRectangle(cornerRadius: 28))
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controller.controlsVisible)
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
                            }.navigationTitle(panel == .appearance ? "Appearance" : "Contents")
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
          }
          #if os(iOS)
          .statusBarHidden(pageContainsInfo && !controller.controlsVisible && !voiceOver)
          #endif
          #if os(macOS)
          .toolbarVisibility(readerChromeVisible ? .visible : .hidden, for: .windowToolbar)
          .toolbar {
              ToolbarItemGroup(placement: .primaryAction) {
                  if ReaderCapabilities(format: prepared.book.format).textSearch {
                      Button("Search book", systemImage: "magnifyingglass", action: openSearch).disabled(!controller.ready)
                  }
                  Button("Appearance", systemImage: "textformat.size") { panel = .appearance; closeSearch() }
                  Button(searchVisible || panel != nil ? "Hide reader sidebar" : "Show reader sidebar", systemImage: "sidebar.right") {
                      if searchVisible || panel != nil { closeSearch(); panel = nil }
                      else { navigationTab = 0; panel = .contents }
                  }
              }
          }
          #endif
          #if os(macOS)
          if readerChromeVisible && (searchVisible || panel != nil) {
              // Reserve reading width without NSSplitView's full-height divider.
              // The glass panel floats on the same canvas and never covers text.
              macSidebar.frame(width: min(340, max(280, geometry.size.width * 0.34)))
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
        #if os(iOS)
        .ignoresSafeArea(.container, edges: pageContainsInfo ? .vertical : [])
        #endif
        .focusedSceneValue(\.readerActions, ReaderSceneActions(
            hasPanel: searchVisible || panel != nil,
            canTurn: controller.ready && showsPageTurnButtons && (isDesktop || (panel == nil && !searchVisible)),
            canSearch: controller.ready && ReaderCapabilities(format: prepared.book.format).textSearch,
            canBookmark: controller.ready,
            canIncreaseText: prepared.book.format == .epub && model.preferences.fontSize < 36,
            canDecreaseText: prepared.book.format == .epub && model.preferences.fontSize > 14,
            controls: { controller.controlsVisible.toggle() },
            previous: { controller.command?("previous", nil) },
            next: { controller.command?("next", nil) },
            contents: { controller.controlsVisible = true; navigationTab = 0; panel = panel == .contents ? nil : .contents },
            appearance: { controller.controlsVisible = true; panel = .appearance },
            search: { openSearch() },
            increaseText: { model.preferences.fontSize = min(36, model.preferences.fontSize + 1) },
            decreaseText: { model.preferences.fontSize = max(14, model.preferences.fontSize - 1) },
            bookmark: { if let bookmark = currentBookmark { removeBookmark(bookmark) } else { addBookmark() } },
            close: { if searchVisible { closeSearch() } else if panel != nil { panel = nil } else { closeReader() } }
        ))
        .alert("Chapter unavailable", isPresented: Binding(get: { controller.navigationError }, set: { controller.navigationError = $0 })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This chapter could not be opened. Your current reading position is unchanged.")
        }
        .preferredColorScheme(darkReader ? .dark : .light)
        .onAppear { controller.changed = { model.savePosition($0, book: prepared.book) }; scrubFraction = progressFraction; controller.pageTapZoneFraction = model.preferences.pageTapZoneFraction }
        .onChange(of: model.preferences.pageTapZoneFraction) { _, width in controller.pageTapZoneFraction = width }
        .onChange(of: controller.ready) { _, ready in if ready { onContentReady(true) } }
        .onChange(of: controller.error) { _, error in if error != nil { onContentReady(false) } }
        .onChange(of: controller.controlsVisible) { _, visible in
            controlsActivity = UUID()
        }
        .onChange(of: controller.bookPage) { _, _ in if !scrubbing { scrubFraction = progressFraction } }
        .onChange(of: controller.bookPageCount) { _, _ in if !scrubbing { scrubFraction = progressFraction } }
        .onChange(of: controller.position) { _, _ in controlsActivity = UUID(); if !scrubbing { scrubFraction = progressFraction } }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: scrubChapterHaptic)
        #endif
        .onChange(of: voiceOver) { _, _ in controlsActivity = UUID() }
        .onChange(of: searchVisible) { _, visible in controlsActivity = UUID(); searchFocused = visible }
        .task(id: controlsActivity) {
            #if os(iOS)
            guard controller.controlsVisible, !voiceOver, panel == nil, !scrubbing, !searchVisible else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, panel == nil, !scrubbing, !voiceOver, !searchVisible else { return }
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
        .onDisappear { searchRevealTask?.cancel(); controller.cancelSearch(); controller.changed = nil; Task { await model.flushProgress() } }
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
            HStack(spacing: 2) {
                        if showsPageTurnButtons {
                        Button { controller.command?("previous", nil) } label: { Image(systemName: "chevron.left").frame(width: isDesktop ? 32 : 44, height: readerControlHeight) }
                            .accessibilityLabel("Previous page").keyboardShortcut(!isDesktop && panel == nil && !searchVisible ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                        }
                        VStack(spacing: 0) {
                            Text(bookPageLabel)
                                .font(.caption2).monospacedDigit().foregroundStyle(readerSecondaryForeground)
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
                        }.padding(.horizontal, 4).frame(maxWidth: .infinity)
                        if showsPageTurnButtons {
                        Button { controller.command?("next", nil) } label: { Image(systemName: "chevron.right").frame(width: isDesktop ? 32 : 44, height: readerControlHeight) }
                            .accessibilityLabel("Next page").keyboardShortcut(!isDesktop && panel == nil && !searchVisible ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
                        }
                        if !isDesktop {
                        Rectangle().fill(readerSecondaryForeground.opacity(0.25)).frame(width: 1, height: 32).padding(.horizontal, 4)
                        Menu {
                            Button("Appearance and page turns", systemImage: "textformat.size") { panel = .appearance }
                            if currentBookmark == nil {
                                Button("Bookmark this page", systemImage: "bookmark.fill") { addBookmark() }
                            }
                            Button("Bookmarks", systemImage: "bookmark") { navigationTab = 1; panel = .contents }
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
            return controller.chapterTitle
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
        (model.store?.bookmarks[prepared.id] ?? []).first { bookmark in
            if prepared.book.format == .epub { return bookmark.position.cfi != nil && bookmark.position.cfi == controller.position.cfi }
            return bookmark.position.page == controller.position.page
        }
    }
    private func removeBookmark(_ bookmark: Bookmark) {
        do { try model.store?.removeBookmark(bookmark, id: prepared.id); model.bookmarksRevision += 1; bookmarkFeedback = "Bookmark removed" }
        catch { model.error = UserFacingError.message(error); bookmarkFeedback = "Bookmark could not be removed" }
    }
    private var readerBackground: Color {
        switch prepared.book.format {
        case .epub:
            switch model.preferences.theme {
            case "sepia": Color(red: 244.0 / 255, green: 236.0 / 255, blue: 216.0 / 255)
            case "dark": Color(red: 23.0 / 255, green: 23.0 / 255, blue: 23.0 / 255)
            default: .white
            }
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
    private func readerSurface(chrome: ReaderPageChrome) -> some View {
        ZStack {
            switch prepared.book.format {
            case .epub: EPUBSurface(prepared: prepared, controller: controller, preferences: model.preferences, chrome: chrome)
            case .pdf: PDFSurface(prepared: prepared, controller: controller)
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
            VStack(alignment: .leading, spacing: 16) { appearanceFields }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        #else
        Form { appearanceFields }.formStyle(.grouped)
        #endif
    }
    @ViewBuilder private var appearanceFields: some View {
        @Bindable var model = model
            if !isDesktop { Section("Tap to turn pages") {
                adjustmentButton(.edgeWidth)
                Text("Tap the left edge for the previous page, the right edge for the next page, and the center for controls. While scrolling an EPUB or zoomed in, taps show controls.").font(.caption).foregroundStyle(.secondary)
            }
            }
            if prepared.book.format == .epub {
                Picker("Theme", selection: $model.preferences.theme) { Text("Light").tag("light"); Text("Sepia").tag("sepia"); Text("Dark").tag("dark") }
                Picker("Font", selection: $model.preferences.font) { Text("Georgia").tag("Georgia"); Text("System sans serif").tag("-apple-system"); Text("Palatino").tag("Palatino") }
                adjustmentButton(.textSize)
                adjustmentButton(.lineSpacing)
                adjustmentButton(.margins)
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
    private func compactAdjustment(_ setting: ReaderAdjustment) -> some View {
        @Bindable var model = model
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
                Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close appearance")
                #endif
            }
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
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
    #if os(macOS)
    private var macSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(searchVisible ? "Search" : panel == .appearance ? "Appearance" : "Book navigation")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { closeSearch(); panel = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close reader sidebar")
            }.frame(height: 44).padding(.horizontal, 16)
            Picker("Reader sidebar", selection: Binding<ReaderPanel>(
                get: { searchVisible ? .search : panel ?? .contents },
                set: { value in
                    if value == .search { openSearch() }
                    else { panel = value; closeSearch() }
                })) {
                Text("Contents").tag(ReaderPanel.contents)
                Text("Appearance").tag(ReaderPanel.appearance)
                if ReaderCapabilities(format: prepared.book.format).textSearch { Text("Search").tag(ReaderPanel.search) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            if searchVisible {
                HStack {
                    MacReaderSearchField(text: $search, onSubmit: { runSearch() }, onCancel: { closeSearch() })
                        .onChange(of: search) { _, _ in
                            controller.cancelSearch(); controller.results = []; controller.searchState = .idle
                        }
                    Button("Search", action: runSearch)
                        .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12)
                searchResults
            } else if panel == .appearance {
                if let adjustment { compactAdjustment(adjustment); Spacer() }
                else { appearance.scrollContentBackground(.hidden) }
            } else { contents.scrollContentBackground(.hidden) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(8)
            .background {
                if !reduceTransparency && contrast != .increased {
                    MacReaderPanelBackdrop().clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
            .glassEffect(reduceTransparency || contrast == .increased ? .regular : .clear, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16).padding(.vertical, 12)
            // Continue the publication canvas behind the glass instead of the inspector
            // host's contrasting system background. Lists/forms hide their own fill.
            .background(readerBackground.ignoresSafeArea())
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
    private func openSearch() {
        searchRevealTask?.cancel(); searchRevealTask = nil
        if isDesktop {
            controller.controlsVisible = true
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) { panel = .search; adjustment = nil; searchVisible = true }
        } else {
            controller.command?("searchPresentation", true)
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88)) { searchVisible = true }
        }
    }
    private func closeSearch() {
        if isDesktop {
            if panel == .search { panel = nil }
            searchFocused = false; controller.cancelSearch()
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) { searchVisible = false }
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
        Picker("Navigation", selection: $navigationTab) { Text("Contents").tag(0); Text("Bookmarks").tag(1) }.pickerStyle(.segmented).padding()
        List {
            if navigationTab == 1 { Section("Bookmarks") {
                let bookmarks = model.store?.bookmarks[prepared.id] ?? []
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
                        Button(role: .destructive) { removeBookmark(bookmark) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("Delete bookmark \(bookmark.name)")
                    }
                }
            }
            }
            if navigationTab == 0 { Section("Table of contents") {
                if controller.toc.isEmpty { Text("No table of contents").foregroundStyle(.secondary) }
                ForEach(controller.toc) { item in Button { controller.returnPosition = controller.position; controller.command?("location", item.id); closeContentsIfCompact() } label: { HStack { Text(item.title); Spacer(); if controller.currentChapter == item.id { Image(systemName: "checkmark").accessibilityLabel("Current chapter") } } } }
            }
            }
        }.id(model.bookmarksRevision)
        }
    }
    private func closeContentsIfCompact() { if !wideContents { panel = nil } }
    private func seek(_ position: ReadingPosition) {
        if prepared.book.format == .epub { controller.command?("seek", ["cfi": position.cfi as Any? ?? NSNull(), "fraction": position.fraction]) }
        else { controller.command?("page", position.page) }
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
    @State private var contentReady: Bool?
    @State private var opening = false
    @State private var revealed = false
    @State private var showDots = false
    @State private var started = Date()
    private var fadeOpening: Bool { reduceMotion || contentReady == false }
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
                    let width = min(geometry.size.width - 48, (geometry.size.height - 120) * 2 / 3, 480)
                    ZStack {
                        paper.ignoresSafeArea().opacity(opening ? 0 : 1)
                        ZStack {
                            paper
                            if let cover = cover ?? model.cachedCoverImage(book, fullSize: true) ?? model.cachedCoverImage(book), let image = platformImage(cover) {
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
                        .rotation3DEffect(.degrees(opening && !fadeOpening ? -90 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.65)
                        .opacity(opening && fadeOpening ? 0 : 1)
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
            // End edge-on: rotating further exposes the back face. Let SwiftUI finish
            // the handoff instead of leaving the cover visible until a timer fires.
            withAnimation(fadeOpening ? .easeOut(duration: 0.18) : .easeIn(duration: 0.5), completionCriteria: .logicallyComplete) {
                opening = true
            } completion: {
                revealed = true
            }
        }
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
            Button("Close Panel or Book") { actions?.close() }.keyboardShortcut(.escape, modifiers: [])
          }.disabled(actions == nil)
        }
    }
}
