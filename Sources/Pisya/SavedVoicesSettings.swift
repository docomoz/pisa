import SwiftUI

struct SavedVoicesSettings: View {
    @EnvironmentObject var state: AppState
    @State private var renaming: VoiceProfile?
    @State private var forgetting: VoiceProfile?
    @FocusState private var focusedControl: VoiceControl?
    var scrollTo: (UUID) -> Void

    private enum VoiceControl: Hashable {
        case actions(UUID), sample(UUID, UUID)
        var profileID: UUID {
            switch self {
            case .actions(let id), .sample(let id, _): return id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            SectionHeading("Сохранённые голоса", subtitle: "Pisya будет узнавать людей по голосу на следующих встречах")
            if state.voiceProfiles.isEmpty {
                emptyState
            } else {
                VStack(spacing: PisyaDesign.Spacing.none) {
                    ForEach(state.voiceProfiles) { profile in
                        voiceRow(profile).id(profile.id)
                        if profile.id != state.voiceProfiles.last?.id {
                            Divider().padding(.horizontal, PisyaDesign.Spacing.content)
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: PisyaDesign.Metrics.surfaceRadius)
                        .strokeBorder(PisyaDesign.Colors.secondaryAction, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                screenText("После переименования или удаления голоса имена в прежних расшифровках сохраняются")
                    .textStyle(PisyaDesign.Typography.detail)
                    .foregroundStyle(Color.mutedInk)
            }
        }
        .sheet(item: $renaming) { profile in SavedVoiceNameEditor(profile: profile).environmentObject(state) }
        .sheet(item: $forgetting) { profile in ForgetSavedVoiceConfirmation(profile: profile).environmentObject(state) }
        .onChange(of: focusedControl) { _, control in
            if let control { scrollTo(control.profileID) }
        }
        .onDisappear { state.stopPlayback() }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: PisyaDesign.Spacing.content) {
            Image(systemName: "waveform")
                .font(PisyaDesign.Typography.Icon.medium)
                .foregroundStyle(Color.moss)
                .frame(width: PisyaDesign.Metrics.regularHeight, height: PisyaDesign.Metrics.regularHeight)
                .background(Color.paper, in: Circle())
                .accessibilityHidden(true)
            SectionHeading("Пока нет сохранённых голосов", subtitle: "В записи откройте «Разметить голоса», назначьте имя и включите «Запомнить голос для будущих встреч»")
        }
        .padding(PisyaDesign.Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainSurface()
    }

    private func voiceRow(_ profile: VoiceProfile) -> some View {
        HStack(spacing: PisyaDesign.Spacing.content) {
            screenText(verbatim: profile.name.prefix(1).uppercased())
                .textStyle(PisyaDesign.Typography.detailStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.moss)
                .frame(width: PisyaDesign.Metrics.regularHeight, height: PisyaDesign.Metrics.regularHeight)
                .background(Color.moss.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            screenText(profile.name)
                .textStyle(PisyaDesign.Typography.bodyStrong)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let examples = profile.examples, !examples.isEmpty {
                sampleControls(examples, for: profile)
            } else {
                screenText("Без аудиообразца")
                    .textStyle(PisyaDesign.Typography.detail)
                    .foregroundStyle(Color.mutedInk)
                    .fixedSize()
                    .screenHelp("Голос доступен для узнавания на будущих встречах")
            }
            NativeActionMenu {
                [NativeActionMenuItem("Переименовать…") { renaming = profile }, .separator(),
                 NativeActionMenuItem("Забыть голос") { forgetting = profile }]
            } label: {
                Image(systemName: "ellipsis")
                    .font(PisyaDesign.Typography.Icon.medium)
                    .foregroundStyle(Color.mutedInk)
                    .frame(width: PisyaDesign.Metrics.smallHeight, height: PisyaDesign.Metrics.smallHeight)
                    .contentShape(Rectangle())
            }
            .shapeAwarePlainButton()
            .fixedSize()
            .focused($focusedControl, equals: .actions(profile.id))
            .screenHelp("Действия с голосом")
            .accessibilityLabel("Действия с голосом «\(profile.name)»")
        }
        .padding(.horizontal, PisyaDesign.Spacing.content)
        .padding(.vertical, PisyaDesign.Spacing.related)
    }

    private func sampleControls(_ examples: [VoiceExample], for profile: VoiceProfile) -> some View {
        let columns = Array(repeating: GridItem(.fixed(120), spacing: PisyaDesign.Spacing.inline), count: min(examples.count, 3))
        return LazyVGrid(columns: columns, spacing: PisyaDesign.Spacing.inline) {
            ForEach(Array(examples.enumerated()), id: \.element.id) { index, example in
                let playing = state.playingSegmentID == example.id
                let title = examples.count == 1 ? "Образец" : "Образец \(index + 1)"
                let action = playing ? "Остановить" : "Послушать"
                Button { state.playExample(example) } label: {
                    screenLabel(title, systemImage: playing ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .actionButton(size: .small)
                .disabled(state.recording)
                .focused($focusedControl, equals: .sample(profile.id, example.id))
                .screenHelp("\(action) образец")
                .accessibilityLabel("\(action) образец \(index + 1), \(profile.name)")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

private struct SavedVoiceNameEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let profile: VoiceProfile
    @State private var name = ""
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Bool {
        state.voiceProfiles.contains { $0.id != profile.id && $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Переименовать голос", subtitle: "Новое имя будет использоваться при узнавании на следующих встречах. Имена в прежних расшифровках сохранятся.", style: .dialog)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                TextField("Имя участника", text: $name).textFieldStyle(PisyaTextFieldStyle())
                    .accessibilityLabel("Имя сохранённого голоса").focused($nameFocused).onSubmit { save() }
                if duplicate { SupportingText("Голос с таким именем уже сохранён. Укажите другое имя.") }
                if let saveError { SupportingText(saveError) }
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer(minLength: PisyaDesign.Spacing.none)
                screenButton("Сохранить") { save() }.actionButton(.primary).disabled(cleanName.isEmpty || duplicate)
            }
        }.dialogContent().frame(width: 480)
            .onAppear { name = profile.name; nameFocused = true }
            .onChange(of: name) { saveError = nil }
    }
    private func save() {
        guard !cleanName.isEmpty, !duplicate else { return }
        do { try state.renameVoice(profile.id, to: cleanName); dismiss() }
        catch { saveError = error.localizedDescription }
    }
}

private struct ForgetSavedVoiceConfirmation: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let profile: VoiceProfile
    @State private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Забыть голос «\(profile.name)»?", subtitle: "Сохранённый профиль и его аудиообразцы будут удалены. Чтобы снова узнавать этого человека, голос нужно будет запомнить заново. Имена в прежних расшифровках сохранятся.", style: .dialog)
            if let saveError { SupportingText(saveError) }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer(minLength: PisyaDesign.Spacing.none)
                screenButton("Забыть голос", role: .destructive) {
                    do { try state.forgetVoice(profile.id); dismiss() }
                    catch { saveError = error.localizedDescription }
                }.actionButton(.recording)
            }
        }.dialogContent().frame(width: 480)
    }
}
