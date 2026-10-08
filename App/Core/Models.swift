import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
struct ReaderPreferences: Codable, Equatable {
    var theme = "light"
    var font = "Georgia"
    var fontSize = 20.0
    var lineHeight = 1.6
    var margin = 24.0
    var scrolling = false
    var pageTransition = "slide"
    var pageTapZoneFraction = 0.2
    private enum CodingKeys: String, CodingKey { case theme, font, fontSize, lineHeight, margin, scrolling, pageTransition, pageTapZoneFraction }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "light"
        font = try values.decodeIfPresent(String.self, forKey: .font) ?? "Georgia"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 20
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.6
        margin = try values.decodeIfPresent(Double.self, forKey: .margin) ?? 24
        scrolling = try values.decodeIfPresent(Bool.self, forKey: .scrolling) ?? false
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
struct PreparedBook: Identifiable { var id: String { book.id }; var book: Book; var directory: URL; var document: URL; var images: [URL]; var position: ReadingPosition }
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
