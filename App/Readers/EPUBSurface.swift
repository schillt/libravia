import SwiftUI
import WebKit
import UniformTypeIdentifiers

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
typealias EPUBViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
typealias EPUBViewRepresentable = UIViewControllerRepresentable
#endif

struct ReaderPageChrome: Codable, Equatable {
    var enabled = false
    var showChapter = true
    var showProgress = true
    var top: Double = 0
    var bottom: Double = 0
    var safeTop: Double = 0
    var safeBottom: Double = 0
    var textSize: Double = 12
    var softEdges = false
}

struct EPUBSurface: EPUBViewRepresentable {
    let prepared: PreparedBook
    let controller: ReaderController
    let preferences: ReaderPreferences
    var chrome = ReaderPageChrome()
    func makeCoordinator() -> Coordinator { Coordinator(prepared: prepared, controller: controller) }
    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(BookScheme(directory: prepared.directory), forURLScheme: "appbook")
        config.userContentController.add(coordinator, name: "reader")
        #if os(macOS)
        let web = ReaderMenuWebView(frame: .zero, configuration: config)
        web.readerController = controller
        web.underPageBackgroundColor = Self.paperColor(preferences.theme)
        coordinator.reflowBridge = MacReflowBridge(web: web, softeningChanged: { [weak controller = coordinator.controller] active, animated in
            guard let controller, controller.reflowSoftening != active else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.16)) { controller.reflowSoftening = active }
            } else {
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                withTransaction(transaction) { controller.reflowSoftening = active }
            }
        }, coverageChanged: { [weak coordinator] active in
            guard let coordinator else { return }
            // A complete frozen page covers the expanding strip too. Keep the
            // paper fallback available if input interrupts that coverage early.
            if !active, coordinator.reflowBridge?.cachedSize == coordinator.web?.bounds.size {
                coordinator.stopSidebarPaper()
            }
            coordinator.controller.reflowCovering = active
        })
        web.reflowGeometryWillChange = { [weak coordinator] in coordinator?.reflowBridge?.geometryWillChange() }
        web.reflowInteraction = { [weak coordinator] in coordinator?.reflowBridge?.invalidate() }
        #else
        let web = WKWebView(frame: .zero, configuration: config)
        #endif
        web.navigationDelegate = coordinator; coordinator.web = web
        #if os(macOS)
        let click = NSClickGestureRecognizer(target: coordinator, action: #selector(Coordinator.readerClick(_:)))
        web.addGestureRecognizer(click)
        #endif
        #if os(iOS)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // A status-bar tap must not move a reader to the beginning of a book.
        // Users navigate deliberately through page turns, scrolling, or contents.
        web.scrollView.scrollsToTop = false
        web.scrollView.bounces = false
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.readerTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        web.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.readerPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = coordinator
        web.scrollView.addGestureRecognizer(pan)
        web.scrollView.panGestureRecognizer.require(toFail: pan)
        web.scrollView.isScrollEnabled = false
        coordinator.pagePan = pan
        coordinator.pageTap = tap
        tap.require(toFail: pan)
        #endif
        web.load(URLRequest(url: URL(string: "appbook://local/reader/index.html")!))
        controller.command = { [weak coordinator] name, value in coordinator?.send(name, value) }
        return web
    }
    #if os(macOS)
    private static func paperColor(_ theme: String) -> NSColor {
        switch theme {
        case "dark": return NSColor(srgbRed: 23.0 / 255, green: 23.0 / 255, blue: 23.0 / 255, alpha: 1)
        case "sepia": return NSColor(srgbRed: 244.0 / 255, green: 236.0 / 255, blue: 216.0 / 255, alpha: 1)
        default: return .white
        }
    }
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) {
        web.underPageBackgroundColor = Self.paperColor(preferences.theme)
        context.coordinator.pageChrome(chrome); context.coordinator.preferences(preferences)
        context.coordinator.updateHighlighter(controller.highlighterColor)
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.updateHighlighter(nil)
        coordinator.stopSidebarPaper()
        coordinator.reflowBridge?.stop()
        (web as? ReaderMenuWebView)?.reflowGeometryWillChange = nil
        (web as? ReaderMenuWebView)?.reflowInteraction = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        coordinator.stopMacTrackpad(); coordinator.controller.command = nil
    }
    #else
    func makeUIViewController(context: Context) -> ReaderHostController {
        let web = makeWebView(context.coordinator)
        let host = ReaderHostController(web: web, coordinator: context.coordinator)
        host.loadViewIfNeeded()
        context.coordinator.host = host.view; context.coordinator.hostController = host
        return host
    }
    func updateUIViewController(_ view: ReaderHostController, context: Context) { context.coordinator.pageChrome(chrome); context.coordinator.preferences(preferences) }
    static func dismantleUIViewController(_ view: ReaderHostController, coordinator: Coordinator) {
        coordinator.web?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        coordinator.controller.command = nil; coordinator.stopSnapshots()
    }
    #endif
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let prepared: PreparedBook
        let controller: ReaderController
        weak var web: WKWebView?
        var latestPreferences = ReaderPreferences()
        var latestChrome = ReaderPageChrome()
        var loaded = false
        private var highlightPayload: [Any] = []
        #if os(macOS)
        fileprivate var reflowBridge: MacReflowBridge?
        private var sidebarPaperRequest: String?
        private var sidebarPaperLive = false
        private var sidebarPaperEnded = false
        private var sidebarPaintGeneration = UUID()
        private var sidebarPaperRecovery: DispatchWorkItem?
        private func beginSidebarPaper(_ request: String, live: Bool) {
            guard UUID(uuidString: request) != nil, let web else { return }
            sidebarPaperRecovery?.cancel()
            sidebarPaperRequest = request
            sidebarPaperLive = live; sidebarPaperEnded = false; sidebarPaintGeneration = UUID()
            controller.sidebarPaperWidth = min(controller.sidebarPaperWidth ?? Double(web.bounds.width), Double(web.bounds.width))
            let recovery = DispatchWorkItem { [weak self] in
                guard self?.sidebarPaperRequest == request else { return }
                self?.stopSidebarPaper()
            }
            sidebarPaperRecovery = recovery
            // Recovery only; renderer paint acknowledgement normally releases it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: recovery)
        }
        fileprivate func stopSidebarPaper() {
            sidebarPaperRecovery?.cancel(); sidebarPaperRecovery = nil
            sidebarPaperRequest = nil; sidebarPaperLive = false; sidebarPaperEnded = false
            sidebarPaintGeneration = UUID()
            controller.sidebarPaperWidth = nil
        }
        private func finishSidebarPaper(request: String, width: Double, settled: Bool) {
            guard request == sidebarPaperRequest, width.isFinite, width > 0, let web else { return }
            let matchesViewport = abs(Double(web.bounds.width) - width) < 2
            guard sidebarPaperLive || (matchesViewport && settled) else { return }
            guard let heldWidth = controller.sidebarPaperWidth else { return }
            if !sidebarPaperLive && width <= heldWidth { stopSidebarPaper(); return }
            let generation = UUID(); sidebarPaintGeneration = generation
            // Live layout can be behind the latest native geometry. Advance the
            // paper edge only to the width actually painted, never stretch text.
            let edge = min(CGFloat(width), web.bounds.width)
            guard edge > 0 else { return }
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = CGRect(x: max(0, edge - 2), y: 0, width: 1, height: 1)
            snapshot.snapshotWidth = 1
            snapshot.afterScreenUpdates = true
            web.takeSnapshot(with: snapshot) { [weak self, weak web] _, error in
                guard let self, let web, error == nil, request == self.sidebarPaperRequest,
                      generation == self.sidebarPaintGeneration else { return }
                let matches = abs(Double(web.bounds.width) - width) < 2
                if self.sidebarPaperLive {
                    self.controller.sidebarPaperWidth = min(width, Double(web.bounds.width))
                    guard self.sidebarPaperEnded && matches && settled else { return }
                } else if !matches { return }
                self.stopSidebarPaper()
            }
        }
        private var highlighterMonitor: Any?
        private var highlighterColor: String?
        private var highlighterGeneration = UUID()
        private var highlighterStart: (window: NSWindow, point: NSPoint, color: String, clickCount: Int, dragged: Bool)?
        fileprivate func updateHighlighter(_ color: String?) {
            guard color != highlighterColor else { return }
            highlighterColor = color; highlighterGeneration = UUID(); highlighterStart = nil
            if let highlighterMonitor { NSEvent.removeMonitor(highlighterMonitor); self.highlighterMonitor = nil }
            if let web { web.window?.invalidateCursorRects(for: web) }
            guard color != nil else { return }
            highlighterMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                if self?.handleHighlighterEscape(event) == true { return nil }
                self?.observeHighlighter(event)
                return event
            }
        }
        private func handleHighlighterEscape(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  controller.highlighterColor != nil, let window = web?.window,
                  event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return false }
            // A toolbar's native responder does not necessarily forward
            // cancelOperation to WebKit. Scope Escape to this armed reader;
            // popovers and editor sheets keep their own cancellation behavior.
            controller.highlighterColor = nil
            highlighterStart = nil
            return true
        }
        private func highlighterContains(_ event: NSEvent, web: WKWebView) -> Bool {
            guard let window = web.window, event.window === window, let content = window.contentView,
                  web.bounds.contains(web.convert(event.locationInWindow, from: nil)),
                  let parent = content.superview,
                  let hit = content.hitTest(parent.convert(event.locationInWindow, from: nil)),
                  hit === web || hit.isDescendant(of: web) else { return false }
            var view: NSView? = hit
            while let current = view, current !== web {
                if current is NSScroller { return false }
                view = current.superview
            }
            return true
        }
        private func observeHighlighter(_ event: NSEvent) {
            guard let web, let color = highlighterColor else { highlighterStart = nil; return }
            switch event.type {
            case .leftMouseDown:
                if let window = web.window, highlighterContains(event, web: web) {
                    highlighterStart = (window, event.locationInWindow, color, event.clickCount, false)
                } else { highlighterStart = nil }
            case .leftMouseDragged:
                guard var start = highlighterStart, event.window === start.window else { return }
                let point = event.locationInWindow
                if hypot(point.x - start.point.x, point.y - start.point.y) >= 3 { start.dragged = true }
                highlighterStart = start
            case .leftMouseUp:
                guard let start = highlighterStart else { return }
                highlighterStart = nil
                guard event.window === start.window, start.color == color, (start.dragged || start.clickCount >= 2),
                      highlighterContains(event, web: web) else { return }
                // A local monitor runs before WebKit receives mouse-up. Defer to
                // the next main-loop turn so its final native selection is ready.
                let generation = highlighterGeneration
                DispatchQueue.main.async { [weak self, weak web] in
                    guard let self, let web, self.highlighterGeneration == generation,
                          self.highlighterColor == color, web.window === start.window else { return }
                    self.sendRaw("commitHighlightSelection", ["request": generation.uuidString])
                }
            default: break
            }
        }
        private final class MacTrackpadTurn {
            let id = UUID()
            let direction: String
            var translation = 0.0
            var ended = false, commit = false, ready = false, previewStarted = false, boundary = false
            var image: MacPagePicture?
            init(direction: String) { self.direction = direction }
        }
        private var macTurn: MacTrackpadTurn?
        private var macWaitingCommands: [(String, Any?)] = []
        private func trackpad(_ value: [String: Any]) {
            guard let phase = value["phase"] as? String, let translation = value["translation"] as? Double,
                  translation.isFinite, let web, controller.ready, !latestPreferences.scrolling else { return }
            if phase == "begin" {
                if let previous = macTurn {
                    guard previous.ended && previous.ready && previous.commit && !previous.boundary else { return }
                    previous.image?.removeFromSuperview(); previous.image = nil; macTurn = nil
                }
                let stroke = MacTrackpadTurn(direction: translation < 0 ? "next" : "previous")
                stroke.translation = translation; macTurn = stroke
                let size = web.bounds.size
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.macTurn === stroke, !stroke.ready else { return }
                    self.cancelMacTrackpad()
                }
                web.evaluateJavaScript("window.readerCanTurn(\(web.bounds.width / 2),\(web.bounds.height / 2))") { [weak self, weak web] allowed, _ in
                    guard let self, let web, self.macTurn === stroke else { return }
                    guard allowed as? Bool == true else { self.macTurn = nil; return }
                    let configuration = WKSnapshotConfiguration(); configuration.rect = web.bounds
                    web.takeSnapshot(with: configuration) { [weak self, weak web] picture, _ in
                        guard let self, let web, self.macTurn === stroke else { return }
                        guard let picture, web.bounds.size == size else { self.macTurn = nil; return }
                        if stroke.ended && !stroke.commit { self.macTurn = nil; return }
                        let overlay = MacPagePicture(); overlay.image = picture
                        overlay.imageScaling = .scaleAxesIndependently; overlay.frame = web.bounds
                        web.addSubview(overlay); stroke.image = overlay; stroke.previewStarted = true
                        self.sendRaw("previewTurn", stroke.direction)
                    }
                }
            } else if let stroke = macTurn {
                stroke.translation = translation
                if phase == "end" { stroke.ended = true; stroke.commit = value["commit"] as? Bool == true }
                updateMacTrackpad(stroke)
            }
        }
        private func updateMacTrackpad(_ stroke: MacTrackpadTurn) {
            guard macTurn === stroke, stroke.ready, let web, let image = stroke.image else { return }
            if stroke.ended {
                let commit = stroke.commit && !stroke.boundary
                sendRaw(commit ? "commitTurn" : "cancelTurn", nil)
                let origin = NSPoint(x: commit ? web.bounds.width * (stroke.direction == "next" ? -1 : 1) : 0, y: 0)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
                    image.animator().setFrameOrigin(origin)
                } completionHandler: { [weak self, weak image] in
                    Task { @MainActor in
                        guard let self, self.macTurn === stroke else { return }
                        if commit { image?.removeFromSuperview(); stroke.image = nil; self.macTurn = nil }
                        // Cancellation removes its cover only after exact CFI restoration.
                    }
                }
            } else {
                let width = web.bounds.width
                let translation = stroke.translation * (stroke.boundary ? 0.12 : 1)
                let x = stroke.direction == "next" ? min(0, max(-width, translation)) : max(0, min(width, translation))
                image.setFrameOrigin(NSPoint(x: x, y: 0))
            }
        }
        fileprivate func stopMacTrackpad() {
            macTurn?.image?.removeFromSuperview(); macTurn?.image = nil; macTurn = nil; macWaitingCommands.removeAll()
        }
        private func drainMacCommands() {
            let waiting = macWaitingCommands; macWaitingCommands.removeAll()
            for (command, value) in waiting { sendRaw(command, value) }
        }
        fileprivate func cancelMacTrackpad() {
            guard let stroke = macTurn else { return }
            stroke.ended = true; stroke.commit = false
            if stroke.previewStarted { sendRaw("cancelTurn", nil) }
            else { stroke.image?.removeFromSuperview(); stroke.image = nil; macTurn = nil }
        }
        #endif
        #if os(iOS)
        weak var host: UIView?
        weak var hostController: ReaderHostController?
        var curlTurning = false
        private var searchPresented = false
        private var curlToken: UUID?
        private var curlCompletion: (() -> Void)?
        private var curlBlockedRegions: [CGRect] = []
        private var textSelectionActive = false
        func viewportDidChange() {
            let interruptedCurl = curlTurning
            interruptDecoration()
            if interruptedCurl { resetCurl() }
            invalidateSnapshots(); cachedPage = nil; captureState.invalidate()
            finishCardIfReady(); drainTurns()
        }
        func cachedAdjacentPage(_ direction: String) -> UIImage? {
            guard cachedPage != nil, cachedPageCFI == controller.position.cfi, cachedPageSize == web?.bounds.size,
                  cachedPagePreferences == latestPreferences, cachedPageChrome == latestChrome else { return nil }
            return adjacentPages[direction]
        }
        private var contentBounds: CGRect {
            guard let web else { return .zero }
            return latestChrome.enabled ? CGRect(x: 0, y: latestChrome.top, width: web.bounds.width,
                height: max(0, web.bounds.height - latestChrome.top - latestChrome.bottom)) : web.bounds
        }
        func canCatchUpCurl(at point: CGPoint) -> Bool {
            guard controller.ready, !searchPresented, !latestPreferences.scrolling, !textSelectionActive,
                  let web, web.bounds.contains(point), contentBounds.contains(point) else { return false }
            return true
        }
        func canCurl(at point: CGPoint) -> Bool {
            guard canCatchUpCurl(at: point), !curlTurning, turnToken == nil, pendingCard == nil,
                  !curlBlockedRegions.contains(where: { $0.contains(point) }) else { return false }
            // Until both directions are known, a gesture toward the uncached
            // side would otherwise be rejected before reaching the queue.
            return ["previous", "next"].allSatisfy { cachedAdjacentPage($0) != nil || unavailablePages.contains($0) }
        }
        func resumeQueuedTurns() { drainTurns() }
        var curlInputBusy: Bool { curlTurning || turnToken != nil || !queuedTurns.isEmpty }
        func queueCurlCatchUp(_ direction: String, start: CGPoint) {
            guard let web, controller.ready, !latestPreferences.scrolling, !searchPresented,
                  !textSelectionActive, contentBounds.contains(start) else { return }
            queueGuardedTurn(direction, start: start, web: web)
        }
        private func resetCurl() {
            curlCompletion = nil; curlToken = nil; curlTurning = false
            hostController?.resetCurlSurface()
        }
        private func recoverTurn(_ token: UUID) {
            guard turnToken == token || pendingCard?.turnID == token || curlToken == token else { return }
            abortInteractive(); resetCurl()
            outgoingPage?.removeFromSuperview(); outgoingPage = nil; turnToken = nil
            invalidateSnapshots(); cachedPage = nil
            controller.error = "The page turn could not finish. Queued page turns have been stopped. Close this book and reopen it before continuing."
        }
        func commitCurl(_ direction: String, completion: @escaping () -> Void) {
            let token = UUID(); curlToken = token; curlCompletion = completion
            sendNativeTurn(direction, token: token)
        }
        weak var pagePan: UIPanGestureRecognizer?
        weak var pageTap: UITapGestureRecognizer?
        private var panStart: CGPoint?
        private var turnToken: UUID?
        private var outgoingPage: UIImageView?
        private var settlingPage: UIImageView?
        private final class InteractiveSwipe {
            let start: CGPoint
            let originCFI: String?
            var translation: CGFloat = 0
            var velocity: CGFloat = 0
            var ended = false
            var allowed: Bool?
            var image: UIImage?
            var outgoing: UIImageView?
            var incoming: UIImageView?
            var direction: String?
            var incomingDirection: String?
            var incomingSnapshotRequest: String?
            var readyTranslation: CGFloat = 0
            var dragBias: CGFloat = 0
            var animationDone = false
            var mainReady = false
            let turnID = UUID()
            var waitedForPreview = false
            var shouldCommit = false
            var guardReservation: UUID?
            init(start: CGPoint, originCFI: String?) { self.start = start; self.originCFI = originCFI }
        }
        private var interactiveSwipe: InteractiveSwipe?

        private var interactiveFinishing = false
        private var snapshotWeb: WKWebView?
        private var snapshotBooted = false
        private var snapshotBusyRequest: String?
        private var captureState = ReaderPreviewCaptureState()
        private var currentCapturePending = false
        private var snapshotOrigin: [String: Any]?
        private var snapshotRequest: String?
        private var snapshotKey: String?
        private var snapshotDirections: [String] = []
        private var adjacentPages: [String: UIImage] = [:]
        private var unavailablePages: Set<String> = []
        private var pendingCard: InteractiveSwipe?
        private var cardAnimator: UIViewPropertyAnimator?
        private var queuedTurns = ReaderRapidTurnQueue()
        private var interactionEpoch = UUID()
        private func invalidateSnapshots() {
            snapshotRequest = nil; snapshotKey = nil; snapshotDirections.removeAll()
            adjacentPages.removeAll(); unavailablePages.removeAll()
        }
        private func warmAdjacentPages() {
            guard controller.ready, !searchPresented, !latestPreferences.scrolling,
                  ["slide", "curl"].contains(latestPreferences.pageTransition), !UIAccessibility.isReduceMotionEnabled,
                  let web, let host, let cfi = controller.position.cfi, web.bounds.width > 0 else { return }
            let key = cfi + "|" + String(describing: web.bounds.size) + "|" + String(describing: latestPreferences) + "|" + String(describing: latestChrome)
            guard key != snapshotKey else { return }
            invalidateSnapshots(); snapshotKey = key
            let request = UUID().uuidString; snapshotRequest = request
            web.evaluateJavaScript("window.readerSnapshotOrigin()") { [weak self] result, _ in
                guard let self, self.snapshotRequest == request else { return }
                guard let origin = result as? [String: Any], origin["cfi"] as? String == self.controller.position.cfi,
                      let size = (origin["hostSize"] ?? origin["size"]) as? [String:Double],
                      abs((size["width"] ?? 0) - web.bounds.width) < 1,
                      abs((size["height"] ?? 0) - web.bounds.height) < 1 else {
                    self.invalidateSnapshots(); return
                }
                self.curlBlockedRegions = (origin["regions"] as? [[String:Double]] ?? []).map {
                    CGRect(x:$0["x"] ?? 0,y:$0["y"] ?? 0,width:$0["width"] ?? 0,height:$0["height"] ?? 0)
                }
                self.snapshotOrigin = origin; self.snapshotDirections = ["next", "previous"]
                if self.snapshotWeb == nil {
                    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
                    config.setURLSchemeHandler(BookScheme(directory: self.prepared.directory), forURLScheme: "appbook")
                    config.userContentController.add(self, name: "reader")
                    let renderer = WKWebView(frame: host.bounds, configuration: config)
                    // A full-page preview must use the same viewport as the live
                    // reader. UIKit's default automatic inset adds safe-area bands
                    // here even though the trusted shell already reserves them.
                    renderer.scrollView.contentInsetAdjustmentBehavior = .never
                    renderer.scrollView.scrollsToTop = false
                    renderer.scrollView.isScrollEnabled = false
                    renderer.scrollView.bounces = false
                    renderer.isUserInteractionEnabled = false; renderer.accessibilityElementsHidden = true
                    renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]; renderer.navigationDelegate = self
                    host.insertSubview(renderer, at: 0); self.snapshotWeb = renderer
                    renderer.load(URLRequest(url: URL(string: "appbook://local/reader/index.html")!))
                } else { self.captureAdjacentPage() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard self?.snapshotRequest == request, self?.snapshotDirections.isEmpty == false else { return }
                self?.invalidateSnapshots()
            }
        }
        private func captureAdjacentPage() {
            guard snapshotBooted, let origin = snapshotOrigin, let request = snapshotRequest,
                  let direction = snapshotDirections.first, snapshotBusyRequest == nil else { return }
            snapshotBusyRequest = request
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.snapshotBusyRequest == request else { return }
                self.invalidateSnapshots(); self.releaseSnapshotRenderer()
            }
            let relative = String(prepared.document.path.dropFirst(prepared.directory.path.count + 1))
            var url = URLComponents(); url.scheme = "appbook"; url.host = "local"; url.path = "/publication/" + relative
            let value: [String: Any] = ["url":url.url!.absoluteString,"origin":origin,"preferences":preferencesObject(),"direction":direction,"request":request,"highlights":highlightPayload]
            guard let data = try? JSONSerialization.data(withJSONObject: ["name":"snapshot","value":value]), let json = String(data:data,encoding:.utf8) else { return }
            snapshotWeb?.evaluateJavaScript("void window.readerCommand(\(json))")
        }
        private func receiveSnapshot(_ value: [String: Any], kind: String) {
            if kind == "boot" { snapshotBooted = true; captureAdjacentPage(); return }
            guard let request = value["request"] as? String, request == snapshotBusyRequest else { return }
            guard request == snapshotRequest else {
                snapshotBusyRequest = nil; captureAdjacentPage(); return
            }
            guard kind == "snapshotReady", let direction = value["direction"] as? String,
                  direction == snapshotDirections.first else {
                invalidateSnapshots(); releaseSnapshotRenderer(); return
            }
            if value["exists"] as? Bool != true {
                snapshotBusyRequest = nil
                // An unchanged preview can be a not-yet-loaded interior page.
                // Only a proven book edge may suppress a committed turn.
                if value["boundary"] as? Bool == true { unavailablePages.insert(direction) }
                snapshotDirections.removeFirst(); captureAdjacentPage()
                if snapshotDirections.isEmpty { hostController?.refreshNeighbours() }
                if let swipe = interactiveSwipe { updateInteractive(swipe) }
                return
            }
            let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
            snapshotWeb?.takeSnapshot(with: config) { [weak self] image, _ in
                guard let self, self.snapshotBusyRequest == request else { return }
                self.snapshotBusyRequest = nil
                guard self.snapshotRequest == request, direction == self.snapshotDirections.first else {
                    self.captureAdjacentPage(); return
                }
                if let image { self.adjacentPages[direction] = image }
                self.snapshotDirections.removeFirst()
                if let swipe = self.interactiveSwipe { swipe.readyTranslation = swipe.translation; self.updateInteractive(swipe) }
                self.captureAdjacentPage()
                if self.snapshotDirections.isEmpty { self.hostController?.refreshNeighbours() }
            }
        }
        private func releaseSnapshotRenderer() {
            snapshotWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
            snapshotWeb?.navigationDelegate = nil; snapshotWeb?.stopLoading()
            snapshotWeb?.removeFromSuperview(); snapshotWeb = nil
            snapshotBooted = false; snapshotBusyRequest = nil; snapshotOrigin = nil
        }
        func stopSnapshots() {
            abortInteractive(); invalidateSnapshots(); releaseSnapshotRenderer()
            cachedPage = nil; captureState = ReaderPreviewCaptureState(); currentCapturePending = false
            curlCompletion = nil; curlToken = nil; curlTurning = false
        }
        func sourcePageImage() -> UIImage? { cachedPage }
        private var cachedPage: UIImage?
        private var cachedPageSize: CGSize = .zero
        private var cachedPageCFI: String?
        private var cachedPagePreferences: ReaderPreferences?
        private var cachedPageChrome: ReaderPageChrome?
        #endif
        init(prepared: PreparedBook, controller: ReaderController) { self.prepared = prepared; self.controller = controller }
        #if os(macOS)
        @objc func readerClick(_ gesture: NSClickGestureRecognizer) {
            reflowBridge?.invalidate()
            guard controller.highlighterColor == nil, let web else { return }
            let point = gesture.location(in: web)
            // WebKit uses top-left document coordinates; NSView may be unflipped.
            let y = web.isFlipped ? point.y : web.bounds.height - point.y
            send("gesture", ["action": "pointerTap", "x": point.x, "y": y])
        }
        #endif
        #if os(iOS)
        @objc func readerTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: web)
            guard !textSelectionActive, !controller.epubSelectionActive else { return }
            send("gesture", ["action": "tap", "x": point.x, "y": point.y])
        }
        @objc func readerPan(_ gesture: UIPanGestureRecognizer) {
            guard let web else { return }
            if latestPreferences.pageTransition == "slide", !UIAccessibility.isReduceMotionEnabled {
                interactivePan(gesture, in: web)
                return
            }
            switch gesture.state {
            case .began:
                finishSettlingForInput()
                panStart = gesture.location(in: web)
            case .ended:
                defer { panStart = nil }
                guard let start = panStart, !latestPreferences.scrolling else { return }
                let movement = gesture.translation(in: web)
                guard abs(movement.x) > abs(movement.y) * 1.5,
                      ReaderTurnDecision.commits(translation: movement.x, velocity: gesture.velocity(in: web).x, width: web.bounds.width) else { return }
                queueGuardedTurn(movement.x < 0 ? "next" : "previous", start: start, web: web)
            case .cancelled, .failed:
                panStart = nil
            default: break
            }
        }
        private func interactivePan(_ gesture: UIPanGestureRecognizer, in web: WKWebView) {
            switch gesture.state {
            case .began:
                finishSettlingForInput()
                if turnToken != nil || pendingCard != nil || interactiveSwipe != nil || !queuedTurns.isEmpty { panStart = gesture.location(in: web); return }
                guard interactiveSwipe == nil else { return }
                let swipe = InteractiveSwipe(start: gesture.location(in: web), originCFI: controller.position.cfi)
                swipe.translation = gesture.translation(in: web).x
                interactiveSwipe = swipe
                warmAdjacentPages()
                if cachedPageSize == web.bounds.size, cachedPageCFI == controller.position.cfi,
                   cachedPagePreferences == latestPreferences, cachedPageChrome == latestChrome { swipe.image = cachedPage }
                let point = swipe.start
                let epoch = interactionEpoch
                web.evaluateJavaScript("window.readerCanTurn(\(point.x),\(point.y))") { [weak self, swipe] result, error in
                    guard let self, self.interactionEpoch == epoch else { return }
                    if let reservation = swipe.guardReservation {
                        if error != nil { self.controller.error = "The EPUB reader could not validate a page turn." }
                        self.queuedTurns.resolve(reservation, allowed: result as? Bool ?? false)
                        self.drainTurns(); return
                    }
                    guard self.interactiveSwipe === swipe else { return }
                    swipe.allowed = result as? Bool ?? false
                    if swipe.allowed == false { self.cancelInteractive(swipe, animated: true) }
                    else { self.updateInteractive(swipe) }
                }
                if swipe.image == nil {
                    web.takeSnapshot(with: nil) { [weak self, weak swipe] image, _ in
                        guard let self, let swipe, self.interactiveSwipe === swipe else { return }
                        swipe.image = image; self.updateInteractive(swipe)
                    }
                }
            case .changed:
                guard panStart == nil, let swipe = interactiveSwipe else { return }
                swipe.translation = gesture.translation(in: web).x
                swipe.velocity = gesture.velocity(in: web).x
                updateInteractive(swipe)
            case .ended, .cancelled, .failed:
                if let start = panStart {
                    defer { panStart = nil }
                    let movement = gesture.translation(in: web).x, velocity = gesture.velocity(in: web).x
                    if gesture.state == .ended, ReaderTurnDecision.commits(translation: movement, velocity: velocity, width: web.bounds.width) {
                        queueGuardedTurn(movement < 0 ? "next" : "previous", start: start, web: web)
                    }
                    return
                }
                guard let swipe = interactiveSwipe else { return }
                swipe.translation = gesture.translation(in: web).x
                swipe.velocity = gesture.velocity(in: web).x; swipe.ended = true
                swipe.shouldCommit = gesture.state == .ended && ReaderTurnDecision.commits(translation: swipe.translation, velocity: swipe.velocity, width: web.bounds.width)
                if swipe.shouldCommit && swipe.allowed == nil {
                    // Reserve this turn before later swipes can complete; the guard
                    // callback decides whether its reservation is eligible.
                    swipe.guardReservation = queuedTurns.reserve(swipe.translation < 0 ? "next" : "previous")
                    swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview()
                    interactiveSwipe = nil
                    drainTurns(); return
                }
                updateInteractive(swipe)
            default: break
            }
        }
        private func updateInteractive(_ swipe: InteractiveSwipe) {
            guard interactiveSwipe === swipe, swipe.allowed == true, let web, let host else { return }
            if abs(swipe.translation) >= 8 { swipe.direction = swipe.translation < 0 ? "next" : "previous" }
            if swipe.outgoing == nil, let image = swipe.image {
                let outgoing = UIImageView(image: image)
                outgoing.frame = host.bounds; outgoing.contentMode = .scaleToFill
                outgoing.isUserInteractionEnabled = false
                outgoing.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                outgoing.layer.shadowColor = UIColor.black.cgColor
                outgoing.layer.shadowOpacity = 0.18; outgoing.layer.shadowRadius = 6
                outgoing.layer.shadowPath = UIBezierPath(rect: outgoing.bounds).cgPath
                host.addSubview(outgoing); swipe.outgoing = outgoing
            }
            guard let outgoing = swipe.outgoing, let direction = swipe.direction else {
                if swipe.ended {
                    if swipe.shouldCommit, let direction = swipe.direction, !unavailablePages.contains(direction) {
                        completeInteractive(swipe)
                    } else { cancelInteractive(swipe, animated: true) }
                }
                return
            }
            if swipe.incomingDirection != direction {
                swipe.incoming?.removeFromSuperview(); swipe.incoming = nil; swipe.incomingDirection = direction; swipe.incomingSnapshotRequest = nil
            }
            if swipe.incoming == nil, let image = adjacentPages[direction] {
                let incoming = UIImageView(image: image)
                incoming.frame = host.bounds; incoming.contentMode = .scaleToFill
                incoming.isUserInteractionEnabled = false; incoming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.insertSubview(incoming, belowSubview: outgoing); swipe.incoming = incoming
                swipe.incomingSnapshotRequest = snapshotRequest
                // Keep a cold drag continuous when its genuine preview arrives.
                swipe.dragBias = swipe.waitedForPreview ? swipe.translation - outgoing.transform.tx : 0
                swipe.readyTranslation = swipe.waitedForPreview ? swipe.translation : 0
                swipe.waitedForPreview = false
            }
            let width = max(1, web.bounds.width)
            let offset: CGFloat
            if swipe.incoming != nil {
                let travelled = abs(swipe.translation - swipe.readyTranslation)
                let bias = swipe.dragBias * max(0, 1 - travelled / (width * 0.35))
                offset = swipe.translation - bias
            } else { swipe.waitedForPreview = true; offset = swipe.translation * 0.08 }
            outgoing.transform = CGAffineTransform(translationX: max(-width, min(width, offset)), y: 0)
            if swipe.ended {
                if swipe.shouldCommit && !unavailablePages.contains(direction) { completeInteractive(swipe) }
                else { cancelInteractive(swipe, animated: true) }
            }
        }
        private func completeInteractive(_ swipe: InteractiveSwipe) {
            guard interactiveSwipe === swipe, let web, let direction = swipe.direction else { return }
            interactiveSwipe = nil; interactiveFinishing = true; pendingCard = swipe
            if swipe.incoming == nil {
                // A cold fast flick still advances immediately. Never reveal a
                // duplicate current page as if it were adjacent content.
                swipe.outgoing?.transform = .identity; swipe.animationDone = true
            } else if let outgoing = swipe.outgoing {
                let distance = web.bounds.width * (direction == "next" ? -1 : 1)
                let remaining = abs(distance - outgoing.transform.tx)
                let speed = max(900, abs(swipe.velocity))
                let duration = min(0.28, max(0.10, remaining / speed))
                let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
                    outgoing.transform = CGAffineTransform(translationX: distance, y: 0)
                }
                cardAnimator = animator
                animator.addCompletion { [weak self, weak swipe] _ in
                    guard let self, let swipe, self.pendingCard === swipe else { return }
                    swipe.animationDone = true; self.finishCardIfReady()
                }
                animator.startAnimation()
            } else { swipe.animationDone = true }
            sendNativeTurn(direction, token: swipe.turnID)

        }
        private func finishCardIfReady() {
            guard let swipe = pendingCard, swipe.mainReady, swipe.animationDone else { return }
            pendingCard = nil; interactiveFinishing = false; cardAnimator = nil
            // A completed interactive preview is an honest image of the page
            // just reached. Reuse it only after the live renderer confirms a
            // different location; layout changes cancel the interactive swipe.
            if let image = swipe.incoming?.image, let web, let cfi = controller.position.cfi,
               let origin = swipe.originCFI, cfi != origin,
               let request = swipe.incomingSnapshotRequest, snapshotRequest == request {
                cachedPage = image; cachedPageCFI = cfi; cachedPageSize = web.bounds.size
                cachedPagePreferences = latestPreferences; cachedPageChrome = latestChrome
            }
            swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview()
            cacheCurrentPage(); drainTurns()
        }
        private func finishSettlingForInput() {
            if let settling = settlingPage {
                settlingPage = nil; settling.layer.removeAllAnimations(); settling.removeFromSuperview()
                queuedTurns.endSettling()
                drainTurns()
                return
            }
            if let swipe = pendingCard {
                cardAnimator?.stopAnimation(true); cardAnimator = nil
                if swipe.incoming != nil { swipe.outgoing?.removeFromSuperview() }
                swipe.animationDone = true; finishCardIfReady()
            } else if turnToken != nil { outgoingPage?.removeFromSuperview(); outgoingPage = nil }
        }
        private func queueGuardedTurn(_ direction: String, start: CGPoint, web: WKWebView) {
            let reservation = queuedTurns.reserve(direction), epoch = interactionEpoch
            web.evaluateJavaScript("window.readerCanTurn(\(start.x),\(start.y))") { [weak self] result, error in
                guard let self, self.interactionEpoch == epoch else { return }
                if error != nil { self.controller.error = "The EPUB reader could not validate a page turn." }
                self.queuedTurns.resolve(reservation, allowed: result as? Bool ?? false)
                self.drainTurns()
            }
            drainTurns()
        }
        private func queueTurn(_ direction: String) {
            finishSettlingForInput()
            queuedTurns.append(direction); drainTurns()
        }
        private func drainTurns() {
            defer { hostController?.scheduleCurlInputOwnershipUpdate() }
            guard turnToken == nil, pendingCard == nil, settlingPage == nil, !curlTurning, interactiveSwipe == nil,
                  queuedTurns.hasReady else { return }
            guard let direction = queuedTurns.takeNext() else { return }
            let token = UUID(); turnToken = token
            if ["slide", "fade"].contains(latestPreferences.pageTransition), !UIAccessibility.isReduceMotionEnabled, let web,
               cachedPageCFI == controller.position.cfi, cachedPageSize == web.bounds.size,
               cachedPagePreferences == latestPreferences, cachedPageChrome == latestChrome, let image = cachedPage {
                let outgoing = UIImageView(image: image)
                outgoing.frame = web.bounds; outgoing.contentMode = .scaleToFill
                outgoing.isUserInteractionEnabled = false
                outgoing.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                (host ?? web).addSubview(outgoing); outgoingPage = outgoing
            }
            // Never wait for or invent an adjacent image during a rapid queue.
            sendNativeTurn(direction, token: token)
        }
        private func cancelInteractive(_ swipe: InteractiveSwipe, animated: Bool) {
            guard interactiveSwipe === swipe else { return }
            interactiveSwipe = nil
            guard animated, let outgoing = swipe.outgoing else {
                swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview(); drainTurns(); return
            }
            let animator = UIViewPropertyAnimator(duration: 0.16, dampingRatio: 0.95) { outgoing.transform = .identity }
            animator.addCompletion { [weak self] _ in outgoing.removeFromSuperview(); swipe.incoming?.removeFromSuperview(); self?.drainTurns() }
            animator.startAnimation()
        }
        // Layout invalidates preview images, not already accepted navigation.
        // Keep the in-flight token so its eventual acknowledgement is processed.
        private func interruptDecoration() {
            cardAnimator?.stopAnimation(true); cardAnimator = nil
            interactiveSwipe?.outgoing?.removeFromSuperview(); interactiveSwipe?.incoming?.removeFromSuperview()
            interactiveSwipe = nil
            if let swipe = pendingCard {
                swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview()
                swipe.outgoing = nil; swipe.incoming = nil; swipe.animationDone = true
            }
            outgoingPage?.removeFromSuperview(); outgoingPage = nil
            settlingPage?.layer.removeAllAnimations(); settlingPage?.removeFromSuperview(); settlingPage = nil
            queuedTurns.interruptDecoration()
        }
        private func abortInteractive() {
            interactionEpoch = UUID()
            cardAnimator?.stopAnimation(true); cardAnimator = nil
            for swipe in [interactiveSwipe, pendingCard].compactMap({ $0 }) {
                swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview()
            }
            interactiveSwipe = nil; pendingCard = nil; interactiveFinishing = false; queuedTurns.removeAll()
        }
        private func cacheCurrentPage() {
            guard controller.ready, !searchPresented, !latestPreferences.scrolling,
                  ["slide", "curl", "fade"].contains(latestPreferences.pageTransition), !UIAccessibility.isReduceMotionEnabled,
                  interactiveSwipe == nil, !interactiveFinishing, !curlTurning, turnToken == nil,
                  let web, let cfi = controller.position.cfi, web.bounds.width > 0 else { return }
            let size = web.bounds.size, preferences = latestPreferences, chrome = latestChrome
            if cachedPage != nil, cachedPageCFI == cfi, cachedPageSize == size, cachedPagePreferences == preferences, cachedPageChrome == chrome {
                warmAdjacentPages(); return
            }
            if captureState.timedOut {
                controller.error = "Page previews stopped responding. Close this book and reopen it to continue."
                return
            }
            guard let request = captureState.begin() else { currentCapturePending = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.captureState.timeout(request) else { return }
                // Quiesce this session rather than spawning overlapping retries.
                // An invalidated capture still owns its watchdog until it replies.
                self.currentCapturePending = false
                self.invalidateSnapshots(); self.releaseSnapshotRenderer()
                if !self.searchPresented {
                    self.controller.error = "Page previews stopped responding. Close this book and reopen it to continue."
                }
            }
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            web.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, let isCurrent = self.captureState.finish(request) else { return }
                defer {
                    if self.currentCapturePending { self.currentCapturePending = false; self.cacheCurrentPage() }
                }
                guard isCurrent, self.interactiveSwipe == nil,
                      self.turnToken == nil, !self.interactiveFinishing, !self.curlTurning,
                      self.controller.position.cfi == cfi, self.latestPreferences == preferences, self.latestChrome == chrome,
                      self.web?.bounds.size == size else { return }
                self.cachedPage = image
                self.cachedPageSize = size
                self.cachedPageCFI = cfi
                self.cachedPagePreferences = preferences; self.cachedPageChrome = chrome
                self.warmAdjacentPages()
                self.drainTurns()
            }
        }
        #endif
        func pageChrome(_ chrome: ReaderPageChrome) {
            guard chrome != latestChrome else { return }
            latestChrome = chrome
            #if os(macOS)
            reflowBridge?.invalidate()
            #endif
            #if os(iOS)
            interruptDecoration(); invalidateSnapshots(); cachedPage = nil; captureState.invalidate()
            #endif
            if loaded { sendRaw("pageChrome", chromeObject()) }
            #if os(iOS)
            finishCardIfReady(); drainTurns()
            #endif
        }
        private func chromeObject() -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(latestChrome))) ?? [:] }
        func preferences(_ preferences: ReaderPreferences) {
            guard preferences != latestPreferences else { return }
            #if os(macOS)
            cancelMacTrackpad()
            reflowBridge?.invalidate()
            #endif
            latestPreferences = preferences
            #if os(iOS)
            // Keep the live WebKit view attached during ordinary typography
            // changes. Only an in-progress curl needs its controller rebuilt.
            let interruptedCurl = curlTurning
            interruptDecoration()
            if interruptedCurl { resetCurl() }
            invalidateSnapshots()
            cachedPage = nil; captureState.invalidate()
            web?.scrollView.isScrollEnabled = preferences.scrolling
            web?.scrollView.bounces = preferences.scrolling
            hostController?.configureCurl()
            #endif
            if loaded { send("preferences", preferencesObject()) }
            #if os(iOS)
            finishCardIfReady(); drainTurns()
            #endif
        }
        private var nativeGestures: Bool {
            #if os(iOS)
            true
            #else
            false
            #endif
        }
        func preferencesObject() -> Any {
            var value = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(latestPreferences))) as? [String: Any] ?? [:]
            value["pageChrome"] = chromeObject(); return value
        }
        func send(_ command: String, _ value: Any?) {
            if command == "savedHighlights" { highlightPayload = value as? [Any] ?? [] }
            #if os(macOS)
            if ["next", "previous", "seek", "location", "annotationLocation", "layoutPage", "trackpad", "savedHighlights", "search", "searchPresentation"].contains(command) {
                reflowBridge?.invalidate()
            }
            if command == "sidebarTransition", let transition = value as? [String: Any],
               let request = transition["request"] as? String {
                if transition["phase"] as? String == "begin" {
                    // Establish cover/softening before SwiftUI starts moving
                    // the inspector, not during its first native layout frame.
                    reflowBridge?.geometryWillChange()
                    beginSidebarPaper(request, live: transition["mode"] as? String == "live")
                } else if transition["phase"] as? String == "end", request == sidebarPaperRequest {
                    sidebarPaperEnded = true
                }
            }
            if command == "trackpad", let value = value as? [String: Any] { trackpad(value); return }
            if macTurn != nil && ["next", "previous", "seek", "location", "annotationLocation", "layoutPage"].contains(command) {
                macWaitingCommands.append((command, value)); cancelMacTrackpad()
                if macTurn == nil { drainMacCommands() }; return
            }
            #endif
            #if os(iOS)
            if command == "searchPresentation", let active = value as? Bool {
                searchPresented = active
                if active {
                    interruptDecoration(); invalidateSnapshots(); cachedPage = nil; captureState.invalidate()
                    finishCardIfReady(); drainTurns()
                }
            }
            if command == "next" || command == "previous" {
                if turnToken != nil || pendingCard != nil || curlTurning || settlingPage != nil || !queuedTurns.isEmpty { queueTurn(command) } else { turnPage(command) }
                return
            }
            #endif
            sendRaw(command, value)
        }
        private func sendRaw(_ command: String, _ value: Any?) {
            guard let data = try? JSONSerialization.data(withJSONObject: ["name": command, "value": value ?? NSNull()]), let json = String(data: data, encoding: .utf8) else { return }
            web?.evaluateJavaScript("void window.readerCommand(\(json))") { [weak self] _, error in if error != nil { self?.controller.error = "The EPUB reader could not complete this action." } }
        }
        #if os(iOS)
        private func sendNativeTurn(_ direction: String, token: UUID) {
            sendRaw("nativeTurn", ["direction":direction,"request":token.uuidString])
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.recoverTurn(token) }
        }
        private func turnPage(_ direction: String) {
            finishSettlingForInput()
            guard turnToken == nil, interactiveSwipe == nil, !interactiveFinishing, !latestPreferences.scrolling, let web else { return }
            if latestPreferences.pageTransition == "curl", !UIAccessibility.isReduceMotionEnabled {
                if hostController?.animateCurl(direction) == true { return }
                let token = UUID(); turnToken = token; sendNativeTurn(direction, token: token); return
            }
            guard latestPreferences.pageTransition != "instant", !UIAccessibility.isReduceMotionEnabled else {
                sendRaw(direction, nil); return
            }
            let token = UUID(); turnToken = token
            // Cached images are optional decoration. Never delay navigation on
            // a fresh WebKit capture when the current image is unavailable.
            if cachedPageCFI == controller.position.cfi, cachedPageSize == web.bounds.size,
               cachedPagePreferences == latestPreferences, cachedPageChrome == latestChrome, let image = cachedPage {
                let outgoing = UIImageView(image: image)
                outgoing.frame = web.bounds; outgoing.contentMode = .scaleToFill
                outgoing.isUserInteractionEnabled = false
                outgoing.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                (host ?? web).addSubview(outgoing); outgoingPage = outgoing
            }
            sendNativeTurn(direction, token: token)
        }
        private func finishTurn(direction: String, animated: Bool) {
            guard turnToken != nil else { return }
            turnToken = nil
            guard let outgoing = outgoingPage else { sendRaw("clearSelection", nil); cacheCurrentPage(); drainTurns(); return }
            outgoingPage = nil
            guard animated, let web else { outgoing.removeFromSuperview(); sendRaw("clearSelection", nil); cacheCurrentPage(); drainTurns(); return }
            settlingPage = outgoing
            queuedTurns.beginSettling()
            // Capture the live destination in the background while the outgoing
            // image is settling, so a follow-up can use it without waiting.
            cacheCurrentPage()
            let distance = web.bounds.width * (direction == "next" ? -1 : 1)
            let duration = queuedTurns.isEmpty ? (latestPreferences.pageTransition == "fade" ? 0.32 : 0.22) : 0.10
            UIView.animate(withDuration: duration,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                outgoing.transform = self.latestPreferences.pageTransition == "fade" ? .identity : CGAffineTransform(translationX: distance, y: 0)
                if self.latestPreferences.pageTransition == "fade" { outgoing.alpha = 0 }
            } completion: { _ in
                outgoing.removeFromSuperview()
                guard self.settlingPage === outgoing else { return }
                self.settlingPage = nil
                self.queuedTurns.endSettling()
                self.sendRaw("clearSelection", nil)
                self.cacheCurrentPage()
                self.drainTurns()
            }
        }
        #endif
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the bundled shell can issue native reader commands. Publication frames are untrusted.
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.host == "local",
                  message.frameInfo.request.url?.path == "/reader/index.html",
                  let value = message.body as? [String: Any], let kind = value["kind"] as? String else { return }
            #if os(iOS)
            if message.webView === snapshotWeb { receiveSnapshot(value, kind: kind); return }
            #endif
            switch kind {
            case "boot":
                loaded = true
                let relative = String(prepared.document.path.dropFirst(prepared.directory.path.count + 1))
                var components = URLComponents(); components.scheme = "appbook"; components.host = "local"; components.path = "/publication/" + relative
                // The shell may boot again during the same reading session.
                // Restore the most recently reported position, not the one
                // captured when the book was first opened.
                let position = controller.position
                send("open", ["url": components.url!.absoluteString, "title": prepared.book.title, "cfi": position.cfi as Any? ?? NSNull(), "fraction": position.fraction, "preferences": preferencesObject(), "nativeGestures": nativeGestures, "nativeReflowBridge": !nativeGestures])
            #if os(macOS)
            case "reflowBegin":
                if let request = value["request"] as? String { reflowBridge?.begin(request: request) }
            case "reflowPainted":
                if let request = value["request"] as? String,
                   let width = value["viewWidth"] as? Double, let height = value["viewHeight"] as? Double {
                    reflowBridge?.painted(request: request, width: width, height: height)
                }
            case "sidebarLayoutReady":
                guard let request = value["request"] as? String, let width = value["width"] as? Double else { return }
                finishSidebarPaper(request: request, width: width, settled: value["settled"] as? Bool ?? false)
            #endif
            case "stage": controller.loadingStatus = value["label"] as? String ?? "Opening book…"
            case "ready":
                controller.ready = true
                #if os(macOS)
                reflowBridge?.prepare()
                #endif
                #if os(iOS)
                cacheCurrentPage()
                #endif
            case "selectedText":
                guard let cfi = value["cfi"] as? String, cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")"), cfi.count <= 8192,
                      let text = value["text"] as? String, !text.isEmpty, text.utf16.count <= 16384 else { return }
                controller.epubSelection = EPUBSelection(cfi: cfi, text: text, context: (value["context"] as? String).flatMap { $0.utf16.count <= 1024 ? $0 : nil })
                controller.controlsVisible = true
                #if os(iOS)
                UIMenuSystem.context.setNeedsRebuild()
                #endif
            case "publicationLayout":
                guard let fixed = value["fixed"] as? Bool else { return }
                controller.fixedLayout = fixed
            case "annotationActivated":
                #if os(macOS)
                guard controller.highlighterColor == nil else { return }
                #endif
                guard let rawID = value["id"] as? String, let id = UUID(uuidString: rawID) else { return }
                controller.annotationAction?(id)
            case "highlighterSelectionCommitted":
                guard let cfi = value["cfi"] as? String, cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")"), cfi.count <= 8192,
                      let text = value["text"] as? String, !text.isEmpty, text.utf16.count <= 16384 else { return }
                #if os(macOS)
                guard controller.highlighterColor != nil,
                      value["request"] as? String == highlighterGeneration.uuidString else { return }
                controller.highlighterAction?(EPUBSelection(cfi: cfi, text: text, context: (value["context"] as? String).flatMap { $0.utf16.count <= 1024 ? $0 : nil }))
                #endif
            case "highlightsUpdated":
                #if os(macOS)
                if controller.ready { reflowBridge?.prepare() }
                #endif
                #if os(iOS)
                // The CFI and viewport can remain unchanged while the painted
                // page changes. Reject any older in-flight capture as well.
                invalidateSnapshots(); cachedPage = nil; captureState.invalidate()
                cacheCurrentPage()
                #endif
            #if os(iOS)
            case "readerRevealed":
                guard !searchPresented else { return }
                textSelectionActive = false
                cacheCurrentPage()
            case "swipe":
                if let direction = value["direction"] as? String, direction == "next" || direction == "previous" {
                    if value["queue"] as? Bool == true {
                        guard value["queueRequest"] as? String == interactionEpoch.uuidString else { return }
                        queueTurn(direction)
                    } else { send(direction, nil) }
                }
            case "turned":
                if let token = curlToken, value["request"] as? String == token.uuidString {
                    let completion = curlCompletion; curlCompletion = nil; curlToken = nil; curlTurning = false
                    completion?(); invalidateSnapshots(); cacheCurrentPage(); drainTurns()
                } else if let swipe = pendingCard, value["request"] as? String == swipe.turnID.uuidString {
                    swipe.mainReady = true; finishCardIfReady()
                } else if value["request"] as? String == turnToken?.uuidString {
                    finishTurn(direction: value["direction"] as? String ?? "next", animated: true)
                }
            #endif
            case "selection":
                let active = value["active"] as? Bool ?? false
                controller.epubSelectionActive = active
                #if os(macOS)
                reflowBridge?.setSuspended(active)
                #endif
                #if os(iOS)
                textSelectionActive = active
                #endif
            #if os(macOS)
            case "previewReady":
                if let stroke = macTurn { stroke.ready = true; stroke.boundary = value["changed"] as? Bool == false; updateMacTrackpad(stroke) }
            case "turnCancelled":
                macTurn?.image?.removeFromSuperview(); macTurn?.image = nil; macTurn = nil; drainMacCommands()
            #endif
            case "position":
                guard let fraction = value["fraction"] as? Double,
                      let position = ReaderPositionValidation.epub(cfi: value["cfi"] as? String, fraction: fraction) else { return }
                #if os(macOS)
                if controller.position.cfi != position.cfi { reflowBridge?.invalidate() }
                if controller.ready { reflowBridge?.prepare() }
                #endif
                if controller.position.cfi != position.cfi { controller.epubSelection = nil }
                controller.currentChapter = value["href"] as? String
                controller.chapterTitle = value["chapterTitle"] as? String ?? ""
                controller.chapterPage = value["chapterPage"] as? Int ?? 0
                controller.chapterPageCount = value["chapterPageCount"] as? Int ?? 0
                controller.bookPage = value["bookPage"] as? Int ?? 0
                controller.bookPageCount = value["bookPageCount"] as? Int ?? 0
                controller.update(position)
                #if os(iOS)
                cacheCurrentPage()
                #endif
            case "pagination":
                controller.bookPageCount = value["pages"] as? Int ?? 0
                controller.paginationFailed = value["failed"] as? Bool ?? false
                controller.pageChapters = (value["chapters"] as? [[String: Any]] ?? []).compactMap { item in
                    guard let number = item["number"] as? Int, let title = item["title"] as? String,
                          let start = item["start"] as? Double, let end = item["end"] as? Double else { return nil }
                    return ReaderChapter(number: number, title: title, href: item["href"] as? String, start: start, end: end)
                }
            case "toc", "results":
                let links = (value["items"] as? [[String: String]] ?? []).compactMap { item -> ReaderLink? in guard let id = item["id"], let title = item["title"] else { return nil }; return ReaderLink(id: id, title: title, context: item["context"]) }
                if kind == "toc" { controller.toc = links } else { controller.completeSearch(links, id: value["id"] as? String ?? "") }
            case "chapters":
                controller.chapters = (value["items"] as? [[String: Any]] ?? []).compactMap { item in
                    guard let number = item["number"] as? Int, let title = item["title"] as? String,
                          let start = item["start"] as? Double, let end = item["end"] as? Double,
                          start.isFinite, end.isFinite, end > start else { return nil }
                    return ReaderChapter(number: number, title: title, href: item["href"] as? String, start: start, end: end)
                }
            case "chapterSnippet":
                if let number = value["number"] as? Int, let snippet = value["text"] as? String {
                    controller.chapterSnippets[number] = snippet
                }
            case "toggleControls": controller.controlsVisible.toggle()
            case "searchError": if value["id"] as? String == controller.searchID { controller.searching = false; controller.searchState = .failed }
            case "navigationError": controller.returnPosition = nil; controller.navigationError = true
            case "error":
                #if os(macOS)
                reflowBridge?.invalidate()
                stopSidebarPaper()
                stopMacTrackpad()
                #endif
                #if os(iOS)
                abortInteractive(); resetCurl()
                finishTurn(direction: "next", animated: false)
                #endif
                controller.error = "This EPUB could not be rendered. It may be damaged or use unsupported content. Some requested page turns may be unfinished. Close this book and reopen it before continuing."; controller.searching = false
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "appbook" || scheme == "about" || scheme == "blob" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            #if os(macOS)
            reflowBridge?.invalidate()
            #endif
            #if os(iOS)
            if webView === snapshotWeb { invalidateSnapshots(); return }
            #endif
            controller.error = "The local reader could not be loaded." }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            #if os(macOS)
            reflowBridge?.invalidate()
            stopMacTrackpad()
            #endif
            #if os(iOS)
            if webView === snapshotWeb { invalidateSnapshots(); releaseSnapshotRenderer(); return }
            stopSnapshots(); hostController?.resetCurlSurface(rebuild: false)
            #endif
            controller.ready = false
            controller.error = "The book's reading process stopped. Uncompleted page turns will not replay. Close this book and reopen it to continue." }
    }
}
#if os(macOS)
@MainActor final class ReaderMenuWebView: WKWebView {
    var reflowGeometryWillChange: (() -> Void)?
    var reflowInteraction: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { reflowGeometryWillChange?() }
        super.setFrameSize(newSize)
    }
    override func mouseDown(with event: NSEvent) { reflowInteraction?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { reflowInteraction?(); super.keyDown(with: event) }
    override func scrollWheel(with event: NSEvent) { reflowInteraction?(); super.scrollWheel(with: event) }
    private static let highlighterCursor: NSCursor = {
        let size = NSSize(width: 24, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            // Draw the insertion marker with a contrasting rim so it remains
            // visible on both light and dark reading themes.
            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: 4, y: 3)); beam.line(to: NSPoint(x: 4, y: 19))
            beam.move(to: NSPoint(x: 1.5, y: 3)); beam.line(to: NSPoint(x: 6.5, y: 3))
            beam.move(to: NSPoint(x: 1.5, y: 19)); beam.line(to: NSPoint(x: 6.5, y: 19))
            beam.lineCapStyle = .round; beam.lineJoinStyle = .round
            NSColor.white.setStroke(); beam.lineWidth = 3; beam.stroke()
            NSColor.black.setStroke(); beam.lineWidth = 1.2; beam.stroke()
            let badge = NSRect(x: 9, y: 0.5, width: 13, height: 13)
            let background = NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4)
            NSColor.white.setFill(); background.fill()
            NSColor.black.setStroke(); background.lineWidth = 1; background.stroke()
            if let pen = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.black])) {
                pen.draw(in: badge.insetBy(dx: 2, dy: 2))
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 11))
    }()
    weak var readerController: ReaderController?
    private var menuRequest = UUID()
    private var menuOrigin: String?
    private var menuCapture: Task<EPUBSelection?, Never>?
    override func resetCursorRects() {
        super.resetCursorRects()
        if readerController?.highlighterColor != nil { addCursorRect(bounds, cursor: Self.highlighterCursor) }
    }
    override func cancelOperation(_ sender: Any?) {
        guard let controller = readerController, controller.highlighterColor != nil else {
            super.cancelOperation(sender)
            return
        }
        controller.highlighterColor = nil
    }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        reflowInteraction?()
        super.willOpenMenu(menu, with: event)
        menuRequest = UUID(); menuCapture?.cancel(); menuCapture = nil; menuOrigin = nil
        let prefix = "LibraVia.Selection."
        // WebKit may reuse its menu; replace only the items we own.
        for item in menu.items where item.identifier?.rawValue.hasPrefix(prefix) == true { menu.removeItem(item) }
        // The WebKit menu is built from its current hit test, which arrives
        // before the reader's periodic selection notification can reach Swift.
        // A native Copy item identifies selected text, unlike Copy Link/Image.
        guard let controller = readerController, controller.ready,
              let origin = controller.position.cfi, let window,
              menu.items.contains(where: { $0.tag == Int(WebMenuItemTagCopy) && $0.isEnabled }) else { return }
        let request = menuRequest
        menuOrigin = origin
        // Begin sampling as the menu opens, without delaying native menu display.
        // An immediate action awaits this capture, then validates the live range.
        let (samples, continuation) = AsyncStream<EPUBSelection>.makeStream(bufferingPolicy: .bufferingNewest(1))
        menuCapture = Task { var iterator = samples.makeAsyncIterator(); return await iterator.next() }
        // Submit the WebKit read synchronously here: a Task alone might not
        // start until AppKit finishes tracking the menu.
        evaluateJavaScript(Self.menuSelectionScript) { [weak self, weak controller, weak window] result, error in
            defer { continuation.finish() }
            guard let self, let controller, let window, error == nil,
                  self.readerController === controller, self.window === window,
                  self.menuRequest == request, controller.ready, controller.position.cfi == origin,
                  let selection = Self.decodeMenuSelection(result, origin: origin) else { return }
            continuation.yield(selection)
        }
        for (index, entry) in [("Highlight", false), ("Add Note", true)].enumerated() {
            let (title, note) = entry
            let item = NSMenuItem(title: title, action: #selector(performReadingAction(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(prefix + (note ? "note" : "highlight"))
            item.representedObject = ["note": note, "request": request.uuidString] as [String: Any]
            menu.insertItem(item, at: index)
        }
        var insertion = 2
        if menu.items.contains(where: { $0.tag == Int(WebMenuItemTagLookUpInDictionary) && $0.isEnabled }) {
            let define = NSMenuItem(title: "Define", action: #selector(defineSelection(_:)), keyEquivalent: "")
            define.target = self; define.identifier = NSUserInterfaceItemIdentifier(prefix + "define")
            define.representedObject = ["point": NSValue(point: convert(event.locationInWindow, from: nil)), "request": request.uuidString]
            menu.insertItem(define, at: insertion); insertion += 1
        }
        let separator = NSMenuItem.separator()
        separator.identifier = NSUserInterfaceItemIdentifier(prefix + "separator")
        menu.insertItem(separator, at: insertion)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            menuRequest = UUID(); menuCapture?.cancel(); menuCapture = nil; menuOrigin = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }
    @objc private func defineSelection(_ item: NSMenuItem) {
        guard let data = item.representedObject as? [String: Any], let point = data["point"] as? NSValue,
              let value = data["request"] as? String, let request = UUID(uuidString: value) else { return }
        resolveMenuSelection(request: request) { [weak self] selection in
            guard let self, let term = ReaderDictionary.term(selection.text) else { return }
            self.showDefinition(for: NSAttributedString(string: term), at: point.pointValue)
        }
    }
    @objc private func performReadingAction(_ item: NSMenuItem) {
        guard let data = item.representedObject as? [String: Any], let note = data["note"] as? Bool,
              let value = data["request"] as? String, let request = UUID(uuidString: value) else { return }
        resolveMenuSelection(request: request) { [weak self] selection in
            guard let controller = self?.readerController else { return }
            controller.epubSelection = selection
            controller.epubSelectionActive = true
            controller.selectionMenuAction?(note, selection)
        }
    }
    // Only the trusted shell reads the script-disabled publication frames.
    private static let menuSelectionScript = """
    (() => {
      if (!ready) return null;
      pollSelection();
      if (!lastPolledSelection) return null;
      const [anchor, cfi, text] = JSON.parse(lastPolledSelection);
      return {anchor, cfi, text, context: lastSelectionContext};
    })()
    """
    private static func decodeMenuSelection(_ raw: Any?, origin: String) -> EPUBSelection? {
        guard let data = raw as? [String: Any], data["anchor"] as? String == origin,
              let cfi = data["cfi"] as? String, cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")"), cfi.count <= 8192,
              let text = data["text"] as? String, !text.isEmpty, text.utf16.count <= 16384 else { return nil }
        let context = (data["context"] as? String).flatMap { $0.utf16.count <= 1024 ? $0 : nil }
        return EPUBSelection(cfi: cfi, text: text, context: context)
    }
    private func sampleMenuSelection(origin: String) async -> EPUBSelection? {
        guard let raw = try? await evaluateJavaScript(Self.menuSelectionScript) else { return nil }
        return Self.decodeMenuSelection(raw, origin: origin)
    }
    private func resolveMenuSelection(request: UUID, _ completion: @escaping (EPUBSelection) -> Void) {
        guard menuRequest == request, let capture = menuCapture,
              let controller = readerController, controller.ready,
              let origin = menuOrigin, controller.position.cfi == origin, let window else { return }
        Task { [weak self, weak controller, weak window] in
            let first = await capture.value
            guard let self, let controller, let window, self.readerController === controller,
                  self.window === window, self.menuRequest == request,
                  controller.ready, controller.position.cfi == origin else { return }
            let second = await self.sampleMenuSelection(origin: origin)
            guard self.readerController === controller, self.window === window, self.menuRequest == request,
                  controller.ready, controller.position.cfi == origin else { return }
            guard let first, let second, first.cfi == second.cfi, first.text == second.text else {
                guard window.attachedSheet == nil else { return }
                let alert = NSAlert(); alert.messageText = "Selection no longer available"
                alert.informativeText = "Select the passage again and reopen the menu."
                alert.beginSheetModal(for: window, completionHandler: nil)
                return
            }
            completion(second)
        }
    }
}
#endif
#if os(iOS)
/// Keep the live WebKit page in the native curl's current controller, so center
/// interaction, selection and accessibility stay live rather than screenshot-only.
@MainActor final class ReaderCurlPage: UIViewController {
    var offset: Int
    init(offset: Int, image: UIImage?, color: UIColor) {
        self.offset = offset; super.init(nibName: nil, bundle: nil)
        view.backgroundColor = color
        if let image {
            let picture = UIImageView(image: image); picture.frame = view.bounds
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]; picture.contentMode = .scaleToFill
            picture.isUserInteractionEnabled = false; picture.accessibilityElementsHidden = true
            view.addSubview(picture)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ image: UIImage) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let picture = UIImageView(image: image); picture.frame = view.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]; picture.contentMode = .scaleToFill
        picture.isUserInteractionEnabled = false; picture.accessibilityElementsHidden = true
        view.addSubview(picture)
    }
    func attach(_ web: WKWebView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        web.frame = view.bounds; web.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(web)
    }
}
// Enabled only after UIKit has finished recognizing its own touch. Tracking
// starts before recognition so a pending touch cannot lose ownership midway.
@MainActor final class ReaderCurlCatchUpPan: UIPanGestureRecognizer {
    private(set) var trackingTouch = false
    private(set) var initialLocation: CGPoint?
    var touchFinished: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if !trackingTouch, let touch = touches.first { initialLocation = touch.location(in: view) }
        trackingTouch = true; super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event); trackingTouch = false; touchFinished?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event); trackingTouch = false; touchFinished?()
    }
    override func reset() {
        super.reset(); trackingTouch = false; initialLocation = nil; touchFinished?()
    }
}
@MainActor final class ReaderCurlGate: UIView {
    weak var owner: ReaderHostController?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches { owner?.gateCurlGestures(at: point) }
        return super.hitTest(point, with: event)
    }
}
@MainActor final class ReaderHostController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    let web: WKWebView
    weak var coordinator: EPUBSurface.Coordinator?
    private var curl: UIPageViewController?
    private var currentPage: ReaderCurlPage?
    private var lastSize = CGSize.zero
    private var neighbours: [Int:ReaderCurlPage] = [:]
    private var catchUpPan: ReaderCurlCatchUpPan?
    private var catchUpOwnsInput = false
    private var curlOwnershipGeneration = UUID()
    private var catchUpStart: CGPoint?
    init(web: WKWebView, coordinator: EPUBSurface.Coordinator) {
        self.web = web; self.coordinator = coordinator; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == UIMenuSystem.context,
              let controller = coordinator?.controller, controller.epubSelectionActive,
              let selection = controller.epubSelection else { return }
        let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak controller] _ in
            controller?.selectionMenuAction?(false, selection)
        }
        let note = UIAction(title: "Add Note", image: UIImage(systemName: "square.and.pencil")) { [weak controller] _ in
            controller?.selectionMenuAction?(true, selection)
        }
        var actions: [UIMenuElement] = [highlight, note]
        if let term = ReaderDictionary.term(selection.text) {
            actions.append(UIAction(title: "Define", image: UIImage(systemName: "book.closed")) { [weak self] _ in
                guard let self, self.presentedViewController == nil else { return }
                self.present(UIReferenceLibraryViewController(term: term), animated: true)
            })
        }
        let menu = UIMenu(title: "", options: .displayInline, children: actions)
        if builder.menu(for: .standardEdit) != nil { builder.insertSibling(menu, afterMenu: .standardEdit) }
        else { builder.insertChild(menu, atEndOfMenu: .root) }
    }
    override func loadView() {
        let host = ReaderCurlGate(); host.owner = self; view = host
        web.frame = host.bounds; web.autoresizingMask = [.flexibleWidth, .flexibleHeight]; host.addSubview(web)
        let catchUp = ReaderCurlCatchUpPan(target: self, action: #selector(catchUpGesture(_:)))
        catchUp.maximumNumberOfTouches = 1; catchUp.cancelsTouchesInView = false
        catchUp.delegate = self; catchUp.isEnabled = false
        catchUp.touchFinished = { [weak self] in self?.scheduleCurlInputOwnershipUpdate() }
        host.addGestureRecognizer(catchUp); catchUpPan = catchUp
        coordinator?.pageTap?.require(toFail: catchUp)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let insets = view.window?.safeAreaInsets, let controller = coordinator?.controller {
            let value = EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
            if controller.viewportInsets != value {
                DispatchQueue.main.async { [weak controller] in controller?.viewportInsets = value }
            }
        }
        guard view.bounds.size != lastSize, view.bounds.width > 0 else { return }
        lastSize = view.bounds.size; coordinator?.viewportDidChange()
    }
    var paperColor: UIColor {
        switch coordinator?.latestPreferences.theme {
        case "dark": return UIColor(white: 23 / 255, alpha: 1)
        case "sepia": return UIColor(red: 244 / 255, green: 236 / 255, blue: 216 / 255, alpha: 1)
        default: return .white
        }
    }
    func configureCurl() {
        curl?.view.backgroundColor = paperColor; currentPage?.view.backgroundColor = paperColor
        for page in neighbours.values { page.view.backgroundColor = paperColor }
        let enabled = coordinator?.latestPreferences.pageTransition == "curl" && coordinator?.latestPreferences.scrolling == false && !UIAccessibility.isReduceMotionEnabled
        if enabled, curl == nil {
            let page = ReaderCurlPage(offset: 0, image: nil, color: paperColor)
            page.view.frame = view.bounds; page.attach(web)
            let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                                  options: [.spineLocation:UIPageViewController.SpineLocation.min.rawValue])
            controller.view.backgroundColor = paperColor; controller.isDoubleSided = true
            controller.dataSource = self; controller.delegate = self
            addChild(controller); controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view); controller.didMove(toParent: self)
            controller.setViewControllers([page], direction: .forward, animated: false)
            currentPage = page; curl = controller
            // Native pans start enabled; missing pages are rejected by the data source.
            // Keep UIKit's delegates and disable only its tap-to-turn recognizers.
            for gesture in controller.gestureRecognizers {
                gesture.isEnabled = !(gesture is UITapGestureRecognizer)
                if let pan = gesture as? UIPanGestureRecognizer {
                    pan.addTarget(self, action: #selector(nativeCurlPanChanged(_:)))
                    coordinator?.pageTap?.require(toFail: pan)
                }
            }
        } else if !enabled, let curl {
            curlOwnershipGeneration = UUID(); catchUpOwnsInput = false; catchUpPan?.isEnabled = false; catchUpStart = nil
            curl.willMove(toParent: nil)
            web.removeFromSuperview(); web.frame = view.bounds; view.addSubview(web)
            curl.view.removeFromSuperview(); curl.removeFromParent(); self.curl = nil; currentPage = nil; neighbours.removeAll()
        }
    }
    func resetCurlSurface(rebuild: Bool = true) {
        guard let old = curl else { return }
        curlOwnershipGeneration = UUID(); catchUpOwnsInput = false; catchUpPan?.isEnabled = false; catchUpStart = nil
        old.delegate = nil; old.dataSource = nil; old.willMove(toParent: nil)
        web.removeFromSuperview(); web.frame = view.bounds; view.addSubview(web)
        old.view.removeFromSuperview(); old.removeFromParent(); curl = nil; currentPage = nil; neighbours.removeAll()
        if rebuild { configureCurl() }
    }
    func restoreLivePage() {
        guard let curl else { return }
        curl.delegate = nil
        let page = ReaderCurlPage(offset: 0, image: nil, color: paperColor)
        page.view.frame = view.bounds; page.attach(web)
        curl.setViewControllers([page], direction: .forward, animated: false)
        currentPage = page; curl.delegate = self
    }
    func refreshNeighbours() {
        guard coordinator?.curlTurning == false, let curl, let currentPage else { return }
        // Refresh UIKit's retained adjacency once per completed preview generation,
        // without reparenting WebKit or resetting its viewport for each image.
        neighbours.removeAll(); curl.dataSource = nil
        curl.setViewControllers([currentPage], direction: .forward, animated: false)
        curl.dataSource = self
    }
    func gateCurlGestures(at point: CGPoint) {
        guard !catchUpOwnsInput, coordinator?.curlTurning == false else { return }
        let allowed = coordinator?.canCurl(at: point) == true
        if !allowed, coordinator?.canCatchUpCurl(at: point) == true {
            // While genuine adjacent snapshots are cold, take the same guarded
            // FIFO path instead of rejecting the user's swipe.
            beginCurlCatchUpOwnership(); return
        }
        // UIKit retains its own gesture delegates. Only documented recognizer
        // enablement is changed; native taps defer to LibraVia's tap zones.
        for gesture in curl?.gestureRecognizers ?? [] { gesture.isEnabled = allowed && !(gesture is UITapGestureRecognizer) }
    }
    @objc private func nativeCurlPanChanged(_ pan: UIPanGestureRecognizer) {
        guard (pan.state == .ended || pan.state == .cancelled), coordinator?.curlTurning == true else { return }
        beginCurlCatchUpOwnership()
    }
    private func beginCurlCatchUpOwnership() {
        guard !catchUpOwnsInput, let curl else { return }
        let nativePans = curl.gestureRecognizers.compactMap { $0 as? UIPanGestureRecognizer }
        guard !nativePans.isEmpty, nativePans.allSatisfy({ $0.state != .began && $0.state != .changed }) else { return }
        // A finished native touch remains UIKit's; later touches belong only to
        // the catch-up pan until navigation and every outstanding guard finish.
        curlOwnershipGeneration = UUID(); catchUpOwnsInput = true
        for pan in nativePans { pan.isEnabled = false }
        catchUpPan?.isEnabled = true
    }
    func scheduleCurlInputOwnershipUpdate() {
        // UIKit may deliver target actions after touchesEnded returns. Do not
        // disarm until that event has had a chance to reserve its turn.
        let generation = curlOwnershipGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.curlOwnershipGeneration == generation else { return }
            self.updateCurlInputOwnership()
        }
    }
    private func updateCurlInputOwnership() {
        guard catchUpOwnsInput, coordinator?.curlInputBusy == false,
              catchUpPan?.trackingTouch != true else { return }
        catchUpOwnsInput = false; catchUpPan?.isEnabled = false; catchUpStart = nil
        for gesture in curl?.gestureRecognizers ?? [] { gesture.isEnabled = !(gesture is UITapGestureRecognizer) }
    }
    @objc private func catchUpGesture(_ pan: ReaderCurlCatchUpPan) {
        switch pan.state {
        case .began:
            guard let point = pan.initialLocation, let container = pan.view else { return }
            catchUpStart = web.convert(point, from: container)
        case .ended:
            defer { catchUpStart = nil }
            guard catchUpOwnsInput, let start = catchUpStart else { return }
            let delta = pan.translation(in: web), speed = pan.velocity(in: web)
            guard abs(delta.x) > abs(delta.y) * 1.5,
                  ReaderTurnDecision.commits(translation: delta.x, velocity: speed.x, width: web.bounds.width) else { return }
            coordinator?.queueCurlCatchUp(delta.x < 0 ? "next" : "previous", start: start)
        case .cancelled, .failed: catchUpStart = nil
        default: break
        }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Keep the observer attached to the complete touch sequence. Direction
        // and commitment are checked only when the gesture ends.
        gestureRecognizer === catchUpPan && catchUpOwnsInput
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if other === coordinator?.pageTap { return false }
        return true
    }
    private func neighbour(_ offset: Int) -> ReaderCurlPage? {
        // A double-sided curl visits the back, then the adjacent front. Only
        // create either when that real adjacent page is available.
        guard (1...2).contains(abs(offset)),
              let image = coordinator?.cachedAdjacentPage(offset > 0 ? "next" : "previous") else { return nil }
        if let page = neighbours[offset] {
            if abs(offset) == 2 { page.show(image) }
            return page
        }
        let page = ReaderCurlPage(offset: offset, image: abs(offset) == 2 ? image : nil, color: paperColor)
        page.view.frame = view.bounds; neighbours[offset] = page; return page
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ReaderCurlPage else { return nil }; return neighbour(page.offset - 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ReaderCurlPage else { return nil }; return neighbour(page.offset + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        coordinator?.curlTurning = true
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === curl, coordinator?.curlTurning == true else { return }
        guard completed else {
            coordinator?.curlTurning = false; coordinator?.resumeQueuedTurns(); return
        }
        guard let page = pageViewController.viewControllers?.first as? ReaderCurlPage, abs(page.offset) == 2 else {
            // Never commit a decorative back as a book page.
            restoreLivePage(); coordinator?.curlTurning = false; coordinator?.resumeQueuedTurns(); return
        }
        commit(page)
    }
    private func commit(_ page: ReaderCurlPage) {
        let direction = page.offset > 0 ? 1 : -1
        let previous = currentPage, sourceImage = coordinator?.sourcePageImage()
        let destinationImage = coordinator?.cachedAdjacentPage(direction > 0 ? "next" : "previous")
        // EPUB.js schedules layout on animation frames. Keep the live renderer
        // in the visible destination hierarchy before asking it to advance.
        // The honest destination preview hides that layout without detaching it.
        if let previous, let sourceImage { previous.offset = -direction * 2; previous.show(sourceImage) }
        page.offset = 0; page.attach(web); currentPage = page; neighbours.removeAll()
        if let previous, sourceImage != nil { neighbours[-direction * 2] = previous }
        let preview = destinationImage.map { UIImageView(image: $0) }
        if let preview {
            preview.frame = page.view.bounds; preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            preview.isUserInteractionEnabled = false; preview.accessibilityElementsHidden = true
            page.view.addSubview(preview)
        }
        coordinator?.commitCurl(direction > 0 ? "next" : "previous") { [weak preview] in
            preview?.removeFromSuperview()
        }
    }
    func animateCurl(_ direction: String) -> Bool {
        let sign = direction == "next" ? 1 : -1
        guard let curl, coordinator?.curlTurning == false,
              let next = neighbour(sign * 2), let back = neighbour(sign) else { return false }
        coordinator?.curlTurning = true
        beginCurlCatchUpOwnership()
        curl.setViewControllers([next, back], direction: direction == "next" ? .forward : .reverse, animated: true) { [weak self, weak next] completed in
            guard let self, let next, self.curl === curl, self.coordinator?.curlTurning == true else { return }
            if completed { self.commit(next) }
            else { self.restoreLivePage(); self.coordinator?.curlTurning = false; self.coordinator?.resumeQueuedTurns() }
        }
        return true
    }
}
#endif

final class BookScheme: NSObject, WKURLSchemeHandler {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local" else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
        let path = url.path
        let root: URL; let relative: String
        if path.hasPrefix("/reader/"), let resource = Bundle.main.url(forResource: "Reader", withExtension: nil) { root = resource; relative = String(path.dropFirst(8)) }
        else if path.hasPrefix("/publication/") { root = directory; relative = String(path.dropFirst(13)) }
        else { urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime: String
        switch file.pathExtension.lowercased() { case "js": mime = "text/javascript"; case "xhtml": mime = "application/xhtml+xml"; case "opf", "ncx", "xml": mime = "application/xml"; default: mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream" }
        let scriptPolicy = path.hasPrefix("/reader/") ? "appbook:" : "'none'"
        let csp = "default-src 'none'; script-src \(scriptPolicy); style-src 'unsafe-inline' appbook:; img-src appbook: data: blob:; font-src appbook: data: blob:; connect-src appbook:; frame-src appbook: blob:; object-src 'none'; base-uri appbook:"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*", "Content-Security-Policy": csp])!
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

#if os(iOS)
extension EPUBSurface.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Let WebKit handle taps on an existing text selection and its edit menu.
        if gestureRecognizer === pageTap {
            return !textSelectionActive && !controller.epubSelectionActive
        }
        guard gestureRecognizer === pagePan, let pan = gestureRecognizer as? UIPanGestureRecognizer, let web else { return true }
        guard controller.ready, !latestPreferences.scrolling else { return false }
        if latestPreferences.pageTransition == "curl", !UIAccessibility.isReduceMotionEnabled { return false }
        guard contentBounds.contains(pan.location(in: web)) else { return false }
        let movement = pan.translation(in: web)
        return abs(movement.x) > abs(movement.y) * 1.5
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Selection can arrive from WebKit after the touch ends. Give its long
        // press recognizers priority before deciding that this was a page tap.
        return gestureRecognizer === pageTap && otherGestureRecognizer is UILongPressGestureRecognizer
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pagePan, otherGestureRecognizer === web?.scrollView.panGestureRecognizer { return false }
        if gestureRecognizer === pageTap, otherGestureRecognizer === pagePan { return false }
        return true
    }
}
#endif

#if os(macOS)
/// The preview decorates the live WebKit surface without intercepting clicks.
private final class MacPagePicture: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
