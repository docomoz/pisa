import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.title = typographicText("О программе Pisya")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        let hosting = NSHostingView(rootView: AboutView().onExitCommand { [weak window] in window?.close() })
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    var body: some View {
        VStack(spacing: PisyaDesign.Spacing.inline) {
            AnimatedBrandMark(size: 68)
                .accessibilityHidden(true)
            VStack(spacing: PisyaDesign.Spacing.inline) {
                screenText("Pisya").textStyle(PisyaDesign.Typography.detailStrong)
                    .accessibilityAddTraits(.isHeader)
                screenText("Версия \(version) (\(build))").textStyle(PisyaDesign.Typography.micro)
            }
            VStack(spacing: PisyaDesign.Spacing.inline) {
                screenText("Максим Берёзкин")
                Link(destination: URL(string: "https://t.me/docomoz")!) {
                    screenText(verbatim: "t.me/docomoz").underline().foregroundStyle(Color(nsColor: .linkColor))
                }
                .shapeAwarePlainButton()
                screenText("Сделано нами для нас\u{00a0}💚")
            }
            .textStyle(PisyaDesign.Typography.detail)
        }
        .multilineTextAlignment(.center)
        .frame(minWidth: 228)
        .padding(.horizontal, PisyaDesign.Spacing.sheetInset)
        .padding(.top, PisyaDesign.Spacing.inline)
        .padding(.bottom, PisyaDesign.Spacing.content)
        .fixedSize()
    }
}
