import XCTest
@testable import QuizVerse

/// Testy reguł gry – muszą dawać te same wyniki co funkcje SQL (supabase/tests/test_01_rules.sql).
final class RulesTests: XCTestCase {

    // MARK: Poziomy

    func testLevelCurve() {
        XCTAssertEqual(Rules.xpForLevel(1), 0)
        XCTAssertEqual(Rules.xpForLevel(2), 100)
        XCTAssertEqual(Rules.xpForLevel(3), 220)
        XCTAssertEqual(Rules.level(forXP: 0), 1)
        XCTAssertEqual(Rules.level(forXP: 99), 1)
        XCTAssertEqual(Rules.level(forXP: 100), 2)
        XCTAssertEqual(Rules.level(forXP: 219), 2)
        XCTAssertEqual(Rules.level(forXP: 220), 3)
        XCTAssertEqual(Rules.level(forXP: 10_000_000), Rules.maxLevel)
    }

    func testTitles() {
        XCTAssertEqual(Rules.title(forLevel: 1), "Nowicjusz")
        XCTAssertEqual(Rules.title(forLevel: 10), "Nowicjusz")
        XCTAssertEqual(Rules.title(forLevel: 11), "Uczeń")
        XCTAssertEqual(Rules.title(forLevel: 100), "Mędrzec")
        XCTAssertEqual(Rules.title(forLevel: 151), "Wszechwiedzący")
        XCTAssertEqual(Rules.titles.count, 9)
        XCTAssertEqual(Rules.unlockedTitles(level: 1), ["Nowicjusz"])
        XCTAssertEqual(Rules.unlockedTitles(level: 26), ["Nowicjusz", "Uczeń", "Odkrywca"])
    }

    // MARK: XP i LP

    func testQuickQuizRewards() {
        let r = Rules.computeRewards(mode: .quick, count: 10, answered: 10, correct: 8, difficulty: 3, completed: true)
        XCTAssertEqual(r.xp, 8 * 5 + 15)
        XCTAssertEqual(r.lp, 20)
    }

    func testPerfectAndExpertBonus() {
        let r = Rules.computeRewards(mode: .thematic, count: 10, answered: 10, correct: 10, difficulty: 5, completed: true)
        XCTAssertEqual(r.xp, 50 + 15 + 20 + 30)
        XCTAssertEqual(r.lp, 20)
    }

    func testLPByQuizLength() {
        XCTAssertEqual(Rules.computeRewards(mode: .thematic, count: 5, answered: 5, correct: 5, difficulty: nil, completed: true).lp, 10)
        XCTAssertEqual(Rules.computeRewards(mode: .thematic, count: 20, answered: 20, correct: 15, difficulty: nil, completed: true).lp, 40)
    }

    func testDailyQuiz() {
        let r = Rules.computeRewards(mode: .daily, count: 10, answered: 10, correct: 6, difficulty: nil, completed: true)
        XCTAssertEqual(r.lp, 25)
        XCTAssertEqual(r.xp, 30 + 15 + 25)
    }

    func testMarathonLPPerFiveQuestions() {
        let r = Rules.computeRewards(mode: .marathon, count: 50, answered: 23, correct: 20, difficulty: nil, completed: true)
        XCTAssertEqual(r.lp, 40) // 4 pełne piątki
    }

    func testLowAccuracyBlocksLP() {
        let r = Rules.computeRewards(mode: .quick, count: 10, answered: 10, correct: 3, difficulty: nil, completed: true)
        XCTAssertEqual(r.lp, 0)
        XCTAssertTrue(r.lpBlockedLowAccuracy)
        XCTAssertEqual(r.xp, 15 + 15) // XP nadal przyznane
    }

    func testIncompleteQuizGivesNoLPOrCompletionBonus() {
        let r = Rules.computeRewards(mode: .quick, count: 10, answered: 6, correct: 6, difficulty: nil, completed: false)
        XCTAssertEqual(r.lp, 0)
        XCTAssertEqual(r.xp, 30)
    }

    func testReviewAndAIGiveNoLP() {
        XCTAssertEqual(Rules.computeRewards(mode: .review, count: 10, answered: 10, correct: 10, difficulty: 6, completed: true).lp, 0)
        XCTAssertEqual(Rules.computeRewards(mode: .ai, count: 10, answered: 10, correct: 10, difficulty: 3, completed: true).lp, 0)
    }

    func testSurvivalAndSprintCap() {
        XCTAssertEqual(Rules.computeRewards(mode: .survival, count: 100, answered: 13, correct: 12, difficulty: nil, completed: true).lp, 20)
        XCTAssertEqual(Rules.computeRewards(mode: .sprint, count: 80, answered: 50, correct: 45, difficulty: nil, completed: true).lp, 60)
    }

    // MARK: Ligi

    func testLeagueZones() {
        XCTAssertEqual(Rules.leagueOutcome(league: 2, rank: 1, lp: 100), .promoted)
        XCTAssertEqual(Rules.leagueOutcome(league: 2, rank: 10, lp: 5), .promoted)
        XCTAssertEqual(Rules.leagueOutcome(league: 2, rank: 11, lp: 500), .stayed)
        XCTAssertEqual(Rules.leagueOutcome(league: 2, rank: 23, lp: 0), .stayed)
        XCTAssertEqual(Rules.leagueOutcome(league: 2, rank: 24, lp: 0), .relegated)
        XCTAssertEqual(Rules.leagueOutcome(league: 2, rank: 30, lp: 0), .relegated)
    }

    func testBronzeCannotDropAndLegendCannotPromote() {
        XCTAssertEqual(Rules.leagueOutcome(league: 1, rank: 30, lp: 0), .stayed)
        XCTAssertEqual(Rules.leagueOutcome(league: 5, rank: 1, lp: 900), .stayed)
        XCTAssertEqual(Rules.leagueAfter(5, .promoted), 5)
        XCTAssertEqual(Rules.leagueAfter(1, .relegated), 1)
        XCTAssertEqual(Rules.leagueAfter(3, .promoted), 4)
    }

    func testZeroLPDoesNotPromote() {
        XCTAssertEqual(Rules.leagueOutcome(league: 1, rank: 3, lp: 0), .stayed)
    }

    // MARK: Powtórki i kosmetyki

    func testReviewFactor() {
        XCTAssertEqual(Rules.reviewFactor(answered: 5, correct: 0), 1)
        XCTAssertEqual(Rules.reviewFactor(answered: 20, correct: 5), 0.7)
        XCTAssertEqual(Rules.reviewFactor(answered: 20, correct: 19), 1.25)
        XCTAssertEqual(Rules.reviewIntervalsDays, [1, 3, 7, 30])
    }

    func testCosmeticsUnlocking() {
        let gold = Rules.frames.first { $0.code == "gold" }!
        XCTAssertFalse(gold.unlocked(level: 99, highestLeague: 2))
        XCTAssertTrue(gold.unlocked(level: 1, highestLeague: 3))
        let orbit = Rules.frames.first { $0.code == "orbit" }!
        XCTAssertFalse(orbit.unlocked(level: 9, highestLeague: 5))
        XCTAssertTrue(orbit.unlocked(level: 10, highestLeague: 1))
    }

    // MARK: Treści i daty

    func testBundledContent() {
        let c = ContentBundle.load()
        XCTAssertEqual(c.leagues.count, 5)
        XCTAssertEqual(c.categories.count, 28)
        XCTAssertGreaterThanOrEqual(c.questions.count, 300)
        for q in c.questions {
            XCTAssertEqual(q.answers.filter(\.isCorrect).count, 1, "Pytanie \(q.id) musi mieć dokładnie jedną poprawną odpowiedź")
            XCTAssertFalse(q.explanation.isEmpty)
        }
    }

    func testDateParsing() {
        XCTAssertNotNil(QVDate.parse("2026-11-23"))
        XCTAssertNotNil(QVDate.parse("2026-11-23T10:00:00Z"))
        XCTAssertNotNil(QVDate.parse("2026-11-23T10:00:00.123Z"))
        XCTAssertNotNil(QVDate.parse("2026-11-23 10:00:00.123456+00:00"))
        XCTAssertNil(QVDate.parse(nil))
    }

    func testPolishPlural() {
        XCTAssertEqual(Fmt.plural(1, "pytanie", "pytania", "pytań"), "1 pytanie")
        XCTAssertEqual(Fmt.plural(3, "pytanie", "pytania", "pytań"), "3 pytania")
        XCTAssertEqual(Fmt.plural(5, "pytanie", "pytania", "pytań"), "5 pytań")
        XCTAssertEqual(Fmt.plural(12, "pytanie", "pytania", "pytań"), "12 pytań")
        XCTAssertEqual(Fmt.plural(22, "pytanie", "pytania", "pytań"), "22 pytania")
    }
}
