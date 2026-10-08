import SwiftUI

/// A platform presentation hook. iPhone/iPad continue using their native dismiss action.
private struct CloseReaderWindowKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}
extension EnvironmentValues {
    var closeReaderWindow: (@MainActor @Sendable () -> Void)? {
        get { self[CloseReaderWindowKey.self] }
        set { self[CloseReaderWindowKey.self] = newValue }
    }
}

#if os(macOS)
import AppKit

/// One reader window shares the application's model and active account with the library.
/// The singleton scene prevents two live renderers from writing the same reading position.
struct MacReaderWindow: View {
    static let sceneID = "reader"
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let book = model.readerLaunchBook {
                BookOpeningView(book: book)
                    .id("\(model.sessionID)|\(book.id)")
            } else {
                ContentUnavailableView("No book open", systemImage: "book.closed",
                                       description: Text("Choose a book from your library."))
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .navigationTitle(model.readerLaunchBook?.title ?? "Reader")
        .environment(\.closeReaderWindow, close)
        .background(ReaderWindowLifecycle(onClose: finishReading))
        .onChange(of: model.readerLaunchBook?.id, initial: true) { _, bookID in
            if bookID == nil { dismissWindow(id: Self.sceneID) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.flushProgress() } }
        }
    }

    private func close() {
        finishReading()
        dismissWindow(id: Self.sceneID)
    }
    private func finishReading() {
        // closeReader cancels unfinished opening and flushes already saved local progress.
        // It also releases cache protection after the active account's flush completes.
        guard model.readerLaunchBook != nil || model.reader != nil || model.openingID != nil else { return }
        model.closeReader()
    }
}

/// Observe the actual window close, including its red button and Command-W.
/// View disappearance alone is not a reliable signal for a retained SwiftUI window scene.
private struct ReaderWindowLifecycle: NSViewRepresentable {
    var onClose: @MainActor @Sendable () -> Void
    func makeNSView(context: Context) -> WindowCloseView {
        let view = WindowCloseView()
        view.onClose = onClose
        return view
    }
    func updateNSView(_ view: WindowCloseView, context: Context) { view.onClose = onClose }
    static func dismantleNSView(_ view: WindowCloseView, coordinator: ()) { view.stopObserving() }

    final class WindowCloseView: NSView {
        var onClose: (@MainActor @Sendable () -> Void)?
        private var observer: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
        }
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Native search editing owns first responder once the field is mounted in its window.
/// Updates refresh bindings/actions without taking focus back from the reader or results.
struct MacReaderSearchField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: @MainActor @Sendable () -> Void
    var onCancel: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> MountedSearchField {
        let field = MountedSearchField()
        field.placeholderString = "Search in book"
        field.setAccessibilityLabel("Search in book")
        field.controlSize = .large
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: MountedSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    static func dismantleNSView(_ field: MountedSearchField, coordinator: Coordinator) {
        field.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacReaderSearchField
        init(_ parent: MacReaderSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "insertNewline:":
                guard !textView.hasMarkedText() else { return false }
                parent.onSubmit()
                return true
            case "cancelOperation:":
                parent.onCancel()
                return true
            default: return false
            }
        }
    }

    final class MountedSearchField: NSSearchField {
        private var requestedInitialFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !requestedInitialFocus else { return }
            requestedInitialFocus = true
            // Wait until SwiftUI has attached the full search overlay and AppKit can
            // assign its field editor. This happens once, never on binding updates.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
#endif
