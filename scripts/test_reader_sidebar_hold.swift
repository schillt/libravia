// Native WebKit regression probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_sidebar_hold.swift -o /tmp/libravia-reader-sidebar-hold
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-sidebar-hold App/Resources/Reader /tmp/libravia-tap-publication
import AppKit
import WebKit

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    let readerRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let bookRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    var window: NSWindow!
    var web: WKWebView!
    var finished = false
    var sidebarReadyEvents: [[String:Any]] = []
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
        if kind == "sidebarLayoutReady" { sidebarReadyEvents.append(body); return }
        if kind == "boot" {
            Task { @MainActor in
                do {
                    _ = try await web.callAsyncJavaScript("""
                    window.probePreferences={theme:'dark',font:'Georgia',fontSize:20,lineHeight:1.6,margin:24,scrolling:false,pageTransition:'instant',pageChrome:{enabled:true,showChapter:true,showProgress:true,top:52,bottom:60,textSize:12}};
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
                    let initial=current; const height=viewportSize.height;
                    let initialLocation=rendition.location;
                    const initialContents=rendition.getContents()[0];
                    const pageBackground=getComputedStyle(document.getElementById('page')).backgroundColor;
                    if(pageBackground !== 'rgb(23, 23, 23)' || getComputedStyle(document.documentElement).backgroundColor !== pageBackground) throw Error('Dark root/page paper mismatch: '+pageBackground);
                    for (const [theme,expected] of [['sepia','rgb(244, 236, 216)'],['light','rgb(255, 255, 255)'],['dark','rgb(23, 23, 23)']]) { preferences({...probePreferences,theme}); const actual=getComputedStyle(document.getElementById('page')).backgroundColor; if(actual!==expected || getComputedStyle(document.documentElement).backgroundColor!==expected) throw Error('Theme mismatch '+theme+': '+actual); }
                    if(initialContents.window.getComputedStyle(initialContents.document.querySelector('p')).fontSize !== '20px') throw Error('Initial reader typography was not injected');
                    if(initialLocation.start.index!==0 || initialLocation.start.displayed.page<=1) throw Error('Expected a nonzero position in first chapter: '+JSON.stringify(initialLocation.start));
                    const reflows=[], originalResize=rendition.resize.bind(rendition);
                    rendition.resize=(width,height,...args)=>{reflows.push(width);return originalResize(width,height,...args);};
                    // Eight width observations must remain under one hold until
                    // the matching native completion, including stale completions.
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'one'}});
                    resizeViewport({width:960,height}); await pause(120);
                    if(!activeReflowTransition || !sidebarHold) throw Error('Initial hold was not active');
                    for(const [theme,expected] of [['light','rgb(255, 255, 255)'],['sepia','rgb(244, 236, 216)'],['dark','rgb(23, 23, 23)']]) { preferences({...probePreferences,theme}); if(getComputedStyle(document.documentElement,'::view-transition').backgroundColor!==expected) throw Error('Transition backdrop mismatch '+theme); }
                    for (const width of [920,880,840,800,760,720,680]) { resizeViewport({width,height}); await pause(40); if(!activeReflowTransition || !sidebarHold) throw Error('Snapshot released before native completion '+width); }
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'two'}});
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'one'}});
                    await pause(30);
                    if(!sidebarHold || sidebarHold.request!=='two') throw Error('Stale completion released superseding hold');
                    resizeViewport({width:1000,height});
                    const heldLayout=layoutTask;
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'two'}});
                    await heldLayout; await pause(450);
                    if(current!==initial || rendition.location.start.cfi!==initialLocation.start.cfi) throw Error('Held resize failed to restore the passage or spread');
                    if(reflows.length) throw Error('Returning to the original width performed intermediate reflows: '+reflows);
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'four'}});
                    resizeViewport({width:940,height}); await pause(120);
                    resizeViewport({width:920,height});
                    const narrower=layoutTask;
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'four'}});
                    await narrower; await pause(450);
                    if(reflows.length!==1 || reflows[0]!==920) throw Error('Expected only the final held width: '+reflows);
                    resizeViewport({width:1000,height}); await layoutTask;
                    if(current!==initial || rendition.location.start.cfi!==initialLocation.start.cfi) throw Error('Narrow round trip lost the original passage');
                    reflows.length=0;
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'three'}});
                    resizeViewport({width:960,height}); await pause(100);
                    const pending=layoutTask, turnRequest=window.readerCommand({name:'next'});
                    await Promise.all([pending,turnRequest]); await pause(450);
                    if(sidebarHold || current===initial) throw Error('Committed turn failed to interrupt hold '+JSON.stringify({hold:!!sidebarHold,current,initial,location:rendition.location.start.cfi,layout:!!layoutTask}));
                    await window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'three'}});
                    const afterInterruptedTurn=current;
                    resizeViewport({width:900,height}); await layoutTask; await pause(150);
                    const afterStart=rendition.location.start.cfi, afterEnd=rendition.location.end.cfi;
                    if(current!==afterInterruptedTurn || cmp(afterStart,afterInterruptedTurn)>0 || cmp(afterInterruptedTurn,afterEnd)>0) throw Error('Later resize lost interrupted-turn position '+JSON.stringify({afterInterruptedTurn,current,afterStart,afterEnd}));
                    await window.readerCommand({name:'layoutPage',value:Math.min(1,layoutPages.length-1)});
                    resizeViewport({width:1000,height}); await layoutTask;
                    await window.readerCommand({name:'layoutPage',value:Math.min(1,layoutPages.length-1)});
                    return "Held eight widths, ignored stale completion, restored spread and interrupted hold with committed page turn";
                    """, arguments: [:], in: nil, contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(200))
                    @MainActor func received(_ request: String, width: Int) -> Bool {
                        sidebarReadyEvents.contains { ($0["request"] as? String) == request && ($0["width"] as? Int) == width }
                    }
                    guard !sidebarReadyEvents.contains(where: { ($0["request"] as? String) == "one" }),
                          received("two", width: 1000), received("four", width: 920),
                          received("three", width: 960) else {
                        finish(false, "Unexpected sidebar layout acknowledgements: \(sidebarReadyEvents)"); return
                    }
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
