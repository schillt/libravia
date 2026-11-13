// Native reader frozen-resize bridge acceptance (offscreen, synthetic images).
// swiftc App/Readers/MacReflowBridge.swift scripts/test_reader_reflow_bridge.swift -o /tmp/libravia-reflow-bridge
import AppKit
import WebKit

@MainActor final class ProbeWebView: WKWebView {
    var simulatedLiveResize=false
    override var inLiveResize: Bool { simulatedLiveResize }
}

@MainActor final class BridgeProbe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var web: ProbeWebView!
    var bridge: MacReflowBridge!
    var completions: [(NSImage?, Error?) -> Void] = []
    var softeningEvents: [(Bool, Bool)] = []
    var coverageEvents: [Bool] = []
    func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
    func check(_ ok: @autoclosure () -> Bool, _ message: String) { if !ok() { fail(message) } }
    func image(_ color:NSColor) -> NSImage {
        let result=NSImage(size:NSSize(width:100,height:80)); result.lockFocus()
        color.setFill(); NSRect(x:0,y:0,width:100,height:80).fill(); result.unlockFocus(); return result
    }
    func sample(_ picture:NSView, x:Int) -> NSColor {
        guard let bitmap=picture.bitmapImageRepForCachingDisplay(in:picture.bounds) else { fail("bitmap unavailable") }
        picture.cacheDisplay(in:picture.bounds,to:bitmap)
        guard let color=bitmap.colorAt(x:bitmap.pixelsWide*x/Int(picture.bounds.width),y:bitmap.pixelsHigh/2)?.usingColorSpace(.sRGB) else { fail("pixel unavailable") }
        return color
    }
    func run() async {
        let red=image(.red), green=image(.green)
        bridge=MacReflowBridge(web:web,snapshot:{ [weak self] _,_,completion in self?.completions.append(completion) },softeningChanged:{ [weak self] active,animated in self?.softeningEvents.append((active,animated)) },coverageChanged:{ [weak self] active in self?.coverageEvents.append(active) })
        bridge.prepare(); check(completions.count==1,"initial capture missing"); bridge.invalidate(); completions.removeFirst()(red,nil)
        check(bridge.cachedSize==nil,"invalidated capture populated cache")
        bridge.prepare(); check(completions.count==1,"replacement capture missing")
        web.setFrameSize(NSSize(width:110,height:80)); completions.removeFirst()(red,nil)
        check(bridge.cachedSize==nil,"stale size capture populated cache")
        web.setFrameSize(NSSize(width:100,height:80));bridge.prepare();completions.removeFirst()(red,nil)
        let before=Set(web.subviews.map(ObjectIdentifier.init))
        bridge.geometryWillChange(); bridge.begin(request:"first")
        guard let cover=web.subviews.first(where:{!before.contains(ObjectIdentifier($0))}) else {fail("cover missing")}
        check(bridge.isCovering,"geometry failed to hold cover")
        check(coverageEvents == [true],"cover creation must report one active coverage event")
        check(softeningEvents.last?.0 == true && softeningEvents.last?.1 == false,"geometry failed to start immediate softening")
        check(cover.hitTest(NSPoint(x:10,y:10))==nil,"cover intercepts input")
        check(!cover.isAccessibilityElement(),"cover duplicates accessibility")
        web.setFrameSize(NSSize(width:140,height:80));cover.layoutSubtreeIfNeeded()
        check(cover.frame.width==140,"cover failed to follow viewport")
        let edge=sample(cover,x:120); check(edge.redComponent>0.9 && edge.greenComponent<0.4,"aspect-fill did not cover expanded area")
        bridge.painted(request:"first"); check(completions.count==1,"first paint capture missing");completions.removeFirst()(green,nil)
        try? await Task.sleep(for:.milliseconds(60))
        bridge.geometryWillChange();bridge.begin(request:"second")
        try? await Task.sleep(for:.milliseconds(160))
        check(bridge.isCovering && web.subviews.contains(where:{$0 === cover}),"old quiet released a newer burst")
        check(coverageEvents == [true],"a retained frozen cover emitted duplicate coverage events")
        let center=sample(cover,x:50);check(center.redComponent>0.9 && center.greenComponent<0.4,"frozen image changed during burst")
        web.simulatedLiveResize=true
        bridge.painted(request:"second");check(completions.count==1,"second paint capture missing");completions.removeFirst()(green,nil)
        try? await Task.sleep(for:.milliseconds(250))
        check(bridge.isCovering && !bridge.isRevealing,"live window resize revealed prematurely")
        web.simulatedLiveResize=false
        try? await Task.sleep(for:.milliseconds(150))
        check(bridge.isCovering && bridge.isRevealing,"cover did not begin its quiet dissolve")
        check(softeningEvents.last?.0 == false && softeningEvents.last?.1 == true,"settled softening did not clear with animation")
        bridge.geometryWillChange();bridge.begin(request:"third")
        try? await Task.sleep(for:.milliseconds(250))
        check(bridge.isCovering && web.subviews.contains(where:{$0 === cover}),"interrupted fade removed the new hold")
        bridge.painted(request:"third");check(completions.count==1,"third paint capture missing");completions.removeFirst()(green,nil)
        try? await Task.sleep(for:.milliseconds(450))
        check(!bridge.isCovering,"settled paint failed to finish reveal")
        check(coverageEvents == [true,false],"finished reveal did not report loss of coverage")
        bridge.geometryWillChange();bridge.begin(request:"wrong-size")
        bridge.painted(request:"wrong-size",width:100,height:80)
        check(completions.isEmpty && bridge.isCovering,"wrong width accepted")
        bridge.painted(request:"wrong-size",width:140,height:40)
        check(completions.isEmpty && bridge.isCovering,"wrong height accepted")
        bridge.painted(request:"wrong-size",width:140,height:80)
        check(completions.count==1,"matching dimensions rejected");completions.removeFirst()(green,nil)
        bridge.begin(request:"stale"); bridge.painted(request:"stale")
        bridge.geometryWillChange();bridge.begin(request:"new")
        check(!completions.isEmpty,"stale completion was not recorded");completions.removeFirst()(red,nil)
        try? await Task.sleep(for:.milliseconds(160))
        check(bridge.isCovering,"stale paint released newer hold")
        bridge.invalidate();check(!bridge.isCovering,"input invalidation did not immediately clear")
        check(coverageEvents.suffix(2).elementsEqual([true,false]),"input did not immediately report coverage loss")
        check(softeningEvents.last?.0 == false && softeningEvents.last?.1 == false,"input did not immediately clear softening")
        bridge.geometryWillChange();check(bridge.isCovering,"missing cache did not show fallback paper")
        guard let paper=web.subviews.first(where:{!before.contains(ObjectIdentifier($0))}) else {fail("fallback paper missing")}
        let color=sample(paper,x:120);check(color.greenComponent>0.75 && color.blueComponent>0.70,"fallback is not themed paper")
        bridge.setSuspended(true);check(!bridge.isCovering,"selection suspension failed to clear cover")
        bridge.geometryWillChange();check(!bridge.isCovering,"suspended bridge displayed overlay")
        bridge.setSuspended(false); if !completions.isEmpty {completions.removeFirst()(red,nil)}
        bridge.geometryWillChange();bridge.begin(request:"missing")
        try? await Task.sleep(for:.milliseconds(3200))
        check(!bridge.isCovering,"missing-paint recovery failed")
        bridge.stop();check(!bridge.isCovering,"stop left cover")
        var reduced=true
        bridge=MacReflowBridge(web:web,snapshot:{ [weak self] _,_,completion in self?.completions.append(completion) },reduceEffects:{ reduced })
        bridge.prepare();bridge.geometryWillChange();bridge.begin(request:"reduced")
        check(completions.isEmpty && !bridge.isCovering,"reduced-effects policy did not bypass the overlay")
        reduced=false;bridge.prepare();check(completions.count==1,"normal policy did not resume capture");completions.removeFirst()(red,nil)
        bridge.geometryWillChange();check(bridge.isCovering,"normal policy did not resume overlay")
        reduced=true;bridge.painted(request:"reduced");bridge.invalidate()
        check(!bridge.isCovering,"policy/invalidation left an overlay")
        bridge.stop()
        print("PASS: frozen image, latest-paint reveal, interruption, fallback and recovery");exit(0)
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {print("SKIP: host accessibility reduction enabled");exit(0)}
        web=ProbeWebView(frame:NSRect(x:0,y:0,width:100,height:80));web.underPageBackgroundColor=NSColor(srgbRed:244.0/255,green:236.0/255,blue:216.0/255,alpha:1)
        window=NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false);window.contentView=web;window.orderBack(nil)
        Task { @MainActor in await run() }
    }
}
@main struct Entry { @MainActor static func main() { let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let probe=BridgeProbe();app.delegate=probe;app.run() } }
