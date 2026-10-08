// Native WebKit regression probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_previews.swift -o /tmp/libravia-reader-previews
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-previews App/Resources/Reader /tmp/libravia-tap-publication
import AppKit
import WebKit

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    let readerRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let bookRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    var window: NSWindow!
    var web: WKWebView!
    var finished = false
    var phase = "opening renderer"
    var preview: WKWebView!
    var previewBooted = false
    var snapshotMessages: [[String:Any]] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: "appbook")
        config.userContentController.add(self, name: "reader")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 375, height: 700), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let previewConfig = WKWebViewConfiguration()
        previewConfig.websiteDataStore = .nonPersistent()
        previewConfig.setURLSchemeHandler(self, forURLScheme: "appbook")
        previewConfig.userContentController.add(self, name: "reader")
        preview = WKWebView(frame: web.frame, configuration: previewConfig)
        let host = NSView(frame: web.frame); host.addSubview(preview); host.addSubview(web)
        window.contentView = host
        preview.load(URLRequest(url: URL(string: "appbook://local/reader/index.html")!))
        window.orderBack(nil)
        web.load(URLRequest(url: URL(string: "appbook://local/reader/index.html")!))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(50))
            if !finished { finish(false, "Timed out while \(phase)") }
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String:Any], let kind = body["kind"] as? String else { return }
        if message.webView === preview {
            if kind == "boot" { previewBooted = true }
            if kind == "snapshotReady" { snapshotMessages.append(body) }
            return
        }
        if kind == "boot" {
            Task { @MainActor in
                do {
                    _ = try await web.callAsyncJavaScript("""
                    window.probePreferences={theme:'light',font:'Georgia',fontSize:20,lineHeight:1.6,margin:24,scrolling:false,pageTransition:'instant'};
                    await window.readerCommand({name:'open',value:{url:'appbook://local/publication/OPS/package.opf',fraction:0,preferences:window.probePreferences,nativeGestures:true}});
                    """, arguments: [:], in: nil, contentWorld: .page)
                } catch { finish(false, "Opening renderer failed") }
            }
        } else if kind == "ready" {
            Task { @MainActor in
                do {
                    for _ in 0..<50 {
                        if previewBooted { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    phase = "counting and positioning live reader"
                    guard previewBooted else { throw NSError(domain: "Preview boot", code: 1) }
                    _ = try await web.callAsyncJavaScript("await paginationTask; await window.readerCommand({name:'layoutPage',value:3}); await new Promise(r=>setTimeout(r,200));", arguments: [:], in: nil, contentWorld: .page)
                    guard let origin = try await web.evaluateJavaScript("window.readerSnapshotOrigin()") as? [String:Any] else { throw NSError(domain:"Origin",code:1) }
                    let before = try await web.evaluateJavaScript("current") as? String
                    let settings: [String:Any] = ["theme":"light","font":"Georgia","fontSize":20,"lineHeight":1.6,"margin":24,"scrolling":false,"pageTransition":"instant"]
                    var fingerprints: [Data] = []
                    var neighbourCFIs: [String:String] = [:]
                    for direction in ["next","previous"] {
                        phase = "preparing \(direction) preview"
                        let value: [String:Any] = ["url":"appbook://local/publication/OPS/package.opf","origin":origin,"preferences":settings,"direction":direction,"request":direction]
                        let location = try await preview.callAsyncJavaScript("""
                        await window.readerCommand({name:'snapshot',value});
                        const p=await rendition.currentLocation();
                        if(p.start.displayed.page !== origin.page+1+(direction==='next'?1:-1))throw Error('Wrong adjacent page: '+p.start.displayed.page);
                        return p.start.cfi;
                        """, arguments: ["value":value,"origin":origin,"direction":direction], in: nil, contentWorld: .page)
                        neighbourCFIs[direction] = location as? String
                        guard (location as? String) != before else { throw NSError(domain:"Duplicate preview",code:1) }
                        let image = try await preview.takeSnapshot(configuration: nil)
                        guard let bytes = image.tiffRepresentation else { throw NSError(domain:"Missing pixels",code:1) }
                        fingerprints.append(bytes)
                        let after = try await web.evaluateJavaScript("current") as? String
                        guard after == before else { throw NSError(domain:"Preview moved live reader",code:1) }
                    }
                    guard fingerprints[0] != fingerprints[1] else { throw NSError(domain:"Identical neighbour images",code:1) }
                    phase = "committing prepared next page"
                    let nextCFI = try await web.callAsyncJavaScript("await window.readerCommand({name:'nativeTurn',value:{direction:'next',request:'actual-next'}}); return (await rendition.currentLocation()).start.cfi;", arguments: [:], in: nil, contentWorld: .page) as? String
                    guard nextCFI == neighbourCFIs["next"] else { throw NSError(domain:"Preview does not match actual next page",code:1) }
                    phase = "executing five rapid turns"
                    _ = try await web.callAsyncJavaScript("""
                    await window.readerCommand({name:'layoutPage',value:3});
                    await Promise.all(Array.from({length:5},(_,i)=>window.readerCommand({name:'nativeTurn',value:{direction:'next',request:'burst-'+i}})));
                    if((await rendition.currentLocation()).start.displayed.page!==8) throw Error('Rapid turns dropped or doubled');
                    await window.readerCommand({name:'layoutPage',value:1});
                    """, arguments: [:], in: nil, contentWorld: .page)
                    guard let first = try await web.evaluateJavaScript("window.readerSnapshotOrigin()") as? [String:Any] else { throw NSError(domain:"First page origin",code:1) }
                    let boundary: [String:Any] = ["url":"appbook://local/publication/OPS/package.opf","origin":first,"preferences":settings,"direction":"previous","request":"boundary"]
                    _ = try await preview.callAsyncJavaScript("await window.readerCommand({name:'snapshot',value});", arguments: ["value":boundary], in: nil, contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(100))
                    guard snapshotMessages.last?["request"] as? String == "boundary", snapshotMessages.last?["exists"] as? Bool == false else { throw NSError(domain:"False previous page at book start",code:1) }
                    let result = "Real adjacent previews match committed pages; peeking preserves position; five rapid turns and book-start boundary pass"
                    finish(true, result)
                } catch {
                    let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? "JavaScript check failed"
                    finish(false, detail)
                }
            }
        } else if kind == "error" { finish(false, "Production renderer reported an error") }
    }
    func finish(_ passed: Bool, _ message: String) {
        guard !finished else { return }; finished = true
        print((passed ? "PASS: " : "FAIL: ") + message)
        fflush(stdout)
        exit(passed ? 0 : 1)
    }
    nonisolated func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated {
            guard let url = task.request.url else { return }
            let base = url.path.hasPrefix("/reader/") ? readerRoot : bookRoot
            let path = url.path.hasPrefix("/reader/") ? String(url.path.dropFirst(8)) : String(url.path.dropFirst(13))
            let file = base.appendingPathComponent(path)
            do {
                let data = try Data(contentsOf: file)
                let mime: String
                switch file.pathExtension {
                case "html": mime = "text/html"
                case "xhtml": mime = "application/xhtml+xml"
                case "opf", "xml": mime = "application/xml"
                case "js": mime = "text/javascript"
                case "css": mime = "text/css"
                default: mime = "application/octet-stream"
                }
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":mime,"Access-Control-Allow-Origin":"*"])!)
                task.didReceive(data);task.didFinish()
            } catch { task.didFailWithError(error) }
        }
    }
    nonisolated func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

guard CommandLine.arguments.count == 3 else {
    print("Usage: reader-previews <reader-resource-directory> <extracted-Harbor-directory>")
    exit(2)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let probe = Probe()
    app.delegate = probe
    app.run()
}
