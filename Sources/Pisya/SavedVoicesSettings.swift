import SwiftUI

struct SavedVoicesSettings: View {
    @EnvironmentObject var state: AppState
    @State private var renaming: VoiceProfile?
    @State private var forgetting: VoiceProfile?
    @FocusState private var focusedControl: VoiceControl?
    var scrollTo: (UUID) -> Void

    private enum VoiceControl: Hashable {
        case rename(UUID), forget(UUID), sample(UUID, UUID)
        var profileID: UUID {
            switch self {
            case .rename(let id), .forget(let id), .sample(let id, _): return id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            SectionHeading("Сохранённые голоса", subtitle: "Pisya использует их, чтобы узнавать людей на следующих встречах. Переименование и удаление голоса сохраняют имена в прежних расшифровках.")
            if state.voiceProfiles.isEmpty {
                FormSection("Пока нет сохранённых голосов") {
                    SupportingText("Откройте запись, нажмите «Разметить голоса», назначьте имя и включите «Запомнить голос для будущих встреч»")
                }.padding(PisyaDesign.Spacing.content).plainSurface()
            } else {
                ForEach(state.voiceProfiles) { profile in
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                        HStack(alignment: .top, spacing: PisyaDesign.Spacing.related) {
                            screenText(profile.name).font(PisyaDesign.Typography.bodyStrong)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            screenButton("Переименовать") { renaming = profile }
                                .actionButton(size: .small).fixedSize()
                                .focused($focusedControl, equals: .rename(profile.id))
                                .accessibilityLabel("Переименовать голос «\(profile.name)»")
                            screenButton("Забыть голос…", role: .destructive) { forgetting = profile }
                                .actionButton(size: .small).fixedSize()
                                .focused($focusedControl, equals: .forget(profile.id))
                                .accessibilityLabel("Забыть голос «\(profile.name)»")
                        }
                        if let examples = profile.examples, !examples.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: PisyaDesign.Spacing.related)], alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                                ForEach(Array(examples.enumerated()), id: \.element.id) { index, example in
                                    Button { state.playExample(example) } label: {
                                        screenLabel("Образец \(index + 1)", systemImage: state.playingSegmentID == example.id ? "stop.fill" : "play.fill")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.actionButton(size: .small).disabled(state.recording)
                                        .focused($focusedControl, equals: .sample(profile.id, example.id))
                                        .accessibilityLabel("\(state.playingSegmentID == example.id ? "Остановить" : "Послушать") образец \(index + 1), \(profile.name)")
                                }
                            }
                        } else {
                            SupportingText("Аудиообразец не сохранён. Голос доступен для узнавания на будущих встречах.")
                        }
                    }.padding(PisyaDesign.Spacing.content).plainSurface().id(profile.id)
                }
            }
        }
        .sheet(item: $renaming) { profile in SavedVoiceNameEditor(profile: profile).environmentObject(state) }
        .sheet(item: $forgetting) { profile in ForgetSavedVoiceConfirmation(profile: profile).environmentObject(state) }
        .onChange(of: focusedControl) { _, control in
            if let control { scrollTo(control.profileID) }
        }
        .onDisappear { state.stopPlayback() }
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
