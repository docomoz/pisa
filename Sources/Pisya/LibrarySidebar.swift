import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject var state: AppState
    @State private var folderEditor = false
    @State private var editingFolder: MeetingFolder?
    @State private var folderName = ""
    @State private var deletingFolder: MeetingFolder?
    @State private var confirmEmptyTrash = false
    @FocusState private var recordingsFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            HStack(spacing: PisyaDesign.Spacing.inline) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.mutedInk)
                TextField("Название, текст, участник", text: $state.search).textFieldStyle(.plain)
                if !state.search.isEmpty { Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }.shapeAwarePlainButton(Circle()).screenHelp("Очистить поиск") }
            }.font(.appFont(size: 12)).padding(PisyaDesign.Spacing.related).plainSurface(radius: 12)
            ScrollView { VStack(spacing: 2) {
                scope("Все записи", icon: "tray", selected: !state.showingTrash && state.folderFilter == nil && !state.unfiledOnly) { state.openFolder() }
                scope("Без папки", icon: "doc", selected: state.unfiledOnly && !state.showingTrash) { state.openFolder(unfiled: true) }
                ForEach(state.folders) { folder in
                    scope(folder.name, icon: folder.iconName, selected: state.folderFilter == folder.id && !state.showingTrash) { state.openFolder(folder.id) }
                        .contextMenu {
                            screenButton("Изменить папку…") { editingFolder = folder; folderName = folder.name; folderEditor = true }
                            screenButton("Удалить папку…", role: .destructive) { deletingFolder = folder }
                        }
                }
                Button { editingFolder = nil; folderName = ""; folderEditor = true } label: { navigationLabel("Новая папка", icon: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.actionButton().disabled(state.demo)
                scope("Корзина", icon: "trash", selected: state.showingTrash) { state.openFolder(trash: true) }
                    .contextMenu { screenButton("Очистить корзину…", role: .destructive) { confirmEmptyTrash = true }.disabled(!state.canEmptyTrash) }
            }.font(.appFont(size: 12)) }.frame(height: min(190, CGFloat(state.folders.count + 4) * 36))
            HStack { screenText(state.search.isEmpty ? "ЗАПИСИ" : "НАЙДЕНО").tracking(1.3); Spacer(); screenText("\(state.filtered.count)") }.font(.appFont(size: 10, weight: .semibold)).foregroundStyle(Color.mutedInk)
            ScrollViewReader { proxy in
              ScrollView {
              LazyVStack(spacing: 4) {
                ForEach(state.filtered) { meeting in
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                        screenText(meeting.title).font(.appFont(size: 13, weight: meeting.hasAutomaticTitle ? .regular : .medium)).lineLimit(1).truncationMode(.tail).screenHelp(meeting.title)
                        HStack(spacing: PisyaDesign.Spacing.inline) {
                            if !meeting.hasAutomaticTitle {
                                screenText(meetingDateLabel(meeting.date)).lineLimit(1).truncationMode(.middle).layoutPriority(1).screenHelp(meetingDateLabel(meeting.date))
                                screenText("·")
                            }
                            if state.recordingMeetingID == meeting.id, let started = state.recordingStarted {
                                Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
                                screenText("Идёт запись").foregroundStyle(Color(red: 0.67, green: 0.20, blue: 0.19))
                                RecordingElapsed(started: started, size: 11)
                            } else { screenText(timecode(meeting.duration)).monospacedDigit().fixedSize() }
                            if let folder = state.folders.first(where: { $0.id == meeting.folderID }) {
                                screenText("·")
                                Image(systemName: folder.iconName).imageScale(.small)
                                screenText(folder.name).lineLimit(1).layoutPriority(-1).screenHelp(folder.name)
                            }
                            Spacer(minLength: 0)
                            if meeting.status == .processing { ProgressView().controlSize(.mini) }
                        }.font(.appFont(size: 11)).foregroundStyle(Color.mutedInk).lineLimit(1)

                    }.padding(.vertical, PisyaDesign.Spacing.related).padding(.horizontal, PisyaDesign.Spacing.related).frame(maxWidth: .infinity, alignment: .leading)
                        .plainSelection(state.selection == meeting.id)
                        .contentShape(Rectangle()).onTapGesture { recordingsFocused = true; state.select(meeting.id) }.id(meeting.id)
                        .accessibilityAddTraits(state.selection == meeting.id ? .isSelected : [])
                        .accessibilityAction { state.select(meeting.id) }
                        .contextMenu { MeetingActions(meeting: meeting) }
                }
              }
              }.focusable().focusEffectDisabled().focused($recordingsFocused)
                .onMoveCommand { direction in
                    let rows = state.filtered
                    guard !rows.isEmpty, direction == .up || direction == .down else { return }
                    let index = rows.firstIndex { $0.id == state.selection } ?? 0
                    let next = min(rows.count - 1, max(0, index + (direction == .down ? 1 : -1)))
                    state.select(rows[next].id); proxy.scrollTo(rows[next].id)
                }
                .overlay { if state.filtered.isEmpty { screenText(state.showingTrash ? "Корзина пуста" : "Записи не найдены").font(.appFont(size: 12)).foregroundStyle(Color.mutedInk) } }
            }
        }.padding(.horizontal, PisyaDesign.Spacing.content).padding(.top, PisyaDesign.Spacing.content).padding(.bottom, PisyaDesign.Spacing.content).background(Color.sidebarTint)
        .confirmationDialog(typographicText("Очистить корзину? Все записи и их аудио будут удалены без возможности восстановления"), isPresented: $confirmEmptyTrash) {
            screenButton("Очистить корзину", role: .destructive) { state.emptyTrash() }
            screenButton("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $folderEditor) {
            FolderEditor(folder: editingFolder) { name, symbol in state.saveFolder(name, id: editingFolder?.id, symbol: symbol) }
        }
        .confirmationDialog(typographicText("Удалить папку? Записи останутся в разделе «Без папки»"), isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
            if let folder = deletingFolder { screenButton("Удалить папку", role: .destructive) { state.removeFolder(folder); deletingFolder = nil } }
        }
    }
    private func navigationLabel(_ name: String, icon: String) -> some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            Image(systemName: icon).frame(width: 20, height: 18)
            screenText(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func scope(_ name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { navigationLabel(name, icon: icon).frame(maxWidth: .infinity, alignment: .leading).padding(PisyaDesign.Spacing.inline).plainSelection(selected, radius: 9).contentShape(Rectangle()) }.shapeAwarePlainButton()
    }
}
struct MeetingActions: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    var body: some View {
        Group {
            if meeting.deletedAt != nil {
                screenButton("Восстановить") { state.trash(meeting, restore: true) }.disabled(!state.canModify(meeting))
            } else {
                screenButton("Разметить голоса…") { state.voiceMeeting = meeting }.disabled(meeting.segments.isEmpty || !state.canModify(meeting))
                screenButton("Переименовать…") { state.renameTarget = meeting }.disabled(!state.canModify(meeting))
                screenMenu("Переместить в папку") {
                    Button { state.move(meeting, to: nil) } label: {
                        screenLabel("Без папки", systemImage: meeting.folderID == nil ? "checkmark" : "tray")
                    }
                    Divider()
                    ForEach(state.folders) { folder in
                        Button { state.move(meeting, to: folder.id) } label: {
                            screenLabel(folder.name, systemImage: meeting.folderID == folder.id ? "checkmark" : folder.iconName)
                        }
                    }
                }.disabled(!state.canModify(meeting))
                Divider()
                screenButton("Расшифровать заново…") { state.reprocessTarget = meeting }.disabled(!state.hasAudio(meeting) || !state.canModify(meeting))
                screenButton("В корзину", role: .destructive) { state.trash(meeting) }.disabled(!state.canModify(meeting))
            }
        }.disabled(!state.canModify(meeting))
    }
}
struct NameEditor: View {
    let title: String
    let initial: String
    var save: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading(title, size: 20)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                TextField("Название", text: $name).textFieldStyle(PisyaTextFieldStyle()).focused($focused).onSubmit { submit() }
            }
            HStack(spacing: PisyaDesign.Spacing.related) { screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction); Spacer(); screenButton("Сохранить") { submit() }.actionButton(.primary).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.font(.appFont(size: 15)).actionControls().padding(PisyaDesign.Spacing.sheetInset).frame(width: 420).popupCanvas().onAppear { name = initial; focused = true }
    }
    private func submit() { guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; save(name); dismiss() }
}

private struct FolderEditor: View {
    let folder: MeetingFolder?
    var save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "folder"
    @FocusState private var nameFocused: Bool
    private let icons: [(String, String)] = [
        ("folder", "Папка"), ("briefcase", "Работа"), ("person", "Человек"), ("person.2", "Команда"),
        ("person.3", "Группа"), ("bubble.left", "Разговор"), ("bubble.left.and.bubble.right", "Обсуждение"), ("phone", "Звонки"),
        ("video", "Видеовстречи"), ("mic", "Микрофон"), ("headphones", "Аудио"), ("music.note", "Музыка"),
        ("doc.text", "Документы"), ("book", "Книги"), ("bookmark", "Закладки"), ("graduationcap", "Обучение"),
        ("lightbulb", "Идеи"), ("sparkles", "Вдохновение"), ("pencil", "Заметки"), ("paintbrush", "Творчество"),
        ("calendar", "Планы"), ("clock", "Время"), ("checkmark.circle", "Задачи"), ("flag", "Цели"),
        ("star", "Избранное"), ("heart", "Личное"), ("house", "Дом"), ("building.2", "Компания"),
        ("globe", "Мир"), ("map", "Карта"), ("location", "Места"), ("airplane", "Поездки"),
        ("car", "Автомобиль"), ("cup.and.saucer", "Кофе"), ("gift", "Подарки"), ("leaf", "Природа"),
        ("wrench.and.screwdriver", "Инструменты"), ("gearshape", "Настройки"), ("chart.bar", "Аналитика"), ("tray", "Входящие")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading(folder == nil ? "Новая папка" : "Изменить папку", size: 22)
            HStack(spacing: PisyaDesign.Spacing.related) {
                Image(systemName: symbol).font(.appFont(size: 18)).foregroundStyle(Color.ink).frame(width: 32, height: 32)
                TextField("Название папки", text: $name).textFieldStyle(PisyaTextFieldStyle()).focused($nameFocused).onSubmit { submit() }
            }
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
            screenText("Иконка папки").font(.appFont(size: 14, weight: .medium)).foregroundStyle(Color.mutedInk)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: PisyaDesign.Spacing.inline), count: 8), spacing: PisyaDesign.Spacing.inline) {
                ForEach(icons, id: \.0) { item in
                    Button { symbol = item.0 } label: {
                        Image(systemName: item.0).font(.appFont(size: 14, weight: .regular)).symbolRenderingMode(.monochrome)
                            .frame(width: 32, height: 32)
                            .background(symbol == item.0 ? PisyaDesign.Colors.selection : PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.shapeAwarePlainButton().frame(width: 32, height: 32).foregroundStyle(Color.ink).screenHelp(item.1).accessibilityLabel(item.1)
                        .accessibilityAddTraits(symbol == item.0 ? .isSelected : [])
                }
            }
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer()
                screenButton(folder == nil ? "Создать папку" : "Сохранить") { submit() }
                    .actionButton(.primary).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.appFont(size: 15)).controlSize(.large).padding(PisyaDesign.Spacing.sheetInset).frame(width: 384).actionControls().popupCanvas()
            .onAppear { name = folder?.name ?? ""; symbol = folder?.iconName ?? "folder"; nameFocused = true }
    }
    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        save(name, symbol); dismiss()
    }
}
