import SwiftUI
import AppKit

/// This view owns its slow timer, independently of capture and waveform updates.
struct BrandMoodView: View {
    private static let phrases = [
        "приподнятая", "в хорошем настроении", "в полный рост", "радует глаз",
        "держится бодро", "на высоте", "в своей стихии", "в прекрасной форме",
        "довольна собой", "ловит момент", "готова к разговору", "вся во внимании",
        "знает своё дело", "сегодня в ударе", "на позитиве", "с огоньком",
        "не унывает", "держит марку", "выглядит отлично", "полна энтузиазма",
        "заряжена на день", "в центре внимания", "с характером", "во всей красе",
        "рада тебя видеть", "настроена серьёзно", "дышит полной грудью", "просто прелесть"
    ]
    private static let emojis = ["🙂", "😊", "😄", "😁", "😎", "🥳", "🤩", "😌", "😉", "🙃", "✨", "🌟", "☀️", "💚", "💛", "🎉", "🚀"]
    private static let colors: [Color] = [
        moodColor(light: (0.22, 0.35, 0.63), dark: (0.70, 0.79, 1.00)),
        moodColor(light: (0.40, 0.29, 0.59), dark: (0.83, 0.73, 0.98)),
        moodColor(light: (0.56, 0.25, 0.37), dark: (1.00, 0.72, 0.80)),
        moodColor(light: (0.24, 0.42, 0.32), dark: (0.66, 0.87, 0.72)),
        moodColor(light: (0.51, 0.33, 0.18), dark: (0.95, 0.78, 0.61)),
        moodColor(light: (0.18, 0.40, 0.43), dark: (0.62, 0.86, 0.88)),
        moodColor(light: (0.51, 0.28, 0.22), dark: (0.98, 0.75, 0.69))
    ]
    @State private var phraseIndex = Int.random(in: 0..<BrandMoodView.phrases.count)
    @State private var emojiIndex = Int.random(in: 0..<BrandMoodView.emojis.count)
    @State private var colorIndex = Int.random(in: 0..<BrandMoodView.colors.count)

    var body: some View {
        HStack(spacing: PisyaDesign.Spacing.inline) {
            screenText("Pisya").textStyle(PisyaDesign.Typography.detailStrong).fixedSize()
            screenText("\(Self.phrases[phraseIndex]) \(Self.emojis[emojiIndex])")
                .textStyle(PisyaDesign.Typography.detail).foregroundStyle(Self.colors[colorIndex])
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 340, alignment: .leading)
        .layoutPriority(-1)
        .screenHelp("Pisya \(Self.phrases[phraseIndex]) \(Self.emojis[emojiIndex])")
        .task {
            while !Task.isCancelled {
                let seconds = UInt64.random(in: 60...120)
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                phraseIndex = Self.nextIndex(after: phraseIndex, count: Self.phrases.count)
                emojiIndex = Self.nextIndex(after: emojiIndex, count: Self.emojis.count)
                colorIndex = Self.nextIndex(after: colorIndex, count: Self.colors.count)
            }
        }
    }

    private static func nextIndex(after current: Int, count: Int) -> Int {
        let candidate = Int.random(in: 0..<(count - 1))
        return candidate >= current ? candidate + 1 : candidate
    }

    private static func moodColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let components = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }
}
