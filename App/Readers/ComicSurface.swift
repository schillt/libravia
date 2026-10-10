import SwiftUI
import ImageIO

struct ComicSurface: View {
    let prepared: PreparedBook
    let controller: ReaderController
    @State private var page = 0
    @State private var zoom = 1.0
    @State private var image: Image?
    @State private var fitWidth = false
    @GestureState private var magnification = 1.0
    @State private var decodeRequest = UUID()

    init(prepared: PreparedBook, controller: ReaderController) {
        self.prepared = prepared
        self.controller = controller
        _page = State(initialValue: ComicNavigation.clampedPage(prepared.position.page, count: prepared.images.count))
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let image { image.resizable().scaledToFit().frame(width: geometry.size.width * effectiveZoom, height: fitWidth ? nil : geometry.size.height * effectiveZoom).accessibilityLabel("Comic page \(page + 1)") }
                    else { ProgressView().frame(width: geometry.size.width, height: geometry.size.height) }
                }
            }.background(Color.black.opacity(0.9))
            .onTapGesture(coordinateSpace: .local) { point in controller.tapped(at: point.x / max(1, geometry.size.width), canTurn: canTurnPages) }
            .simultaneousGesture(DragGesture(minimumDistance: 60).onEnded { value in guard let direction = ComicNavigation.swipeDirection(horizontal: value.translation.width, vertical: value.translation.height, canTurn: canTurnPages) else { return }; setPage(page + direction) })
            .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }.onEnded { value in zoom = ComicNavigation.clampedZoom(zoom * value.magnification) })
        }
        .task(id: ComicPageRequest(page: page, images: prepared.images)) {
            let request = UUID()
            decodeRequest = request
            image = nil
            controller.error = nil
            guard prepared.images.indices.contains(page) else {
                controller.ready = false
                controller.error = "This comic contains no readable pages."
                return
            }
            let requestedPage = page
            let url = prepared.images[requestedPage]
            let thumbnail = await ComicNavigation.decodeThumbnail(at: url)
            guard !Task.isCancelled, decodeRequest == request, page == requestedPage,
                  prepared.images.indices.contains(page), prepared.images[page] == url else { return }
            if let thumbnail {
                image = Image(decorative: thumbnail, scale: 1)
                controller.error = nil
                controller.ready = true
                publishPosition()
            } else {
                controller.ready = false
                controller.error = "This comic page could not be decoded."
            }
        }
        .onAppear {
            page = ComicNavigation.clampedPage(prepared.position.page, count: prepared.images.count)
            controller.pageCount = prepared.images.count
            controller.command = { name, value in
                switch name {
                case "next": setPage(page + 1)
                case "previous": setPage(page - 1)
                case "page": if let value = value as? Int { setPage(value) }
                case "zoomIn": zoom = min(4, zoom + 0.25)
                case "zoomOut": zoom = max(1, zoom - 0.25)
                case "fit": zoom = 1; fitWidth = false
                case "fitWidth": zoom = 1; fitWidth = true
                default: break
                }
            }
        }
        .onChange(of: prepared.images) { _, _ in
            controller.ready = false
            decodeRequest = UUID()
            page = ComicNavigation.clampedPage(prepared.position.page, count: prepared.images.count)
            zoom = 1
            controller.pageCount = prepared.images.count
        }
        .onDisappear { decodeRequest = UUID(); controller.command = nil }
    }
    private func setPage(_ index: Int) {
        guard prepared.images.indices.contains(index), index != page else { return }
        decodeRequest = UUID()
        page = index; image = nil; zoom = 1
    }
    private var effectiveZoom: Double { ComicNavigation.clampedZoom(zoom * magnification) }
    private var canTurnPages: Bool { zoom == 1 && magnification == 1 && !fitWidth }
    private func publishPosition() {
        guard prepared.images.indices.contains(page) else { return }
        controller.update(ReadingPosition(fraction: Double(page) / Double(max(1, prepared.images.count)), page: page))
    }
}

// Page identity includes the source URLs so a replaced preparation cannot publish an old decode.
private struct ComicPageRequest: Equatable {
    let page: Int
    let images: [URL]
}

enum ComicNavigation {
    static func decodeThumbnail(at url: URL) async -> CGImage? {
        let decoding = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let result = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 3000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            return Task.isCancelled ? nil : result
        }
        let result = await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
        return Task.isCancelled ? nil : result
    }
    static func clampedPage(_ page: Int, count: Int) -> Int { min(max(0, page), max(0, count - 1)) }
    static func clampedZoom(_ value: Double) -> Double { value.isFinite ? min(4, max(1, value)) : 1 }
    static func swipeDirection(horizontal: Double, vertical: Double, canTurn: Bool) -> Int? {
        guard canTurn, horizontal.isFinite, vertical.isFinite,
              abs(horizontal) >= 60, abs(horizontal) > abs(vertical) * 1.5 else { return nil }
        return horizontal < 0 ? 1 : -1
    }
}
