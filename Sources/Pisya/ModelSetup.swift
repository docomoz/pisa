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
        return ModelInstaller(root: root, assets: usingCustom ? assets.filter { !$0.path.hasPrefix("Qwen3-ASR/") } : assets)
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
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.none) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                Image(nsImage: BrandMark.headerIcon).resizable().frame(width: 26, height: 26)
                screenText("Pisya").textStyle(PisyaDesign.Typography.brand)
                Spacer()
                Eyebrow("НА ЭТОМ MAC")
            }.padding(.bottom, PisyaDesign.Spacing.page)
            SectionHeading(setup.ready ? "Всё готово к первой встрече" : "Подготовим Pisya к работе",
                           subtitle: setup.ready ? "Модели установлены. Перед записью macOS попросит доступ к микрофону и системному звуку." : "Один раз загрузим модели для распознавания речи и участников. Затем встречи можно расшифровывать без интернета.",
                           style: .page)
                .padding(.bottom, PisyaDesign.Spacing.content)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
                item("waveform", "Речь и участники", "Русский и английский · локальная обработка")
                Divider().opacity(0.5)
                item("internaldrive", "Около 3 ГБ на Mac", "Загрузка с Hugging Face · аудио остаётся у вас")
            }.padding(PisyaDesign.Spacing.content).plainSurface().padding(.bottom, PisyaDesign.Spacing.section)
            if setup.busy {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                    HStack(spacing: PisyaDesign.Spacing.related) {
                        screenText(setup.phase == .checking ? "Проверяем установленные модели…" : setup.progress?.verifying == true ? "Проверяем целостность…" : "Загружаем модели…")
                        Spacer()
                        if let p = setup.progress, p.expectedBytes > 0 { screenText("\(Int(p.fraction * 100)) %").monospacedDigit() }
                    }.textStyle(PisyaDesign.Typography.detailMedium)
                    if let p = setup.progress { ProgressView(value: p.fraction).tint(Color.moss) }
                    else { ProgressView().controlSize(.small) }
                    if let p = setup.progress {
                        screenText(p.verifying ? "Большой файл проверяется на Mac. Это может занять немного времени" : "Файл \(min(p.completedFiles + 1, p.totalFiles)) из \(p.totalFiles) · \(ByteCountFormatter.string(fromByteCount: p.downloadedBytes, countStyle: .file))")
                            .textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(minHeight: 66, alignment: .top)
            } else if let error = setup.error {
                screenText(error).textStyle(PisyaDesign.Typography.detail).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true).frame(minHeight: 66, alignment: .top)
            } else {
                screenLabel(setup.ready ? "Можно начинать" : "Модели загрузятся из интернета", systemImage: setup.ready ? "checkmark.circle.fill" : "lock.shield")
                    .textStyle(PisyaDesign.Typography.detail).foregroundStyle(Color.moss)
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                if setup.phase == .downloading { screenButton("Отменить загрузку") { setup.cancel() }.actionButton() }
                else if !setup.ready { screenButton("Позже") { setup.dismiss() }.actionButton().disabled(setup.busy) }
                Spacer()
                if setup.ready { screenButton("Начать работу") { setup.dismiss() }.actionButton(.primary).keyboardShortcut(.defaultAction) }
                else if setup.phase != .downloading {
                    screenButton(setup.phase == .failed ? "Повторить загрузку" : "Загрузить модели") { setup.install(onReady: onReady) }.actionButton(.primary).disabled(setup.busy).keyboardShortcut(.defaultAction)
                }
            }.padding(.top, PisyaDesign.Spacing.section)
        }.dialogContent().frame(width: 600).interactiveDismissDisabled(setup.busy)
    }
    private func item(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            Image(systemName: symbol).font(PisyaDesign.Typography.Icon.featured).foregroundStyle(Color.moss).frame(width: 28)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                screenText(title).textStyle(PisyaDesign.Typography.bodyStrong)
                screenText(subtitle).textStyle(PisyaDesign.Typography.caption).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
