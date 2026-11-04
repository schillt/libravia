import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ReaderPanel: String {
    case contents, appearance, search
    static func afterToggle(_ target: Self, active: Self?, visible: Bool) -> Self? {
        visible && active == target ? nil : target
    }
}

enum BookFormat: String, Codable, CaseIterable, Sendable {
    case epub, pdf, cbz, unsupported
    init(path: String?) { self = BookFormat(rawValue: (path ?? "").split(separator: ".").last.map(String.init)?.lowercased() ?? "") ?? .unsupported }
}
struct Account: Codable, Sendable {
    var server: URL
    var userID: String
    var serverID: String
    var username: String
    var token: String
    var namespace: String {
        var endpoint = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        endpoint.scheme = endpoint.scheme?.lowercased()
        endpoint.host = endpoint.host?.lowercased()
        if endpoint.port == 443 { endpoint.port = nil }
        while endpoint.path.hasSuffix("/") { endpoint.path.removeLast() }
        return "\(endpoint.string ?? server.absoluteString)|\(serverID)|\(userID)"
    }
}
struct Library: Identifiable, Hashable, Sendable { var id: String; var name: String }
struct BookAuthor: Hashable, Sendable { var name: String; var imageTag: String?; var id: String? = nil }
struct Book: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var author: String
    var summary: String
    var format: BookFormat
    var isFolder: Bool
    var imageTag: String?
    var ticks: Int64
    var libraryID: String? = nil
    var libraryName: String? = nil
    var readingStatus: CatalogReadingStatus = .notFinished
    var authors: [BookAuthor] = []
}
struct CatalogPage: Sendable { var items: [Book]; var total: Int; var nextCursor: String? = nil }
struct ReadingPosition: Codable, Equatable, Sendable {
    var fraction: Double = 0
    var page: Int = 0
    var cfi: String? = nil
    func ticks(for format: BookFormat) -> Int64 {
        format == .epub ? Int64(min(1, max(0, fraction)) * 10_000_000) : Int64(max(0, page)) * 10_000
    }
    static func from(ticks: Int64, format: BookFormat) -> Self {
        format == .epub ? Self(fraction: min(1, max(0, Double(ticks) / 10_000_000))) : Self(page: max(0, Int(ticks / 10_000)))
    }
}
struct ReadingRecord: Codable, Sendable {
    var position: ReadingPosition
    var acknowledgedTicks: Int64
    var dirty: Bool
    var updated: Date
    var title: String
    var format: BookFormat
    var syncBlock: ProgressSyncBlock? = nil
    func conflicts(with remoteTicks: Int64) -> Bool {
        dirty && remoteTicks != acknowledgedTicks && remoteTicks != position.ticks(for: format)
    }
}
enum ProgressSyncBlock: String, Codable, Sendable {
    case unavailable, conflict
}
struct Bookmark: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var position: ReadingPosition
}

/// A local anchor keeps the format-specific location and the original text for
/// recovery. A location from a different edition must never be attached silently.
enum AnnotationAnchor: Codable, Equatable, Sendable {
    case epub(cfi: String)
    case pdf(page: Int, selections: [PDFAnnotationRect])
    case page(Int)
}
struct PDFAnnotationRect: Codable, Equatable, Sendable {
    // PDFKit page coordinates, before display rotation or zoom.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}
struct PDFTextSelection: Equatable {
    var page: Int
    var rectangles: [PDFAnnotationRect]
    var text: String
}

/// Tracks a single WebKit preview capture even when its content becomes stale.
/// An invalidated request still needs a watchdog because WebKit may never reply.
struct ReaderPreviewCaptureState {
    private(set) var active: UUID?
    private(set) var timedOut = false
    private var generation = UUID()
    mutating func invalidate() { generation = UUID() }
    mutating func begin() -> UUID? {
        guard active == nil, !timedOut else { return nil }
        let request = UUID(); active = request; generation = request
        return request
    }
    /// Nil means the callback belongs to an already retired request.
    mutating func finish(_ request: UUID) -> Bool? {
        guard active == request else { return nil }
        let current = generation == request && !timedOut
        active = nil; timedOut = false
        return current
    }
    mutating func timeout(_ request: UUID) -> Bool {
        guard active == request, !timedOut else { return false }
        timedOut = true; invalidate()
        return true
    }
}

/// Ordered user requests; renderer acknowledgement remains owned by the caller.
struct ReaderRapidTurnQueue {
    private struct Entry {
        var id: UUID
        var direction: String
        var allowed: Bool?
    }
    private var pending: [Entry] = []
    private(set) var isSettling = false
    var isEmpty: Bool { pending.isEmpty }
    var hasReady: Bool { pending.first?.allowed == true }
    mutating func append(_ direction: String) { pending.append(Entry(id: UUID(), direction: direction, allowed: true)) }
    mutating func reserve(_ direction: String) -> UUID {
        let id = UUID(); pending.append(Entry(id: id, direction: direction, allowed: nil)); return id
    }
    @discardableResult mutating func resolve(_ id: UUID, allowed: Bool) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id && $0.allowed == nil }) else { return false }
        if allowed { pending[index].allowed = true } else { pending.remove(at: index) }
        return true
    }
    mutating func takeNext() -> String? {
        guard !isSettling, hasReady else { return nil }
        return pending.removeFirst().direction
    }
    mutating func beginSettling() { isSettling = true }
    mutating func endSettling() { isSettling = false }
    // Decoration may be interrupted without losing accepted turns.
    mutating func interruptDecoration() { isSettling = false }
    mutating func removeAll() { pending.removeAll(); isSettling = false }
}
struct ReadingAnnotation: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var anchor: AnnotationAnchor
    var selectedText: String?
    var context: String?
    var note: String
    var color: String?
    var style: String? = nil
    /// A content fingerprint enables an eventual renderer to detect changed editions.
    /// Unknown is not proof that an anchor is safe to apply.
    var contentFingerprint: String? = nil
    var created: Date = Date()
    var modified: Date = Date()

    func availablePage(fingerprint: String?, pageCount: Int) -> Int? {
        guard let fingerprint, let saved = contentFingerprint, saved == fingerprint else { return nil }
        let page: Int
        switch anchor {
        case .page(let index): page = index
        case .pdf(let index, let rectangles):
            guard !rectangles.isEmpty, rectangles.allSatisfy(\.isValid) else { return nil }
            page = index
        case .epub: return nil
        }
        guard page >= 0, page < pageCount else { return nil }
        return page
    }
    func availableEPUB(fingerprint: String?) -> String? {
        guard let fingerprint, let saved = contentFingerprint, saved == fingerprint,
              case .epub(let cfi) = anchor, cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")"), cfi.count <= 8192 else { return nil }
        return cfi
    }
}

/// Export is an explicit user action and does not change local reading data.
enum AnnotationExport {
    private struct Archive: Codable {
        let version: Int
        let title: String
        let format: BookFormat
        let annotations: [ReadingAnnotation]
        let bookmarks: [Bookmark]
    }
    static func json(title: String, format: BookFormat, annotations: [ReadingAnnotation], bookmarks: [Bookmark]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Archive(version: 1, title: title, format: format, annotations: annotations, bookmarks: bookmarks))
    }
    static func markdown(title: String, format: BookFormat, annotations: [ReadingAnnotation], bookmarks: [Bookmark]) -> Data {
        func quoted(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }
        func pageLabel(_ index: Int) -> String {
            guard index >= 0, index < Int.max else { return "Invalid page index: \(index)" }
            return "Page \(index + 1)"
        }
        var lines = ["# Reading notes", "", quoted(title), ""]
        for annotation in annotations.sorted(by: { $0.created < $1.created }) {
            let location: String
            switch annotation.anchor {
            case .epub(let cfi): location = "EPUB location: \(cfi)"
            case .pdf(let page, _), .page(let page): location = pageLabel(page)
            }
            lines += ["## Annotation", "", quoted(location), ""]
            if let selected = annotation.selectedText, !selected.isEmpty { lines += ["Selected text:", "", quoted(selected), ""] }
            if let context = annotation.context, !context.isEmpty { lines += ["Context:", "", quoted(context), ""] }
            if !annotation.note.isEmpty { lines += ["Note:", "", quoted(annotation.note), ""] }
        }
        for bookmark in bookmarks {
            let location = format == .epub ? (bookmark.position.cfi ?? "Location unavailable") : pageLabel(bookmark.position.page)
            lines += ["## Bookmark", "", quoted(bookmark.name), "", quoted(location), ""]
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
struct ReaderPreferences: Codable, Equatable {
    var theme = "light"
    var font = "Georgia"
    var fontSize = 20.0
    var lineHeight = 1.6
    var margin = 24.0
    var scrolling = false
    var originalFormatting = false
    var pageTransition = "slide"
    var pageTapZoneFraction = 0.2
    private enum CodingKeys: String, CodingKey { case theme, font, fontSize, lineHeight, margin, scrolling, originalFormatting, pageTransition, pageTapZoneFraction }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "light"
        font = try values.decodeIfPresent(String.self, forKey: .font) ?? "Georgia"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 20
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.6
        margin = try values.decodeIfPresent(Double.self, forKey: .margin) ?? 24
        scrolling = try values.decodeIfPresent(Bool.self, forKey: .scrolling) ?? false
        originalFormatting = try values.decodeIfPresent(Bool.self, forKey: .originalFormatting) ?? false
        pageTransition = try values.decodeIfPresent(String.self, forKey: .pageTransition) ?? "slide"
        pageTapZoneFraction = ReaderTapAction.edgeFraction(try values.decodeIfPresent(Double.self, forKey: .pageTapZoneFraction) ?? 0.2)
    }
}
enum ReaderTapAction: Equatable {
    case previous, next, controls
    static func edgeFraction(_ value: Double) -> Double { value.isFinite ? min(0.3, max(0.1, value)) : 0.2 }
    static func action(at fraction: Double, edge: Double, canTurn: Bool) -> ReaderTapAction {
        guard canTurn, fraction.isFinite, (0...1).contains(fraction) else { return .controls }
        let width = edgeFraction(edge)
        if fraction < width { return .previous }
        if fraction > 1 - width { return .next }
        return .controls
    }
}
/// EPUB whole-book pagination is a reflow estimate; PDF/CBZ page totals are exact.
enum ReaderPagination {
    static func page(at fraction: Double, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return Int((progress * Double(total - 1)).rounded()) + 1
    }
    static func bookLabel(at fraction: Double, total: Int, estimated: Bool, scrolling: Bool = false) -> String {
        if scrolling {
            let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
            return "\(Int((progress * 100).rounded()))% through book"
        }
        guard total > 0 else { return estimated ? "Book page estimate unavailable" : "Book pages unavailable" }
        return "\(estimated ? "About page" : "Page") \(page(at: fraction, total: total)) of \(total)"
    }
}
struct PreparedBook: Identifiable { var id: String { book.id }; var book: Book; var directory: URL; var document: URL; var images: [URL]; var position: ReadingPosition; var hasDurableSidecars = false }
enum ReaderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
protocol AuthenticationProvider { func login(server: URL, username: String, password: String) async throws -> Account }
protocol CatalogProvider {
    func libraries() async throws -> [Library]
    func browse(parent: String?, query: String, start: Int, resume: Bool) async throws -> CatalogPage
    func book(id: String) async throws -> Book
    func catalog(_ request: CatalogRequest) async throws -> CatalogPage
    func filterOptions(scope: CatalogScope) async throws -> CatalogFilterOptions
    func authors(scope: CatalogScope, query: String, start: Int) async throws -> CatalogAuthorPage
    func discoveryAuthors(scope: CatalogScope, query: String, start: Int) async throws -> CatalogAuthorPage
    func discoveryGenres(scope: CatalogScope) async throws -> [CatalogOption]
    func discoveryCollections(scope: CatalogScope, query: String, start: Int) async throws -> CatalogCollectionPage
    func suggestedBooks(scope: CatalogScope, limit: Int) async throws -> [Book]
    func invalidateCatalogMetadata() async
}
protocol ContentProvider { func download(_ book: Book, progress: @escaping @Sendable (Double) -> Void) async throws -> URL }
protocol ProgressProvider { func remoteTicks(id: String) async throws -> Int64; func report(id: String, ticks: Int64) async throws }

/// Descriptions are native text. Only generated, resource-free markup reaches Apple's importer.
@MainActor enum BookOverview {
    static func plainText(_ source: String) -> String {
        guard source.contains("<") || source.contains("&") else { return source }
        var text = source.replacingOccurrences(of: "(?is)<(script|style|iframe|object)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|h[1-6]|li|blockquote)\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->|<[^>]*>", with: "", options: .regularExpression)
        // Escape remaining literal brackets so metadata cannot introduce resource-bearing HTML.
        let safe = text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let decoded = try? NSAttributedString(data: Data(safe.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        return (decoded?.string ?? text).replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Only app-authored messages are displayed; system/decoder errors may carry paths or server data.
enum UserFacingError {
    static func message(_ error: Error) -> String {
        if let error = error as? ReaderError { return error.localizedDescription }
        if let error = error as? JellyfinAuthenticationError { return error.localizedDescription }
        if let error = error as? JellyfinContentError { return error.localizedDescription }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "The operation was cancelled." }
        if error is URLError { return "Could not connect securely to the server. Check your connection and try again." }
        return "The operation could not be completed. Please try again."
    }
}

/// Release intent for a horizontal page drag. Returning toward the origin is a
/// cancellation even after a substantial peek; velocity projects quick flicks.
enum ReaderTurnDecision {
    static func commits(translation: Double, velocity: Double, width: Double) -> Bool {
        guard translation.isFinite, velocity.isFinite, width.isFinite, width > 0, abs(translation) >= 18 else { return false }
        if translation * velocity < 0 && abs(velocity) > 180 { return false }
        let projected = abs(translation) + max(0, (translation < 0 ? -velocity : velocity)) * 0.14
        return projected >= width * 0.35
    }
}

/// A dictionary action is offered only for one linguistic word, not a passage.
enum ReaderDictionary {
    static func term(_ text: String) -> String? {
        guard text.utf16.count <= 256 else { return nil }
        var words: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, stop in
            if let word { words.append(word) }
            if words.count > 1 { stop = true }
        }
        return words.count == 1 ? words[0] : nil
    }
}
