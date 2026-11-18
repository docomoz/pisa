import SwiftUI
import AppKit

@MainActor
final class ModelSetup: ObservableObject {
    enum Phase { case checking, available, downloading, ready, failed }
    @Published var phase: Phase = .checking
    @Published var progress: ModelInstallProgress?
    @Published var error: String?
    @Published var presented = false
    @Published var upgradeDownloadBytes: Int64?
    @Published private(set) var missingDownloadBytes: Int64?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var didCheck = false
    private(set) var installedUsingCustom = false
    private(set) var installedUsingCustomVerifier = false
    private let root: URL
    private let manifestURL: URL?
    private let customModel: () -> URL?
    private let usesCustomModel: () -> Bool
    private let customVerifier: () -> URL?
    private let usesCustomVerifier: () -> Bool
    var busy: Bool { phase == .checking || phase == .downloading }
    var ready: Bool { phase == .ready }
    init(root: URL, manifestURL: URL? = Bundle.main.url(forResource: "models", withExtension: "json"), customModel: @escaping () -> URL?, usesCustomModel: @escaping () -> Bool,
         customVerifier: @escaping () -> URL? = { nil }, usesCustomVerifier: @escaping () -> Bool = { false }) {
        self.root = root; self.manifestURL = manifestURL; self.customModel = customModel; self.usesCustomModel = usesCustomModel
        self.customVerifier = customVerifier; self.usesCustomVerifier = usesCustomVerifier
    }
    private func installer(usingCustom: Bool = false, usingCustomVerifier: Bool = false) throws -> ModelInstaller {
        guard let manifestURL else { throw ModelInstallError.invalidManifest }
        let assets = try JSONDecoder().decode([ModelAsset].self, from: Data(contentsOf: manifestURL))
        return ModelInstaller(root: root, assets: assets.filter {
            !(usingCustom && $0.path.hasPrefix(SpeechModelFiles.primaryDirectoryName + "/")) &&
            !(usingCustomVerifier && $0.path.hasPrefix(SpeechModelFiles.verifierDirectoryName + "/"))
        })
    }
    func check(presentWhenNeeded: Bool = true) {
        guard !busy || !didCheck else { return }
        didCheck = true; phase = .checking; error = nil; progress = nil
        missingDownloadBytes = nil
        let token = UUID(); generation = token
        let custom = customModel()
        let useCustom = usesCustomModel() && custom.map { Self.customIsUsable($0, kind: .parakeet) } == true
        let useCustomVerifier = usesCustomVerifier() && customVerifier().map { Self.customIsUsable($0, kind: .qwen) } == true
        installedUsingCustom = useCustom
        installedUsingCustomVerifier = useCustomVerifier
        let invalidCustom = usesCustomModel() && !useCustom || usesCustomVerifier() && !useCustomVerifier
        let installer: ModelInstaller
        do { installer = try self.installer(usingCustom: useCustom, usingCustomVerifier: useCustomVerifier) }
        catch {
            self.error = error.localizedDescription
            phase = .failed
            if presentWhenNeeded { presented = true }
            return
        }
        operation = Task { [weak self] in
            // Existing custom MLX folders remain supported, without applying the official
            // download's hashes to a different model version.
            let worker = Task.detached(priority: .utility) {
                Result { try installer.missingAssets() }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.upgradeDownloadBytes = nil
            switch result {
            case .success(let missing):
                let bytes = missing.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
                if missing.allSatisfy({ $0.bytes != nil }) {
                    self.missingDownloadBytes = bytes
                }
                let primaryPrefix = SpeechModelFiles.primaryDirectoryName + "/"
                let verifierPrefix = SpeechModelFiles.verifierDirectoryName + "/"
                let installedQwen = useCustomVerifier || (
                    installer.assets.contains { $0.path.hasPrefix(verifierPrefix) } &&
                    !missing.contains { $0.path.hasPrefix(verifierPrefix) }
                )
                if installedQwen && missing.contains(where: { $0.path.hasPrefix(primaryPrefix) }) {
                    self.upgradeDownloadBytes = bytes
                }
                self.phase = !invalidCustom && missing.isEmpty ? .ready : .available
            case .failure(let error):
                self.error = error.localizedDescription
                self.phase = .failed
            }
            if !self.ready && presentWhenNeeded { self.presented = true }
        }
    }
    func install(onReady: @escaping () -> Void) {
        guard !busy else { return }
        Analytics.modelInstallStarted()
        let installer: ModelInstaller
        let useCustom = usesCustomModel() && customModel().map { Self.customIsUsable($0, kind: .parakeet) } == true
        let useCustomVerifier = usesCustomVerifier() && customVerifier().map { Self.customIsUsable($0, kind: .qwen) } == true
        installedUsingCustom = useCustom
        installedUsingCustomVerifier = useCustomVerifier
        do { installer = try self.installer(usingCustom: useCustom, usingCustomVerifier: useCustomVerifier) }
        catch { Analytics.modelInstallFailed(); self.error = error.localizedDescription; phase = .failed; return }
        error = nil; progress = nil; phase = .downloading
        missingDownloadBytes = nil
        let token = UUID(); generation = token
        operation = Task { [weak self] in
            let coordinator = self
            let worker = Task.detached(priority: .utility) {
                try await installer.install { value in
                    Task { @MainActor in
                        guard let coordinator, coordinator.generation == token, coordinator.phase == .downloading else { return }
                        coordinator.progress = value
                    }
                }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == token else { return }
                if Task.isCancelled { Analytics.modelInstallCancelled(); self.phase = .available; self.progress = nil; return }
                Analytics.modelInstallCompleted()
                onReady(); self.phase = .ready; self.progress = nil; self.missingDownloadBytes = 0
            } catch {
                guard let self, self.generation == token else { return }
                if error is CancellationError || Task.isCancelled { Analytics.modelInstallCancelled(); self.phase = .available }
                else { Analytics.modelInstallFailed(); self.phase = .failed; self.error = error.localizedDescription }
                self.progress = nil
            }
        }
    }
    private static func customIsUsable(_ url: URL, kind: SpeechModelFiles.Kind) -> Bool {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return SpeechModelFiles.isUsable(at: url, kind: kind)
    }
    func cancel() { operation?.cancel() }
    func cancelAndWait() async { operation?.cancel(); await operation?.value }
    func dismiss() { guard !busy else { return }; presented = false }
}

func modelDownloadSize(_ bytes: Int64) -> String {
    let locale = Locale(identifier: "ru_RU")
    if bytes >= 1_000_000_000 {
        let size = (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return "\(size) ГБ"
    }
    let size = (Double(bytes) / 1_000_000).rounded(.up).formatted(.number.locale(locale))
    return "\(size) МБ"
}

struct ModelSetupView: View {
    @ObservedObject var setup: ModelSetup
    let onReady: () -> Void
    private var isUpgrade: Bool { setup.upgradeDownloadBytes != nil }
    private var title: String {
        if isUpgrade { return setup.ready ? "Распознавание обновлено" : "Обновим распознавание речи" }
        return setup.ready ? "Всё готово к первой встрече" : "Подготовим Pisa к работе"
    }
    private var subtitle: String {
        if isUpgrade {
            return setup.ready
                ? "Parakeet v3 готов к расшифровке. Сохранённые записи и расшифровки на месте."
                : "Parakeet v3 станет основной моделью расшифровки. Ваши записи и готовые расшифровки сохранятся."
        }
        return setup.ready
            ? "Модели установлены. Перед записью macOS попросит доступ к микрофону и системному звуку."
            : "Один раз загрузим модели для распознавания речи и участников. Затем встречи можно расшифровывать без интернета."
    }
    private var downloadSize: String {
        guard let bytes = setup.upgradeDownloadBytes, bytes > 0 else { return "Загрузка моделей" }
        return "Около \(modelDownloadSize(bytes)) для обновления"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.none) {
            HStack(spacing: PisaDesign.Spacing.related) {
                Image(nsImage: BrandMark.headerIcon).resizable().frame(width: 26, height: 26)
                screenText("Pisa").textStyle(PisaDesign.Typography.brand)
                Spacer()
                Eyebrow("НА ЭТОМ MAC")
            }.padding(.bottom, PisaDesign.Spacing.page)
            SectionHeading(title, subtitle: subtitle, style: .page)
                .padding(.bottom, PisaDesign.Spacing.content)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.content) {
                if isUpgrade {
                    if !setup.ready {
                        item("internaldrive", downloadSize, "Pisa скачает недостающие файлы с Hugging Face")
                        Divider().opacity(0.5)
                    }
                    item("waveform", "Qwen останется на Mac", "Она перепроверяет отдельные фразы и термины")
                } else {
                    item("waveform", "Речь и участники", "Русский и английский · локальная обработка")
                    Divider().opacity(0.5)
                    item("internaldrive", "Около 5,5 ГБ на Mac", "Загрузка с Hugging Face · аудио остаётся у вас")
                }
            }.padding(PisaDesign.Spacing.content).plainSurface().padding(.bottom, PisaDesign.Spacing.section)
            if setup.busy {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                    HStack(spacing: PisaDesign.Spacing.related) {
                        screenText(setup.phase == .checking ? "Проверяем установленные модели…" : setup.progress?.verifying == true ? "Проверяем целостность…" : "Загружаем модели…")
                        Spacer()
                        if let p = setup.progress, p.expectedBytes > 0 { screenText("\(Int(p.fraction * 100)) %").monospacedDigit() }
                    }.textStyle(PisaDesign.Typography.detailMedium)
                    if let p = setup.progress { ProgressView(value: p.fraction).tint(Color.moss) }
                    else { ProgressView().controlSize(.small) }
                    if let p = setup.progress {
                        screenText(p.verifying ? "Большой файл проверяется на Mac. Это может занять немного времени" : "Файл \(min(p.completedFiles + 1, p.totalFiles)) из \(p.totalFiles) · \(ByteCountFormatter.string(fromByteCount: p.downloadedBytes, countStyle: .file))")
                            .textStyle(PisaDesign.Typography.footnote).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(minHeight: 66, alignment: .top)
            } else if let error = setup.error {
                screenText(error).textStyle(PisaDesign.Typography.detail).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true).frame(minHeight: 66, alignment: .top)
            } else {
                screenLabel(setup.ready ? (isUpgrade ? "Можно расшифровывать" : "Можно начинать")
                            : (isUpgrade ? "Для расшифровки нужно завершить обновление" : "Модели загрузятся из интернета"),
                            systemImage: setup.ready ? "checkmark.circle.fill" : "lock.shield")
                    .textStyle(PisaDesign.Typography.detail).foregroundStyle(Color.moss)
                    .measuredForInterfaceTest(.setupStatus)
            }
            HStack(spacing: PisaDesign.Spacing.related) {
                if setup.phase == .downloading { screenButton("Отменить загрузку") { setup.cancel() }.actionButton() }
                else if !setup.ready { screenButton("Позже") { setup.dismiss() }.actionButton().disabled(setup.busy) }
                Spacer()
                if setup.ready {
                    screenButton(isUpgrade ? "Готово" : "Начать работу") { setup.dismiss() }.actionButton(.primary).keyboardShortcut(.defaultAction)
                        .measuredForInterfaceTest(.setupAction)
                }
                else if setup.phase != .downloading {
                    screenButton(setup.phase == .failed ? "Повторить загрузку" : (isUpgrade ? "Обновить распознавание" : "Загрузить модели")) { setup.install(onReady: onReady) }.actionButton(.primary).disabled(setup.busy).keyboardShortcut(.defaultAction)
                        .measuredForInterfaceTest(.setupAction)
                }
            }.padding(.top, PisaDesign.Spacing.section)
        }.dialogContent().frame(width: 600).interactiveDismissDisabled(setup.busy)
    }
    private func item(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: PisaDesign.Spacing.related) {
            Image(systemName: symbol).font(PisaDesign.Typography.Icon.featured).foregroundStyle(Color.moss).frame(width: 28)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                screenText(title).textStyle(PisaDesign.Typography.bodyStrong)
                screenText(subtitle).textStyle(PisaDesign.Typography.caption).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
