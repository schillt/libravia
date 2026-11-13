#if os(macOS)
import AppKit
import WebKit
import QuartzCore

/// Hold one painted page through a resize burst. Live layout and input never
/// wait for decoration; only a matching, settled paint reveals the new page.
@MainActor final class MacReflowBridge {
    typealias Snapshotter = @MainActor (WKWebView, WKSnapshotConfiguration, @escaping @MainActor @Sendable (NSImage?, Error?) -> Void) -> Void
    private weak var web: WKWebView?
    private let snapshot: Snapshotter
    private let softeningChanged: @MainActor (Bool, Bool) -> Void
    private let coverageChanged: @MainActor (Bool) -> Void
    private let reduceEffects: @MainActor () -> Bool
    private var generation = UUID()
    private var capture: UUID?
    private var request: String?
    private var cached: (image: NSImage, size: NSSize)?
    private var cover: ReflowPicture?
    private var quiet: DispatchWorkItem?
    private var recovery: DispatchWorkItem?
    private var reveal: DispatchWorkItem?
    private var softening = false
    private var activated = false
    private var suspended = false
    var isCovering: Bool { cover != nil }
    var isRevealing: Bool { reveal != nil }
    var cachedSize: NSSize? { cached?.size }

    init(web: WKWebView,
         snapshot: @escaping Snapshotter = { web, config, done in web.takeSnapshot(with: config, completionHandler: done) },
         softeningChanged: @escaping @MainActor (Bool, Bool) -> Void = { _, _ in },
         coverageChanged: @escaping @MainActor (Bool) -> Void = { _ in },
         reduceEffects: @escaping @MainActor () -> Bool = {
             NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
         }) {
        self.web = web; self.snapshot = snapshot
        self.softeningChanged = softeningChanged; self.reduceEffects = reduceEffects
        self.coverageChanged = coverageChanged
    }

    private var allowed: Bool { !suspended && !reduceEffects() }

    func prepare() {
        guard allowed, let web, web.window != nil,
              web.bounds.width > 0, web.bounds.height > 0 else { return }
        activated = true
        guard capture == nil, cover == nil else { return }
        let id = UUID(), epoch = generation, size = web.bounds.size
        capture = id
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds; config.afterScreenUpdates = true
        snapshot(web, config) { [weak self, weak web] image, error in
            guard let self, self.capture == id else { return }
            self.capture = nil
            guard let web, self.generation == epoch, self.allowed, self.cover == nil,
                  web.bounds.size == size, error == nil, let image else { return }
            self.cached = (image, size)
        }
    }

    func geometryWillChange() {
        generation = UUID(); capture = nil; request = nil
        holdPage()
    }

    func begin(request: String) {
        guard !request.isEmpty, request.count <= 64 else { return }
        generation = UUID(); capture = nil; self.request = request
        holdPage()
    }

    private func holdPage() {
        quiet?.cancel(); quiet = nil
        reveal?.cancel(); reveal = nil
        guard activated, allowed, let web else { clearPresentation(); return }
        // A reversal during the dissolve restores the same frozen image.
        if let cover { setOpacity(1, on: cover); cover.layer?.removeAnimation(forKey: "readerReveal") }
        else {
            let picture = ReflowPicture(image: cached?.image, size: cached?.size ?? web.bounds.size,
                                        paper: web.underPageBackgroundColor)
            picture.frame = web.bounds; picture.autoresizingMask = [.width, .height]
            web.addSubview(picture, positioned: .above, relativeTo: nil)
            cover = picture
            coverageChanged(true)
        }
        if !softening { softening = true; softeningChanged(true, false) }
        armRecovery()
    }

    func painted(request: String, width: Double? = nil, height: Double? = nil) {
        guard self.request == request, let web else { return }
        if let width, (!width.isFinite || abs(Double(web.bounds.width) - width) >= 2) { return }
        if let height, (!height.isFinite || abs(Double(web.bounds.height) - height) >= 2) { return }
        guard allowed else { invalidate(); return }
        let epoch = generation, size = web.bounds.size
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds; config.afterScreenUpdates = true
        snapshot(web, config) { [weak self, weak web] image, error in
            guard let self, let web, self.generation == epoch,
                  self.request == request, web.bounds.size == size else { return }
            guard error == nil, let image else { self.invalidate(); return }
            self.request = nil
            // Refresh the next burst's cache, never the image currently held.
            self.cached = (image, size)
            self.scheduleReveal(epoch: epoch, size: size)
        }
    }

    private func scheduleReveal(epoch: UUID, size: NSSize) {
        quiet?.cancel()
        let settled = DispatchWorkItem { [weak self] in
            guard let self, let web = self.web, self.generation == epoch,
                  self.request == nil, web.bounds.size == size else { return }
            if web.inLiveResize { self.scheduleReveal(epoch: epoch, size: size); return }
            guard self.allowed else { self.invalidate(); return }
            self.quiet = nil; self.recovery?.cancel(); self.recovery = nil
            self.finishSoftening(animated: true)
            guard let cover = self.cover else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.setOpacity(0, on: cover)
            cover.layer?.add(fade, forKey: "readerReveal")
            let completed = DispatchWorkItem { [weak self, weak cover] in
                guard let self, self.generation == epoch, self.cover === cover else { return }
                self.removeCover()
            }
            self.reveal = completed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: completed)
        }
        quiet = settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: settled)
    }

    private func armRecovery() {
        recovery?.cancel()
        let epoch = generation
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            if self.web?.inLiveResize == true { self.armRecovery(); return }
            self.invalidate()
        }
        recovery = fallback
        // Recovery only. Never expose intermediate layouts on a short timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fallback)
    }

    private func setOpacity(_ value: Float, on picture: ReflowPicture) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.layer?.opacity = value
        CATransaction.commit()
    }

    private func finishSoftening(animated: Bool) {
        guard softening else { return }
        softening = false; softeningChanged(false, animated && allowed)
    }

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value; invalidate()
        if !value { prepare() }
    }

    func invalidate() {
        generation = UUID(); capture = nil; request = nil; cached = nil
        clearPresentation()
    }

    func stop() { suspended = true; activated = false; invalidate(); web = nil }

    private func clearPresentation() {
        quiet?.cancel(); quiet = nil; recovery?.cancel(); recovery = nil
        finishSoftening(animated: false); removeCover()
    }

    private func removeCover() {
        reveal?.cancel(); reveal = nil
        let wasCovering = cover != nil
        cover?.layer?.removeAnimation(forKey: "readerReveal")
        cover?.removeFromSuperview(); cover = nil
        if wasCovering { coverageChanged(false) }
    }
}

/// Uniformly fill the moving viewport from one frozen image; text never reflows
/// in this layer. The live page and its accessibility remain underneath.
private final class ReflowPicture: NSView {
    private let image: NSImage?
    private let imageSize: NSSize
    private let paper: NSColor
    override var isFlipped: Bool { true }
    init(image: NSImage?, size: NSSize, paper: NSColor) {
        self.image = image; imageSize = size; self.paper = paper
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        setAccessibilityElement(false); setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { nil }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); bounds.fill()
        guard let image, imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        image.draw(in: NSRect(origin: .zero, size: NSSize(width: imageSize.width * scale, height: imageSize.height * scale)),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
#endif
