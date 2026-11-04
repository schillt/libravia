// Native WebKit regression probe using the CC0 Harbor fixture.
// Compile: swiftc scripts/test_reader_selection.swift -o /tmp/libravia-reader-selection
// Extract Fixtures/Harbor.epub into /tmp/libravia-tap-publication, then run:
// /tmp/libravia-reader-selection App/Resources/Reader /tmp/libravia-tap-publication
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
                    const chapter=rendition.location.start.index, oldTitle=navigationTitles.get(chapter);
                    navigationTitles.set(chapter,'A deliberately long chapter title '.repeat(20)); updatePageInformation(rendition.location);
                    const title=document.getElementById('chapter-title'), header=document.getElementById('page-chapter');
                    assert(getComputedStyle(title).webkitLineClamp==='2','Long chapter titles use a bounded two-line label');
                    assert(title.getBoundingClientRect().height <= parseFloat(getComputedStyle(title).lineHeight)*2+1,'Chapter title stays within two lines');
                    assert(header.getBoundingClientRect().bottom <= document.getElementById('reader').getBoundingClientRect().top+1,'Title stays above book content');
                    if(oldTitle===undefined) navigationTitles.delete(chapter); else navigationTitles.set(chapter,oldTitle);
                    updatePageInformation(rendition.location);
                    const contents=rendition.getContents()[0];
                    assert(contents && contents.document,'Chapter contents available');
                    const walker=contents.document.createTreeWalker(contents.document.body,4);
                    let node; while((node=walker.nextNode()) && node.textContent.trim().length<8) {}
                    assert(node,'Fixture has selectable text');
                    let selectedCFI;
                    const range=contents.document.createRange(); range.setStart(node,0); range.setEnd(node,Math.min(node.length,8));
                    const selection=contents.window.getSelection();selection.removeAllRanges();selection.addRange(range); selectedCFI=contents.cfiFromRange(range); 
                    await pause(1000);
                    assert(selectedCFI && selectedCFI.startsWith('epubcfi('),'EPUB.js produces selected range CFI: '+selection.rangeCount+' text '+selection.toString()+' collapsed '+selection.isCollapsed);
                    assert(selectionContext(range,selection.toString()).includes(selection.toString()),'Selection context preserves the excerpt');
                    assert(contents.cfiFromRange(range)===selectedCFI,'Capturing context leaves the exact location unchanged');
                    await window.readerCommand({name:'commitHighlightSelection',value:{request:'1D3A408B-7840-44E8-A1C6-E90020209001'}});
                    await window.readerCommand({name:'savedHighlights',value:[selectedCFI]});
                    assert(Object.keys(rendition.annotations._annotations).length===1,'Saved highlight was registered');
                    const id='1D3A408B-7840-44E8-A1C6-E90020209001';
                    await window.readerCommand({name:'savedHighlights',value:[{id,cfi:selectedCFI,color:'blue',style:'underline',hasNote:true}]});
                    await pause(100);
                    refreshNoteMarkers();
                    assert(document.querySelectorAll('.reader-note-marker').length===1,'A saved note has one margin button');
                    const boxes=visibleAnnotationRects(selectedCFI);
                    assert(boxes.length>0,'Saved annotation has a visible range');
                    assert(activateAnnotationAt((boxes[0].left+boxes[0].right)/2,(boxes[0].top+boxes[0].bottom)/2),'Clicking the passage activates the saved annotation');
                    await queueLayout({...probePreferences,fontSize:24}); await pause(300);
                    assert(Object.keys(rendition.annotations._annotations).length===1,'Saved annotation survives typography reflow');
                    assert(Object.values(rendition.annotations._annotations)[0].mark,'Saved highlight attaches to the reflowed view');
                    assert(document.querySelectorAll('.reader-note-marker').length===1,'Note marker returns after reflow');
                    let prose=rendition.getContents()[0].document.querySelector('p');
                    assert(prose,'Fixture has prose');
                    prose.style.fontFamily='monospace'; prose.style.fontSize='13px'; prose.style.lineHeight='1.1';
                    assert(rendition.getContents()[0].window.getComputedStyle(prose).fontSize==='24px','Reader typography overrides publisher prose');
                    await queueLayout({...probePreferences,originalFormatting:true}); await pause(300);
                    let active=rendition.getContents()[0];
                    prose=active.document.querySelector('p');
                    assert(active.window.getComputedStyle(prose).fontSize==='13px','Original mode restores publisher prose size');
                    let css=active.document.getElementById('epubjs-inserted-css-default')?.textContent || '';
                    assert(!css.includes('font-family') && !css.includes('font-size'),'Original mode removes previous reader typography');
                    assert(rendition.getRange(selectedCFI),'Original mode preserves the selected CFI');
                    await queueLayout({...probePreferences,originalFormatting:false}); await pause(300);
                    active=rendition.getContents()[0]; css=active.document.getElementById('epubjs-inserted-css-default')?.textContent || '';
                    assert(css.includes('font-family') && css.includes('font-size'),'Reader typography returns after switching back');
                    assert(active.window.getComputedStyle(active.document.querySelector('p')).fontSize==='20px','Reader prose styling returns');
                    assert(rendition.getRange(selectedCFI),'Returning to reader style preserves the selected CFI');
                    await window.readerCommand({name:'location',value:selectedCFI});
                    assert(Object.values(rendition.annotations._annotationsBySectionIndex).flat().length===1,'Search does not duplicate saved overlay');
                    await window.readerCommand({name:'clearSelection'});  await pause(150);
                    await window.readerCommand({name:'annotationLocation',value:selectedCFI});
                    await pause(100);
                    await window.readerCommand({name:'savedHighlights',value:[]});
                    assert(Object.keys(rendition.annotations._annotations).length===0,'Saved highlight was removed');
                    await window.readerCommand({name:'location',value:selectedCFI});
                    await window.readerCommand({name:'location',value:selectedCFI});
                    await window.readerCommand({name:'savedHighlights',value:[selectedCFI]});
                    assert(Object.values(rendition.annotations._annotationsBySectionIndex).flat().length===1,'Saved overlay replaces existing search mark');
                    await window.readerCommand({name:'savedHighlights',value:[]});
                    assert(Object.keys(rendition.annotations._annotations).length===0,'Replacement mark is removed');
                    return 'Selection CFI, saved overlay, jump and removal passed';
                    """, arguments: [:], in: nil, contentWorld: .page)
                    guard contextualSelection && contextualCommit else { finish(false, "Bounded selection context was not delivered for native actions and tool commits"); return }
                    guard highlighterMessage else { finish(false, "Completed tool selection was not delivered to native"); return }
                    guard annotationMessage else { finish(false, "Saved annotation activation was not delivered to native"); return }
                    guard selectedMessage else { finish(false, "Selected text was not delivered to the native bridge"); return }
                    guard selectionEvents.contains(true), selectionEvents.last == false else { finish(false, "Selection activity was not delivered for selected and cleared states: \(selectionEvents)"); return }
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
