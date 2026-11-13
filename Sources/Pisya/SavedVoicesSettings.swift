import SwiftUI

struct SavedVoicesSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var expandedVoices: Set<UUID> = []
    @State private var dialog: VoiceDialog?
    @State private var mergedVoiceID: UUID?
    @State private var voiceToReveal: UUID?
    @FocusState private var focusedControl: VoiceControl?

    private enum VoiceControl: Hashable {
        case disclosure(UUID), actions(UUID), play(UUID), remove(UUID)

        var scrollID: UUID {
            switch self {
            case .disclosure(let id), .actions(let id), .play(let id), .remove(let id): id
            }
        }
    }

    private enum VoiceDialog: Identifiable {
        case rename(VoiceProfile), merge(VoiceProfile), forget(VoiceProfile)
        case remove(VoiceExample, number: Int, from: VoiceProfile)

        var id: UUID {
            switch self {
            case .rename(let profile), .merge(let profile), .forget(let profile): profile.id
            case .remove(let example, _, _): example.id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            SectionHeading("Сохранённые голоса", subtitle: "Pisya узнаёт людей по этим образцам на новых встречах")
            if state.voiceProfiles.isEmpty {
                emptyState
            } else {
                SearchField(title: "Найти голос по имени", text: $query)
                ScrollViewReader { proxy in
                    ScrollView { voiceList }
                        .onChange(of: focusedControl) { _, control in
                            if let control { proxy.scrollTo(control.scrollID) }
                        }
                        .onChange(of: voiceToReveal) { _, id in
                            if let id { proxy.scrollTo(id); voiceToReveal = nil }
                        }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $dialog, onDismiss: revealMergedVoice) { dialog in
            switch dialog {
            case .rename(let profile):
                SavedVoiceNameEditor(profile: profile) { mergedVoiceID = $0 }
            case .merge(let profile):
                SavedVoiceMergeEditor(profile: profile) { mergedVoiceID = $0 }
            case .forget(let profile):
                SavedVoiceConfirmation(
                    title: "Забыть голос «\(profile.name)»?",
                    detail: "Профиль и его образцы будут удалены. Имена в прежних расшифровках сохранятся.",
                    action: "Забыть голос"
                ) {
                    try state.forgetVoice(profile.id)
                }
            case .remove(let example, let number, let profile):
                SavedVoiceConfirmation(
                    title: "Удалить образец \(number)?",
                    detail: "Для распознавания голоса «\(profile.name)» останутся другие образцы",
                    action: "Удалить образец"
                ) {
                    try state.removeVoiceExample(example.id, from: profile.id)
                }
            }
        }
        .onDisappear { state.stopPlayback() }
    }

    private func revealMergedVoice() {
        guard let id = mergedVoiceID else { return }
        if let profile = state.voiceProfiles.first(where: { $0.id == id }) {
            if !matchesVoiceSearch(profile, query: query) { query = "" }
            if profile.examples?.isEmpty == false { expandedVoices.insert(id) }
            voiceToReveal = id
        }
        mergedVoiceID = nil
    }

    private var voiceList: some View {
        let profiles = filteredVoices(state.voiceProfiles, query: query)
        return Group {
            if profiles.isEmpty {
                SupportingText("Голоса с таким именем не найдены")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PisyaDesign.Spacing.content)
                    .plainSurface()
            } else {
                VStack(spacing: PisyaDesign.Spacing.none) {
                    ForEach(profiles) { profile in
                        voiceRow(profile)
                        if profile.id != profiles.last?.id {
                            Divider().padding(.horizontal, PisyaDesign.Spacing.content)
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: PisyaDesign.Metrics.surfaceRadius)
                        .strokeBorder(PisyaDesign.Colors.secondaryAction, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
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
        .padding(PisyaDesign.Spacing.content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainSurface()
    }

    private func voiceRow(_ profile: VoiceProfile) -> some View {
        let examples = profile.examples ?? []
        let expanded = expandedVoices.contains(profile.id) && !examples.isEmpty
        return VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                if examples.isEmpty {
                    voiceIdentity(profile, sampleCount: 0)
                } else {
                    Button {
                        if expanded {
                            expandedVoices.remove(profile.id)
                            if examples.contains(where: { $0.id == state.playingSegmentID }) { state.stopPlayback() }
                        } else {
                            expandedVoices.insert(profile.id)
                        }
                    } label: {
                        HStack(spacing: PisyaDesign.Spacing.related) {
                            voiceIdentity(profile, sampleCount: examples.count)
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(PisyaDesign.Typography.Icon.disclosure)
                                .foregroundStyle(Color.mutedInk)
                                .frame(width: PisyaDesign.Metrics.smallHeight, height: PisyaDesign.Metrics.smallHeight)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .shapeAwarePlainButton()
                    .focused($focusedControl, equals: .disclosure(profile.id))
                    .accessibilityLabel(typographicText("\(profile.name), \(voiceSampleCount(examples.count))"))
                    .accessibilityValue(expanded ? "Образцы показаны" : "Образцы свёрнуты")
                    .screenHelp(expanded ? "Свернуть образцы" : "Показать образцы")
                }
                voiceActions(profile)
            }
            .id(profile.id)
            if expanded {
                VStack(spacing: PisyaDesign.Spacing.compact) {
                    ForEach(Array(examples.enumerated()), id: \.element.id) { index, example in
                        sampleRow(example, number: index + 1, profile: profile, canRemove: examples.count > 1)
                            .id(example.id)
                    }
                }
                .padding(PisyaDesign.Spacing.inline)
                .plainSurface()
            }
        }
        .padding(.horizontal, PisyaDesign.Spacing.content)
        .padding(.vertical, PisyaDesign.Spacing.related)
    }

    private func voiceIdentity(_ profile: VoiceProfile, sampleCount: Int) -> some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            screenText(verbatim: profile.name.prefix(1).uppercased())
                .textStyle(PisyaDesign.Typography.detailStrong)
                .foregroundStyle(Color.moss)
                .frame(width: PisyaDesign.Metrics.regularHeight, height: PisyaDesign.Metrics.regularHeight)
                .background(Color.moss.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.hairline) {
                screenText(profile.name)
                    .textStyle(PisyaDesign.Typography.bodyStrong)
                    .lineLimit(2)
                    .screenHelp(profile.name)
                screenText(sampleCount == 0 ? "Без аудиообразцов" : voiceSampleCount(sampleCount))
                    .textStyle(PisyaDesign.Typography.detail)
                    .foregroundStyle(Color.mutedInk)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func voiceActions(_ profile: VoiceProfile) -> some View {
        NativeActionMenu {
            [
                NativeActionMenuItem("Переименовать…") { dialog = .rename(profile) },
                NativeActionMenuItem("Объединить с другим голосом…", enabled: state.voiceProfiles.count > 1) { dialog = .merge(profile) },
                .separator(),
                NativeActionMenuItem("Забыть голос") { dialog = .forget(profile) },
            ]
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
        .accessibilityLabel(typographicText("Действия с голосом «\(profile.name)»"))
    }

    private func sampleRow(_ example: VoiceExample, number: Int, profile: VoiceProfile, canRemove: Bool) -> some View {
        let playing = state.playingSegmentID == example.id
        let meetingTitle = state.meetings.first { $0.id == example.meetingID }?.title
        return HStack(spacing: PisyaDesign.Spacing.related) {
            Button { state.playExample(example) } label: {
                HStack(spacing: PisyaDesign.Spacing.inline) {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                        .font(PisyaDesign.Typography.Icon.featured)
                        .foregroundStyle(state.recording ? Color.disabledInk : Color.moss)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.hairline) {
                        screenText("Образец \(number)")
                            .textStyle(PisyaDesign.Typography.detail)
                        if let meetingTitle, !meetingTitle.isEmpty {
                            screenText(meetingTitle)
                                .textStyle(PisyaDesign.Typography.caption)
                                .foregroundStyle(Color.mutedInk)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, PisyaDesign.Spacing.inline)
                .padding(.vertical, PisyaDesign.Spacing.compact)
                .frame(maxWidth: .infinity, minHeight: PisyaDesign.Metrics.smallHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .shapeAwarePlainButton()
            .disabled(state.recording)
            .focused($focusedControl, equals: .play(example.id))
            .screenHelp(playing ? "Остановить образец" : "Послушать образец")
            .accessibilityLabel(typographicText("\(playing ? "Остановить" : "Послушать") образец \(number), \(profile.name)"))
            .accessibilityHint(typographicText(meetingTitle ?? ""))

            if canRemove {
                Button { dialog = .remove(example, number: number, from: profile) } label: {
                    Image(systemName: "trash")
                        .font(PisyaDesign.Typography.Icon.medium)
                        .foregroundStyle(Color.mutedInk)
                        .frame(width: PisyaDesign.Metrics.smallHeight, height: PisyaDesign.Metrics.smallHeight)
                        .contentShape(Rectangle())
                }
                .shapeAwarePlainButton()
                .focused($focusedControl, equals: .remove(example.id))
                .screenHelp("Удалить образец")
                .accessibilityLabel(typographicText("Удалить образец \(number), \(profile.name)"))
            }
        }
    }
}

private func filteredVoices(_ profiles: [VoiceProfile], query: String) -> [VoiceProfile] {
    profiles.filter { matchesVoiceSearch($0, query: query) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

private func matchesVoiceSearch(_ profile: VoiceProfile, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || profile.name.localizedStandardContains(query)
}

private func voiceSampleCount(_ count: Int) -> String {
    let ending: String
    switch (count % 100, count % 10) {
    case (11...14, _): ending = "образцов"
    case (_, 1): ending = "образец"
    case (_, 2...4): ending = "образца"
    default: ending = "образцов"
    }
    return "\(count)\u{00a0}\(ending)"
}

private func voiceMergeDetail(from source: VoiceProfile, into target: VoiceProfile) -> String {
    "Образцы обоих голосов сохранятся. В прежних расшифровках вместо «\(source.name)» будет «\(target.name)»."
}

private struct SavedVoiceNameEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale
    let profile: VoiceProfile
    let onMerge: (UUID) -> Void
    @State private var name = ""
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingVoices: [VoiceProfile] {
        guard cleanName != profile.name else { return [] }
        return state.voiceProfiles.filter {
            $0.id != profile.id && $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }
    }
    private var matchingVoice: VoiceProfile? {
        let matches = matchingVoices
        if matches.count == 1 { return matches.first }
        let exact = matches.filter { $0.name == cleanName }
        return exact.count == 1 ? exact.first : nil
    }

    var body: some View {
        let match = matchingVoice
        let ambiguous = match == nil && !matchingVoices.isEmpty
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Переименовать голос", subtitle: "Имя обновится в прежних расшифровках и на новых встречах", style: .dialog)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                TextField("Имя участника", text: $name)
                    .textFieldStyle(PisyaTextFieldStyle(isEditing: nameFocused && textScale != AppTextSize.factor(for: 110)))
                    .accessibilityLabel("Имя сохранённого голоса")
                    .focused($nameFocused)
                    .onSubmit { if matchingVoices.isEmpty { save() } }
                if let match {
                    SupportingText(voiceMergeDetail(from: profile, into: match))
                } else if ambiguous {
                    SupportingText("Найдено несколько похожих имён. Выберите нужное через «Объединить с другим голосом…».")
                }
                if let saveError { SupportingText(saveError) }
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer(minLength: PisyaDesign.Spacing.none)
                screenButton(match == nil ? "Сохранить" : "Объединить", action: save)
                    .actionButton(.primary)
                    .disabled(cleanName.isEmpty || cleanName == profile.name || ambiguous)
            }
        }
        .dialogContent()
        .frame(width: 480)
        .onAppear { name = profile.name; nameFocused = true }
        .onChange(of: name) { saveError = nil }
    }

    private func save() {
        guard !cleanName.isEmpty, cleanName != profile.name else { return }
        do {
            if let match = matchingVoice {
                try state.mergeVoice(profile.id, into: match.id)
                onMerge(match.id)
            } else {
                guard matchingVoices.isEmpty else { return }
                try state.renameVoice(profile.id, to: cleanName)
            }
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}

private struct SavedVoiceMergeEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let profile: VoiceProfile
    let onMerge: (UUID) -> Void
    @State private var query = ""
    @State private var targetID: UUID?
    @State private var saveError: String?
    @FocusState private var focusedTargetID: UUID?

    private var target: VoiceProfile? { state.voiceProfiles.first { $0.id == targetID } }

    var body: some View {
        let candidates = filteredVoices(state.voiceProfiles.filter { $0.id != profile.id }, query: query)
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            SectionHeading("Объединить голоса", subtitle: "Выберите, какое имя оставить для голоса «\(profile.name)»", style: .dialog)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                SearchField(title: "Найти голос по имени", text: $query)
                ScrollViewReader { proxy in
                    ScrollView {
                        if candidates.isEmpty {
                            SupportingText("Голоса с таким именем не найдены")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(PisyaDesign.Spacing.inline)
                        } else {
                            VStack(spacing: PisyaDesign.Spacing.compact) {
                                ForEach(candidates) { candidate in
                                    candidateRow(candidate).id(candidate.id)
                                }
                            }
                            .padding(PisyaDesign.Spacing.compact)
                        }
                    }
                    .frame(height: PisyaDesign.Metrics.editorHeight)
                    .plainSurface()
                    .onChange(of: focusedTargetID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            if let target { SupportingText(voiceMergeDetail(from: profile, into: target)) }
            if let saveError { SupportingText(saveError) }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer(minLength: PisyaDesign.Spacing.none)
                screenButton("Объединить", action: merge)
                    .actionButton(.primary)
                    .disabled(target == nil)
            }
        }
        .dialogContent()
        .frame(width: 480)
        .onChange(of: query) {
            if let target, !matchesVoiceSearch(target, query: query) { targetID = nil }
            saveError = nil
        }
    }

    private func candidateRow(_ candidate: VoiceProfile) -> some View {
        let selected = targetID == candidate.id
        return Button {
            targetID = candidate.id
            saveError = nil
        } label: {
            HStack(spacing: PisyaDesign.Spacing.inline) {
                screenText(candidate.name)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.moss)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, PisyaDesign.Spacing.inline)
            .padding(.vertical, PisyaDesign.Spacing.compact)
            .frame(minHeight: PisyaDesign.Metrics.regularHeight)
            .background(selected ? Color.moss.opacity(0.10) : Color.paper, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
            .contentShape(Rectangle())
        }
        .shapeAwarePlainButton()
        .focused($focusedTargetID, equals: candidate.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .screenHelp(candidate.name)
    }

    private func merge() {
        guard let target else { return }
        do {
            try state.mergeVoice(profile.id, into: target.id)
            onMerge(target.id)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}

private struct SavedVoiceConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let detail: String
    let action: String
    let confirm: () throws -> Void
    @State private var saveError: String?
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading(title, subtitle: detail, style: .dialog)
            if let saveError { SupportingText(saveError) }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена", role: .cancel) { dismiss() }
                    .actionButton()
                    .focused($cancelFocused)
                    .keyboardShortcut(.cancelAction)
                    .onKeyPress(.return) { dismiss(); return .handled }
                Spacer(minLength: PisyaDesign.Spacing.none)
                screenButton(action, role: .destructive) {
                    do { try confirm(); dismiss() }
                    catch { saveError = error.localizedDescription }
                }.actionButton(.recording)
            }
        }
        .dialogContent()
        .frame(width: 480)
        .defaultFocus($cancelFocused, true)
    }
}
