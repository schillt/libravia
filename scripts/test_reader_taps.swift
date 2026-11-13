// Native WebKit regression probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_taps.swift -o /tmp/libravia-reader-taps
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-taps App/Resources/Reader /tmp/libravia-tap-publication
import AppKit
import WebKit

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    let readerRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let bookRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    var window: NSWindow!
    var web: WKWebView!
    var finished = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: "appbook")
        config.userContentController.add(self, name: "reader")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 375, height: 700), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        web.load(URLRequest(url: URL(string: "appbook://local/reader/index.html")!))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(50))
            if !finished { finish(false, "Timed out before completing renderer checks") }
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String:Any], let kind = body["kind"] as? String else { return }
        if kind == "boot" {
            Task { @MainActor in
                do {
                    _ = try await web.callAsyncJavaScript("""
                    window.probePreferences={theme:'light',font:'Georgia',fontSize:20,lineHeight:1.6,margin:24,scrolling:false,pageTransition:'instant'};
                    await window.readerCommand({name:'open',value:{url:'appbook://local/publication/OPS/package.opf',fraction:0,preferences:window.probePreferences,nativeGestures:false}});
                    """, arguments: [:], in: nil, contentWorld: .page)
                } catch { finish(false, "Opening renderer failed") }
            }
        } else if kind == "ready" {
            Task { @MainActor in
                do {
                    let result = try await web.callAsyncJavaScript("""
                    const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
                    const assert=(ok,label)=>{if(!ok)throw Error(label);};
                    await pause(400);
                    const original=current;
                    const click=async fraction=>{
                      const viewport=document.getElementById('reader').getBoundingClientRect();
                      await window.readerCommand({name:'gesture',value:{action:'tap',x:viewport.left+viewport.width*fraction,y:100}});
                      await pause(400);
                    };
                    await click(0.95);
                    assert(current!==original,'Right edge tap advances the rendered EPUB');
                    const advanced=current;
                    await click(0.5);
                    assert(current===advanced,'Center click does not move the reading position');
                    await click(0.05);
                    assert(current===original,'Left edge click returns to the original page');
                    probePreferences.pageTapZoneFraction=0.1;
                    await window.readerCommand({name:'preferences',value:probePreferences});await pause(400);
                    const narrow=current;
                    await click(0.85);
                    assert(current===narrow,'Narrow edge setting leaves this point in the center');
                    probePreferences.pageTapZoneFraction=0.3;
                    await window.readerCommand({name:'preferences',value:probePreferences});await pause(400);
                    await click(0.85);
                    assert(current!==narrow,'Wide edge setting turns from the same point');
                    probePreferences.scrolling=true;
                    await window.readerCommand({name:'preferences',value:probePreferences});await pause(500);
                    const scrollAnchor=current;
                    await click(0.95);
                    assert(current===scrollAnchor,'Vertical mode edge click preserves position');
                    return 'Native WebKit edge/center tap commands, zone preferences and scrolling suppression passed';
                    """, arguments: [:], in: nil, contentWorld: .page)
                    finish(true, result as? String ?? "Renderer checks passed")
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
    print("Usage: reader-taps <reader-resource-directory> <extracted-Harbor-directory>")
    exit(2)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let probe = Probe()
    app.delegate = probe
    app.run()
}
