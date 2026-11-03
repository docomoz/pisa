import AppKit
import SwiftUI

/// Native overlay scrollers keep their standard mouse target and accessibility.
struct SlimScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollbarStyler { ScrollbarStyler() }
    func updateNSView(_ view: ScrollbarStyler, context: Context) { view.schedule() }
}
final class ScrollbarStyler: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
    func schedule() {
        DispatchQueue.main.async { [weak self] in
            guard let root = self?.window?.contentView else { return }
            self?.apply(to: root)
        }
    }
    private func apply(to view: NSView) {
        if let scroll = view as? NSScrollView {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            if let bar = scroll.verticalScroller, bar.controlSize != .mini { bar.controlSize = .mini }
            if let bar = scroll.horizontalScroller, bar.controlSize != .mini { bar.controlSize = .mini }
        }
        for child in view.subviews { apply(to: child) }
    }
}
