import SwiftUI

struct SettingsSectionPicker: View {
    @Binding var selection: String
    @FocusState private var focused: String?
    private let sections = ["Запись", "Модель", "Голоса", "Словарь", "Экспорт", "Хранилище", "MCP", "Обновления"]
    var body: some View {
        HStack(spacing: PisaDesign.Spacing.compact) {
            ForEach(sections, id: \.self) { item in
                let isSelected = selection == item
                Button { selection = item } label: {
                    // Keep both font weights in layout so selection never resizes a tab.
                    ZStack {
                        screenText(item).textStyle(PisaDesign.Typography.detailMedium)
                            .opacity(isSelected ? 0 : 1)
                            .accessibilityHidden(isSelected)
                        screenText(item).textStyle(PisaDesign.Typography.detailStrong)
                            .opacity(isSelected ? 1 : 0)
                            .accessibilityHidden(!isSelected)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, PisaDesign.Spacing.related).frame(height: 32)
                    .foregroundStyle(Color.ink)
                    .background(isSelected ? Color.paper : .clear, in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                    .contentShape(RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                }
#if !PISA_CONTROLS_PROBE
                    .measuredForInterfaceTest(.settingsTab(item))
#endif
                    .shapeAwarePlainButton().focused($focused, equals: item)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .onMoveCommand { direction in
                        guard direction == .left || direction == .right,
                              let index = sections.firstIndex(of: item) else { return }
                        let next = min(sections.count - 1, max(0, index + (direction == .right ? 1 : -1)))
                        selection = sections[next]; focused = sections[next]
                    }
            }
        }.padding(PisaDesign.Spacing.compact).background(PisaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.surfaceRadius))
            .accessibilityElement(children: .contain).accessibilityLabel("Раздел настроек")
    }
}
