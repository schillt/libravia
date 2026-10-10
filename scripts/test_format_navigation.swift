// Compile against the actual format surfaces, without launching or automating the app:
// swiftc App/Readers/PDFSurface.swift App/Readers/ComicSurface.swift scripts/test_format_navigation.swift -o /tmp/libravia-format-probe
// /tmp/libravia-format-probe Fixtures/Harbor.pdf
import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// Minimal bridge models keep this focused probe independent of networking/account state.
typealias PlatformViewRepresentable = NSViewRepresentable
struct PreparedBook { let document: URL; let images: [URL]; let position: ReadingPosition }
struct ReadingPosition { var fraction = 0.0; var page = 0 }
struct ReaderLink { var id: String; var title: String; var context: String? = nil }
enum SearchState { case idle, failed }
@MainActor final class ReaderController {
    var position = ReadingPosition()
    var pageCount = 0
    var ready = false
    var error: String?
    var currentChapter: String?
    var toc: [ReaderLink] = []
    var searchID = "active"
    var searching = false
    var searchState = SearchState.idle
    var results: [ReaderLink] = []
    var command: ((String, Any?) -> Void)?
    func update(_ position: ReadingPosition) { self.position = position }
    func tapped(at: Double, canTurn: Bool = true) {}
    func completeSearch(_ results: [ReaderLink], id: String) { if id == searchID { self.results = results } }
}

@main struct FormatNavigationProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        precondition(CommandLine.arguments.count == 2, "Pass the original Harbor PDF fixture")
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let document = PDFDocument(url: url), document.pageCount >= 2 else { fatalError("Fixture needs two pages") }
        let view = PositionPreservingPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.layout()
        let controller = ReaderController()
        let coordinator = PDFSurface.Coordinator(controller: controller)
        coordinator.view = view
        view.layoutWillChange = { coordinator.restoringLayout = true }
        view.layoutDidChange = { coordinator.restoringLayout = false; coordinator.pageChanged() }
        let last = document.pageCount - 1
        coordinator.command("page", last)
        coordinator.pageChanged()
        precondition(controller.position.page == last, "Page restoration must publish the displayed page")
        // A deliberately unsorted outline must still choose the nearest preceding chapter.
        controller.toc = [ReaderLink(id: String(last), title: "Last"), ReaderLink(id: "0", title: "First")]
        coordinator.pageChanged()
        precondition(controller.currentChapter == String(last))
        for size in [CGSize(width: 900, height: 700), CGSize(width: 400, height: 1000)] {
            view.frame.size = size
            view.layout()
            precondition(view.currentPage === document.page(at: last), "Viewport changes must retain PDF page")
            precondition(controller.position.page == last, "Relayout must not publish an intermediate page")
        }
        if let selection = document.page(at: last)?.selection(for: document.page(at: last)!.bounds(for: .cropBox)) {
            view.setCurrentSelection(selection, animate: false)
            precondition(!coordinator.acceptsNavigationTap(at: .zero), "Selection dismissal cannot also turn a page")
            coordinator.command("page", 0)
            precondition(view.currentSelection == nil, "Explicit navigation clears old search/selection highlighting")
        }
        coordinator.pageChanged()
        precondition(controller.position.page == 0)
        coordinator.command("previous", nil)
        precondition(view.currentPage === document.page(at: 0), "Book boundary must not move")
        coordinator.command("page", document.pageCount + 10)
        precondition(view.currentPage === document.page(at: 0), "Invalid page must not move")
        // A callback belonging to an obsolete search document must not add results.
        let oldDocument = PDFDocument(url: url)!
        coordinator.searchDocument = document
        coordinator.activeSearchID = controller.searchID
        if let selection = oldDocument.page(at: 0)?.selection(for: oldDocument.page(at: 0)!.bounds(for: .cropBox)) {
            coordinator.didMatchString(selection)
            precondition(coordinator.matches.isEmpty)
        }
        // Current search selection maps back into the displayed document and can jump back.
        let currentSearchDocument = PDFDocument(url: url)!
        coordinator.searchDocument = currentSearchDocument
        if let matchPage = currentSearchDocument.page(at: last), let match = matchPage.selection(for: matchPage.bounds(for: .cropBox)) {
            coordinator.didMatchString(match)
            precondition(coordinator.matches.count == 1)
            coordinator.documentDidEndDocumentFind(Notification(name: .PDFDocumentDidEndFind, object: oldDocument))
            precondition(controller.results.isEmpty, "Obsolete search completion cannot publish current results")
            coordinator.documentDidEndDocumentFind(Notification(name: .PDFDocumentDidEndFind, object: currentSearchDocument))
            precondition(controller.results.count == 1)
            coordinator.command("location", "search-0")
            coordinator.pageChanged()
            precondition(controller.position.page == last, "Search result maps to the live document")
            coordinator.command("page", 0)
            coordinator.pageChanged()
            precondition(controller.position.page == 0 && view.currentSelection == nil, "Jump-back restores page and releases search selection")
        }
        let firstPage = document.page(at: 0)!
        let annotation = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 80, height: 30), forType: .link, withProperties: nil)
        firstPage.addAnnotation(annotation)
        let point = view.convert(CGPoint(x: 60, y: 45), from: firstPage)
        precondition(!coordinator.acceptsNavigationTap(at: point), "PDF links must bypass reader tap routing")
        view.autoScales = false
        view.scaleFactor = 2
        coordinator.command("page", last)
        view.frame.size = CGSize(width: 500, height: 600)
        view.layout()
        precondition(view.currentPage === document.page(at: last), "Zoomed resize preserves page")
        precondition(abs(view.scaleFactor - 2) < 0.01, "Manual zoom survives resize")
        coordinator.cleanup()
        precondition(coordinator.activeSearchID.isEmpty && view.layoutWillChange == nil && view.layoutDidChange == nil)
        precondition(ComicNavigation.clampedPage(-4, count: 0) == 0)
        precondition(ComicNavigation.clampedPage(50, count: 4) == 3)
        precondition(ComicNavigation.swipeDirection(horizontal: -120, vertical: 5, canTurn: true) == 1)
        precondition(ComicNavigation.swipeDirection(horizontal: 120, vertical: 5, canTurn: true) == -1)
        precondition(ComicNavigation.swipeDirection(horizontal: -120, vertical: 100, canTurn: true) == nil)
        precondition(ComicNavigation.swipeDirection(horizontal: -120, vertical: 0, canTurn: false) == nil)
        precondition(ComicNavigation.swipeDirection(horizontal: .infinity, vertical: 0, canTurn: true) == nil)
        precondition(ComicNavigation.clampedZoom(.nan) == 1 && ComicNavigation.clampedZoom(10) == 4)
        // An original synthetic raster tests the production async decode/cancellation path.
        let rasterURL = FileManager.default.temporaryDirectory.appendingPathComponent("libravia-format-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: rasterURL) }
        let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let output = CGImageDestinationCreateWithURL(rasterURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, bitmap.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(output))
        let decoded = await ComicNavigation.decodeThumbnail(at: rasterURL)
        precondition(decoded?.width == 8 && decoded?.height == 8)
        let cancelled = Task { await ComicNavigation.decodeThumbnail(at: rasterURL) }
        cancelled.cancel()
        let discarded = await cancelled.value
        precondition(discarded == nil, "Cancelled decode cannot publish an image")
        print("PASS: PDF page/resize/selection/boundaries/stale-search and comic gesture/restore/decode cancellation regressions")
    }
}
