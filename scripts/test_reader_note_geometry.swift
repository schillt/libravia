// Native WebKit regression probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_note_geometry.swift -o /tmp/libravia-reader-note-geometry
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-note-geometry App/Resources/Reader /tmp/libravia-tap-publication
import AppKit
import WebKit

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    let readerRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let bookRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    var window: NSWindow!
    var web: WKWebView!
    var finished = false
    var selectedMessage = false
    var contextualSelection = false
    var contextualCommit = false
    var annotationMessage = false
    var highlighterMessage = false
    var fixedLayoutMessage = false
    var fixedProbe: Bool { CommandLine.arguments.count == 4 }
    var selectionEvents: [Bool] = []
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
        } else if kind == "selection" {
            if let active = body["active"] as? Bool { selectionEvents.append(active) }
        } else if kind == "publicationLayout" {
            fixedLayoutMessage = body["fixed"] as? Bool == true
        } else if kind == "highlighterSelectionCommitted" {
            contextualCommit = (body["context"] as? String).map { !$0.isEmpty && $0.utf16.count <= 1024 } == true
            highlighterMessage = body["request"] as? String == "1D3A408B-7840-44E8-A1C6-E90020209001" && (body["cfi"] as? String)?.hasPrefix("epubcfi(") == true
        } else if kind == "annotationActivated" {
            annotationMessage = body["id"] as? String == "1D3A408B-7840-44E8-A1C6-E90020209001"
        } else if kind == "selectedText" {
            contextualSelection = (body["context"] as? String).map { !$0.isEmpty && $0.utf16.count <= 1024 } == true
            selectedMessage = (body["cfi"] as? String)?.hasPrefix("epubcfi(") == true && !(body["text"] as? String ?? "").isEmpty
        } else if kind == "ready" {
            if fixedProbe {
                Task { @MainActor in
                    do {
                        let result = try await web.callAsyncJavaScript("""
                        const content = rendition.getContents()[0];
                        const art = content.document.getElementById('art');
                        const style = content.window.getComputedStyle(art);
                        if (!art || style.position !== 'absolute' || style.left !== '23px' || style.top !== '37px' || style.fontSize !== '31px') throw Error('Authored page composition changed');
                        const css = content.document.getElementById('epubjs-inserted-css-default')?.textContent || '';
                        if (css.includes('font-family') || css.includes('background:')) throw Error('Reader typography overrode fixed layout');
                        return 'Fixed-layout composition preserved';
                        """, arguments: [:], in: nil, contentWorld: .page)
                        guard fixedLayoutMessage else { finish(false, "Fixed layout signal missing"); return }
                        finish(true, result as? String ?? "Fixed-layout check passed")
                    } catch { finish(false, "Fixed-layout check failed: \(error)") }
                }
                return
            }
            Task { @MainActor in
                do {
                    let result = try await web.callAsyncJavaScript("""
                    const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
                    const assert=(ok,label)=>{if(!ok)throw Error(label);};
                    await pause(300);
                    assert(rendition.manager.layout.divisor===2,'Fixture uses a two-column spread');
                    const content=rendition.getContents()[0], doc=content.document;
                    const reader=document.getElementById('reader').getBoundingClientRect();
                    const frame=Array.from(document.querySelectorAll('iframe')).find(f=>f.contentDocument===doc).getBoundingClientRect();
                    const split=(reader.left+reader.right)/2;
                    const walker=doc.createTreeWalker(doc.body,4); let node, left, right, bottom;
                    while ((node=walker.nextNode())) {
                      for(let i=0;i<node.length-1;i+=3) {
                        const range=doc.createRange();range.setStart(node,i);range.setEnd(node,i+1);
                        const box=range.getBoundingClientRect();
                        const x=box.left+frame.left,y=box.top+frame.top;
                        if (x<reader.left || x>=reader.right || y<reader.top || y>=reader.bottom || !box.width || !box.height) continue;
                        const cfi=content.cfiFromRange(range), item={cfi,x,y};
                        if (!left && x<split && y<reader.top+reader.height/2) left=item;
                        if (!right && left && x>=split && Math.abs(y-left.y)<12) right=item;
                        if (!bottom && y>viewportSize.height && y<reader.bottom) bottom=item;
                        if(left && right && bottom) break;
                      }
                      if(left && right && bottom) break;
                    }
                    assert(left && right && bottom,'Found left, right and inset bottom-line text: '+JSON.stringify({reader,frame,left,right,bottom,viewportSize}));
                    const ids=['1D3A408B-7840-44E8-A1C6-E90020209001','1D3A408B-7840-44E8-A1C6-E90020209002','1D3A408B-7840-44E8-A1C6-E90020209003'];
                    const original=doc.body.innerHTML;
                    const anchors=[left,right,bottom].map(item=>content.cfiFromRange(rendition.getRange(item.cfi)));
                    await window.readerCommand({name:'savedHighlights',value:[left,right,bottom].map((item,i)=>({id:ids[i],cfi:item.cfi,hasNote:true,style:i===0?'underline':'highlight',color:'blue'}))});
                    const group=document.querySelector('g.saved-underline'), rect=group?.querySelector('rect'), line=group?.querySelector('line');
                    assert(rect && line,'Underline SVG exists');
                    assert(getComputedStyle(rect).stroke==='none','Underline hit rectangle has no visible outline');
                    assert(getComputedStyle(line).stroke==='rgb(105, 166, 223)','Underline line uses selected blue');
                    assert(getComputedStyle(line).strokeWidth==='2px','Underline line uses selected width');
                    refreshNoteMarkers();
                    const markers=ids.map(id=>document.querySelector(`[data-annotation="${id}"]`));
                    assert(markers.every(Boolean),'Each note has a marker, including the bottom line');
                    const boxes=markers.map(marker=>marker.getBoundingClientRect());
                    assert(boxes[0].left < split && boxes[0].right <= split,'Left-page note uses left-page margin');
                    assert(boxes[1].left >= split && boxes[1].right <= reader.right,'Right-page note uses right-page margin');
                    assert(Math.abs(boxes[0].top-boxes[1].top)<12,'Markers on different pages do not collide vertically');
                    assert(boxes.every(box=>box.top>=reader.top && box.bottom<=reader.bottom),'Markers stay inside content bounds');
                    assert(visibleAnnotationRects(bottom.cfi).length>0,'Bottom line remains hit-testable below content-height coordinate');
                    assert(doc.body.innerHTML===original,'Note markers do not mutate the publication body');
                    assert([left,right,bottom].every((item,i)=>content.cfiFromRange(rendition.getRange(item.cfi))===anchors[i]),'Note markers preserve all selected CFIs');
                    const lower=visibleAnnotationRects(bottom.cfi)[0];
                    assert(activateAnnotationAt((lower.left+lower.right)/2,(lower.top+lower.bottom)/2),'Bottom annotation remains tappable');
                    return 'Both page margins and the inset bottom line passed';
                    """, arguments: [:], in: nil, contentWorld: .page)
                    finish(true, result as? String ?? "Geometry checks passed")
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

guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
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
