import SwiftUI

extension AppState {
    /// Publish only after the complete current preferences have been written atomically.
    func saveVocabulary(_ vocabulary: String, variants: [String: [String]]? = nil) throws {
        var updated = preferences
        updated.vocabulary = vocabulary
        if let variants { updated.vocabularyVariants = variants }
        if !demo { try library.savePreferences(updated) }
        preferences = updated
    }
}

struct VocabularyDictionaryView: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""
    @State private var input = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var revealText: String?
    @State private var highlighted: Int?
    @State private var scrollTarget: Int?
    @State private var editing: VocabularyDictionary.Entry?
    @State private var confirmingSpelling = false
    @State private var removal: VocabularyDictionary.Removal?
    @State private var inputFocused = false

    private var entries: [VocabularyDictionary.Entry] { VocabularyDictionary.entries(in: state.preferences.vocabulary) }
    private var variants: [String: [String]] { state.preferences.vocabularyVariants }
    private var filtered: [VocabularyDictionary.Entry] {
        entries.filter { entry in
            search.isEmpty || entry.text.localizedCaseInsensitiveContains(search) ||
                variants[entry.text, default: []].contains { $0.localizedCaseInsensitiveContains(search) }
        }
            .sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.content) {
            SectionHeading("Словарь распознавания", subtitle: "Нужное написание имён, названий и специальных слов")
            SupportingText(search.isEmpty ? "Записей: \(entries.count)" : "Найдено: \(filtered.count) из \(entries.count)")
            HStack(spacing: PisaDesign.Spacing.related) {
                SearchField(title: typographicText("Поиск по словарю"), text: $search)
                    .measuredForInterfaceTest(.dictionarySearch)
                FormTextField(title: "Слово или название", text: $input, isFocused: $inputFocused, onSubmit: { add() })
                    .measuredForInterfaceTest(.dictionaryEntry)
                screenButton("Добавить") { add() }
                    .actionButton(.primary)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fixedSize(horizontal: true, vertical: false)
                    .measuredForInterfaceTest(.dictionaryAdd)
            }
            if let error { SupportingText(error).foregroundStyle(.red) }
            if let notice {
                HStack(spacing: PisaDesign.Spacing.related) {
                    SupportingText(notice)
                    if let revealText {
                        screenButton("Показать запись") { reveal(revealText) }.actionButton()
                    }
                }
            }
            if removal != nil {
                HStack(spacing: PisaDesign.Spacing.related) {
                    SupportingText("Запись удалена")
                    screenButton("Отменить удаление", action: undo).actionButton()
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                        if entries.isEmpty {
                            SupportingText("Добавьте имена и названия, которые Pisa записывает неточно")
                        } else if filtered.isEmpty {
                            SectionHeading("Ничего не найдено")
                            screenButton("Очистить поиск") { search = "" }.actionButton()
                        }
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: PisaDesign.Spacing.related) {
                                VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                                    screenText(verbatim: entry.text, highlighting: search)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .measuredForInterfaceTest(.dictionaryResult)
                                    if let forms = variants[entry.text], !forms.isEmpty {
                                        screenText(verbatim: forms.joined(separator: ", "), highlighting: search)
                                            .textStyle(PisaDesign.Typography.caption)
                                            .foregroundStyle(Color.mutedInk)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                HStack(spacing: PisaDesign.Spacing.related) {
                                    screenButton("Изменить…") { editing = entry }.actionButton(size: .small)
                                    screenButton("Удалить") { delete(entry) }.actionButton(size: .small)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(PisaDesign.Spacing.related)
                            .background(highlighted == entry.id ? Color.moss.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                            .id(entry.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: scrollTarget) { _, target in
                    if let target { withAnimation { proxy.scrollTo(target, anchor: .center) } }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .topLeading)
            .sheet(item: $editing) { entry in
                VocabularyEditForm(entry: entry, variants: variants[entry.text, default: []]).environmentObject(state)
            }
            .sheet(isPresented: $confirmingSpelling) {
                ConfirmationSheet(
                    title: "Добавить «\(TranscriptTerms.dictionaryTerm(input))»?",
                    message: "В словаре сохранится основная форма",
                    actionTitle: "Добавить"
                ) { add(confirmSpelling: true) }
            }
            .task(id: highlighted) {
                guard highlighted != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { highlighted = nil }
            }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); error = nil }
        catch { self.error = "Не удалось сохранить словарь: " + error.localizedDescription }
    }

    private func add(confirmSpelling: Bool = false) {
        perform {
            let literal = try VocabularyDictionary.validatedText(input)
            let current = state.preferences.vocabulary
            let preview = VocabularyDictionary.preview(literal, vocabulary: current)
            let owner = VocabularyDictionary.variantOwner(of: literal, in: variants)
                ?? preview.additions.first.flatMap { VocabularyDictionary.variantOwner(of: $0, in: variants) }
            if let owner {
                notice = "Уже есть в словаре как вариант"
                revealText = owner
                return
            }
            guard let canonical = preview.additions.first else {
                notice = "Уже есть в словаре"
                revealText = entries.first { VocabularyDictionary.preview(literal, vocabulary: $0.text).additions.isEmpty }?.text
                return
            }
            if canonical != literal && !confirmSpelling {
                confirmingSpelling = true
                return
            }
            try state.saveVocabulary(preview.vocabulary)
            input = ""; inputFocused = true
            added(canonical)
        }
    }

    private func added(_ text: String) {
        notice = "Добавлено: \(text)"; revealText = nil
        if !search.isEmpty && !text.localizedCaseInsensitiveContains(search) { revealText = text }
        else { reveal(text, clearSearch: false) }
    }

    private func reveal(_ text: String, clearSearch: Bool = true) {
        if clearSearch { search = "" }
        guard let entry = entries.last(where: { $0.text == text }) else { return }
        highlighted = entry.id
        scrollTarget = nil
        DispatchQueue.main.async { scrollTarget = entry.id }
        revealText = nil
    }

    private func delete(_ entry: VocabularyDictionary.Entry) {
        perform {
            let change = try VocabularyDictionary.removing(entry, from: state.preferences.vocabulary, variants: variants)
            try state.saveVocabulary(change.vocabulary, variants: change.variants)
            removal = change; notice = nil; revealText = nil
        }
    }

    private func undo() {
        guard let removal else { return }
        perform {
            let restored = try removal.restoring(in: state.preferences.vocabulary, variants: variants)
            try state.saveVocabulary(restored.vocabulary, variants: restored.variants)
            self.removal = nil
        }
    }
}

struct VocabularyEditForm: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let entry: VocabularyDictionary.Entry
    private let initialVariants: [String]
    @State private var text: String
    @State private var variantInput: String
    @State private var error: String?

    init(entry: VocabularyDictionary.Entry, variants: [String] = []) {
        self.entry = entry
        initialVariants = variants
        _text = State(initialValue: entry.text)
        _variantInput = State(initialValue: variants.joined(separator: ", "))
    }

    private var valid: Bool {
        guard let validated = try? VocabularyDictionary.validatedText(text) else { return false }
        return validated != entry.text || variantInput != initialVariants.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.content) {
            SectionHeading("Изменить запись", subtitle: "Сохранится именно указанное вами написание", style: .dialog)
            FormTextField(title: "Слово или название", text: $text, onSubmit: save)
                .measuredForInterfaceTest(.dictionaryEdit)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                SectionHeading("Варианты распознавания")
                FormTextField(title: "Через запятую", text: $variantInput,
                              accessibilityTitle: "Варианты распознавания", onSubmit: save)
            }
            if let error { SupportingText(error).foregroundStyle(.red) }
            HStack(spacing: PisaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer()
                screenButton("Сохранить", action: save).actionButton(.primary).disabled(!valid)
            }
        }.dialogContent().frame(width: 500)
    }

    private func save() {
        guard valid else { return }
        do {
            let current = state.preferences
            guard current.vocabularyVariants[entry.text, default: []] == initialVariants else {
                throw VocabularyDictionary.Failure.stale
            }
            let updated = try VocabularyDictionary.replacing(entry, with: text, variantInput: variantInput,
                                                               in: current.vocabulary, variants: current.vocabularyVariants)
            try state.saveVocabulary(updated.vocabulary, variants: updated.variants)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
