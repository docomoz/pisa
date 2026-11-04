import SwiftUI
import AppKit

@MainActor
final class ModelSetup: ObservableObject {
    enum Phase { case checking, available, downloading, ready, failed }
    @Published var phase: Phase = .checking
    @Published var progress: ModelInstallProgress?
    @Published var error: String?
    @Published var presented = false
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var didCheck = false
    private(set) var installedUsingCustom = false
    private let root: URL
    private let manifestURL: URL?
    private let customModel: () -> URL?
    private let usesCustomModel: () -> Bool
    var busy: Bool { phase == .checking || phase == .downloading }
    var ready: Bool { phase == .ready }
    init(root: URL, manifestURL: URL? = Bundle.main.url(forResource: "models", withExtension: "json"), customModel: @escaping () -> URL?, usesCustomModel: @escaping () -> Bool) {
        self.root = root; self.manifestURL = manifestURL; self.customModel = customModel; self.usesCustomModel = usesCustomModel
    }
    private func installer(usingCustom: Bool = false) throws -> ModelInstaller {
        guard let manifestURL else { throw ModelInstallError.invalidManifest }
        let assets = try JSONDecoder().decode([ModelAsset].self, from: Data(contentsOf: manifestURL))
        return ModelInstaller(root: root, assets: usingCustom ? assets.filter { $0.path.hasPrefix("Speakers/") } : assets)
    }
    func check(presentWhenNeeded: Bool = true) {
        guard !busy || !didCheck else { return }
        didCheck = true; phase = .checking; error = nil; progress = nil
        let token = UUID(); generation = token
        let custom = customModel()
        let useCustom = usesCustomModel() && custom.map(Self.customIsUsable) == true
        installedUsingCustom = useCustom
        let invalidCustom = usesCustomModel() && !useCustom
        let installer: ModelInstaller
        do { installer = try self.installer(usingCustom: useCustom) }
        catch { self.error = error.localizedDescription; phase = .failed; presented = true; return }
        operation = Task { [weak self] in
            // Existing custom MLX folders remain supported, without applying the official
            // download's hashes to a different model version.
            let worker = Task.detached(priority: .utility) {
                if invalidCustom { return false }
                return (try? await installer.isReady()) == true
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.phase = result ? .ready : .available
            if !result && presentWhenNeeded { self.presented = true }
        }
    }
    func install(onReady: @escaping () -> Void) {
        guard !busy else { return }
        let installer: ModelInstaller
        let useCustom = usesCustomModel() && customModel().map(Self.customIsUsable) == true
        installedUsingCustom = useCustom
        do { installer = try self.installer(usingCustom: useCustom) }
        catch { self.error = error.localizedDescription; phase = .failed; return }
        error = nil; progress = nil; phase = .downloading
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
                guard let self, self.generation == token, !Task.isCancelled else { return }
                onReady(); self.phase = .ready; self.progress = nil
            } catch {
                guard let self, self.generation == token else { return }
                if error is CancellationError { self.phase = .available }
                else { self.phase = .failed; self.error = error.localizedDescription }
                self.progress = nil
            }
        }
    }
    private static func customIsUsable(_ url: URL) -> Bool {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        func exists(_ name: String) -> Bool {
            guard let size = try? url.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return size > 0
        }
        return exists("config.json") && exists("model.safetensors") && exists("tokenizer_config.json") &&
            (exists("tokenizer.json") || exists("vocab.json") && exists("merges.txt"))
    }
    func cancel() { operation?.cancel() }
    func cancelAndWait() async { operation?.cancel(); await operation?.value }
    func dismiss() { guard !busy else { return }; presented = false }
}

struct ModelSetupView: View {
    @ObservedObject var setup: ModelSetup
    let onReady: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(nsImage: BrandMark.headerIcon).resizable().frame(width: 26, height: 26)
                screenText("Pisya").font(.appFont(size: 23, weight: .semibold))
                Spacer()
                screenText("НА ЭТОМ MAC").font(.appFont(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Color.mutedInk)
            }.padding(.bottom, 30)
            screenText(setup.ready ? "Всё готово к первой встрече" : "Подготовим Pisya к работе")
                .font(.appFont(size: 29, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            screenText(setup.ready ? "Модели установлены. Перед записью macOS попросит доступ к микрофону и системному звуку." : "Один раз загрузим модели для распознавания речи и участников. Затем встречи можно расшифровывать без интернета.")
                .font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true).padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 16) {
                item("waveform", "Речь и участники", "Qwen3-ASR · локальная обработка")
                Divider().opacity(0.5)
                item("internaldrive", "Около 3 ГБ на Mac", "Загрузка с Hugging Face · аудио остаётся у вас")
            }.padding(20).plainSurface().padding(.bottom, 24)
            if setup.busy {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        screenText(setup.phase == .checking ? "Проверяем установленные модели…" : setup.progress?.verifying == true ? "Проверяем целостность…" : "Загружаем модели…")
                        Spacer()
                        if let p = setup.progress, p.expectedBytes > 0 { screenText("\(Int(p.fraction * 100)) %").monospacedDigit() }
                    }.font(.appFont(size: 14, weight: .medium))
                    if let p = setup.progress { ProgressView(value: p.fraction).tint(Color.moss) }
                    else { ProgressView().controlSize(.small) }
                    if let p = setup.progress {
                        screenText(p.verifying ? "Большой файл проверяется на Mac. Это может занять немного времени" : "Файл \(min(p.completedFiles + 1, p.totalFiles)) из \(p.totalFiles) · \(ByteCountFormatter.string(fromByteCount: p.downloadedBytes, countStyle: .file))")
                            .font(.appFont(size: 12)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(minHeight: 66, alignment: .top)
            } else if let error = setup.error {
                screenText(error).font(.appFont(size: 14)).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true).frame(minHeight: 66, alignment: .top)
            } else {
                screenLabel(setup.ready ? "Можно начинать" : "Понадобится интернет только для загрузки", systemImage: setup.ready ? "checkmark.circle.fill" : "lock.shield")
                    .font(.appFont(size: 14)).foregroundStyle(Color.moss).frame(minHeight: 66, alignment: .top)
            }
            HStack {
                if setup.phase == .downloading { screenButton("Отменить загрузку") { setup.cancel() }.plainButton(neutral: true) }
                else if !setup.ready { screenButton("Позже") { setup.dismiss() }.plainButton(neutral: true).disabled(setup.busy) }
                Spacer()
                if setup.ready { screenButton("Начать работу") { setup.dismiss() }.plainButton(prominent: true).keyboardShortcut(.defaultAction) }
                else if setup.phase != .downloading {
                    screenButton(setup.phase == .failed ? "Повторить загрузку" : "Загрузить модели") { setup.install(onReady: onReady) }.plainButton(prominent: true).disabled(setup.busy).keyboardShortcut(.defaultAction)
                }
            }.padding(.top, 16)
        }.padding(36).frame(width: 600).popupCanvas().interactiveDismissDisabled(setup.busy)
    }
    private func item(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Color.moss).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                screenText(title).font(.appFont(size: 16, weight: .semibold))
                screenText(subtitle).font(.appFont(size: 13)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
