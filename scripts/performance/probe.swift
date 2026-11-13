// Isolated framework/renderer timings, never physical UI acceptance.
import Foundation
import AppKit
import PDFKit
import ImageIO
import WebKit

func elapsed(_ body: () throws -> Void) rethrows -> Double {
    let start = ProcessInfo.processInfo.systemUptime
    try body()
    return (ProcessInfo.processInfo.systemUptime - start) * 1000
}
func output(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self)); fflush(stdout)
}
let args = CommandLine.arguments
let iterations = Int(args.last ?? "") ?? 10
func frameworkProbe() throws {
    var samples: [String: [Double]] = [:]
    if args[1] == "pdf" {
        let url = URL(fileURLWithPath: args[2]); var document: PDFDocument!
        for _ in 0..<iterations {
            samples["document_open_ms", default: []].append(try elapsed {
                document = PDFDocument(url: url)
                guard document != nil, document.pageCount > 0 else { throw NSError(domain:"fixture", code:1) }
            })
            samples["first_page_render_ms", default: []].append(try elapsed {
                guard let page = document.page(at:0) else { throw NSError(domain:"fixture",code:2) }
                _ = page.thumbnail(of: NSSize(width:375,height:700), for:.mediaBox)
            })
            samples["search_ms", default: []].append(try elapsed {
                guard !document.findString("harbor", withOptions:.caseInsensitive).isEmpty else { throw NSError(domain:"fixture",code:3) }
            })
            samples["selection_construct_ms", default: []].append(try elapsed {
                guard let selection = document.page(at:0)?.selection(for:NSRange(location:0,length:10)), !(selection.string ?? "").isEmpty else { throw NSError(domain:"fixture",code:4) }
            })
        }
    } else {
        let data = try Data(contentsOf: URL(fileURLWithPath:args[2]))
        for _ in 0..<iterations {
            samples["image_decode_ms", default: []].append(try elapsed {
                guard let source = CGImageSourceCreateWithData(data as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary), image.width > 0 else { throw NSError(domain:"fixture",code:5) }
            })
        }
    }
    output(["status":"measured", "evidence":"isolated_framework", "samples":samples])
}

@MainActor final class RendererProbe: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    var web: WKWebView!; var window: NSWindow!; var finished = false
    var started = ProcessInfo.processInfo.systemUptime
    func applicationDidFinishLaunching(_ notification:Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self,name:"reader")
        configuration.setURLSchemeHandler(self,forURLScheme:"appbook")
        web = WKWebView(frame:NSRect(x:0,y:0,width:375,height:700),configuration:configuration)
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = web; window.orderBack(nil)
        started = ProcessInfo.processInfo.systemUptime
        web.load(URLRequest(url:URL(string:"appbook://local/reader/index.html")!))
        Task { try? await Task.sleep(for:.seconds(40)); if !finished { finish(["status":"unavailable","reason":"renderer_timeout","samples":[:]]) } }
    }
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String:Any], let kind = body["kind"] as? String else { return }
        if kind == "boot" {
            Task { do { _ = try await web.callAsyncJavaScript("""
            await window.readerCommand({name:'open',value:{url:'appbook://local/publication/OPS/package.opf',fraction:0,nativeGestures:true,preferences:{theme:'light',font:'Georgia',fontSize:20,lineHeight:1.6,margin:24,scrolling:false,pageTransition:'instant'}}});
            """,arguments:[:],in:nil,contentWorld:.page) } catch { finish(["status":"unavailable","reason":"open_failed","samples":[:]]) } }
        } else if kind == "ready" {
            let openMS = (ProcessInfo.processInfo.systemUptime-started)*1000
            Task { do {
                let value = try await web.callAsyncJavaScript("""
                const times={turn_render_ms:[],search_ms:[],selection_construct_ms:[]};
                const count=iterations;
                const measure=async(key,fn)=>{const start=performance.now();await fn();times[key].push(performance.now()-start);};
                await paginationTask;
                if(layoutPages.length<count+1)throw Error('insufficient pages');
                for(let i=0;i<count;i++) {
                  await measure('turn_render_ms',async()=>{const before=current;await readerCommand({name:'nativeTurn',value:{direction:'next',request:'baseline-'+i}});if(current===before)throw Error('turn did not move');});
                  await measure('search_ms',async()=>{await readerCommand({name:'search',value:{query:'harbor',id:i}});});
                  await measure('selection_construct_ms',async()=>{
                    const view=rendition.manager.views.displayed()[0];const d=view.contents.document;
                    const walker=d.createTreeWalker(d.body,NodeFilter.SHOW_TEXT);let node;
                    while((node=walker.nextNode())&&!node.textContent.trim()){}
                    if(!node)throw Error('no text');const r=d.createRange();r.setStart(node,0);r.setEnd(node,Math.min(10,node.length));
                    const s=view.contents.window.getSelection();s.removeAllRanges();s.addRange(r);if(!s.toString())throw Error('empty selection');s.removeAllRanges();
                  });
                }
                return times;
                """,arguments:["iterations":iterations],in:nil,contentWorld:.page)
                finish(["status":"measured","evidence":"isolated_webkit", "open_renderer_ready_ms":[openMS],"samples":value ?? [:]])
            } catch { finish(["status":"unavailable","reason":"renderer_metric_failed","samples":[:]]) } }
        } else if kind == "results", let items=body["items"] as? [Any], items.isEmpty { finish(["status":"unavailable","reason":"missing_search_results","samples":[:]])
        } else if kind == "searchError" { finish(["status":"unavailable","reason":"search_error","samples":[:]])
        } else if kind == "error" { finish(["status":"unavailable","reason":"renderer_error","samples":[:]]) }
    }
    func finish(_ value:[String:Any]) { guard !finished else { return };finished=true;output(value);exit(value["status"] as? String == "measured" ? 0 : 1) }
    nonisolated func webView(_ webView:WKWebView,start task:WKURLSchemeTask) {
        MainActor.assumeIsolated {
            guard let url=task.request.url else { return }
            let reader=url.path.hasPrefix("/reader/")
            let root=URL(fileURLWithPath:args[reader ? 2 : 3]).standardizedFileURL
            let relative=String(url.path.dropFirst(reader ? 8 : 13))
            let file=root.appendingPathComponent(relative).standardizedFileURL
            guard file.path.hasPrefix(root.path+"/") else { task.didFailWithError(NSError(domain:"fixture",code:6));return }
            do {
                let data=try Data(contentsOf:file)
                let mime=["html":"text/html","xhtml":"application/xhtml+xml","opf":"application/xml","xml":"application/xml","js":"text/javascript","css":"text/css"][file.pathExtension] ?? "application/octet-stream"
                task.didReceive(HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":mime,"Access-Control-Allow-Origin":"*"])!)
                task.didReceive(data);task.didFinish()
            } catch { task.didFailWithError(error) }
        }
    }
    nonisolated func webView(_ webView:WKWebView,stop task:WKURLSchemeTask) {}
}
guard args.count >= 4, ["epub","pdf","image","pdf-fixture"].contains(args[1]), (args[1] != "epub" || args.count == 5), (args[1] != "pdf-fixture" || args.count == 5), iterations >= 1, iterations <= 100 else { output(["status":"invalid_arguments"]);exit(2) }
if args[1] == "pdf-fixture" {
    guard let source=PDFDocument(url:URL(fileURLWithPath:args[2])), let page=source.page(at:0) else { exit(2) }
    let document=PDFDocument()
    for i in 0..<180 { document.insert(page.copy() as! PDFPage,at:i) }
    guard document.write(to:URL(fileURLWithPath:args[3])) else { exit(2) };exit(0)
} else if args[1] == "epub" {
    MainActor.assumeIsolated { let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let probe=RendererProbe();app.delegate=probe;app.run() }
} else {
    do { try frameworkProbe() } catch { output(["status":"unavailable","reason":"fixture_or_framework_error","samples":[:]]);exit(1) }
}
