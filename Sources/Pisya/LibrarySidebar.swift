import SwiftUI
import AppKit

struct LibrarySidebar: View {
    @EnvironmentObject var state: AppState
    @State private var folderEditor = false
    @State private var editingFolder: MeetingFolder?
    @State private var folderName = ""
    @State private var deletingFolder: MeetingFolder?
    @State private var confirmEmptyTrash = false
    @State private var folderRowFrames: [UUID: CGRect] = [:]
    @State private var folderDrag: FolderDrag?
    @GestureState private var folderDragActive = false
    @State private var folderScrollPosition = ScrollPosition()
    @State private var folderScrollGeometry: ScrollGeometry?
    private static let folderViewport = "folder-sidebar"
    @FocusState private var recordingsFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            SearchField(title: "Название, фраза, участник", text: $state.search, compact: true)
            ScrollView { VStack(spacing: PisyaDesign.Spacing.hairline) {
                scope("Все записи", icon: "tray", selected: !state.showingTrash && state.folderFilter == nil && !state.unfiledOnly) { state.openFolder() }
                scope("Без папки", icon: "doc", selected: state.unfiledOnly && !state.showingTrash) { state.openFolder(unfiled: true) }
                if !state.folders.isEmpty { folderRows }
                scope("Новая папка…", icon: "folder.badge.plus", selected: false) { editingFolder = nil; folderName = ""; folderEditor = true }
                    .disabled(state.demo)
                scope("Корзина", icon: "trash", selected: state.showingTrash) { state.openFolder(trash: true) }
                    .popupContextMenu { [NativeActionMenuItem("Очистить корзину", enabled: state.canEmptyTrash) { confirmEmptyTrash = true }] }
            }.textStyle(PisyaDesign.Typography.footnote) }
            .frame(height: min(190, CGFloat(state.folders.count + 4) * 36))
            .coordinateSpace(name: Self.folderViewport)
            .scrollPosition($folderScrollPosition)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                folderScrollGeometry = geometry
            }
            .task(id: folderScrollDirection) { await scrollDuringFolderDrag() }
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
                            } else { screenText(sidebarDuration(meeting.duration)).monospacedDigit().fixedSize() }
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
                        .contentShape(Rectangle()).onTapGesture { recordingsFocused = true; state.select(meeting.id) }.pointingHandCursor().id(meeting.id)
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
    private struct FolderDrag {
        let id: UUID
        let grabOffsetY: CGFloat
        var location: CGPoint
        var isCancelled = false
    }

    private var folderRows: some View {
        VStack(spacing: PisyaDesign.Spacing.hairline) {
            ForEach(state.folders) { folder in
                scope(folder.name, icon: folder.iconName, selected: state.folderFilter == folder.id && !state.showingTrash) {
                    state.openFolder(folder.id)
                }
                .popupContextMenu {
                    [NativeActionMenuItem("Изменить папку…") { editingFolder = folder; folderName = folder.name; folderEditor = true },
                     NativeActionMenuItem("Удалить папку") { deletingFolder = folder }]
                }
                .opacity(activeFolderDrag?.id == folder.id ? 0.45 : 1)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(Self.folderViewport))
                } action: { frame in
                    folderRowFrames[folder.id] = frame
                }
                .onDisappear { folderRowFrames[folder.id] = nil }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(folderDragGesture)
        .onChange(of: folderDragActive) { _, active in
            if !active { folderDrag = nil }
        }
        .onExitCommand {
            folderDrag?.isCancelled = true
        }
        .overlay(alignment: .top) {
            if let drag = activeFolderDrag, isInFolderViewport(drag.location),
               let first = state.folders.first, let origin = folderRowFrames[first.id]?.minY {
                ZStack(alignment: .top) {
                    folderDragPreview(drag, origin: origin)
                }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var activeFolderDrag: FolderDrag? {
        guard let folderDrag, !folderDrag.isCancelled else { return nil }
        return folderDrag
    }

    private var folderDragGesture: some Gesture {
        DragGesture(minimumDistance: PisyaDesign.Spacing.compact, coordinateSpace: .named(Self.folderViewport))
            .updating($folderDragActive) { _, active, _ in active = true }
            .onChanged { value in
                if folderDrag != nil {
                    folderDrag?.location = value.location
                } else if !state.demo, state.folders.count > 1,
                          let folder = state.folders.first(where: { folderRowFrames[$0.id]?.contains(value.startLocation) == true }),
                          let frame = folderRowFrames[folder.id] {
                    folderDrag = FolderDrag(id: folder.id, grabOffsetY: value.startLocation.y - frame.minY, location: value.location)
                }
            }
            .onEnded { value in
                defer { folderDrag = nil }
                guard let drag = activeFolderDrag, let insertion = folderInsertion(at: value.location) else { return }
                state.reorderFolder(drag.id, relativeTo: insertion.id, after: insertion.after)
            }
    }

    @ViewBuilder
    private func folderDragPreview(_ drag: FolderDrag, origin: CGFloat) -> some View {
        if let folder = state.folders.first(where: { $0.id == drag.id }) {
            navigationLabel(folder.name, icon: folder.iconName)
                .padding(PisyaDesign.Spacing.inline)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.navigationRadius))
                .shadow(color: .black.opacity(0.15), radius: PisyaDesign.Spacing.compact, y: PisyaDesign.Spacing.hairline)
                .opacity(0.88)
                .padding(.horizontal, PisyaDesign.Spacing.compact)
                .offset(y: drag.location.y - drag.grabOffsetY - origin)
        }
        if let insertion = folderInsertion(at: drag.location) {
            Capsule().fill(Color.moss)
                .frame(height: PisyaDesign.Spacing.hairline)
                .padding(.horizontal, PisyaDesign.Spacing.inline)
                .offset(y: insertion.lineY - origin - PisyaDesign.Spacing.hairline / 2)
        }
    }

    private func folderInsertion(at point: CGPoint) -> (id: UUID, after: Bool, lineY: CGFloat)? {
        let halfGap = PisyaDesign.Spacing.hairline / 2
        guard isInFolderViewport(point),
              let first = state.folders.first, let start = folderRowFrames[first.id],
              let last = state.folders.last, let end = folderRowFrames[last.id],
              point.x >= start.minX, point.x <= start.maxX,
              point.y >= start.minY - halfGap, point.y <= end.maxY + halfGap else { return nil }
        for folder in state.folders {
            guard let frame = folderRowFrames[folder.id] else { return nil }
            if point.y < frame.midY { return (folder.id, false, frame.minY - halfGap) }
        }
        return (last.id, true, end.maxY + halfGap)
    }

    private func isInFolderViewport(_ point: CGPoint) -> Bool {
        guard let geometry = folderScrollGeometry else { return false }
        return CGRect(origin: .zero, size: geometry.containerSize).contains(point)
    }

    private var folderScrollDirection: Int {
        guard let point = activeFolderDrag?.location, let geometry = folderScrollGeometry,
              isInFolderViewport(point) else { return 0 }
        let edge = PisyaDesign.Spacing.content
        if point.y < edge { return -1 }
        if point.y > geometry.containerSize.height - edge { return 1 }
        return 0
    }

    private func scrollDuringFolderDrag() async {
        let direction = folderScrollDirection
        guard direction != 0 else { return }
        while !Task.isCancelled, let geometry = folderScrollGeometry {
            let offset = geometry.contentOffset.y
            let limit = max(0, geometry.contentSize.height - geometry.containerSize.height)
            let next = min(limit, max(0, offset + CGFloat(direction) * PisyaDesign.Spacing.inline))
            guard abs(next - offset) >= 1 else { return }
            folderScrollPosition.scrollTo(y: next)
            try? await Task.sleep(for: .milliseconds(35))
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
        move.isEnabled = state.canMove(meeting)
        let transcribeItem = transcribe.nativeItem
        transcribeItem.isEnabled = canModify && transcribeItem.isEnabled
        let trashItem = trash.nativeItem
        trashItem.isEnabled = canModify
        return [voices, rename.nativeItem, move, .separator(), transcribeItem, .separator(), trashItem]
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

    var rename: Item { Item(title: "Переименовать…", enabled: state.canRename(meeting)) { state.renameTarget = meeting } }
    var transcribe: Item {
        let isFinalized = meeting.status == .ready
        return Item(title: isFinalized ? "Расшифровать заново" : "Расшифровать", enabled: state.hasAudio(meeting)) {
            if isFinalized {
                state.reprocessTarget = meeting
            } else {
                state.enqueue(meeting.id)
            }
        }
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
                TextField("Название", text: $name).textFieldStyle(PisyaTextFieldStyle(isEditing: focused)).focused($focused).onSubmit { submit() }
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
        ("folder", "Папка"), ("briefcase", "Проекты"), ("person", "Встречи один на один"), ("person.2", "Команда"),
        ("person.3", "Общие собрания"), ("bubble.left.and.bubble.right", "Обсуждения"), ("phone", "Звонки"), ("video", "Видеовстречи"),
        ("doc.text", "Документы"), ("graduationcap", "Обучение"), ("lightbulb", "Идеи"), ("calendar", "Планирование"),
        ("checkmark.circle", "Задачи"), ("flag", "Цели"), ("star", "Избранное"), ("airplane", "Командировки"),
        ("building.2", "Компания"), ("globe", "Международные проекты"), ("map", "География"), ("chart.bar", "Аналитика"),
        ("chevron.left.forwardslash.chevron.right", "Разработка"), ("shippingbox", "Продукт"), ("megaphone", "Маркетинг"), ("creditcard", "Финансы"),
        ("cart", "Продажи"), ("person.crop.rectangle", "Найм"), ("headphones", "Поддержка"), ("paintpalette", "Дизайн"),
        ("exclamationmark.triangle", "Риски"), ("lock.shield", "Безопасность"), ("ladybug", "Тестирование"), ("arrow.triangle.branch", "Процессы")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading(folder == nil ? "Новая папка" : "Изменить папку", style: .dialog)
            HStack(spacing: PisyaDesign.Spacing.related) {
                Image(systemName: symbol).font(PisyaDesign.Typography.Icon.medium).foregroundStyle(Color.ink).frame(width: 32, height: 32)
                TextField("Название папки", text: $name).textFieldStyle(PisyaTextFieldStyle(isEditing: nameFocused)).focused($nameFocused).onSubmit { submit() }
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
