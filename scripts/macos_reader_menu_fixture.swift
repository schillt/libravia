// Native AppKit/WebKit menu transaction probe. The Python runner injects the
// production menu class and value helpers; this controller and trusted HTML
// shell are synthetic. Real native menu hit testing and dictionary presentation
// remain separate interaction checks.
import AppKit
import WebKit

// PRODUCTION_SELECTION
struct Position { var cfi: String? }
@MainActor final class ReaderController {
    var highlighterColor: String?
    var ready = true
    var position = Position(cfi: "epubcfi(book)")
    var epubSelection: EPUBSelection?
    var epubSelectionActive = false
    var selectionMenuAction: ((Bool, EPUBSelection) -> Void)?
}
// PRODUCTION_DICTIONARY

// PRODUCTION_CLASS

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: ReaderMenuWebView!
    var controller = ReaderController()
    var actions: [(Bool, EPUBSelection)] = []
    var finished = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        web = ReaderMenuWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 480), configuration: WKWebViewConfiguration())
        web.readerController = controller; web.navigationDelegate = self
        controller.selectionMenuAction = { [weak self] note, selection in self?.actions.append((note, selection)) }
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderBack(nil)
        web.loadHTMLString("""
        <html><body><p id="p">alpha beta</p><script>
        let ready=true, current='epubcfi(book)', lastPolledSelection='', lastSelectionContext='';
        function pollSelection() { const text=window.getSelection().toString();
          lastPolledSelection=text ? JSON.stringify([current, 'epubcfi('+text+')', text]) : '';
          lastSelectionContext=text ? 'alpha beta' : ''; }
        function selectWord(start,end) { const r=document.createRange(), n=document.getElementById('p').firstChild;
          r.setStart(n,start); r.setEnd(n,end); const s=window.getSelection(); s.removeAllRanges(); s.addRange(r); }
        </script></body></html>
        """, baseURL: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            if !finished { finish(false, "Timed out") }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do { try await run() } catch { finish(false, "\(error)") }
        }
    }
    enum Failure: Error { case assertion(String) }
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    func pause() async throws { try await Task.sleep(for: .milliseconds(150)) }
    func execute(_ code: String) async throws { _ = try await web.evaluateJavaScript(code) }
    func menu(tag: Int = Int(WebMenuItemTagCopy)) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""); copy.tag = tag; copy.isEnabled = true; menu.addItem(copy)
        let lookup = NSMenuItem(title: "Look Up", action: nil, keyEquivalent: ""); lookup.tag = Int(WebMenuItemTagLookUpInDictionary); lookup.isEnabled = true
        if tag == Int(WebMenuItemTagCopy) { menu.addItem(lookup) }
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 40,y: 40), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        web.willOpenMenu(menu, with: event)
        return menu
    }
    func item(_ menu: NSMenu, _ name: String) throws -> NSMenuItem {
        guard let result = menu.items.first(where: { $0.identifier?.rawValue == "LibraVia.Selection." + name }) else { throw Failure.assertion("missing " + name) }
        return result
    }
    func invoke(_ item: NSMenuItem) { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
    func dismissSheet() { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
    func run() async throws {
        for tag in [Int(WebMenuItemTagCopyLinkToClipboard), Int(WebMenuItemTagCopyImageToClipboard)] {
            try require(!menu(tag: tag).items.contains(where: { $0.identifier?.rawValue.hasPrefix("LibraVia.Selection.") == true }), "non-text Copy exposed annotation menu")
        }
        try await execute("selectWord(0,5)")
        let highlight = menu(); let h = try item(highlight, "highlight"); invoke(h); try await pause()
        try require(actions.count == 1 && actions[0].0 == false && actions[0].1.text == "alpha", "highlight did not dispatch selected alpha")
        try await execute("selectWord(6,10)")
        let note = menu(); let n = try item(note, "note"); try await pause(); invoke(n); try await pause()
        try require(actions.count == 2 && actions[1].0 && actions[1].1.text == "beta", "note did not dispatch selected beta")
        try await execute("selectWord(0,5)")
        let clear = menu(); let c = try item(clear, "highlight"); try await pause(); try await execute("window.getSelection().removeAllRanges()")
        invoke(c); try await pause()
        try require(actions.count == 2 && window.attachedSheet != nil, "cleared selection was not rejected and reported")
        dismissSheet(); try await pause()
        try await execute("selectWord(0,5)")
        let change = menu(); let d = try item(change, "highlight"); try await pause(); try await execute("selectWord(6,10)")
        invoke(d); try await pause()
        try require(actions.count == 2 && window.attachedSheet != nil, "changed selection was not rejected and reported")
        dismissSheet(); try await pause()
        try await execute("selectWord(0,5)")
        let old = menu(); let o = try item(old, "highlight"); try await pause(); _ = menu(); invoke(o); try await pause()
        try require(actions.count == 2, "superseded menu dispatched")
        let detach = menu(); let j = try item(detach, "highlight"); try await pause(); web.removeFromSuperview(); invoke(j); try await pause()
        try require(actions.count == 2, "detached menu dispatched")
        finish(true, "production menu class: highlight/note, cleared/changed, superseded/detached and synthetic link/image gating")
    }
    func finish(_ passed: Bool, _ message: String) {
        guard !finished else { return }; finished = true
        print((passed ? "PASS: " : "FAIL: ") + message); fflush(stdout); exit(passed ? 0 : 1)
    }
}
MainActor.assumeIsolated { let app = NSApplication.shared; app.setActivationPolicy(.prohibited); let probe = Probe(); app.delegate = probe; app.run() }
