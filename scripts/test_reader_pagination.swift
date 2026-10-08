// Native WebKit regression probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_pagination.swift -o /tmp/libravia-reader-pagination
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-pagination App/Resources/Reader /tmp/libravia-tap-publication
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
                    assert(layoutPages.length>10,'The long fixture must have a complete rendered page map');
                    const page=()=>paginationPosition(rendition.location).bookPage;
                    assert(page()===1,'First page');
                    const chrome=()=>{const info=pageInformation(rendition.location);assert(document.getElementById('page-chapter').textContent===info.chapter,'Page owns its chapter title');assert(document.getElementById('page-progress').textContent===info.progress,'Page owns its actual progress');};
                    chrome();
                    const origin=window.readerSnapshotOrigin();
                    assert(origin.hostSize.height>origin.size.height,'Full page and inset content sizes remain distinct');
                    assert(getComputedStyle(document.getElementById('page')).viewTransitionName==='page','Whole page owns the transition');
                    for(let i=2;i<=layoutPages.length;i++) {
                      await window.readerCommand({name:'next'});await pause(120);
                      assert(page()===i,'Consecutive page '+i+' got '+page());chrome();
                    }
                    for(const target of [1,Math.floor(layoutPages.length/2),layoutPages.length]) {
                      await window.readerCommand({name:'layoutPage',value:target-1});await pause(180);
                      assert(page()===target,'Scrub target '+target+' got '+page());
                    }
                    const before=layoutPages.length;
                    probePreferences.fontSize=30;
                    await queueLayout(probePreferences);await paginationTask;await pause(250);
                    assert(layoutPages.length>before,'Larger type recounts pages');
                    const oldCount=layoutPages.length;
                    resizeViewport({width:500,height:700});
                    await pause(300);await paginationTask;
                    assert(layoutPages.length<oldCount,'Wider viewport recounts pages');
                    const anchor=current;
                    await requestPagination();
                    assert(current===anchor,'Counting cannot move the live reader');
                    resizeViewport({width:900,height:700});await pause(300);await paginationTask;
                    await window.readerCommand({name:'layoutPage',value:0});await pause(200);
                    assert(rendition.manager.layout.divisor===2,'Wide reader uses a two-column spread');
                    assert(page()===1,'First wide spread');
                    for(let i=2;i<=layoutPages.length;i++) {
                      await window.readerCommand({name:'next'});await pause(120);
                      assert(page()===i,'Consecutive wide spread '+i+' got '+page());
                    }
                    for(const target of [1,Math.floor(layoutPages.length/2),layoutPages.length]) {
                      await window.readerCommand({name:'layoutPage',value:target-1});await pause(180);
                      assert(page()===target,'Wide scrub target '+target+' got '+page());
                    }
                    navigationTitles.set(1,'Chapter 7');
                    probePreferences.scrolling=true;
                    await queueLayout(probePreferences);
                    await rendition.display('two.xhtml');await pause(300);
                    const chapterView=rendition.manager.views.find(book.spine.get('two.xhtml'));
                    assert(chapterView.element.querySelector('.reader-chapter-break')?.textContent==='Chapter 7','Visible chapter boundary uses the navigation title');
                    assert(navigationTitles.get(rendition.location.start.index)==='Chapter 7','Current chapter follows content rather than its ordinal');
                    assert(layoutPages.length===0,'Scrolling cannot retain an obsolete page map');
                    return 'Consecutive pages, exact scrub, type/viewport recount, position preservation and chapter boundaries passed';
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
