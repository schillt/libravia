// macOS WebKit probe for continuous scrolling through viewport and visibility
// changes. This does not simulate iPhone locking or replace device acceptance.
// Compile: swiftc scripts/test_reader_scroll_resume.swift -o /tmp/libravia-reader-scroll-resume
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-scroll-resume App/Resources/Reader /tmp/libravia-tap-publication
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
                    window.probePreferences={theme:'light',font:'Georgia',fontSize:20,lineHeight:1.6,margin:24,scrolling:true,pageTransition:'instant',pageChrome:{enabled:true,showChapter:true,showProgress:true,top:52,bottom:60,textSize:12}};
                    await window.readerCommand({name:'open',value:{url:'appbook://local/publication/OPS/package.opf',fraction:0,preferences:window.probePreferences,nativeGestures:false}});
                    """, arguments: [:], in: nil, contentWorld: .page)
                } catch { finish(false, "Opening renderer failed") }
            }
        } else if kind == "ready" {
            Task { @MainActor in
                do {
                    let result = try await web.callAsyncJavaScript("""
                    const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
                    if(document.visibilityState !== 'visible') throw Error('The WebKit window must be visible before this probe can test hide/show');
                    const cmp=(a,b)=>new ePub.CFI().compare(a,b);
                    const target=book.locations.cfiFromPercentage(0.65);
                    await rendition.display(target); await pause(350); await rendition.reportLocation(); await pause(100);
                    const anchor=current;
                    if(!scrolling || !anchor || book.locations.percentageFromCfi(anchor)<0.1) throw Error('Fixture must begin well inside the publication: '+JSON.stringify({visibility:document.visibilityState,anchor,percent:anchor && book.locations.percentageFromCfi(anchor)}));
                    const trace=[];
                    for(let cycle=0;cycle<3;cycle++) {
                      resizeViewport({width:0,height:0});
                      resizeViewport({width:375,height:520}); await layoutTask; await pause(150);
                      resizeViewport({width:375,height:700}); await layoutTask; await pause(250);
                      const start=rendition.location.start.cfi, end=rendition.location.end.cfi;
                      trace.push({start,end,current,anchor,inside:cmp(start,anchor)<=0 && cmp(anchor,end)<=0});
                      if(current!==anchor || cmp(start,anchor)>0 || cmp(anchor,end)>0)
                        throw Error('Continuous reading lost its passage after transient viewport change: '+JSON.stringify(trace));
                    }
                    window.__probeResumed=false;
                    send('probeHide');
                    for(let i=0;i<60 && !window.__probeResumed;i++) await pause(50);
                    if(!window.__probeResumed) throw Error('Native visibility cycle did not finish');
                    if(window.__probeHiddenVisibility!=='hidden') throw Error('Native window did not put WebKit into the hidden state: '+window.__probeHiddenVisibility);
                    if(window.__probeHiddenRetained!==true) throw Error('A hidden relocation replaced the saved position');
                    for(let i=0;i<80 && visibilityAnchor;i++) await pause(50);
                    if(visibilityAnchor) throw Error('The visible passage did not settle');
                    await rendition.reportLocation(); await pause(150);
                    const start=rendition.location.start.cfi, end=rendition.location.end.cfi;
                    if(current!==anchor || cmp(start,anchor)>0 || cmp(anchor,end)>0)
                      throw Error('Continuous reading lost its passage after native hide/show: '+JSON.stringify({anchor,current,start,end}));
                    const destinationCFI=new ePub.CFI(book.locations.cfiFromPercentage(0.30));
                    destinationCFI.collapse(true);
                    const destination=destinationCFI.toString();
                    await window.readerCommand({name:'seek',value:{cfi:destination}});
                    await pause(200); await rendition.reportLocation(); await pause(150);
                    const directStart=rendition.location.start.cfi;
                    if(cmp(directStart,destination)>0 || cmp(destination,rendition.location.end.cfi)>0) {
                      const range=rendition.getRange(destination), rect=range?.getBoundingClientRect();
                      const frame=range?.startContainer?.ownerDocument?.defaultView?.frameElement?.getBoundingClientRect();
                      const viewport=document.getElementById('reader').getBoundingClientRect();
                      const view=rendition.manager.views.find(book.spine.get(destination));
                      throw Error('Direct navigation did not show its requested point: '+JSON.stringify({destination,location:rendition.location,rect:rect?.toJSON(),frame:frame?.toJSON(),viewport:viewport.toJSON(),scrollTop:rendition.manager.container.scrollTop,viewOffset:view?.offset(),targetOffset:view?.locationOf(destination)}));
                    }
                    visibilityAnchor=anchor;
                    await rendition.display(book.locations.cfiFromPercentage(0.02));
                    await rendition.reportLocation();
                    const originalDisplay=rendition.display.bind(rendition);
                    let release, began;
                    const started=new Promise(resolve=>began=resolve);
                    const gate=new Promise(resolve=>release=resolve);
                    let intercept=true;
                    rendition.display=async cfi=>{
                      if(intercept) { intercept=false; began(); await gate; }
                      return originalDisplay(cfi);
                    };
                    scheduleVisibilityRestore(++visibilityGeneration);
                    await Promise.race([started,pause(5000).then(()=>{throw Error('Restore display did not start')})]);
                    const seek=window.readerCommand({name:'seek',value:{cfi:destination}});
                    await pause(50); release(); await seek;
                    rendition.display=originalDisplay;
                    await rendition.reportLocation(); await pause(150);
                    const sought=rendition.location;
                    if(sought.start.cfi!==directStart)
                      throw Error('Delayed restore changed the direct navigation result: '+JSON.stringify({destination,directStart,location:sought}));
                    const nextChapterCFI=new ePub.CFI(book.locations.cfiFromPercentage(0.85));
                    nextChapterCFI.collapse(true);
                    const nextChapter=nextChapterCFI.toString();
                    await window.readerCommand({name:'seek',value:{cfi:nextChapter}});
                    await pause(200); await rendition.reportLocation(); await pause(150);
                    const nextLocation=rendition.location;
                    if(cmp(nextLocation.start.cfi,nextChapter)>0 || cmp(nextChapter,nextLocation.end.cfi)>0)
                      throw Error('Cross-chapter navigation did not show the chosen point: '+JSON.stringify({nextChapter,location:nextLocation}));
                    return 'Continuous reading retained its passage through visibility changes and an interrupted restore';
                    """, arguments: [:], in: nil, contentWorld: .page)
                    finish(true, result as? String ?? "Renderer checks passed")
                } catch {
                    let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? "JavaScript check failed"
                    finish(false, detail)
                }
            }
        } else if kind == "probeHide" {
            window.orderOut(nil)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                let visibility = (try? await web.evaluateJavaScript("document.visibilityState")) as? String ?? "unavailable"
                var retained = false
                if visibility == "hidden" {
                    retained = ((try? await web.callAsyncJavaScript("""
                    const before = current;
                    await rendition.display(book.locations.cfiFromPercentage(0.02));
                    await rendition.reportLocation();
                    return current === before;
                    """, arguments: [:], in: nil, contentWorld: .page)) as? Bool) == true
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                _ = try? await web.callAsyncJavaScript("window.__probeHiddenVisibility=visibility; window.__probeHiddenRetained=retained; window.__probeResumed=true", arguments: ["visibility":visibility, "retained":retained], in: nil, contentWorld: .page)
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
    print("Usage: reader-scroll-resume <reader-resource-directory> <extracted-Harbor-directory>")
    exit(2)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let probe = Probe()
    app.delegate = probe
    app.run()
}
