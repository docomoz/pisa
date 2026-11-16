import XCTest
@testable import PisaCore

final class RecognitionBoundaryRepairTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> RecognitionTimedWord {
        RecognitionTimedWord(text: text, start: start, end: end)
    }
    private var left: [RecognitionTimedWord] { [word("ноябре", 13.7, 14.1), word("обещали", 14.1, 15.0)] }
    private var right: [RecognitionTimedWord] { [word("Первую", 15.06, 15.45), word("реализацию", 15.45, 16.1)] }
    private var whole: [RecognitionTimedWord] {
        [word("обещали", 14.1, 15.02), word("первую", 15.02, 15.4), word("реализацию", 15.4, 16.1)]
    }
    private func probe(leftText: String = "В ноябре обещали первым.", rightText: String = "первоу реализацию, давай оставим.",
                       leftWords: [RecognitionTimedWord]? = nil, rightWords: [RecognitionTimedWord]? = nil) -> RecognitionBoundaryRepair.Probe? {
        RecognitionBoundaryRepair.probe(left: leftText, right: rightText,
            leftWords: leftWords ?? left, rightWords: rightWords ?? right,
            cut: 15, sharedAudio: 14.88..<15.12)
    }

    func testDifferentCorruptedFormsNeedIndependentWholeAudioAgreement() throws {
        let probe = try XCTUnwrap(probe())
        let proposal = try XCTUnwrap(RecognitionBoundaryRepair.proposal(probe, unionWords: whole))
        let result = try XCTUnwrap(RecognitionBoundaryRepair.confirm(proposal,
            reread: "В ноябре обещали первую реализацию, давай оставим."))
        XCTAssertEqual(result.left, "В ноябре обещали.")
        XCTAssertEqual(result.right, "первую реализацию, давай оставим.")
        XCTAssertNil(RecognitionBoundaryRepair.confirm(proposal, reread: "В ноябре обещали первым первую реализацию."))
        XCTAssertNil(RecognitionBoundaryRepair.confirm(proposal, reread: "В ноябре обещали другую реализацию."))
    }

    func testClippedAcousticPrefixNeedsACompleteWordFromBothWholeDecodes() throws {
        let left = [word("обещали", 14.396875, 14.916875), word("пе", 14.916875, 15.116875)]
        let right = [word("Первую", 15.1434375, 15.5034375), word("реализацию", 15.5034375, 16.2634375)]
        let probe = try XCTUnwrap(RecognitionBoundaryRepair.probe(left: "В ноябре обещали первым.", right: "первоу реализацию, давай оставим.",
            leftWords: left, rightWords: right, cut: 15.0234375, sharedAudio: 14.9034375..<15.1434375))
        let whole = [word("обещали", 14.41031235, 15.05031221), word("первую", 15.05031221, 15.45031231), word("реализацию", 15.45031231, 16.09031265)]
        let proposal = try XCTUnwrap(RecognitionBoundaryRepair.proposal(probe, unionWords: whole))
        let revised = try XCTUnwrap(RecognitionBoundaryRepair.confirm(proposal, reread: "В ноябре обещали первую реализацию, давай оставим."))
        XCTAssertEqual(revised.left, "В ноябре обещали.")
        XCTAssertEqual(revised.right, "первую реализацию, давай оставим.")
        XCTAssertNil(RecognitionBoundaryRepair.probe(left: "В ноябре обещали первым.", right: "первоу реализацию, давай оставим.",
            leftWords: [left[0], word("не", 14.916875, 15.116875)], rightWords: right,
            cut: 15.0234375, sharedAudio: 14.9034375..<15.1434375))
    }

    func testActualWordOnTheLeftKeepsItsOwnershipAndOutsidePunctuation() throws {
        let probe = try XCTUnwrap(probe(leftText: "Да, в ноябре обещали первым!", rightText: "первоу реализацию; дальше — проверка."))
        let evidence = [word("обещали", 14.1, 14.9), word("первую", 14.9, 15.4), word("реализацию", 15.4, 16.1)]
        let proposal = try XCTUnwrap(RecognitionBoundaryRepair.proposal(probe, unionWords: evidence))
        let result = try XCTUnwrap(RecognitionBoundaryRepair.confirm(proposal, reread: "Да, в ноябре обещали первую реализацию; дальше — проверка."))
        XCTAssertEqual(result.left, "Да, в ноябре обещали первую!")
        XCTAssertEqual(result.right, "реализацию; дальше — проверка.")
    }

    func testConfidentDifferentAcousticWordsAndNamesAreNeverCombined() {
        XCTAssertNil(probe(leftWords: [word("обещали", 14, 14.6), word("первым", 14.6, 15.1)]))
        XCTAssertNil(RecognitionBoundaryRepair.probe(left: "Спросили Ивана", right: "Мария ответила сразу",
            leftWords: [word("Спросили", 14, 14.6), word("Ивана", 14.6, 15.1)],
            rightWords: [word("Мария", 14.95, 15.4), word("ответила", 15.4, 16)],
            cut: 15, sharedAudio: 14.88..<15.12))
    }

    func testActualRepetitionAndAmbiguousAnchorsArePreserved() throws {
        let probe = try XCTUnwrap(probe())
        let repeated = [whole[0], word("первую", 14.95, 15.2), word("первую", 15.2, 15.4), whole[2]]
        XCTAssertNil(RecognitionBoundaryRepair.proposal(probe, unionWords: repeated))
        XCTAssertNil(RecognitionBoundaryRepair.proposal(probe, unionWords: whole + whole))
        let proposal = try XCTUnwrap(RecognitionBoundaryRepair.proposal(probe, unionWords: whole))
        XCTAssertNil(RecognitionBoundaryRepair.confirm(proposal, reread: "Обещали первую реализацию. И снова обещали первую реализацию."))
    }

    func testNumbersCompoundsAndShortConfirmationsCannotBecomeCandidates() {
        XCTAssertNil(probe(leftText: "В ноябре обещали 2026"))
        XCTAssertNil(probe(rightText: "Санкт-Петербург уже подключён"))
        XCTAssertNil(RecognitionBoundaryRepair.probe(left: "Ну да", right: "Да всё верно", leftWords: left, rightWords: right,
            cut: 15, sharedAudio: 14.88..<15.12))
    }

    func testMissingEvidenceOrAWordOutsideSharedAudioCannotBeRepaired() throws {
        XCTAssertNil(probe(leftWords: []))
        let probe = try XCTUnwrap(probe())
        XCTAssertNil(RecognitionBoundaryRepair.proposal(probe, unionWords: []))
        let remote = [whole[0], word("первую", 15.3, 15.6), whole[2]]
        XCTAssertNil(RecognitionBoundaryRepair.proposal(probe, unionWords: remote))
        XCTAssertNil(RecognitionBoundaryRepair.probe(left: "Обещали первым", right: "первоу реализацию",
            leftWords: left, rightWords: right, cut: 15, sharedAudio: 16..<17))
    }

    func testBoundaryQuotesApostrophesAndHyphensAreNeverDamaged() {
        XCTAssertNil(probe(leftText: "В ноябре «обещали первым»"))
        XCTAssertNil(probe(rightText: "«первоу реализацию, давай оставим»"))
        XCTAssertNil(probe(leftText: "В ноябре обещали первым’"))
        XCTAssertNil(probe(leftText: "В ноябре обещали « первым »."))
        XCTAssertNil(probe(leftText: "В ноябре обещали « первым"))
        XCTAssertNil(probe(rightText: "первоу » реализацию, давай оставим."))
        XCTAssertNil(probe(leftText: "В ноябре обещали first's"))
        XCTAssertNil(probe(rightText: "первоу-реализацию давай оставим"))
    }

    func testBoundaryPairsFollowTheAudioFileAcrossInterleavedTracks() {
        var turns = (0..<5).map { TranscriptSegment(start: Double($0), end: Double($0 + 1), speaker: "Собеседники", text: "Реплика") }
        for (index, file) in ["remote.caf", "mic.caf", "remote.caf", "remote.caf", "mic.caf"].enumerated() {
            turns[index].audioFile = file
        }
        let pairs = RecognitionBoundaryRepair.adjacentPairs(turns)
        XCTAssertEqual(pairs.map { [$0.left, $0.right] }, [[0, 2], [2, 3], [1, 4]])
        // A non-recovered middle turn of the same file remains a barrier. The
        // integration's exact-gap check rejects it instead of jumping over it.
        XCTAssertFalse(pairs.contains { $0.left == 0 && $0.right == 3 })
    }

    func testRealShortWordsAreNotTreatedAsIncompletePrefixes() {
        for (short, complete) in [("да", "данные"), ("ну", "нужную"), ("не", "неверную"), ("ли", "лишнюю"), ("ко", "корректную"), ("те", "текущую"), ("we", "welcome")] {
            XCTAssertNil(RecognitionBoundaryRepair.probe(left: "Мы проверили данным", right: "данных версию после встречи",
                leftWords: [word("проверили", 14, 14.9), word(short, 14.9, 15.1)],
                rightWords: [word(complete, 15.05, 15.4), word("версию", 15.4, 16)],
                cut: 15, sharedAudio: 14.88..<15.12))
        }
    }

    func testEllipsisAttachedToTheRemovedTokenDoesNotBecomeLeadingText() throws {
        let probe = try XCTUnwrap(probe(rightText: "первоу… реализацию; дальше — проверка."))
        let evidence = [word("обещали", 14.1, 14.9), word("первую", 14.9, 15.4), word("реализацию", 15.4, 16.1)]
        let proposal = try XCTUnwrap(RecognitionBoundaryRepair.proposal(probe, unionWords: evidence))
        let result = try XCTUnwrap(RecognitionBoundaryRepair.confirm(proposal, reread: "Обещали первую реализацию; дальше — проверка."))
        XCTAssertEqual(result.right, "реализацию; дальше — проверка.")
    }

    func testOnlyTheConfirmedReplacementReceivesOrthographyAndVocabulary() throws {
        let probe = try XCTUnwrap(RecognitionBoundaryRepair.probe(left: "Мы еще получили отчетный.", right: "отчетом заказчика, все верно.",
            leftWords: [word("еще", 13.5, 14.4), word("получили", 14.4, 15)],
            rightWords: [word("отчет", 15.02, 15.4), word("заказчика", 15.4, 16)],
            cut: 15, sharedAudio: 14.88..<15.12))
        let proposal = try XCTUnwrap(RecognitionBoundaryRepair.proposal(probe, unionWords: [
            word("получили", 14.4, 15.02), word("отчет", 15.02, 15.4), word("заказчика", 15.4, 16)
        ]))
        for vocabulary in ["", "отчет"] {
            let spelling = SpokenVocabulary(vocabulary)
            let revised = try XCTUnwrap(RecognitionBoundaryRepair.confirm(proposal, reread: "Мы еще получили отчет заказчика, все верно.") { token in
                XCTAssertEqual(token, "отчет")
                return TranscriptOrthography.normalize(spelling.apply(to: token), vocabulary: vocabulary)
            })
            XCTAssertEqual(revised.left, "Мы еще получили.")
            XCTAssertEqual(revised.right, (vocabulary.isEmpty ? "отчёт" : "отчет") + " заказчика, все верно.")
        }
        var calls = 0
        XCTAssertNil(RecognitionBoundaryRepair.confirm(proposal, reread: "Мы еще получили документ заказчика.") { token in
            calls += 1
            return token
        })
        XCTAssertEqual(calls, 0)
    }

    func testUnanchoredOrDifferentFullContextEvidenceIsRejected() throws {
        let probe = try XCTUnwrap(probe())
        XCTAssertNil(RecognitionBoundaryRepair.proposal(probe, unionWords: [whole[0], whole[1], word("версию", 15.4, 16)]))
        let proposal = try XCTUnwrap(RecognitionBoundaryRepair.proposal(probe, unionWords: whole))
        XCTAssertNil(RecognitionBoundaryRepair.confirm(proposal, reread: "Обещали первую полную реализацию."))
    }
}
