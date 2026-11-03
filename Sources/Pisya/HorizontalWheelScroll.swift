import SwiftUI
import AppKit

/// Convert vertical mouse-wheel movement only over this horizontal strip.
struct HorizontalWheelScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ nsView: Observer, context: Context) {}
    final class Observer: NSView {
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                let hit = window.contentView?.hitTest(event.locationInWindow)
                let scroll = (hit as? NSScrollView) ?? hit?.enclosingScrollView ?? self.enclosingScrollView
                guard let scroll, let document = scroll.documentView else { return event }
                let maximum = max(0, document.bounds.width - scroll.contentView.bounds.width)
                guard maximum > 0 else { return event }
                var point = scroll.contentView.bounds.origin
                point.x = min(maximum, max(0, point.x - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)))
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
