import SwiftUI
#if os(iOS)
import UIKit
#endif

/// UIApplication's idle timer is process-wide. One reader leaving must not
/// release another active reader's request in a separate iPad scene.
@MainActor final class ReaderIdleTimerController {
    private var readers: Set<UUID> = []
    private var disabled = false
    private let apply: (Bool) -> Void

    init(apply: @escaping (Bool) -> Void) { self.apply = apply }

    func setReading(_ reading: Bool, for reader: UUID) {
        if reading { readers.insert(reader) } else { readers.remove(reader) }
        let value = !readers.isEmpty
        guard value != disabled else { return }
        disabled = value
        apply(value)
    }

    #if os(iOS)
    static let shared = ReaderIdleTimerController { UIApplication.shared.isIdleTimerDisabled = $0 }
    #endif
}

#if os(iOS)
private struct ReaderScreenAwake: ViewModifier {
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var readerID = UUID()
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onChange(of: enabled) { _, _ in update() }
            .onChange(of: scenePhase) { _, _ in update() }
            .onDisappear { visible = false; update() }
    }

    private func update() {
        ReaderIdleTimerController.shared.setReading(visible && enabled && scenePhase == .active, for: readerID)
    }
}
#endif

extension View {
    @ViewBuilder func readerScreenAwake(_ enabled: Bool) -> some View {
        #if os(iOS)
        modifier(ReaderScreenAwake(enabled: enabled))
        #else
        self
        #endif
    }
}
