import SwiftUI

extension AppState {
    /// Publish only after the complete current preferences have been written atomically.
    func saveVocabulary(_ vocabulary: String) throws {
        var updated = preferences
        updated.vocabulary = vocabulary
        if !demo { try library.savePreferences(updated) }
        preferences = updated
    }
}

struct VocabularyDictionaryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
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
    @FocusState private var inputFocused: Bool

    private var entries: [VocabularyDictionary.Entry] { VocabularyDictionary.entries(in: state.preferences.vocabulary) }
    private var filtered: [VocabularyDictionary.Entry] {
        search.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            HStack(alignment: .top, spacing: PisyaDesign.Spacing.related) {
                SectionHeading("Словарь распознавания", subtitle: "Нужное написание имён, названий и специальных слов", style: .window)
                Spacer(minLength: PisyaDesign.Spacing.inline)
                screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction)
            }
            SupportingText(search.isEmpty ? "Записей: \(entries.count)" : "Найдено: \(filtered.count) из \(entries.count)")
            HStack(spacing: PisyaDesign.Spacing.related) {
                SearchField(title: typographicText("Поиск по словарю"), text: $search)
                    .measuredForInterfaceTest(.dictionarySearch)
                TextField(text: $input, prompt: screenText("Слово или название")) {
                    screenText("Слово или название")
                }
                .textFieldStyle(PisyaTextFieldStyle(isEditing: inputFocused))
                .focused($inputFocused)
                .onSubmit { add() }
                .measuredForInterfaceTest(.dictionaryEntry)
                screenButton("Добавить") { add() }
                    .actionButton(.primary)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fixedSize(horizontal: true, vertical: false)
                    .measuredForInterfaceTest(.dictionaryAdd)
            }
            if let error { SupportingText(error).foregroundStyle(.red) }
            if let notice {
                HStack(spacing: PisyaDesign.Spacing.related) {
                    SupportingText(notice)
                    if let revealText {
                        screenButton("Показать запись") { reveal(revealText) }.actionButton()
                    }
                }
            }
            if removal != nil {
                HStack(spacing: PisyaDesign.Spacing.related) {
                    SupportingText("Запись удалена")
                    screenButton("Отменить удаление", action: undo).actionButton()
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                        if entries.isEmpty {
                            SupportingText("Добавьте имена и названия, которые Pisya записывает неточно")
                        } else if filtered.isEmpty {
                            SectionHeading("Ничего не найдено")
                            screenButton("Очистить поиск") { search = "" }.actionButton()
                        }
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: PisyaDesign.Spacing.related) {
                                screenText(verbatim: entry.text, highlighting: search).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                    .measuredForInterfaceTest(.dictionaryResult)
                                HStack(spacing: PisyaDesign.Spacing.related) {
                                    screenButton("Изменить…") { editing = entry }.actionButton(size: .small)
                                    screenButton("Удалить") { delete(entry) }.actionButton(size: .small)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(PisyaDesign.Spacing.related)
                            .background(highlighted == entry.id ? Color.moss.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                            .id(entry.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: scrollTarget) { _, target in
                    if let target { withAnimation { proxy.scrollTo(target, anchor: .center) } }
                }
            }
        }.dialogContent().frame(width: 780, height: 620)
            .sheet(item: $editing) { entry in
                VocabularyEditForm(entry: entry).environmentObject(state)
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
            let change = try VocabularyDictionary.removing(entry, from: state.preferences.vocabulary)
            try state.saveVocabulary(change.vocabulary)
            removal = change; notice = nil; revealText = nil
        }
    }

    private func undo() {
        guard let removal else { return }
        perform {
            try state.saveVocabulary(removal.restoring(in: state.preferences.vocabulary))
            self.removal = nil
        }
    }
}

private struct VocabularyEditForm: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let entry: VocabularyDictionary.Entry
    @State private var text: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(entry: VocabularyDictionary.Entry) {
        self.entry = entry
        _text = State(initialValue: entry.text)
    }

    private var valid: Bool {
        guard let validated = try? VocabularyDictionary.validatedText(text) else { return false }
        return validated != entry.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            SectionHeading("Изменить запись", subtitle: "Сохранится именно указанное вами написание", style: .dialog)
            TextField("Слово или название", text: $text)
                .textFieldStyle(PisyaTextFieldStyle(isEditing: focused)).focused($focused).onSubmit(save)
            if let error { SupportingText(error).foregroundStyle(.red) }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer()
                screenButton("Сохранить", action: save).actionButton(.primary).disabled(!valid)
            }
        }.dialogContent().frame(width: 500)
    }

    private func save() {
        guard valid else { return }
        do {
            let updated = try VocabularyDictionary.replacing(entry, with: text, in: state.preferences.vocabulary)
            try state.saveVocabulary(updated); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
