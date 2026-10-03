import SwiftUI
import ImageIO

struct ComicSurface: View {
    let prepared: PreparedBook
    let controller: ReaderController
    @State private var page = 0
    @State private var zoom = 1.0
    @State private var image: Image?
    @State private var fitWidth = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let image { image.resizable().scaledToFit().frame(width: geometry.size.width * zoom, height: fitWidth ? nil : geometry.size.height * zoom).accessibilityLabel("Comic page \(page + 1)") }
                    else { ProgressView().frame(width: geometry.size.width, height: geometry.size.height) }
                }
            }.background(Color.black.opacity(0.9))
            .onTapGesture { controller.controlsVisible.toggle() }
            .simultaneousGesture(DragGesture(minimumDistance: 60).onEnded { value in guard zoom == 1, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }; setPage(page + (value.translation.width < 0 ? 1 : -1)) })
            .gesture(MagnifyGesture().onEnded { value in zoom = min(4, max(1, zoom * value.magnification)) })
        }
        .task(id: page) {
            guard prepared.images.indices.contains(page) else { return }
            let url = prepared.images[page]
            let thumbnail = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 3000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let thumbnail { image = Image(decorative: thumbnail, scale: 1); controller.ready = true }
            else { controller.error = "This comic page could not be decoded." }
        }
        .onAppear {
            page = min(max(0, prepared.position.page), prepared.images.count - 1)
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
        .onDisappear { controller.command = nil }
    }
    private func setPage(_ index: Int) {
        guard prepared.images.indices.contains(index) else { return }
        page = index; image = nil; zoom = 1
        controller.update(ReadingPosition(fraction: Double(index) / Double(max(1, prepared.images.count)), page: index))
    }
}
