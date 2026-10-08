import SwiftUI
import WebKit
import UniformTypeIdentifiers

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct EPUBSurface: PlatformViewRepresentable {
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
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        let web = makeWebView(context.coordinator)
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
        context.coordinator.host = container
        return container
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.preferences(preferences) }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.web?.configuration.userContentController.removeScriptMessageHandler(forName: "reader"); coordinator.controller.command = nil; coordinator.stopSnapshots() }
    #endif
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let prepared: PreparedBook
        let controller: ReaderController
        weak var web: WKWebView?
        var latestPreferences = ReaderPreferences()
        var loaded = false
        #if os(iOS)
        weak var host: UIView?
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
            guard controller.ready, !latestPreferences.scrolling, let web, let host,
                  let cfi = controller.position.cfi, web.bounds.width > 0 else { return }
            let key = cfi + "|" + String(describing: web.bounds.size) + "|" + String(describing: latestPreferences)
            guard key != snapshotKey else { return }
            invalidateSnapshots(); snapshotKey = key
            let request = UUID().uuidString; snapshotRequest = request
            web.evaluateJavaScript("window.readerSnapshotOrigin()") { [weak self] result, _ in
                guard let self, self.snapshotRequest == request else { return }
                guard let origin = result as? [String: Any], origin["cfi"] as? String == self.controller.position.cfi else {
                    self.invalidateSnapshots(); return
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
                self.captureAdjacentPage()
            }
        }
        func stopSnapshots() {
            abortInteractive(); invalidateSnapshots()
            snapshotWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
            snapshotWeb?.removeFromSuperview(); snapshotWeb = nil
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
                if turnToken != nil || pendingCard != nil {
                    if turnToken != nil || pendingCard != nil { panStart = gesture.location(in: web); return }
                }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak swipe] in
                guard let self, let swipe, self.pendingCard === swipe else { return }
                // Rendering failure cannot leave a snapshot blocking the book.
                swipe.mainReady = true; self.finishSettlingForInput(); self.finishCardIfReady()
            }
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
            guard turnToken == nil, pendingCard == nil, interactiveSwipe == nil, !queuedTurns.isEmpty else { return }
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
                  !interactiveFinishing, turnToken == nil,
                  let web, let cfi = controller.position.cfi, web.bounds.width > 0 else { return }
            let request = UUID(); cacheRequest = request
            let size = web.bounds.size, preferences = latestPreferences
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            web.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, self.cacheRequest == request, self.interactiveSwipe == nil,
                      self.turnToken == nil, !self.interactiveFinishing,
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
            abortInteractive(); invalidateSnapshots()
            cachedPage = nil; cacheRequest = UUID()
            web?.scrollView.isScrollEnabled = preferences.scrolling
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
                if turnToken != nil || pendingCard != nil { queueTurn(command) } else { turnPage(command) }
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
        }
        private func turnPage(_ direction: String) {
            finishSettlingForInput()
            guard turnToken == nil, interactiveSwipe == nil, !interactiveFinishing, !latestPreferences.scrolling, let web else { return }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard self?.turnToken == token else { return }
                self?.finishTurn(direction: direction, animated: false)
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
            case "turned":
                if let swipe = pendingCard, value["request"] as? String == swipe.turnID.uuidString {
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
                abortInteractive()
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
        let movement = pan.translation(in: web)
        return abs(movement.x) > abs(movement.y) * 1.5
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pagePan, otherGestureRecognizer === web?.scrollView.panGestureRecognizer { return false }
        return true
    }
}
#endif
