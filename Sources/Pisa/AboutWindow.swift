import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(textScale: CGFloat) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.title = typographicText("О программе Pisa")
        window.appearance = NSAppearance(named: .aqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        let hosting = NSHostingView(rootView: AboutView()
            .environment(\.appTextScale, textScale)
            .onExitCommand { [weak window] in window?.close() })
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
    @Environment(\.openURL) private var openURL
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    var body: some View {
        VStack(spacing: PisaDesign.Spacing.none) {
            identity
            authorLink
                .padding(.horizontal, PisaDesign.Spacing.sheetInset)
                .padding(.bottom, PisaDesign.Spacing.section)
            screenText("For us by us\u{00a0}💚")
                .textStyle(PisaDesign.Typography.detailMedium)
                .foregroundStyle(Color.moss)
                .padding(.vertical, PisaDesign.Spacing.content)
                .frame(maxWidth: .infinity)
                .background(Color.brandAccent.opacity(0.08))
        }
        .frame(width: 360)
        .fixedSize()
        .popupCanvas()
    }

    private var identity: some View {
        VStack(spacing: PisaDesign.Spacing.related) {
            AnimatedBrandMark(size: 108)
                .shadow(color: Color.ink.opacity(0.13), radius: 12, y: 5)
                .accessibilityHidden(true)
            VStack(spacing: PisaDesign.Spacing.compact) {
                SectionHeading("Pisa", style: .page)
                    .accessibilityAddTraits(.isHeader)
                SupportingText("Версия \(version) (\(build))", style: PisaDesign.Typography.footnote)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, PisaDesign.Spacing.page)
        .padding(.bottom, PisaDesign.Spacing.section)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Color.brandAccent.opacity(0.12), .clear],
                           startPoint: .top, endPoint: .bottom)
                .accessibilityHidden(true)
        }
    }

    private var authorLink: some View {
        Button {
            openURL(URL(string: "https://t.me/docomoz")!)
        } label: {
            HStack(spacing: PisaDesign.Spacing.related) {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                    screenText("Максим Берёзкин").textStyle(PisaDesign.Typography.detailStrong)
                    screenText(verbatim: "t.me/docomoz")
                        .textStyle(PisaDesign.Typography.caption)
                        .foregroundStyle(Color.moss)
                }
                Spacer(minLength: PisaDesign.Spacing.none)
                Image(systemName: "arrow.up.right")
                    .font(PisaDesign.Typography.Icon.regular)
                    .foregroundStyle(Color.moss)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, PisaDesign.Spacing.content)
            .padding(.vertical, PisaDesign.Spacing.related)
            .plainSurface(radius: PisaDesign.Metrics.cornerRadius)
        }
        .shapeAwarePlainButton()
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isLink)
    }
}
