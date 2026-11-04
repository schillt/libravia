// Native WebKit regression probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_resize_anchor.swift -o /tmp/libravia-reader-resize-anchor
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-resize-anchor App/Resources/Reader /tmp/libravia-tap-publication
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
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
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
                    window.probePreferences={theme:'light',font:'Georgia',fontSize:20,lineHeight:1.6,margin:24,scrolling:false,pageTransition:'instant',pageChrome:{enabled:true,showChapter:true,showProgress:true,top:52,bottom:60,textSize:12}};
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
                    await paginationTask;
                    const cmp=(a,b)=>new ePub.CFI().compare(a,b);
                    await window.readerCommand({name:'layoutPage',value:Math.min(1,layoutPages.length-1)});
                    await pause(200);
                    const initial=current, height=viewportSize.height;
                    const initialLocation=rendition.location;
                    const initialContents=rendition.getContents()[0];
                    if(initialContents.window.getComputedStyle(initialContents.document.querySelector('p')).fontSize !== '20px') throw Error('Initial reader typography was not injected');
                    if(initialLocation.start.index!==0 || initialLocation.start.displayed.page<=1) throw Error('Expected a nonzero position in first chapter: '+JSON.stringify(initialLocation.start));
                    await queueLayout({...probePreferences,fontSize:24}); await pause(150);
                    let firstStart=rendition.location.start.cfi, firstEnd=rendition.location.end.cfi;
                    if(current!==initial || cmp(firstStart,initial)>0 || cmp(initial,firstEnd)>0) throw Error('Typography-only reflow lost the precise passage');
                    await queueLayout({...probePreferences,fontSize:20}); await pause(150);
                    if(current!==initial || rendition.location.start.cfi!==initialLocation.start.cfi) throw Error('Typography-only round trip did not restore the original spread');
                    let trace=[];
                    function inspect(width) {
                      const start=rendition.location.start.cfi, end=rendition.location.end.cfi;
                      trace.push({width,start,end,anchorVisible:cmp(start,initial)<=0 && cmp(initial,end)<=0});
                    }
                    inspect(1000);
                    await window.readerCommand({name:'sidebarTransition'});
                    for(const width of [960,920,880,840,800,760,720,680]) {
                      resizeViewport({width,height}); await layoutTask; await pause(60); inspect(width);
                    }
                    await pause(400);
                    await window.readerCommand({name:'sidebarTransition'});
                    for(const width of [720,760,800,840,880,920,960,1000]) {
                      resizeViewport({width,height}); await layoutTask; await pause(60); inspect(width);
                    }
                    if (trace.some(step=>!step.anchorVisible) || current !== initial) throw Error('Resize lost the precise reading anchor: '+JSON.stringify({initial,trace,current}));
                    if (rendition.location.start.cfi !== initialLocation.start.cfi) throw Error('Original spread was not restored: '+JSON.stringify({initial,trace,resizeOrigin,resizeAnchor,viewportSize,signature:paginationSignature(),currentLocation:rendition.location}));
                    const realNext=rendition.next;
                    rendition.next=async()=>{throw Error('synthetic rejected turn');};
                    let rejected=false;
                    try { await turn('next'); } catch (_) { rejected=true; }
                    rendition.next=realNext;
                    if(!rejected || current!==initial || resizeAnchor!==initial) throw Error('A failed turn discarded the retained passage');
                    await queueLayout({...probePreferences,fontSize:24}); await pause(150);
                    let start=rendition.location.start.cfi, end=rendition.location.end.cfi;
                    if(current!==initial || cmp(start,initial)>0 || cmp(initial,end)>0) throw Error('Typography after resize lost the passage: '+JSON.stringify({current,initial,start,end,resizeAnchor,resizeBoundary}));
                    await queueLayout({...probePreferences,fontSize:20}); await pause(150);
                    start=rendition.location.start.cfi; end=rendition.location.end.cfi;
                    if(current!==initial || cmp(start,initial)>0 || cmp(initial,end)>0) throw Error('Returning typography lost the passage');
                    if(start !== initialLocation.start.cfi) throw Error('Matching typography and layout did not restore the original spread');
                    await queueLayout({...probePreferences,fontSize:24}); await pause(150);
                    await window.readerCommand({name:'previewTurn',value:'next'});
                    await window.readerCommand({name:'cancelTurn'});
                    if (current !== initial) throw Error('Cancelled preview changed the precise passage');
                    resizeViewport({width:960,height});
                    const resizeInFlight=layoutTask;
                    const turnInFlight=window.readerCommand({name:'next'});
                    await Promise.all([resizeInFlight,turnInFlight]); await pause(150);
                    const afterTurn=current;
                    if (afterTurn === initial) throw Error('Interleaved page turn was not honored');
                    if (resizeOrigin !== null) throw Error('A page turn retained a stale spread origin');
                    for (const width of [940,880,820,760,700,680,760,840,920,1000]) {
                      resizeViewport({width,height}); await layoutTask; await pause(60);
                      const start=rendition.location.start.cfi, end=rendition.location.end.cfi;
                      if (cmp(start,afterTurn)>0 || cmp(afterTurn,end)>0 || current!==afterTurn)
                        throw Error('Resize restored a stale pre-turn passage at width '+width);
                    }
                    await queueLayout({...probePreferences,fontSize:20}); await pause(150);
                    start=rendition.location.start.cfi; end=rendition.location.end.cfi;
                    if(current!==afterTurn || cmp(start,afterTurn)>0 || cmp(afterTurn,end)>0) throw Error('Typography returned to a stale pre-turn passage');
                    await requestPagination();
                    await window.readerCommand({name:'layoutPage',value:0}); await pause(150);
                    resizeViewport({width:900,height}); await layoutTask; await pause(100);
                    const last=current, lastBoundary=rendition.location.start.cfi;
                    await window.readerCommand({name:'previous'}); await pause(100);
                    if(rendition.location.start.cfi !== lastBoundary) throw Error('Fixture did not reach the first page boundary');
                    if(current !== last || resizeAnchor !== last) throw Error('A boundary turn discarded the retained passage');
                    await queueLayout({...probePreferences,scrolling:true}); await pause(150);
                    if(!scrolling || resizeAnchor !== null || resizeOrigin !== null) throw Error('Entering scroll mode retained a paginated origin');
                    await queueLayout({...probePreferences,scrolling:true,fontSize:24}); await pause(150);
                    if(!scrolling || resizeAnchor !== null || resizeOrigin !== null) throw Error('Scrolling typography created a paginated anchor');
                    await queueLayout({...probePreferences,scrolling:false}); await pause(150);
                    if(scrolling || resizeAnchor !== null || resizeOrigin !== null) throw Error('Returning to pages retained a stale origin');
                    return 'Resize retained its passage and rebased only after a page turn';
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
    print("Usage: reader-pagination <reader-resource-directory> <extracted-Harbor-directory>")
    exit(2)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let probe = Probe()
    app.delegate = probe
    app.run()
}
