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
        window.title = typographicText("О программе Pisya")
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
        VStack(spacing: PisyaDesign.Spacing.none) {
            identity
            authorLink
                .padding(.horizontal, PisyaDesign.Spacing.sheetInset)
                .padding(.bottom, PisyaDesign.Spacing.section)
            screenText("For us by us\u{00a0}💚")
                .textStyle(PisyaDesign.Typography.detailMedium)
                .foregroundStyle(Color.moss)
                .padding(.vertical, PisyaDesign.Spacing.content)
                .frame(maxWidth: .infinity)
                .background(Color.brandAccent.opacity(0.08))
        }
        .frame(width: 360)
        .fixedSize()
        .popupCanvas()
    }

    private var identity: some View {
        VStack(spacing: PisyaDesign.Spacing.related) {
            AnimatedBrandMark(size: 108)
                .shadow(color: Color.ink.opacity(0.13), radius: 12, y: 5)
                .accessibilityHidden(true)
            VStack(spacing: PisyaDesign.Spacing.compact) {
                SectionHeading("Pisya", style: .page)
                    .accessibilityAddTraits(.isHeader)
                SupportingText("Версия \(version) (\(build))", style: PisyaDesign.Typography.footnote)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, PisyaDesign.Spacing.page)
        .padding(.bottom, PisyaDesign.Spacing.section)
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
            HStack(spacing: PisyaDesign.Spacing.related) {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.compact) {
                    screenText("Максим Берёзкин").textStyle(PisyaDesign.Typography.detailStrong)
                    screenText(verbatim: "t.me/docomoz")
                        .textStyle(PisyaDesign.Typography.caption)
                        .foregroundStyle(Color.moss)
                }
                Spacer(minLength: PisyaDesign.Spacing.none)
                Image(systemName: "arrow.up.right")
                    .font(PisyaDesign.Typography.Icon.regular)
                    .foregroundStyle(Color.moss)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, PisyaDesign.Spacing.content)
            .padding(.vertical, PisyaDesign.Spacing.related)
            .plainSurface(radius: PisyaDesign.Metrics.cornerRadius)
        }
        .shapeAwarePlainButton()
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isLink)
    }
}
