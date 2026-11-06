import SwiftUI
import AppKit

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
            SearchField(title: "Название, текст, участник", text: $state.search, compact: true)
            ScrollView { VStack(spacing: PisyaDesign.Spacing.hairline) {
                scope("Все записи", icon: "tray", selected: !state.showingTrash && state.folderFilter == nil && !state.unfiledOnly) { state.openFolder() }
                scope("Без папки", icon: "doc", selected: state.unfiledOnly && !state.showingTrash) { state.openFolder(unfiled: true) }
                ForEach(state.folders) { folder in
                    scope(folder.name, icon: folder.iconName, selected: state.folderFilter == folder.id && !state.showingTrash) { state.openFolder(folder.id) }
                        .popupContextMenu {
                            [NativeActionMenuItem("Изменить папку…") { editingFolder = folder; folderName = folder.name; folderEditor = true },
                             NativeActionMenuItem("Удалить папку") { deletingFolder = folder }]
                        }
                }
                scope("Новая папка…", icon: "folder.badge.plus", selected: false) { editingFolder = nil; folderName = ""; folderEditor = true }
                    .disabled(state.demo)
                scope("Корзина", icon: "trash", selected: state.showingTrash) { state.openFolder(trash: true) }
                    .popupContextMenu { [NativeActionMenuItem("Очистить корзину", enabled: state.canEmptyTrash) { confirmEmptyTrash = true }] }
            }.textStyle(PisyaDesign.Typography.footnote) }.frame(height: min(190, CGFloat(state.folders.count + 4) * 36))
            HStack(spacing: PisyaDesign.Spacing.inline) { Eyebrow(state.search.isEmpty ? "ЗАПИСИ" : "НАЙДЕНО"); Spacer(); screenText("\(state.filtered.count)") }.textStyle(PisyaDesign.Typography.overline).foregroundStyle(Color.mutedInk)
            ScrollViewReader { proxy in
              ScrollView {
              LazyVStack(spacing: PisyaDesign.Spacing.compact) {
                ForEach(state.filtered) { meeting in
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                        screenText(meeting.title).textStyle(meeting.hasAutomaticTitle ? PisyaDesign.Typography.caption : PisyaDesign.Typography.captionMedium).lineLimit(1).truncationMode(.tail).screenHelp(meeting.title)
                        HStack(spacing: PisyaDesign.Spacing.inline) {
                            if !meeting.hasAutomaticTitle {
                                screenText(meetingDateLabel(meeting.date)).lineLimit(1).truncationMode(.middle).layoutPriority(1).screenHelp(meetingDateLabel(meeting.date))
                                screenText("·")
                            }
                            if state.recordingMeetingID == meeting.id, let started = state.recordingStarted {
                                Circle().fill(Color.recordingRed).frame(width: 6, height: 6).accessibilityHidden(true)
                                screenText("Идёт запись").foregroundStyle(Color.recordingRed)
                                RecordingElapsed(started: started)
                            } else { screenText(timecode(meeting.duration)).monospacedDigit().fixedSize() }
                            if let folder = state.folders.first(where: { $0.id == meeting.folderID }) {
                                screenText("·")
                                Image(systemName: folder.iconName).imageScale(.small)
                                screenText(folder.name).lineLimit(1).layoutPriority(-1).screenHelp(folder.name)
                            }
                            Spacer(minLength: 0)
                            if state.isQueued(meeting.id) {
                                Image(systemName: "clock").accessibilityLabel("В очереди на расшифровку").screenHelp("В очереди на расшифровку")
                            } else if meeting.status == .processing { ProgressView().controlSize(.mini) }
                        }.textStyle(PisyaDesign.Typography.micro).foregroundStyle(Color.mutedInk).lineLimit(1)

                    }.padding(.vertical, PisyaDesign.Spacing.related).padding(.horizontal, PisyaDesign.Spacing.related).frame(maxWidth: .infinity, alignment: .leading)
                        .plainSelection(state.selection == meeting.id)
                        .contentShape(Rectangle()).onTapGesture { recordingsFocused = true; state.select(meeting.id) }.id(meeting.id)
                        .accessibilityAddTraits(state.selection == meeting.id ? .isSelected : [])
                        .accessibilityAction { state.select(meeting.id) }
                        .popupContextMenu(onOpen: {
                            if state.selection != meeting.id { state.select(meeting.id) }
                            recordingsFocused = true
                        }) {
                            MeetingActionSet(state: state, meeting: meeting).contextMenuItems
                        }
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
                .overlay { if state.filtered.isEmpty { screenText(state.showingTrash ? "Корзина пуста" : "Записи не найдены").textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk) } }
            }
        }.padding(.horizontal, PisyaDesign.Spacing.content).padding(.top, PisyaDesign.Spacing.content).padding(.bottom, PisyaDesign.Spacing.content).background(Color.sidebarTint)
        .sheet(isPresented: $confirmEmptyTrash) {
            ConfirmationSheet(
                title: "Очистить корзину?",
                message: "Все записи и их аудио будут удалены навсегда",
                actionTitle: "Очистить корзину",
                role: .destructive
            ) { state.emptyTrash() }
        }
        .sheet(isPresented: $folderEditor) {
            FolderEditor(folder: editingFolder) { name, symbol in state.saveFolder(name, id: editingFolder?.id, symbol: symbol) }
        }
        .sheet(item: $deletingFolder) { folder in
            ConfirmationSheet(
                title: "Удалить папку?",
                message: "Записи останутся в разделе «Без папки»",
                actionTitle: "Удалить папку",
                role: .destructive
            ) { state.removeFolder(folder) }
        }
    }
    private func navigationLabel(_ name: String, icon: String) -> some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            Image(systemName: icon).frame(width: 20, height: 18)
            screenText(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func scope(_ name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { navigationLabel(name, icon: icon).frame(maxWidth: .infinity, alignment: .leading).padding(PisyaDesign.Spacing.inline).plainSelection(selected, radius: PisyaDesign.Metrics.navigationRadius).contentShape(Rectangle()) }.shapeAwarePlainButton()
    }
}
@MainActor
struct MeetingActionSet {
    let state: AppState
    let meeting: Meeting

    @MainActor
    struct Item {
        let title: String
        var role: ButtonRole? = nil
        var enabled = true
        let perform: () -> Void

        var nativeItem: NSMenuItem {
            NativeActionMenuItem(title, enabled: enabled, perform: perform)
        }
    }

    var contextMenuItems: [NSMenuItem] {
        let canModify = state.canModify(meeting)
        if meeting.deletedAt != nil {
            let item = restore.nativeItem
            item.isEnabled = canModify
            return [item]
        }
        let voices = NativeActionMenuItem("Разметить голоса…", enabled: canModify && !meeting.segments.isEmpty) { state.voiceMeeting = meeting }
        let move = NSMenuItem(title: "Переместить в папку", action: nil, keyEquivalent: "")
        move.submenu = nativeActionMenu(items: folderMenuItems)
        let items = [voices, rename.nativeItem, move, .separator(), reprocess.nativeItem, .separator(), trash.nativeItem]
        if !canModify { items.filter { !$0.isSeparatorItem }.forEach { $0.isEnabled = false } }
        return items
    }

    var folderMenuItems: [NSMenuItem] { folderMenuItems(beforeNewFolder: {}) }

    func folderMenuItems(beforeNewFolder: @escaping () -> Void) -> [NSMenuItem] {
        func folderItem(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> NSMenuItem {
            let item = NativeActionMenuItem(title, perform: action)
            item.image = NSImage(systemSymbolName: selected ? "checkmark" : icon, accessibilityDescription: nil)
            return item
        }
        var items: [NSMenuItem] = [folderItem("Без папки", icon: "tray", selected: meeting.folderID == nil) { state.move(meeting, to: nil) }]
        if !state.folders.isEmpty { items.append(.separator()) }
        items += state.folders.map { folder in
            folderItem(folder.name, icon: folder.iconName, selected: meeting.folderID == folder.id) { state.move(meeting, to: folder.id) }
        }
        if meeting.deletedAt == nil {
            items.append(.separator())
            items.append(folderItem("Новая папка…", icon: "folder.badge.plus", selected: false) { beforeNewFolder(); state.newFolderMeeting = meeting })
        }
        return items
    }

    var rename: Item { Item(title: "Переименовать…") { state.renameTarget = meeting } }
    var reprocess: Item {
        Item(title: "Расшифровать заново", enabled: state.hasAudio(meeting)) { state.reprocessTarget = meeting }
    }
    var trash: Item { Item(title: "В корзину", role: .destructive) { state.trash(meeting) } }
    var restore: Item { Item(title: "Восстановить") { state.trash(meeting, restore: true) } }
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
            SectionHeading(title, style: .dialog)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                TextField("Название", text: $name).textFieldStyle(PisyaTextFieldStyle()).focused($focused).onSubmit { submit() }
            }
            HStack(spacing: PisyaDesign.Spacing.related) { screenButton("Отмена") { dismiss() }.actionButton().keyboardShortcut(.cancelAction); Spacer(); screenButton("Сохранить") { submit() }.actionButton(.primary).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.dialogContent().frame(width: 420).onAppear { name = initial; focused = true }
    }
    private func submit() { guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; save(name); dismiss() }
}

struct FolderEditor: View {
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
            SectionHeading(folder == nil ? "Новая папка" : "Изменить папку", style: .dialog)
            HStack(spacing: PisyaDesign.Spacing.related) {
                Image(systemName: symbol).font(PisyaDesign.Typography.Icon.medium).foregroundStyle(Color.ink).frame(width: 32, height: 32)
                TextField("Название папки", text: $name).textFieldStyle(PisyaTextFieldStyle()).focused($nameFocused).onSubmit { submit() }
            }
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
            screenText("Иконка папки").textStyle(PisyaDesign.Typography.detailMedium).foregroundStyle(Color.mutedInk)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: PisyaDesign.Spacing.inline), count: 8), spacing: PisyaDesign.Spacing.inline) {
                ForEach(icons, id: \.0) { item in
                    Button { symbol = item.0 } label: {
                        Image(systemName: item.0).textStyle(PisyaDesign.Typography.detail).symbolRenderingMode(.monochrome)
                            .frame(width: 32, height: 32)
                            .background(symbol == item.0 ? PisyaDesign.Colors.selection : PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
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
        }.dialogContent().frame(width: 384)
            .onAppear { name = folder?.name ?? ""; symbol = folder?.iconName ?? "folder"; nameFocused = true }
    }
    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        save(name, symbol); dismiss()
    }
}
