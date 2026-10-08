import SwiftUI
import PDFKit

struct PDFSurface: PlatformViewRepresentable {
    let prepared: PreparedBook
    let controller: ReaderController
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    private func make(_ coordinator: Coordinator) -> PDFView {
        let view = PositionPreservingPDFView()
        guard let document = PDFDocument(url: prepared.document), !document.isLocked, document.pageCount > 0 else { Task { @MainActor in controller.error = "This PDF is damaged, empty, or password protected." }; return view }
        view.document = document; view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        coordinator.view = view
        view.layoutWillChange = { [weak coordinator] in coordinator?.restoringLayout = true }
        view.layoutDidChange = { [weak coordinator] in
            coordinator?.restoringLayout = false
            coordinator?.pageChanged()
        }
        #if os(iOS)
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        #else
        let tap = NSClickGestureRecognizer(target: coordinator, action: #selector(Coordinator.clicked(_:)))
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        #endif
        if let page = document.page(at: min(max(0, prepared.position.page), document.pageCount - 1)) { view.go(to: page) }
        coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak coordinator] _ in MainActor.assumeIsolated { coordinator?.pageChanged() } }
        Task { @MainActor [weak coordinator] in
            guard let coordinator, coordinator.active, coordinator.view === view else { return }
            controller.pageCount = document.pageCount; controller.ready = true
            controller.toc = coordinator.outline(document.outlineRoot)
            coordinator.pageChanged()
            controller.command = { [weak coordinator] name, value in coordinator?.command(name, value) }
        }
        return view
    }
    #if os(macOS)
    func makeNSView(context: Context) -> PDFView { make(context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) {}
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { coordinator.cleanup() }
    #else
    func makeUIView(context: Context) -> PDFView { make(context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) {}
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) { coordinator.cleanup() }
    #endif
    @MainActor final class Coordinator: NSObject, PDFDocumentDelegate {
        var searchDocument: PDFDocument?
        var activeSearchID = ""
        var matches: [ReaderLink] = []
        weak var view: PDFView?
        let controller: ReaderController
        var observer: NSObjectProtocol?
        var selections: [String: PDFSelection] = [:]
        var restoringLayout = false
        var active = true
        init(controller: ReaderController) { self.controller = controller }
        func cleanup() {
            if let view = view as? PositionPreservingPDFView { view.layoutWillChange = nil; view.layoutDidChange = nil }
            active = false
            activeSearchID = ""; selections = [:]; matches = []
            searchDocument?.delegate = nil
            searchDocument?.cancelFindString()
            searchDocument = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            controller.command = nil
        }
        #if os(iOS)
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view, view.currentSelection == nil else { return }
            if let page = view.page(for: gesture.location(in: view), nearest: false), page.annotation(at: view.convert(gesture.location(in: view), to: page)) != nil { return }
            controller.tapped(at: gesture.location(in: view).x / max(1, view.bounds.width), canTurn: view.scaleFactor <= view.scaleFactorForSizeToFit * 1.05)
        }
        #else
        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let view, view.currentSelection == nil else { return }
            if let page = view.page(for: gesture.location(in: view), nearest: false), page.annotation(at: view.convert(gesture.location(in: view), to: page)) != nil { return }
            controller.tapped(at: gesture.location(in: view).x / max(1, view.bounds.width), canTurn: view.scaleFactor <= view.scaleFactorForSizeToFit * 1.05)
        }
        #endif
        func acceptsNavigationTap(at point: CGPoint) -> Bool {
            guard active, let view, view.currentSelection == nil else { return false }
            if let page = view.page(for: point, nearest: false), page.annotation(at: view.convert(point, to: page)) != nil { return false }
            return true
        }
        func pageChanged() {
            guard active, !restoringLayout, let view, let doc = view.document, let page = view.currentPage else { return }
            let index = doc.index(for: page)
            controller.currentChapter = controller.toc.filter { (Int($0.id) ?? Int.max) <= index }.max { (Int($0.id) ?? -1) < (Int($1.id) ?? -1) }?.id
            controller.update(ReadingPosition(fraction: Double(index) / Double(max(1, doc.pageCount)), page: index))
        }
        func outline(_ item: PDFOutline?) -> [ReaderLink] {
            guard let item, let doc = view?.document else { return [] }
            var result: [ReaderLink] = []
            if let page = item.destination?.page { result.append(ReaderLink(id: String(doc.index(for: page)), title: item.label ?? "Chapter")) }
            for index in 0..<item.numberOfChildren { result += outline(item.child(at: index)) }
            return result
        }
        func didMatchString(_ instance: PDFSelection) {
            guard activeSearchID == controller.searchID, matches.count < 200, let document = searchDocument, instance.pages.first?.document === document else { return }
            let key = "search-\(matches.count)"
            if let sourcePage = instance.pages.first, let page = view?.document?.page(at: document.index(for: sourcePage)), let selection = page.selection(for: instance.bounds(for: sourcePage)) { selections[key] = selection }
            let page = instance.pages.first.map { document.index(for: $0) + 1 } ?? 1
            let excerpt = instance.copy() as? PDFSelection
            excerpt?.extend(atStart: 80)
            excerpt?.extend(atEnd: 160)
            excerpt?.extendForLineBoundaries()
            let text = (excerpt?.string ?? instance.string ?? "Match").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            matches.append(ReaderLink(id: key, title: text, context: "Page \(page)"))
            if matches.count == 200 { controller.completeSearch(matches, id: activeSearchID); document.cancelFindString() }
        }
        func documentDidEndDocumentFind(_ notification: Notification) { guard notification.object as? PDFDocument === searchDocument else { return }; controller.completeSearch(matches, id: activeSearchID) }
        func command(_ name: String, _ value: Any?) {
            guard active, let view, let document = view.document else { return }
            switch name {
            case "next": guard view.canGoToNextPage else { return }; view.clearSelection(); view.goToNextPage(nil)
            case "previous": guard view.canGoToPreviousPage else { return }; view.clearSelection(); view.goToPreviousPage(nil)
            case "zoomIn": view.zoomIn(nil)
            case "zoomOut": view.zoomOut(nil)
            case "fit": view.autoScales = true
            case "page": if let index = value as? Int, let page = document.page(at: index) { view.clearSelection(); view.go(to: page) }
            case "location":
                if let key = value as? String, let selection = selections[key] { view.setCurrentSelection(selection, animate: true); view.go(to: selection) }
                else if let key = value as? String, let index = Int(key), let page = document.page(at: index) { view.clearSelection(); view.go(to: page) }
            case "search":
                guard let request = value as? [String: String], let query = request["query"], let id = request["id"], !query.isEmpty else { return }
                searchDocument?.delegate = nil; searchDocument?.cancelFindString()
                guard let url = document.documentURL, let searchDocument = PDFDocument(url: url) else { controller.searching = false; controller.searchState = .failed; return }
                self.searchDocument = searchDocument
                activeSearchID = id; selections = [:]; matches = []
                searchDocument.delegate = self
                searchDocument.beginFindString(query, withOptions: .caseInsensitive)
            case "cancelSearch": activeSearchID = ""; searchDocument?.delegate = nil; searchDocument?.cancelFindString()
            case "fitWidth":
                if let page = view.currentPage { view.autoScales = false; view.scaleFactor = view.bounds.width / max(1, page.bounds(for: view.displayBox).width) }
            default: break
            }
        }
    }
}

// Preserve the visible PDF destination during viewport relayout, including zoomed pages.
// This does not persist a finer-grained location: stored PDF reading data remains page-based.
final class PositionPreservingPDFView: PDFView {
    var layoutWillChange: (() -> Void)?
    var layoutDidChange: (() -> Void)?
    private var previousSize = CGSize.zero
    private var restoring = false

    #if os(macOS)
    override func layout() { preservingDestination { super.layout() } }
    #else
    override func layoutSubviews() { preservingDestination { super.layoutSubviews() } }
    #endif

    private func preservingDestination(_ layout: () -> Void) {
        let size = bounds.size
        guard !restoring, size.width > 0, size.height > 0, size != previousSize else { layout(); return }
        let destination = currentDestination
        previousSize = size
        restoring = true
        layoutWillChange?()
        layout()
        if let destination, destination.page?.document === document { go(to: destination) }
        layoutDidChange?()
        restoring = false
    }
}

#if os(iOS)
extension PDFSurface.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view else { return false }
        // Decide before PDFKit consumes a touch that dismisses its selection.
        return acceptsNavigationTap(at: touch.location(in: view))
    }
}
#else
extension PDFSurface.Coordinator: NSGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let view else { return false }
        return acceptsNavigationTap(at: view.convert(event.locationInWindow, from: nil))
    }
}
#endif
