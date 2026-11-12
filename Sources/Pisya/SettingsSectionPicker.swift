import SwiftUI

struct SettingsSectionPicker: View {
    @Binding var selection: String
    @FocusState private var focused: String?
    private let sections = ["Запись", "Модель", "Голоса", "Экспорт", "MCP", "Обновления"]
    var body: some View {
        HStack(spacing: PisyaDesign.Spacing.compact) {
            ForEach(sections, id: \.self) { item in
                let isSelected = selection == item
                Button { selection = item } label: {
                    // Keep both font weights in layout so selection never resizes a tab.
                    ZStack {
                        screenText(item).textStyle(PisyaDesign.Typography.detailMedium)
                            .opacity(isSelected ? 0 : 1)
                            .accessibilityHidden(isSelected)
                        screenText(item).textStyle(PisyaDesign.Typography.detailStrong)
                            .opacity(isSelected ? 1 : 0)
                            .accessibilityHidden(!isSelected)
                    }
                    .padding(.horizontal, PisyaDesign.Spacing.content).frame(height: 32)
                    .foregroundStyle(Color.ink)
                    .background(isSelected ? Color.paper : .clear, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                    .contentShape(RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                }.shapeAwarePlainButton().focused($focused, equals: item)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .onMoveCommand { direction in
                        guard direction == .left || direction == .right,
                              let index = sections.firstIndex(of: item) else { return }
                        let next = min(sections.count - 1, max(0, index + (direction == .right ? 1 : -1)))
                        selection = sections[next]; focused = sections[next]
                    }
            }
        }.padding(PisyaDesign.Spacing.compact).background(PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.surfaceRadius))
            .accessibilityElement(children: .contain).accessibilityLabel("Раздел настроек")
    }
}
