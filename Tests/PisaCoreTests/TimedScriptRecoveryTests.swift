import XCTest
@testable import PisaCore

final class TimedScriptRecoveryTests: XCTestCase {
    func testDisputedEndingsAndAnAlreadyCorrectInteriorCannotReplaceTheTurn() throws {
        let source = "Длінні, длинношерстна собака, на выставке это точно не блокнот пад."
        var target = TranscriptSegment(start: 12, end: 16, speaker: "Собеседник", text: source)
        target.audioFile = "test-remote.caf"
        var before = TranscriptSegment(start: 4, end: 11, speaker: target.speaker, text: "Мы уже осмотрели весь зал.")
        before.audioFile = target.audioFile
        let repair = try XCTUnwrap(RecognitionContext(segments: [before, target]).scriptRepair(for: target, vocabulary: ""))

        func timed(_ text: String, start: Double) -> RecognitionAcousticResult {
            .init(text: text, words: text.split(separator: " ").enumerated().map { i, token in
                let onset = start + Double(i) * 0.3
                return .init(text: String(token), start: onset, end: onset + 0.3)
            })
        }

        let narrow = timed("Длинные длинношерстные собаки на выставке это точно не Bloknot пад", start: 0)
        let wide = timed("Вчера мы видели длинные длинношерстные собаки на выставке это точно не блокнод пад потом", start: 1.1)
        let interval = 2..<(2 + 0.3 * Double(narrow.words.count))
        let uncertain = repair.timedFragments(acoustic: wide, target: interval,
            primary: "Вчера мы видели длинношерстно собаки. На выставке это точно не блокнот, пак, потом.",
            verifier: "Вчера мы видели длинные, длинно шерстно собаки. На выставке это точно не блок нот, паку, потом.",
            language: "Russian", exact: {
                .init(acoustic: narrow, verifier: "Длиннее, длинно шерстная собака. На выставке это точно не блакнот паку.", language: "Russian")
            }, exactPrimary: { "Длінні, длина шерстна собака, на выставке это точно ні блокнот паку." })
        // The models disagree on the adjective and noun inflections. Their
        // common middle is already intact, including the participant's negation.
        XCTAssertNil(uncertain)
    }

    func testBoundedCompoundKeepsExactlyTheHeardFormAndTheAgreedClause() throws {
        let narrow = ["длинные", "длинношерстные", "собаки", "на", "выставке", "это", "точно", "не", "Bloknot", "под"]
        let wide = ["вчера", "мы", "выбирали"] + Array(narrow.dropLast(2)) + ["блокнод", "под", "потом"]
        func timed(_ keys: [String], at offset: Double) -> RecognitionAcousticResult {
            .init(text: keys.joined(separator: " "), words: keys.enumerated().map { i, word in
                let start = offset + Double(i) * 0.4
                return .init(text: word, start: start, end: start + 0.36)
            })
        }
        let core = timed(narrow, at: 0.04), padded = timed(Array(wide), at: 0.84)
        let source = "Длінні, длинношерстна собака, на выставке это точно не блокнот пудк."
        let primary = "Вчера мы выбирали длинношерстно собаки. На выставке это точно не блокнот, под, потом."
        let check = "Вчера мы выбирали длинные, длинно шерстно собаки. На выставке это точно не блок нот, под, потом."
        let bounded = "Мы выбирали длинно-шерстно собаки."
        let checked = "Длиннее, длинно шерстная собака. На выставке это точно не блокнот под."

        func resolve(_ src: String = source, p: String = primary, q: String = check,
                     exact: String = checked, wideLanguage: String = "Russian",
                     smallP: String = "Мы выбирали длинношерстно собаки.", smallQ: String = bounded,
                     targetStart: Double = 2) throws -> (String?, Int) {
            var target = TranscriptSegment(start: 8, end: 12, speaker: "Собеседник", text: src)
            target.audioFile = "test-remote.caf"
            var previous = TranscriptSegment(start: 1, end: 7, speaker: target.speaker, text: "Мы уже осмотрели большой зал.")
            previous.audioFile = target.audioFile
            let plan = try XCTUnwrap(RecognitionContext(segments: [previous, target]).scriptRepair(for: target, vocabulary: ""))
            var calls = 0
            let result = plan.timedCompound(acoustic: padded, target: targetStart..<(targetStart + 4), primary: p,
                verifier: q, language: wideLanguage, exact: { .init(acoustic: core, verifier: exact, language: "Russian") },
                bounded: { window in
                    calls += 1
                    XCTAssertEqual(window.lowerBound, 1.24, accuracy: 0.001)
                    XCTAssertEqual(window.upperBound, 3.24, accuracy: 0.001)
                    return (bounded, smallP, smallQ, "Russian")
                })
            return (result, calls)
        }

        let result = try resolve()
        XCTAssertEqual(result.0, "… длинношерстно собаки. На выставке это точно не блокнот…")
        XCTAssertEqual(result.1, 1)
        for q in ["Мы выбирали длинношерстные собаки.", "Мы выбирали длинно шерстно собака.",
                  "Мы выбирали не длинношерстно собаки.", "Мы выбирали длинно. Шерстно собаки.",
                  "Мы выбирали длинношерстно. Собаки.", "Мы выбирали длинношерстно собаки потом."] {
            XCTAssertNil(try resolve(smallQ: q).0, q)
        }
        XCTAssertNil(try resolve(exact: checked.replacingOccurrences(of: "точно не", with: "точно")).0)
        XCTAssertNil(try resolve(p: primary.replacingOccurrences(of: "под,", with: "Игорь,")).0)
        XCTAssertNil(try resolve(q: check.replacingOccurrences(of: "под,", with: "пять,")).0)
        XCTAssertNil(try resolve(source.replacingOccurrences(of: "пудк", with: "фред")).0)
        XCTAssertNil(try resolve(source.replacingOccurrences(of: "пудк", with: "нельзя")).0)
        XCTAssertEqual(try resolve(wideLanguage: "Ukrainian").1, 0)
        XCTAssertEqual(try resolve(targetStart: 1.6).1, 0)
    }
}
