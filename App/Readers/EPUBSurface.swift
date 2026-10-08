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

struct EPUBSurface: EPUBViewRepresentable {
    let prepared: PreparedBook
    let controller: ReaderController
    let preferences: ReaderPreferences
    func makeCoordinator() -> Coordinator { Coordinator(prepared: prepared, controller: controller) }
    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(BookScheme(directory: prepared.directory), forURLScheme: "appbook")
        config.userContentController.add(coordinator, name: "reader")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator; coordinator.web = web
        #if os(iOS)
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
        #endif
        web.load(URLRequest(url: URL(string: "appbook://local/reader/index.html")!))
        controller.command = { [weak coordinator] name, value in coordinator?.send(name, value) }
        return web
    }
    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.preferences(preferences) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { web.configuration.userContentController.removeScriptMessageHandler(forName: "reader"); coordinator.controller.command = nil }
    #else
    func makeUIViewController(context: Context) -> ReaderHostController {
        let web = makeWebView(context.coordinator)
        let host = ReaderHostController(web: web, coordinator: context.coordinator)
        host.loadViewIfNeeded()
        context.coordinator.host = host.view; context.coordinator.hostController = host
        return host
    }
    func updateUIViewController(_ view: ReaderHostController, context: Context) { context.coordinator.preferences(preferences) }
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
        var loaded = false
        #if os(iOS)
        weak var host: UIView?
        weak var hostController: ReaderHostController?
        var curlTurning = false
        private var curlToken: UUID?
        private var curlCompletion: (() -> Void)?
        private var curlBlockedRegions: [CGRect] = []
        private var textSelectionActive = false
        func viewportDidChange() {
            abortInteractive(); resetCurl(); invalidateSnapshots(); cachedPage = nil; cacheRequest = UUID()
        }
        func cachedAdjacentPage(_ direction: String) -> UIImage? {
            guard cachedPageCFI == controller.position.cfi, cachedPageSize == web?.bounds.size,
                  cachedPagePreferences == latestPreferences else { return nil }
            return adjacentPages[direction]
        }
        func canCurl(at point: CGPoint) -> Bool {
            guard controller.ready, !curlTurning, turnToken == nil, pendingCard == nil, !textSelectionActive, let web,
                  !curlBlockedRegions.contains(where: { $0.contains(point) }) else { return false }
            let edge = min(72, web.bounds.width * 0.2)
            if point.x < edge { return cachedAdjacentPage("previous") != nil }
            if point.x > web.bounds.width - edge { return cachedAdjacentPage("next") != nil }
            return false
        }
        func resumeQueuedTurns() { drainTurns() }
        private func resetCurl() {
            curlCompletion = nil; curlToken = nil; curlTurning = false
            hostController?.resetCurlSurface()
        }
        private func recoverTurn(_ token: UUID) {
            guard turnToken == token || pendingCard?.turnID == token || curlToken == token else { return }
            abortInteractive(); resetCurl()
            outgoingPage?.removeFromSuperview(); outgoingPage = nil; turnToken = nil
            invalidateSnapshots(); cachedPage = nil
            controller.error = "The page turn could not finish. Close this book and reopen it to continue."
        }
        func commitCurl(_ direction: String, completion: @escaping () -> Void) {
            let token = UUID(); curlToken = token; curlCompletion = completion
            sendNativeTurn(direction, token: token)
        }
        weak var pagePan: UIPanGestureRecognizer?
        private var panStart: CGPoint?
        private var turnToken: UUID?
        private var outgoingPage: UIImageView?
        private var settlingPage: UIImageView?
        private final class InteractiveSwipe {
            let start: CGPoint
            var translation: CGFloat = 0
            var velocity: CGFloat = 0
            var ended = false
            var allowed: Bool?
            var image: UIImage?
            var outgoing: UIImageView?
            var incoming: UIImageView?
            var direction: String?
            var incomingDirection: String?
            var readyTranslation: CGFloat = 0
            var dragBias: CGFloat = 0
            var animationDone = false
            var mainReady = false
            let turnID = UUID()
            var waitedForPreview = false
            var shouldCommit = false
            init(start: CGPoint) { self.start = start }
        }
        private var interactiveSwipe: InteractiveSwipe?

        private var interactiveFinishing = false
        private var snapshotWeb: WKWebView?
        private var snapshotBooted = false
        private var snapshotOrigin: [String: Any]?
        private var snapshotRequest: String?
        private var snapshotKey: String?
        private var snapshotDirections: [String] = []
        private var adjacentPages: [String: UIImage] = [:]
        private var unavailablePages: Set<String> = []
        private var pendingCard: InteractiveSwipe?
        private var cardAnimator: UIViewPropertyAnimator?
        private var queuedTurns: [String] = []
        private func invalidateSnapshots() {
            snapshotRequest = nil; snapshotKey = nil; snapshotDirections.removeAll()
            adjacentPages.removeAll(); unavailablePages.removeAll()
        }
        private func warmAdjacentPages() {
            guard controller.ready, !latestPreferences.scrolling,
                  ["slide", "curl"].contains(latestPreferences.pageTransition), !UIAccessibility.isReduceMotionEnabled,
                  let web, let host, let cfi = controller.position.cfi, web.bounds.width > 0 else { return }
            let key = cfi + "|" + String(describing: web.bounds.size) + "|" + String(describing: latestPreferences)
            guard key != snapshotKey else { return }
            invalidateSnapshots(); snapshotKey = key
            let request = UUID().uuidString; snapshotRequest = request
            web.evaluateJavaScript("window.readerSnapshotOrigin()") { [weak self] result, _ in
                guard let self, self.snapshotRequest == request else { return }
                guard let origin = result as? [String: Any], origin["cfi"] as? String == self.controller.position.cfi,
                      let size = origin["size"] as? [String:Double],
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
                  let direction = snapshotDirections.first else { return }
            let relative = String(prepared.document.path.dropFirst(prepared.directory.path.count + 1))
            var url = URLComponents(); url.scheme = "appbook"; url.host = "local"; url.path = "/publication/" + relative
            let value: [String: Any] = ["url":url.url!.absoluteString,"origin":origin,"preferences":preferencesObject(),"direction":direction,"request":request]
            guard let data = try? JSONSerialization.data(withJSONObject: ["name":"snapshot","value":value]), let json = String(data:data,encoding:.utf8) else { return }
            snapshotWeb?.evaluateJavaScript("void window.readerCommand(\(json))")
        }
        private func receiveSnapshot(_ value: [String: Any], kind: String) {
            if kind == "boot" { snapshotBooted = true; captureAdjacentPage(); return }
            guard let request = value["request"] as? String, request == snapshotRequest else { return }
            guard kind == "snapshotReady", let direction = value["direction"] as? String,
                  direction == snapshotDirections.first else { invalidateSnapshots(); return }
            if value["exists"] as? Bool != true {
                unavailablePages.insert(direction); snapshotDirections.removeFirst(); captureAdjacentPage()
                if let swipe = interactiveSwipe { updateInteractive(swipe) }
                return
            }
            let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
            snapshotWeb?.takeSnapshot(with: config) { [weak self] image, _ in
                guard let self, self.snapshotRequest == request, direction == self.snapshotDirections.first else { return }
                if let image { self.adjacentPages[direction] = image }
                self.snapshotDirections.removeFirst()
                if let swipe = self.interactiveSwipe { swipe.readyTranslation = swipe.translation; self.updateInteractive(swipe) }
                self.hostController?.refreshNeighbours()
                self.captureAdjacentPage()
            }
        }
        func stopSnapshots() {
            abortInteractive(); invalidateSnapshots()
            snapshotWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
            snapshotWeb?.removeFromSuperview(); snapshotWeb = nil
            curlCompletion = nil; curlToken = nil; curlTurning = false
        }
        private var cachedPage: UIImage?
        private var cachedPageSize: CGSize = .zero
        private var cachedPageCFI: String?
        private var cachedPagePreferences: ReaderPreferences?
        private var cacheRequest = UUID()
        #endif
        init(prepared: PreparedBook, controller: ReaderController) { self.prepared = prepared; self.controller = controller }
        #if os(iOS)
        @objc func readerTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: web)
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
                panStart = gesture.location(in: web)
            case .ended:
                defer { panStart = nil }
                guard let start = panStart, !latestPreferences.scrolling else { return }
                let movement = gesture.translation(in: web)
                guard abs(movement.x) > 60, abs(movement.x) > abs(movement.y) * 1.5 else { return }
                send("gesture", ["action": movement.x < 0 ? "next" : "previous", "x": start.x, "y": start.y])
            case .cancelled, .failed:
                panStart = nil
            default: break
            }
        }
        private func interactivePan(_ gesture: UIPanGestureRecognizer, in web: WKWebView) {
            switch gesture.state {
            case .began:
                finishSettlingForInput()
                if turnToken != nil || pendingCard != nil { panStart = gesture.location(in: web); return }
                guard interactiveSwipe == nil else { return }
                let swipe = InteractiveSwipe(start: gesture.location(in: web))
                swipe.translation = gesture.translation(in: web).x
                interactiveSwipe = swipe
                warmAdjacentPages()
                if cachedPageSize == web.bounds.size, cachedPageCFI == controller.position.cfi,
                   cachedPagePreferences == latestPreferences { swipe.image = cachedPage }
                let point = swipe.start
                web.evaluateJavaScript("window.readerCanTurn(\(point.x),\(point.y))") { [weak self, weak swipe] result, _ in
                    guard let self, let swipe, self.interactiveSwipe === swipe else { return }
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
                guard let swipe = interactiveSwipe else { return }
                swipe.translation = gesture.translation(in: web).x
                swipe.velocity = gesture.velocity(in: web).x
                updateInteractive(swipe)
            case .ended, .cancelled, .failed:
                if panStart != nil {
                    defer { panStart = nil }
                    let movement = gesture.translation(in: web).x, velocity = gesture.velocity(in: web).x
                    if gesture.state == .ended, ReaderTurnDecision.commits(translation: movement, velocity: velocity, width: web.bounds.width) {
                        queueTurn(movement < 0 ? "next" : "previous")
                    }
                    return
                }
                guard let swipe = interactiveSwipe else { return }
                swipe.translation = gesture.translation(in: web).x
                swipe.velocity = gesture.velocity(in: web).x; swipe.ended = true
                swipe.shouldCommit = gesture.state == .ended && ReaderTurnDecision.commits(translation: swipe.translation, velocity: swipe.velocity, width: web.bounds.width)
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
                if swipe.ended { cancelInteractive(swipe, animated: true) }
                return
            }
            if swipe.incomingDirection != direction {
                swipe.incoming?.removeFromSuperview(); swipe.incoming = nil; swipe.incomingDirection = direction
            }
            if swipe.incoming == nil, let image = adjacentPages[direction] {
                let incoming = UIImageView(image: image)
                incoming.frame = host.bounds; incoming.contentMode = .scaleToFill
                incoming.isUserInteractionEnabled = false; incoming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.insertSubview(incoming, belowSubview: outgoing); swipe.incoming = incoming
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
            swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview()
            cacheCurrentPage(); drainTurns()
        }
        private func finishSettlingForInput() {
            settlingPage?.layer.removeAllAnimations(); settlingPage?.removeFromSuperview(); settlingPage = nil
            if let swipe = pendingCard {
                cardAnimator?.stopAnimation(true); cardAnimator = nil
                if swipe.incoming != nil { swipe.outgoing?.removeFromSuperview() }
                swipe.animationDone = true; finishCardIfReady()
            } else if turnToken != nil { outgoingPage?.removeFromSuperview(); outgoingPage = nil }
        }
        private func queueTurn(_ direction: String) {
            finishSettlingForInput()
            queuedTurns.append(direction); drainTurns()
        }
        private func drainTurns() {
            guard turnToken == nil, pendingCard == nil, !curlTurning, interactiveSwipe == nil, !queuedTurns.isEmpty else { return }
            let direction = queuedTurns.removeFirst()
            // The renderer serializes actual changes. Rapid input skips the
            // decorative settling animation rather than dropping page turns.
            let token = UUID(); turnToken = token; sendNativeTurn(direction, token: token)
        }
        private func cancelInteractive(_ swipe: InteractiveSwipe, animated: Bool) {
            guard interactiveSwipe === swipe else { return }
            interactiveSwipe = nil
            guard animated, let outgoing = swipe.outgoing else {
                swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview(); return
            }
            let animator = UIViewPropertyAnimator(duration: 0.16, dampingRatio: 0.95) { outgoing.transform = .identity }
            animator.addCompletion { _ in outgoing.removeFromSuperview(); swipe.incoming?.removeFromSuperview() }
            animator.startAnimation()
        }
        private func abortInteractive() {
            cardAnimator?.stopAnimation(true); cardAnimator = nil
            for swipe in [interactiveSwipe, pendingCard].compactMap({ $0 }) {
                swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview()
            }
            interactiveSwipe = nil; pendingCard = nil; interactiveFinishing = false; queuedTurns.removeAll()
        }
        private func cacheCurrentPage() {
            guard controller.ready, !latestPreferences.scrolling, interactiveSwipe == nil,
                  !interactiveFinishing, !curlTurning, turnToken == nil,
                  let web, let cfi = controller.position.cfi, web.bounds.width > 0 else { return }
            let request = UUID(); cacheRequest = request
            let size = web.bounds.size, preferences = latestPreferences
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            web.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, self.cacheRequest == request, self.interactiveSwipe == nil,
                      self.turnToken == nil, !self.interactiveFinishing, !self.curlTurning,
                      self.controller.position.cfi == cfi, self.latestPreferences == preferences,
                      self.web?.bounds.size == size else { return }
                self.cachedPage = image
                self.cachedPageSize = size
                self.cachedPageCFI = cfi
                self.cachedPagePreferences = preferences
                self.warmAdjacentPages()
            }
        }
        #endif
        func preferences(_ preferences: ReaderPreferences) {
            guard preferences != latestPreferences else { return }
            latestPreferences = preferences
            #if os(iOS)
            abortInteractive(); resetCurl(); invalidateSnapshots()
            cachedPage = nil; cacheRequest = UUID()
            web?.scrollView.isScrollEnabled = preferences.scrolling
            hostController?.configureCurl()
            #endif
            if loaded { send("preferences", preferencesObject()) }
        }
        private var nativeGestures: Bool {
            #if os(iOS)
            true
            #else
            false
            #endif
        }
        func preferencesObject() -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(latestPreferences))) ?? [:] }
        func send(_ command: String, _ value: Any?) {
            #if os(iOS)
            if command == "next" || command == "previous" {
                if turnToken != nil || pendingCard != nil || curlTurning { queueTurn(command) } else { turnPage(command) }
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
            web.takeSnapshot(with: nil) { [weak self, weak web] image, _ in
                guard let self, self.turnToken == token, let web else { return }
                if let image {
                    let outgoing = UIImageView(image: image)
                    outgoing.frame = web.bounds
                    outgoing.contentMode = .scaleToFill
                    outgoing.isUserInteractionEnabled = false
                    outgoing.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    (self.host ?? web).addSubview(outgoing)
                    self.outgoingPage = outgoing
                }
                self.sendNativeTurn(direction, token: token)
            }

        }
        private func finishTurn(direction: String, animated: Bool) {
            guard turnToken != nil else { return }
            turnToken = nil
            defer { drainTurns() }
            guard let outgoing = outgoingPage else { sendRaw("clearSelection", nil); cacheCurrentPage(); return }
            outgoingPage = nil
            guard animated, queuedTurns.isEmpty, let web else { outgoing.removeFromSuperview(); sendRaw("clearSelection", nil); cacheCurrentPage(); return }
            settlingPage = outgoing
            let distance = web.bounds.width * (direction == "next" ? -1 : 1)
            UIView.animate(withDuration: latestPreferences.pageTransition == "fade" ? 0.18 : 0.22,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                outgoing.transform = self.latestPreferences.pageTransition == "fade" ? .identity : CGAffineTransform(translationX: distance, y: 0)
                outgoing.alpha = 0
            } completion: { _ in
                outgoing.removeFromSuperview()
                if self.settlingPage === outgoing { self.settlingPage = nil }
                self.sendRaw("clearSelection", nil)
                self.cacheCurrentPage()
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
                send("open", ["url": components.url!.absoluteString, "cfi": prepared.position.cfi as Any? ?? NSNull(), "fraction": prepared.position.fraction, "preferences": preferencesObject(), "nativeGestures": nativeGestures])
            case "stage": controller.loadingStatus = value["label"] as? String ?? "Opening book…"
            case "ready":
                controller.ready = true
                #if os(iOS)
                cacheCurrentPage()
                #endif
            #if os(iOS)
            case "swipe":
                if let direction = value["direction"] as? String, direction == "next" || direction == "previous" { send(direction, nil) }
            case "selection": textSelectionActive = value["active"] as? Bool ?? false
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
            case "position":
                guard let fraction = value["fraction"] as? Double, fraction.isFinite else { return }
                controller.currentChapter = value["href"] as? String
                controller.chapterTitle = value["chapterTitle"] as? String ?? "Reading"
                controller.chapterPage = value["chapterPage"] as? Int ?? 0
                controller.chapterPageCount = value["chapterPageCount"] as? Int ?? 0
                controller.bookPage = value["bookPage"] as? Int ?? 0
                controller.bookPageCount = value["bookPageCount"] as? Int ?? 0
                controller.update(ReadingPosition(fraction: min(1, max(0, fraction)), cfi: value["cfi"] as? String))
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
                #if os(iOS)
                abortInteractive(); resetCurl()
                finishTurn(direction: "next", animated: false)
                #endif
                controller.error = "This EPUB could not be rendered. It may be damaged or use unsupported content."; controller.searching = false
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "appbook" || scheme == "about" || scheme == "blob" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            #if os(iOS)
            if webView === snapshotWeb { invalidateSnapshots(); return }
            #endif
            controller.error = "The local reader could not be loaded." }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            #if os(iOS)
            if webView === snapshotWeb { stopSnapshots(); snapshotBooted = false; return }
            #endif
            controller.error = "The reader ran out of resources. Close this book and reopen it." }
    }
}
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
    func attach(_ web: WKWebView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        web.frame = view.bounds; web.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(web)
    }
}
@MainActor final class ReaderCurlGate: UIView {
    weak var owner: ReaderHostController?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches, event?.allTouches?.contains(where: { $0.phase == .began }) == true {
            owner?.gateCurlGestures(at: point)
        }
        return super.hitTest(point, with: event)
    }
}
@MainActor final class ReaderHostController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let web: WKWebView
    weak var coordinator: EPUBSurface.Coordinator?
    private var curl: UIPageViewController?
    private var currentPage: ReaderCurlPage?
    private var lastSize = CGSize.zero
    init(web: WKWebView, coordinator: EPUBSurface.Coordinator) {
        self.web = web; self.coordinator = coordinator; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let host = ReaderCurlGate(); host.owner = self; view = host
        web.frame = host.bounds; web.autoresizingMask = [.flexibleWidth, .flexibleHeight]; host.addSubview(web)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
        let enabled = coordinator?.latestPreferences.pageTransition == "curl" && coordinator?.latestPreferences.scrolling == false && !UIAccessibility.isReduceMotionEnabled
        if enabled, curl == nil {
            let page = ReaderCurlPage(offset: 0, image: nil, color: paperColor); page.attach(web)
            let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                                  options: [.spineLocation:UIPageViewController.SpineLocation.min.rawValue])
            controller.view.backgroundColor = paperColor; controller.isDoubleSided = false
            controller.dataSource = self; controller.delegate = self
            addChild(controller); controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view); controller.didMove(toParent: self)
            controller.setViewControllers([page], direction: .forward, animated: false)
            currentPage = page; curl = controller
            gateCurlGestures(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        } else if !enabled, let curl {
            curl.willMove(toParent: nil)
            web.removeFromSuperview(); web.frame = view.bounds; view.addSubview(web)
            curl.view.removeFromSuperview(); curl.removeFromParent(); self.curl = nil; currentPage = nil
        }
    }
    func resetCurlSurface() {
        guard let old = curl else { return }
        old.delegate = nil; old.dataSource = nil; old.willMove(toParent: nil)
        web.removeFromSuperview(); web.frame = view.bounds; view.addSubview(web)
        old.view.removeFromSuperview(); old.removeFromParent(); curl = nil; currentPage = nil
        configureCurl()
    }
    func restoreLivePage() {
        guard let curl else { return }
        curl.delegate = nil
        let page = ReaderCurlPage(offset: 0, image: nil, color: paperColor); page.attach(web)
        curl.setViewControllers([page], direction: .forward, animated: false)
        currentPage = page; curl.delegate = self
    }
    func refreshNeighbours() {
        guard coordinator?.curlTurning == false, let curl, let currentPage else { return }
        curl.dataSource = nil; curl.dataSource = self
        curl.setViewControllers([currentPage], direction: .forward, animated: false)
    }
    func gateCurlGestures(at point: CGPoint) {
        let allowed = coordinator?.canCurl(at: point) == true
        // UIKit retains its own gesture delegates. Only documented recognizer
        // enablement is changed; native taps defer to LibraVia's tap zones.
        for gesture in curl?.gestureRecognizers ?? [] { gesture.isEnabled = allowed && !(gesture is UITapGestureRecognizer) }
    }
    private func neighbour(_ offset: Int) -> ReaderCurlPage? {
        guard abs(offset) == 1, let image = coordinator?.cachedAdjacentPage(offset > 0 ? "next" : "previous") else { return nil }
        return ReaderCurlPage(offset: offset, image: image, color: paperColor)
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
        guard pageViewController === curl else { return }
        guard completed, let page = pageViewController.viewControllers?.first as? ReaderCurlPage, page.offset != 0 else {
            coordinator?.curlTurning = false; coordinator?.resumeQueuedTurns(); return
        }
        commit(page)
    }
    private func commit(_ page: ReaderCurlPage) {
        coordinator?.commitCurl(page.offset > 0 ? "next" : "previous") { [weak self, weak page] in
            guard let self, let page else { return }
            page.offset = 0; page.attach(self.web); self.currentPage = page; self.refreshNeighbours()
        }
    }
    func animateCurl(_ direction: String) -> Bool {
        guard let curl, coordinator?.curlTurning == false, let next = neighbour(direction == "next" ? 1 : -1) else { return false }
        coordinator?.curlTurning = true
        curl.setViewControllers([next], direction: direction == "next" ? .forward : .reverse, animated: true) { [weak self, weak next] completed in
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
        guard gestureRecognizer === pagePan, let pan = gestureRecognizer as? UIPanGestureRecognizer, let web else { return true }
        guard controller.ready, !latestPreferences.scrolling, interactiveSwipe == nil else { return false }
        if latestPreferences.pageTransition == "curl", !UIAccessibility.isReduceMotionEnabled { return false }
        let movement = pan.translation(in: web)
        return abs(movement.x) > abs(movement.y) * 1.5
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pagePan, otherGestureRecognizer === web?.scrollView.panGestureRecognizer { return false }
        return true
    }
}
#endif
