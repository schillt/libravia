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
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.web?.configuration.userContentController.removeScriptMessageHandler(forName: "reader"); coordinator.controller.command = nil }
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
        private final class InteractiveSwipe {
            let start: CGPoint
            var translation: CGFloat = 0
            var velocity: CGFloat = 0
            var ended = false
            var allowed: Bool?
            var image: UIImage?
            var outgoing: UIImageView?
            var incoming: UIImageView?
            var underlay: UIView?
            var direction: String?
            var requested = false
            var pageReady = false
            var shouldCommit = false
            init(start: CGPoint) { self.start = start }
        }
        private var interactiveSwipe: InteractiveSwipe?
        private var rollbackSwipe: InteractiveSwipe?
        private var interactiveFinishing = false
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
                guard interactiveSwipe == nil, turnToken == nil, !interactiveFinishing else { return }
                let swipe = InteractiveSwipe(start: gesture.location(in: web))
                let initialMovement = gesture.translation(in: web).x
                if abs(initialMovement) > 1 { swipe.direction = initialMovement < 0 ? "next" : "previous" }
                interactiveSwipe = swipe
                if cachedPageSize == web.bounds.size, cachedPageCFI == controller.position.cfi,
                   cachedPagePreferences == latestPreferences {
                    swipe.image = cachedPage
                }
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
                        swipe.image = image
                        self.updateInteractive(swipe)
                    }
                }
            case .changed:
                guard let swipe = interactiveSwipe else { return }
                swipe.translation = gesture.translation(in: web).x
                swipe.velocity = gesture.velocity(in: web).x
                if swipe.direction == nil, abs(swipe.translation) >= 12 {
                    swipe.direction = swipe.translation < 0 ? "next" : "previous"
                }
                updateInteractive(swipe)
            case .ended, .cancelled, .failed:
                guard let swipe = interactiveSwipe else { return }
                swipe.translation = gesture.translation(in: web).x
                swipe.velocity = gesture.velocity(in: web).x
                swipe.ended = true
                if swipe.direction == nil, abs(swipe.translation) >= 12 {
                    swipe.direction = swipe.translation < 0 ? "next" : "previous"
                }
                let sameDirection = (swipe.direction == "next" && swipe.translation < 0) || (swipe.direction == "previous" && swipe.translation > 0)
                let distance = sameDirection ? abs(swipe.translation) : 0
                let isFlick = distance > 60 && abs(swipe.velocity) > 700 && swipe.translation * swipe.velocity > 0
                swipe.shouldCommit = gesture.state == .ended && (distance >= web.bounds.width * 0.38 || isFlick)
                if swipe.direction == nil || (!swipe.requested && !swipe.shouldCommit) { cancelInteractive(swipe, animated: true) }
                else { updateInteractive(swipe) }
            default: break
            }
        }
        private func updateInteractive(_ swipe: InteractiveSwipe) {
            guard interactiveSwipe === swipe, swipe.allowed == true, let web, let host else { return }
            if swipe.outgoing == nil, let image = swipe.image {
                let underlay = UIView(frame: host.bounds)
                underlay.backgroundColor = switch latestPreferences.theme {
                case "sepia": UIColor(red: 244 / 255, green: 236 / 255, blue: 216 / 255, alpha: 1)
                case "dark": UIColor(white: 23 / 255, alpha: 1)
                default: .white
                }
                underlay.isUserInteractionEnabled = false
                underlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                let paperTexture = UIImageView(image: image)
                paperTexture.frame = underlay.bounds
                paperTexture.contentMode = .scaleToFill
                paperTexture.alpha = 0.16
                paperTexture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                underlay.addSubview(paperTexture)
                host.addSubview(underlay)
                swipe.underlay = underlay
                let outgoing = UIImageView(image: image)
                outgoing.frame = host.bounds
                outgoing.contentMode = .scaleToFill
                outgoing.isUserInteractionEnabled = false
                outgoing.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                outgoing.layer.shadowColor = UIColor.black.cgColor
                outgoing.layer.shadowOpacity = 0.18
                outgoing.layer.shadowRadius = 12
                host.addSubview(outgoing)
                swipe.outgoing = outgoing
            }
            guard let outgoing = swipe.outgoing else {
                if swipe.ended {
                    if swipe.shouldCommit, let direction = swipe.direction { sendRaw(direction, nil) }
                    interactiveSwipe = nil
                }
                return
            }
            let width = max(1, web.bounds.width)
            let offset: CGFloat
            if let direction = swipe.direction {
                offset = direction == "next" ? min(0, swipe.translation) : max(0, swipe.translation)
            } else {
                offset = swipe.translation
            }
            // Let the card track the finger while the faint page texture
            // bridges the short wait for the incoming WebKit snapshot.
            let pull = min(1, abs(offset) / width)
            outgoing.layer.shadowOpacity = Float(0.18 + 0.18 * pull)
            outgoing.layer.shadowRadius = 12 + 10 * pull
            let visibleOffset = offset
            outgoing.transform = CGAffineTransform(translationX: max(-width, min(width, visibleOffset)), y: 0)
            if let incoming = swipe.incoming, let direction = swipe.direction {
                let progress = min(1, abs(visibleOffset) / width)
                let reveal = min(1, progress * 1.4)
                let scale = 0.96 + 0.04 * reveal
                let drift = (direction == "next" ? 1.0 : -1.0) * 24 * (1 - reveal)
                incoming.transform = CGAffineTransform(translationX: drift, y: 0).scaledBy(x: scale, y: scale)
                incoming.alpha = 0.85 + 0.15 * reveal
            }
            if let direction = swipe.direction, !swipe.requested {
                swipe.requested = true
                sendRaw("previewTurn", direction)
            }
            if swipe.ended, swipe.pageReady {
                if swipe.shouldCommit { completeInteractive(swipe) }
                else { rollbackInteractive(swipe) }
            }
        }
        private func completeInteractive(_ swipe: InteractiveSwipe) {
            guard interactiveSwipe === swipe, let web, let outgoing = swipe.outgoing, let direction = swipe.direction else { return }
            interactiveSwipe = nil
            interactiveFinishing = true
            sendRaw("commitTurn", nil)
            let remaining = max(0, 1 - abs(swipe.translation) / max(1, web.bounds.width))
            let duration = max(0.22, min(0.48, 0.48 * remaining))
            let distance = web.bounds.width * (direction == "next" ? -1 : 1)
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                outgoing.transform = CGAffineTransform(translationX: distance, y: 0)
                outgoing.alpha = 0.7
                swipe.incoming?.transform = .identity
                swipe.incoming?.alpha = 1
            } completion: { _ in
                outgoing.removeFromSuperview()
                swipe.incoming?.removeFromSuperview()
                swipe.underlay?.removeFromSuperview()
                self.interactiveFinishing = false
                self.sendRaw("clearSelection", nil)
                self.cacheCurrentPage()
            }
        }
        private func rollbackInteractive(_ swipe: InteractiveSwipe) {
            guard interactiveSwipe === swipe, let outgoing = swipe.outgoing else { return }
            interactiveSwipe = nil
            rollbackSwipe = swipe
            interactiveFinishing = true
            let distance = abs(outgoing.transform.tx)
            let duration = max(0.08, min(0.28, distance / max(1, outgoing.bounds.width) * 0.4))
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                outgoing.transform = .identity
                outgoing.alpha = 1
            } completion: { _ in
                self.sendRaw("cancelTurn", nil)
            }
        }
        private func cancelInteractive(_ swipe: InteractiveSwipe, animated: Bool) {
            guard interactiveSwipe === swipe, !swipe.requested else { return }
            interactiveSwipe = nil
            guard let outgoing = swipe.outgoing, animated else {
                swipe.outgoing?.removeFromSuperview(); swipe.incoming?.removeFromSuperview(); swipe.underlay?.removeFromSuperview(); return
            }
            interactiveFinishing = true
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                outgoing.transform = .identity
            } completion: { _ in
                outgoing.removeFromSuperview()
                swipe.incoming?.removeFromSuperview()
                swipe.underlay?.removeFromSuperview()
                self.interactiveFinishing = false
            }
        }
        private func abortInteractive() {
            guard let swipe = interactiveSwipe ?? rollbackSwipe else { return }
            interactiveSwipe = nil
            rollbackSwipe = nil
            interactiveFinishing = false
            swipe.outgoing?.removeFromSuperview()
            swipe.incoming?.removeFromSuperview()
            swipe.underlay?.removeFromSuperview()
        }
        private func cacheCurrentPage() {
            guard controller.ready, !latestPreferences.scrolling, interactiveSwipe == nil,
                  rollbackSwipe == nil, !interactiveFinishing, turnToken == nil,
                  let web, let cfi = controller.position.cfi, web.bounds.width > 0 else { return }
            let request = UUID(); cacheRequest = request
            let size = web.bounds.size, preferences = latestPreferences
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            web.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, self.cacheRequest == request, self.interactiveSwipe == nil,
                      self.rollbackSwipe == nil, self.turnToken == nil, !self.interactiveFinishing,
                      self.controller.position.cfi == cfi, self.latestPreferences == preferences,
                      self.web?.bounds.size == size else { return }
                self.cachedPage = image
                self.cachedPageSize = size
                self.cachedPageCFI = cfi
                self.cachedPagePreferences = preferences
            }
        }
        #endif
        func preferences(_ preferences: ReaderPreferences) {
            guard preferences != latestPreferences else { return }
            latestPreferences = preferences
            #if os(iOS)
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
            if command == "next" || command == "previous" { turnPage(command); return }
            #endif
            sendRaw(command, value)
        }
        private func sendRaw(_ command: String, _ value: Any?) {
            guard let data = try? JSONSerialization.data(withJSONObject: ["name": command, "value": value ?? NSNull()]), let json = String(data: data, encoding: .utf8) else { return }
            web?.evaluateJavaScript("void window.readerCommand(\(json))") { [weak self] _, error in if error != nil { self?.controller.error = "The EPUB reader could not complete this action." } }
        }
        #if os(iOS)
        private func turnPage(_ direction: String) {
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
                self.sendRaw(direction, nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard self?.turnToken == token else { return }
                self?.finishTurn(direction: direction, animated: false)
            }
        }
        private func finishTurn(direction: String, animated: Bool) {
            guard turnToken != nil else { return }
            turnToken = nil
            guard let outgoing = outgoingPage else { sendRaw("clearSelection", nil); cacheCurrentPage(); return }
            outgoingPage = nil
            guard animated, let web else { outgoing.removeFromSuperview(); sendRaw("clearSelection", nil); cacheCurrentPage(); return }
            let distance = web.bounds.width * 0.8 * (direction == "next" ? -1 : 1)
            UIView.animate(withDuration: latestPreferences.pageTransition == "fade" ? 0.18 : 0.22,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                outgoing.transform = self.latestPreferences.pageTransition == "fade" ? .identity : CGAffineTransform(translationX: distance, y: 0)
                outgoing.alpha = 0
            } completion: { _ in
                outgoing.removeFromSuperview()
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
            case "previewReady":
                if let swipe = interactiveSwipe, swipe.requested {
                    let configuration = WKSnapshotConfiguration()
                    configuration.afterScreenUpdates = true
                    web?.takeSnapshot(with: configuration) { [weak self, weak swipe] image, _ in
                        guard let self, let swipe, self.interactiveSwipe === swipe else { return }
                        if let image, let host = self.host, let outgoing = swipe.outgoing {
                            let incoming = UIImageView(image: image)
                            incoming.frame = host.bounds
                            incoming.contentMode = .scaleToFill
                            incoming.isUserInteractionEnabled = false
                            incoming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                            incoming.alpha = 0
                            host.insertSubview(incoming, belowSubview: outgoing)
                            swipe.incoming = incoming
                        }
                        swipe.pageReady = true
                        if swipe.ended { self.updateInteractive(swipe) }
                        else {
                            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                                self.updateInteractive(swipe)
                            }
                        }
                    }
                }
            case "turnCancelled":
                if let swipe = rollbackSwipe {
                    rollbackSwipe = nil
                    swipe.outgoing?.removeFromSuperview()
                    swipe.incoming?.removeFromSuperview()
                    swipe.underlay?.removeFromSuperview()
                    interactiveFinishing = false
                    sendRaw("clearSelection", nil)
                    cacheCurrentPage()
                }
            case "turned": finishTurn(direction: value["direction"] as? String ?? "next", animated: true)
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
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { controller.error = "The local reader could not be loaded." }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { controller.error = "The reader ran out of resources. Close this book and reopen it." }
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
        guard controller.ready, !latestPreferences.scrolling, turnToken == nil, interactiveSwipe == nil, !interactiveFinishing else { return false }
        let movement = pan.translation(in: web)
        return abs(movement.x) > abs(movement.y) * 1.5
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pagePan, otherGestureRecognizer === web?.scrollView.panGestureRecognizer { return false }
        return true
    }
}
#endif
