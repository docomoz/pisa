import Foundation

public enum TranscriptionStatus {
    static let legacyStoppedMessage = "Обработка остановлена. Аудио сохранено"
    static let stoppedMessage = legacyStoppedMessage + "."
    static let interruptedMessage = "Обработка прервалась. Аудио сохранено — можно повторить"

    public static func title(fraction: Double?, roundsDown: Bool = false) -> String {
        guard let fraction, fraction.isFinite else { return "Расшифровываю аудио" }
        let percent = (min(max(fraction, 0), 1) * 100).rounded(roundsDown ? .down : .toNearestOrEven)
        if percent < 5 { return "Начинаю расшифровку" }
        if percent <= 80 { return "Расшифровываю аудио" }
        return "Завершаю расшифровку"
    }
}
