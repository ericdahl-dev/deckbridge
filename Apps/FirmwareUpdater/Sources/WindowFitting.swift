import AppKit
import SwiftUI
import UpdaterScreen

/// Sizes the updater's window to its content (#761) by WindowFit's rule: it grows when new text appears, up to the
/// screen's visible frame, and a size the owner sets by hand is remembered and never shrunk.
@MainActor
final class WindowFitting {
    private weak var window: NSWindow?
    private var content: CGSize?
    private let store = HandSetSize()
    private var observer: NSObjectProtocol?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handResized() }
        }
        fit()
    }

    /// The content's own size changed: new text appeared or went away.
    func contentChanged(_ size: CGSize) {
        content = size
        fit()
    }

    private func handResized() {
        guard let window else { return }
        store.remember(window.frame.size)
    }

    private func fit() {
        guard let window, let content, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let size = WindowFit.size(content: CGSize(width: WindowFit.minWidth, height: content.height), titleBar: titleBar,
                                  visible: visible.size, handSet: store.size)
        guard size != window.frame.size else { return }
        // Keep the top edge where it is, and the whole window on the screen.
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: true, animate: false)
    }
}

/// Hands the hosting NSWindow to `found` once the view is in one.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Reader(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
