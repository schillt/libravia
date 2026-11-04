import UIKit

final class Page: UIViewController {
    let index: Int
    init(_ index: Int) { self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = index.isMultiple(of: 2) ? UIColor(white: 0.1, alpha: 1) : UIColor(red: 0.25, green: 0.18, blue: 0.05, alpha: 1)
        let label = UILabel(frame: CGRect(x: 35, y: 120, width: 300, height: 100))
        label.textColor = .white; label.font = .systemFont(ofSize: 30); label.text = "Page \(index) \(index.isMultiple(of: 2) ? "front" : "back")"
        view.addSubview(label)
    }
}
@MainActor final class ReaderCurlCatchUpPan: UIPanGestureRecognizer {
    private(set) var trackingTouch = false
    private(set) var initialLocation: CGPoint?
    var touchFinished: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if !trackingTouch, let touch = touches.first { initialLocation = touch.location(in: view) }
        trackingTouch = true; super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event); trackingTouch = false; touchFinished?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event); trackingTouch = false; touchFinished?()
    }
    override func reset() {
        super.reset(); trackingTouch = false; initialLocation = nil; touchFinished?()
    }
}
final class FixtureGate: UIView {
    weak var owner: Host?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches, ProcessInfo.processInfo.arguments.contains("cold") { owner?.beginOwnership() }
        return super.hitTest(point, with: event)
    }
}
final class Host: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    var nativeOff = false
    var busy = false
    var pending: [Int] = []
    var catchUp: ReaderCurlCatchUpPan?
    var ownershipGeneration = UUID()
    override func loadView() { let gate = FixtureGate(); gate.owner = self; view = gate }
    let state = UILabel(frame: CGRect(x: 16, y: 50, width: 300, height: 30))
    let page = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        page.isDoubleSided = true; page.dataSource = self; page.delegate = self
        addChild(page); page.view.frame = view.bounds; page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(page.view); page.didMove(toParent: self)
        state.text = "idle"; state.textColor = .white; view.addSubview(state)
        if ProcessInfo.processInfo.arguments.contains("rapid") {
            page.view.layer.speed = 0.1
            let observer = ReaderCurlCatchUpPan(target: self, action: #selector(observe(_:)))
            observer.maximumNumberOfTouches = 1; observer.cancelsTouchesInView = false; observer.delegate = self; observer.isEnabled = false
            observer.touchFinished = { [weak self] in self?.scheduleOwnershipUpdate() }
            view.addGestureRecognizer(observer); catchUp = observer
        }
        let two = ProcessInfo.processInfo.arguments.contains("two")
        NSLog("PROBE initial double=\(page.isDoubleSided) spine=\(page.spineLocation.rawValue) two=\(two)")
        page.setViewControllers(two ? [Page(0), Page(-1)] : [Page(0)], direction: .forward, animated: false)
        NSLog("PROBE initial OK count=\(page.viewControllers?.count ?? -1)")
        for gesture in page.gestureRecognizers {
            gesture.isEnabled = !(gesture is UITapGestureRecognizer)
            if (ProcessInfo.processInfo.arguments.contains("gate") || ProcessInfo.processInfo.arguments.contains("rapid")), gesture is UIPanGestureRecognizer { gesture.addTarget(self, action: #selector(nativePan(_:))) }
        }
        if !ProcessInfo.processInfo.arguments.contains("interactive") { DispatchQueue.main.asyncAfter(deadline: .now()+2) { self.turn() } }
    }
    func turn() {
        if ProcessInfo.processInfo.arguments.contains("slow") { page.view.layer.speed = 0.1 }
        NSLog("PROBE forward begin double=\(page.isDoubleSided) count=\(page.viewControllers?.count ?? -1)")
        page.setViewControllers([Page(2), Page(1)], direction: .forward, animated: true) { finished in
            NSLog("PROBE forward done=\(finished) count=\(self.page.viewControllers?.count ?? -1)")
            DispatchQueue.main.asyncAfter(deadline: .now()+2) { self.reverse() }
        }
    }
    func reverse() {
        NSLog("PROBE reverse begin")
        page.setViewControllers([Page(0), Page(1)], direction: .reverse, animated: true) { finished in
            NSLog("PROBE reverse done=\(finished) count=\(self.page.viewControllers?.count ?? -1)")
        }
    }
    @objc func nativePan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .ended || pan.state == .cancelled, busy { beginOwnership() }
    }
    func beginOwnership() {
        guard !nativeOff else { return }
        let pans = page.gestureRecognizers.compactMap { $0 as? UIPanGestureRecognizer }
        guard !pans.isEmpty, pans.allSatisfy({ $0.state != .began && $0.state != .changed }) else { return }
        ownershipGeneration = UUID(); nativeOff = true
        for pan in pans { pan.isEnabled = false }
        catchUp?.isEnabled = true
    }
    func scheduleOwnershipUpdate() {
        let generation = ownershipGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ownershipGeneration == generation, self.nativeOff,
                  !self.busy, self.pending.isEmpty, self.catchUp?.trackingTouch != true else { return }
            self.nativeOff = false; self.catchUp?.isEnabled = false
            for gesture in self.page.gestureRecognizers { gesture.isEnabled = !(gesture is UITapGestureRecognizer) }
        }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { gestureRecognizer === catchUp && nativeOff }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    @objc func observe(_ pan: ReaderCurlCatchUpPan) {
        guard pan.state == .ended else { return }
        let x = pan.translation(in: view).x
        if abs(x) > 60 {
            pending.append(x < 0 ? 1 : -1); state.text = "queued \(pending.count)"
            if !busy { busy = true; drain() }
        }
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { busy = true; state.text = "transition started" }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        state.text = completed ? "transition committed" : "transition cancelled"
        if ProcessInfo.processInfo.arguments.contains("rapid") { drain() }
        else { busy = false; nativeOff = false; if ProcessInfo.processInfo.arguments.contains("gate") { for gesture in page.gestureRecognizers where gesture is UIPanGestureRecognizer { gesture.isEnabled = true } } }
    }
    func drain() {
        guard let current = page.viewControllers?.first as? Page else { return }
        while !pending.isEmpty {
            let direction = pending.removeFirst(), index = current.index
            let target = index + direction * 2
            if target < 0 || target > 4 { continue }
            page.setViewControllers([Page(target), Page(index + direction)], direction: direction > 0 ? .forward : .reverse, animated: true) { _ in self.drain() }
            return
        }
        state.text = "drained"
        busy = false; scheduleOwnershipUpdate()
    }
    func pageViewController(_ p: UIPageViewController, viewControllerBefore v: UIViewController) -> UIViewController? { guard let v = v as? Page else { return nil }; NSLog("PROBE before \(v.index)"); return Page(v.index-1) }
    func pageViewController(_ p: UIPageViewController, viewControllerAfter v: UIViewController) -> UIViewController? { guard let v = v as? Page else { return nil }; NSLog("PROBE after \(v.index)"); return Page(v.index+1) }
}
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene); w.rootViewController = Host(); w.makeKeyAndVisible(); window = w
    }
}
@main class App: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self; return config
    }
}
