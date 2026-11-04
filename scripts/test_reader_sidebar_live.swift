// Native WebKit live inspector resize probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_sidebar_live.swift -o /tmp/libravia-reader-sidebar-live
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-sidebar-live App/Resources/Reader /tmp/libravia-tap-publication
import AppKit
import WebKit

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    let readerRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let bookRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    var window: NSWindow!
    var web: WKWebView!
    var finished = false
    var readyEvents: [[String:Any]] = []
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
        if kind == "sidebarLayoutReady" { readyEvents.append(body); return }
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
                    func js(_ code:String) async throws -> Any? { try await web.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page) }
                    _ = try await js("await paginationTask; await window.readerCommand({name:'layoutPage',value:Math.min(1,layoutPages.length-1)}); await new Promise(r=>setTimeout(r,200)); window.startCFI=current; window.reflows=[]; window.turns=[]; window.snapshots=0; const transition=document.startViewTransition.bind(document); document.startViewTransition=(...a)=>{window.snapshots++;return transition(...a)}; for(const name of ['next','prev']) { const fn=rendition[name].bind(rendition); rendition[name]=(...a)=>{window.turns.push(name);return fn(...a)}; } const r=rendition.resize.bind(rendition); rendition.resize=(w,h,...a)=>{window.reflows.push(w); return r(w,h,...a)}; await window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'live-one',mode:'live'}});")
                    _ = try await js("await window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'live-one'}}); if(!sidebarLive?.endRequested || sidebarLive.sawResize) throw Error('Early end hint ended live session');")
                    try await Task.sleep(for:.milliseconds(150))
                    _ = try await js("if(!sidebarLive || paginationTimer) throw Error('Live session ended before first resize')")
                    for width in [960,920,880,840,800,760,720,680] {
                        window.setContentSize(NSSize(width:width,height:700))
                        try await Task.sleep(for:.milliseconds(35))
                        if width != 680 && readyEvents.contains(where:{($0["request"] as? String)=="live-one" && ($0["settled"] as? Bool)==true}) { finish(false,"Settled before width movement ended: \(readyEvents)"); return }
                    }
                    for _ in 0..<30 {
                        if readyEvents.contains(where:{($0["request"] as? String)=="live-one" && ($0["width"] as? Int)==680 && ($0["settled"] as? Bool)==true}) { break }
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    guard readyEvents.contains(where:{($0["request"] as? String)=="live-one" && ($0["settled"] as? Bool)==false}) else { finish(false,"No intermediate acknowledgement: \(readyEvents)"); return }
                    guard readyEvents.contains(where:{($0["request"] as? String)=="live-one" && ($0["width"] as? Int)==680 && ($0["settled"] as? Bool)==true}) else { finish(false,"No settled acknowledgement: \(readyEvents)"); return }
                    let first = try await js("const cmp=(a,b)=>new ePub.CFI().compare(a,b); const loc=rendition.location; if(snapshots!==0) throw Error('Live reflow captured a snapshot'); if(reflows.length<2 || reflows.length>8) throw Error('Unbounded reflows '+JSON.stringify(reflows)); if(viewportSize.width!==680 || current!==startCFI || cmp(loc.start.cfi,startCFI)>0 || cmp(startCFI,loc.end.cfi)>0) throw Error('Final width or anchor lost '+JSON.stringify({viewportSize,current,startCFI,start:loc.start.cfi,end:loc.end.cfi})); return JSON.stringify({reflows, width:viewportSize.width});")
                    print("FINAL \(first ?? "nil")")
                    guard readyEvents.contains(where:{($0["request"] as? String)=="live-one" && ($0["width"] as? Int)==680}) else { finish(false,"No final 680-pixel acknowledgement: \(readyEvents)"); return }
                    _ = try await js("await window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'old',mode:'live'}}); await window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'new',mode:'live'}}); await window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'old'}}); if(sidebarLive?.request!=='new') throw Error('Stale end ended new session');")
                    readyEvents.removeAll()
                    window.setContentSize(NSSize(width:1000,height:700))
                    try await Task.sleep(for:.milliseconds(40))
                    _ = try await js("await Promise.all([window.readerCommand({name:'next'}),window.readerCommand({name:'next'}),window.readerCommand({name:'previous'})]); await window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'new'}}); await layoutTask; await nextPaint();")
                    for _ in 0..<30 {
                        if readyEvents.contains(where:{($0["request"] as? String)=="new" && ($0["width"] as? Int)==1000 && ($0["settled"] as? Bool)==true}) { break }
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    guard !readyEvents.contains(where:{($0["request"] as? String)=="old"}), readyEvents.contains(where:{($0["request"] as? String)=="new" && ($0["width"] as? Int)==1000 && ($0["settled"] as? Bool)==true}) else { finish(false,"Stale or missing reversal acknowledgement: \(readyEvents)"); return }
                    let ending = try await js("if(current===startCFI || turns.join(',')!=='next,next,prev') throw Error('Turn sequence lost or reordered '+JSON.stringify(turns)); if(snapshots!==0) throw Error('Live mode captured a snapshot'); return JSON.stringify({width:viewportSize.width,live:!!sidebarLive,reflows,turns,snapshots});")
                    print("REVERSAL \(ending ?? "nil")"); finish(true,"Live reflow followed native widths and kept committed turn")
                } catch { let detail=(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? "\(error)"; finish(false,detail) }
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
