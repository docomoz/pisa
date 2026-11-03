import SwiftUI
import AppKit

/// Let a click on non-editable content end field editing without consuming the click.
struct ClickToUnfocus: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusObserver { FocusObserver() }
    func updateNSView(_ nsView: FocusObserver, context: Context) {}
    final class FocusObserver: NSView {
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let window = self?.window, event.window === window else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53, window.firstResponder is NSTextView {
                        window.makeFirstResponder(nil)
                        return nil
                    }
                    return event
                }
                var hit = window.contentView?.hitTest(event.locationInWindow)
                while let view = hit {
                    if view is NSTextField || (view as? NSTextView)?.isEditable == true { return event }
                    hit = view.superview
                }
                window.makeFirstResponder(nil)
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
