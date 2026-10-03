import SwiftUI
import Observation
#if os(iOS)
import UIKit
#endif

struct ReaderCapabilities { let textSearch: Bool; let reflow: Bool; init(format: BookFormat) { textSearch = format == .epub || format == .pdf; reflow = format == .epub } }
enum ReaderPanel: String { case contents, appearance }
enum ReaderSearchState { case idle, searching, results, empty, failed }
struct ReaderLink: Identifiable { var id: String; var title: String; var context: String? = nil }
struct ReaderChapter: Identifiable {
    var id: Int { number }
    let number: Int
    let title: String
    let start: Double
    let end: Double
    func contains(_ fraction: Double) -> Bool { fraction >= start && (fraction < end || end >= 1 && fraction >= start) }
    func progress(at fraction: Double) -> Double { min(1, max(0, (fraction - start) / max(0.000_001, end - start))) }
}
@MainActor @Observable final class ReaderController {
    var position: ReadingPosition
    var pageCount = 0
    var currentChapter: String?
    var chapterPage = 0
    var chapterPageCount = 0
    var estimatedBookPages = 0
    var chapters: [ReaderChapter] = []
    var chapterSnippets: [Int: String] = [:]
    var toc: [ReaderLink] = []
    var results: [ReaderLink] = []
    var searching = false
    var searchState: ReaderSearchState = .idle
    var searchID = UUID().uuidString
    #if os(iOS)
    var controlsVisible = false
    #else
    var controlsVisible = true
    #endif
    var returnPosition: ReadingPosition?
    var navigationError = false
    func cancelSearch() { searchID = UUID().uuidString; command?("cancelSearch", nil); searching = false; if searchState == .searching { searchState = .idle } }
    func completeSearch(_ links: [ReaderLink], id: String) { guard id == searchID else { return }; results = links; searching = false; searchState = links.isEmpty ? .empty : .results }
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
    let prepared: PreparedBook
    private let onContentReady: (Bool) -> Void
    @State private var controller: ReaderController
    @State private var panel: ReaderPanel?
    @State private var searchVisible = false
    @State private var searchKeyboardVisible = false
    @FocusState private var searchFocused: Bool
    @Namespace private var glassNamespace
    @State private var navigationTab = 0
    @State private var bookmarkFeedback = ""
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var search = ""
    @State private var pageNumber = 1
    @State private var scrubFraction = 0.0
    @State private var controlsActivity = UUID()
    @State private var scrubbing = false
    @State private var showBookTitle = false
    @State private var requestedChapterSnippets: Set<Int> = []
    init(prepared: PreparedBook, onContentReady: @escaping (Bool) -> Void = { _ in }) { self.prepared = prepared; self.onContentReady = onContentReady; _controller = State(initialValue: ReaderController(position: prepared.position)) }
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            readerSurface
                .padding(.top, 40)
                .padding(.bottom, 20)
                .background(readerBackground.ignoresSafeArea())
                .overlay {
                    if searchVisible {
                        searchResults
                            .background(readerBackground.ignoresSafeArea())
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                    GlassEffectContainer(spacing: 0) { HStack {
                        if searchVisible {
                            searchField
                                .transition(.opacity)
                        } else {
                        if controller.controlsVisible || voiceOver {
                            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }
                                .accessibilityLabel("Back to library").buttonStyle(.plain).glassEffect(readerGlass.interactive(), in: Circle())
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { showBookTitle.toggle() }
                            controlsActivity = UUID()
                        } label: {
                            VStack(spacing: 2) {
                                if showBookTitle {
                                    Text(prepared.book.title).font(.caption2).foregroundStyle(readerForeground.opacity(0.85))
                                        .lineLimit(1).transition(.opacity)
                                }
                                Text(chapterHeaderLabel).font(.caption.weight(.semibold)).lineLimit(1)
                                if controller.controlsVisible, !bookmarkFeedback.isEmpty {
                                    Text(bookmarkFeedback).font(.caption2).foregroundStyle(readerSecondaryForeground).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chapterHeaderLabel), \(prepared.book.title)")
                        .accessibilityHint("Show or hide the book title")
                        if controller.controlsVisible || voiceOver, ReaderCapabilities(format: prepared.book.format).textSearch {
                            Button { openSearch() } label: { Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }
                                .accessibilityLabel("Search book").buttonStyle(.plain).glassEffect(readerGlass.interactive(), in: Circle())
                                .glassEffectID("readerSearch", in: glassNamespace)
                                .keyboardShortcut("f", modifiers: .command)
                        }
                        }
                    }}.foregroundStyle(readerForeground).padding(.horizontal, 16).frame(height: 44).padding(.top, 2)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Keep the native Menu's source mounted while the chrome fades.
                    // Removing it would dismiss an open system menu on the hide timer.
                    ZStack(alignment: .bottom) {
                        if !searchVisible && (controller.controlsVisible || voiceOver) {
                            bottomChromeFade.frame(height: 192).ignoresSafeArea(edges: .bottom)
                        }
                        readerControls.frame(maxWidth: 540).padding(.horizontal, 16).padding(.bottom, 2)
                            .opacity(!searchVisible && (controller.controlsVisible || voiceOver) ? 1 : 0)
                            .allowsHitTesting(!searchVisible && (controller.controlsVisible || voiceOver))
                            .accessibilityHidden(searchVisible || !(controller.controlsVisible || voiceOver))
                        restingProgress.frame(maxWidth: 320).padding(.horizontal, 40).offset(y: 16)
                            .opacity(!searchVisible && !(controller.controlsVisible || voiceOver) ? 1 : 0)
                            .allowsHitTesting(!searchVisible && !(controller.controlsVisible || voiceOver))
                            .accessibilityHidden(searchVisible || controller.controlsVisible || voiceOver)
                    }
                }
            .animation(.easeInOut(duration: 0.25), value: controller.controlsVisible)
            .navigationTitle(prepared.book.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .sheet(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
                NavigationStack {
                    Group {
                        if panel == .appearance { appearance }
                        else { contents }
                    }.navigationTitle(panel == .appearance ? "Appearance" : "Contents")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
                }.frame(minWidth: 320, idealWidth: 420, minHeight: 380)
                .presentationDetents([.medium, .large])
            }
        }
        .alert("Chapter unavailable", isPresented: Binding(get: { controller.navigationError }, set: { controller.navigationError = $0 })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This chapter could not be opened. Your current reading position is unchanged.")
        }
        .preferredColorScheme(darkReader ? .dark : .light)
        .onAppear { controller.changed = { model.savePosition($0, book: prepared.book) }; scrubFraction = progressFraction }
        .onChange(of: controller.ready) { _, ready in if ready { onContentReady(true) } }
        .onChange(of: controller.error) { _, error in if error != nil { onContentReady(false) } }
        .onChange(of: controller.controlsVisible) { _, visible in
            controlsActivity = UUID()
            if !visible { withAnimation(.easeOut(duration: 0.25)) { showBookTitle = false } }
        }
        .onChange(of: controller.position) { _, _ in controlsActivity = UUID(); if !scrubbing { scrubFraction = progressFraction } }
        .onChange(of: scrubFraction) { _, _ in if scrubbing { requestChapterSnippet() } }
        .onChange(of: scrubbing) { _, editing in if editing { requestChapterSnippet() } }
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
        .onChange(of: panel) { _, _ in controlsActivity = UUID(); pageNumber = controller.position.page + 1 }
        .onDisappear { controller.cancelSearch(); controller.changed = nil; Task { await model.flushProgress() } }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            searchKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            searchKeyboardVisible = false
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
                        Text(scrubChapterNumber).font(.caption2.weight(.semibold))
                        if let title = scrubChapterTitle {
                            Text(title).font(.caption).lineLimit(2)
                                .multilineTextAlignment(.center)
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
                        Button { controller.command?("previous", nil) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 56) }
                            .accessibilityLabel("Previous page").keyboardShortcut(panel == nil && !searchVisible ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                        VStack(spacing: 0) {
                            Text(bookPageLabel)
                                .font(.caption2).monospacedDigit().foregroundStyle(readerSecondaryForeground)
                                .lineLimit(1)
                            Slider(value: $scrubFraction, in: 0...1) { editing in
                                withAnimation(.easeInOut(duration: 0.18)) { scrubbing = editing }
                                controlsActivity = UUID()
                                if !editing { scrubToProgress() }
                            }
                            .accessibilityLabel("Book position")
                            .accessibilityValue(prepared.book.format == .epub ? "Approximately \(bookPageLabel)" : bookPageLabel)
                        }.padding(.horizontal, 4).frame(maxWidth: .infinity)
                        Button { controller.command?("next", nil) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 56) }
                            .accessibilityLabel("Next page").keyboardShortcut(panel == nil && !searchVisible ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
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
                                .frame(width: 54, height: 56)
                                .contentShape(Rectangle())
                        }
                        .menuOrder(.fixed)
                        .accessibilityLabel("Reader options")
                        .simultaneousGesture(TapGesture().onEnded { controlsActivity = UUID() })
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
        controller.chapters.last(where: { $0.contains(fraction) }) ?? controller.chapters.first
    }
    private var currentChapter: ReaderChapter? { chapter(at: controller.position.fraction) }
    private var chapterHeaderLabel: String {
        if prepared.book.format == .epub {
            guard let currentChapter else { return "Reading" }
            let title = currentChapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["prologue", "epilogue", "introduction", "preface", "foreword"].contains(title.lowercased()) { return title }
            if let numberRange = title.range(of: #"\bchapter\s+([0-9]+|[IVXLCDM]+)\b"#, options: [.regularExpression, .caseInsensitive]) {
                return String(title[numberRange])
            }
            return "Chapter \(currentChapter.number)"
        }
        return "Page \(controller.position.page + 1)"
    }
    private var chapterProgressFraction: Double {
        if prepared.book.format == .epub { return currentChapter?.progress(at: controller.position.fraction) ?? progressFraction }
        return progressFraction
    }
    private var chapterPagesRemainingLabel: String {
        if prepared.book.format == .epub {
            if !model.preferences.scrolling, controller.chapterPageCount > 0, controller.chapterPage > 0 {
                return "\(max(0, controller.chapterPageCount - controller.chapterPage)) pages left in chapter"
            }
            if let currentChapter, controller.estimatedBookPages > 0 {
                let chapterPages = max(1, Int((Double(controller.estimatedBookPages) * (currentChapter.end - currentChapter.start)).rounded()))
                let remaining = Int((Double(chapterPages) * (1 - chapterProgressFraction)).rounded())
                return "About \(max(0, remaining)) pages left in chapter"
            }
            return "Chapter pages unavailable"
        }
        return "\(max(0, controller.pageCount - controller.position.page - 1)) pages left in book"
    }
    private var scrubChapterNumber: String {
        if prepared.book.format == .epub, let chapter = chapter(at: scrubFraction) {
            return "Chapter \(chapter.number)"
        }
        return "Page \(Int((scrubFraction * Double(max(0, controller.pageCount - 1))).rounded()) + 1)"
    }
    private var scrubChapterTitle: String? {
        guard prepared.book.format == .epub, let chapter = chapter(at: scrubFraction) else { return nil }
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty && title.localizedCaseInsensitiveCompare("Chapter \(chapter.number)") != .orderedSame { return title }
        if let snippet = controller.chapterSnippets[chapter.number], !snippet.isEmpty { return "Opening: \(snippet)" }
        return nil
    }
    private func requestChapterSnippet() {
        guard prepared.book.format == .epub, let chapter = chapter(at: scrubFraction),
              scrubChapterTitle == nil, requestedChapterSnippets.insert(chapter.number).inserted else { return }
        controller.command?("chapterSnippet", ["fraction": scrubFraction, "number": chapter.number])
    }
    private var progressFraction: Double {
        prepared.book.format == .epub ? controller.position.fraction : Double(controller.position.page) / Double(max(1, controller.pageCount - 1))
    }
    private var bookPageLabel: String {
        let total = prepared.book.format == .epub ? controller.estimatedBookPages : controller.pageCount
        guard total > 0 else { return "Book pages unavailable" }
        let page = min(total, max(1, Int((scrubFraction * Double(max(0, total - 1))).rounded()) + 1))
        return "Page \(page) of \(total)"
    }
    private func scrubToProgress() {
        controller.returnPosition = controller.position
        if prepared.book.format == .epub { seek(ReadingPosition(fraction: scrubFraction)) }
        else { controller.command?("page", Int((scrubFraction * Double(max(0, controller.pageCount - 1))).rounded())) }
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
    private var readerSurface: some View {
        ZStack {
            switch prepared.book.format {
            case .epub: EPUBSurface(prepared: prepared, controller: controller, preferences: model.preferences)
            case .pdf: PDFSurface(prepared: prepared, controller: controller)
            case .cbz: ComicSurface(prepared: prepared, controller: controller)
            case .unsupported: ContentUnavailableView("Unsupported book", systemImage: "book.closed")
            }
            if let error = controller.error {
                ContentUnavailableView { Label("Couldn’t open book", systemImage: "exclamationmark.triangle") }
                    description: { Text(error) }
                    actions: { Button("Back to library") { dismiss() } }
                    .background(.background)
            }
        }
    }
    private func addBookmark() {
        let added = model.addBookmark(book: prepared.book, position: controller.position)
        bookmarkFeedback = model.error == nil ? (added ? "Bookmark added" : "Already bookmarked") : "Bookmark could not be saved"

    }
    private var appearance: some View {
        @Bindable var model = model
        return Form {
            if prepared.book.format == .epub {
                Picker("Theme", selection: $model.preferences.theme) { Text("Light").tag("light"); Text("Sepia").tag("sepia"); Text("Dark").tag("dark") }
                Picker("Font", selection: $model.preferences.font) { Text("Georgia").tag("Georgia"); Text("System sans serif").tag("-apple-system"); Text("Palatino").tag("Palatino") }
                LabeledContent("Text size", value: "\(Int(model.preferences.fontSize))")
                Slider(value: $model.preferences.fontSize, in: 14...36, step: 1).accessibilityLabel("Text size")
                Text("Line spacing"); Slider(value: $model.preferences.lineHeight, in: 1.2...2.2, step: 0.1).accessibilityLabel("Line spacing")
                Text("Margins"); Slider(value: $model.preferences.margin, in: 8...64, step: 4).accessibilityLabel("Margins")
                Toggle("Scroll vertically", isOn: $model.preferences.scrolling)
                if !model.preferences.scrolling {
                    Picker("Page turn", selection: $model.preferences.pageTransition) {
                        Text("Instant").tag("instant")
                        Text("Fade").tag("fade")
                        Text("Card swipe").tag("slide")
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
        }.formStyle(.grouped)
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button { runSearch() } label: {
                    Image(systemName: "magnifyingglass").frame(width: 40, height: 48)
                }
                .accessibilityLabel("Search book text")
                .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                TextField("Search in book", text: $search)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { runSearch() }
                    .onChange(of: search) { _, _ in
                        controller.cancelSearch(); controller.results = []; controller.searchState = .idle
                    }
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
        .padding(.top, 78)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func openSearch() {
        controller.command?("searchPresentation", true)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { searchVisible = true }
    }
    private func closeSearch() {
        searchFocused = false
        controller.cancelSearch()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { searchVisible = false }
        // Keep the EPUB box fixed through the keyboard dismissal animation.
        // Hardware-keyboard and Mac searches have no keyboard dismissal to await.
        if !searchKeyboardVisible { controller.command?("searchPresentation", false) }
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
                        Button(bookmark.name) { controller.returnPosition = controller.position; seek(bookmark.position); panel = nil }
                        Spacer()
                        Button(role: .destructive) { removeBookmark(bookmark) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete bookmark")
                    }
                }
            }
            }
            if navigationTab == 0 { Section("Table of contents") {
                if controller.toc.isEmpty { Text("No table of contents").foregroundStyle(.secondary) }
                ForEach(controller.toc) { item in Button { controller.returnPosition = controller.position; controller.command?("location", item.id); panel = nil } label: { HStack { Text(item.title); Spacer(); if controller.currentChapter == item.id { Image(systemName: "checkmark").accessibilityLabel("Current chapter") } } } }
            }
            }
        }.id(model.bookmarksRevision)
        }
    }
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
    private func close() { model.error = nil; model.cancelOpen(); dismiss() }
}

private struct BookLoadingDots: View {
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.24) % 4
            HStack(spacing: 7) {
                ForEach(0..<4) { index in
                    Circle().fill(.primary.opacity(reduceMotion || index >= 3 - phase ? 0.95 : 0.25)).frame(width: 5, height: 5)
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
