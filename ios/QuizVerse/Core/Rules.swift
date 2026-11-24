import Foundation

/// Reguły gry – lustrzane odbicie funkcji SQL (qv_compute_rewards, qv_level_for_xp,
/// qv_league_outcome). W trybie z backendem punkty liczy WYŁĄCZNIE serwer; ten kod
/// służy trybowi demonstracyjnemu i podglądowi w interfejsie. Testy: QuizVerseTests/RulesTests.
enum Rules {
    static let maxLevel = 151
    static let dailyLPCap = 300
    static let dailyXPCap = 3000
    static let minLPAccuracy = 0.4
    static let minAvgAnswerMs = 800.0
    static let groupSize = 30
    static let reviewIntervalsDays: [Double] = [1, 3, 7, 30]

    static let titles: [(maxLevel: Int, title: String)] = [
        (10, "Nowicjusz"), (25, "Uczeń"), (40, "Odkrywca"), (60, "Badacz"), (80, "Uczony"),
        (100, "Mędrzec"), (120, "Arcymistrz"), (140, "Geniusz"), (151, "Wszechwiedzący"),
    ]

    /// Łączne XP potrzebne do osiągnięcia poziomu n.
    static func xpForLevel(_ level: Int) -> Int {
        let n = max(level, 1)
        return 100 * (n - 1) + 10 * (n - 1) * (n - 2)
    }

    static func level(forXP xp: Int) -> Int {
        var n = 1
        while n < maxLevel && xpForLevel(n + 1) <= xp { n += 1 }
        return n
    }

    static func title(forLevel level: Int) -> String {
        titles.first { level <= $0.maxLevel }?.title ?? "Wszechwiedzący"
    }

    static func unlockedTitles(level: Int) -> [String] {
        var out: [String] = []
        for t in titles {
            out.append(t.title)
            if level <= t.maxLevel { break }
        }
        return out
    }

    struct Rewards: Equatable {
        var xp = 0
        var lp = 0
        var xpItems: [RewardItem] = []
        var lpItems: [RewardItem] = []
        var accuracy = 0.0
        var lpBlockedLowAccuracy = false
    }

    static func computeRewards(mode: QuizMode, count: Int, answered: Int, correct: Int,
                               difficulty: Int?, completed: Bool) -> Rewards {
        var r = Rewards()
        r.accuracy = answered > 0 ? Double(correct) / Double(answered) : 0
        let lpAllowed = r.accuracy >= minLPAccuracy

        if correct > 0 {
            r.xp += 5 * correct
            r.xpItems.append(.init(key: "correct", label: "Poprawne odpowiedzi", value: 5 * correct))
        }
        if completed && answered > 0 {
            r.xp += 15; r.xpItems.append(.init(key: "completed", label: "Ukończenie quizu", value: 15))
            if ![.survival, .sprint].contains(mode) && count >= 5 && correct == count {
                r.xp += 20; r.xpItems.append(.init(key: "perfect", label: "Komplet poprawnych", value: 20))
            }
            if (difficulty ?? 0) >= 5 && r.accuracy >= 0.5 && mode != .review {
                r.xp += 30; r.xpItems.append(.init(key: "expert", label: "Quiz ekspercki", value: 30))
            }
            if mode == .daily {
                r.xp += 25; r.xpItems.append(.init(key: "daily", label: "Quiz dnia", value: 25))
            }
        }

        if lpAllowed {
            var v = 0
            var item: RewardItem? = nil
            switch mode {
            case .daily:
                if completed { v = 25; item = .init(key: "daily", label: "Quiz dnia", value: 25) }
            case .marathon:
                v = (answered / 5) * 10
                item = .init(key: "marathon", label: "Maraton (10 LP / 5 pytań)", value: v)
            case .survival, .sprint:
                v = min((correct / 5) * 10, 60)
                item = .init(key: mode.rawValue, label: mode == .survival ? "Przetrwanie" : "Sprint", value: v)
            case .quick, .thematic, .detective:
                if completed {
                    v = count >= 20 ? 40 : count >= 10 ? 20 : count >= 5 ? 10 : 0
                    item = .init(key: "quiz", label: "Quiz \(count) pytań", value: v)
                }
            case .review, .ai:
                break // powtórki i pytania AI (przed akceptacją redakcji) nie dają LP
            }
            if v > 0, let item { r.lp = v; r.lpItems.append(item) }
        }
        r.lpBlockedLowAccuracy = !lpAllowed && answered > 0
        return r
    }

    enum Outcome: String { case promoted, stayed, relegated }

    /// Miejsca 1–10 awans, 11–23 utrzymanie, 24–30 spadek. Brąz nie spada, Legenda nie awansuje.
    static func leagueOutcome(league: Int, rank: Int, lp: Int) -> Outcome {
        if rank <= 10 && lp > 0 && league < 5 { return .promoted }
        if rank >= 24 && league > 1 { return .relegated }
        return .stayed
    }

    static func leagueAfter(_ league: Int, _ outcome: Outcome) -> Int {
        switch outcome {
        case .promoted: return min(league + 1, 5)
        case .relegated: return max(league - 1, 1)
        case .stayed: return league
        }
    }

    /// Mnożnik interwału powtórek zależny od skuteczności w kategorii.
    static func reviewFactor(answered: Int, correct: Int) -> Double {
        guard answered >= 10 else { return 1 }
        let acc = Double(correct) / Double(answered)
        if acc < 0.5 { return 0.7 }
        if acc > 0.85 { return 1.25 }
        return 1
    }

    /// Ramki i tła profilu – wymagania muszą być zgodne z qv_cosmetic_unlocked().
    struct Cosmetic: Identifiable, Hashable {
        let code: String
        let name: String
        let requirement: String
        let minLevel: Int
        let minLeague: Int
        var id: String { code }
        func unlocked(level: Int, highestLeague: Int) -> Bool { level >= minLevel && highestLeague >= minLeague }
    }

    static let frames: [Cosmetic] = [
        .init(code: "none", name: "Brak", requirement: "Dostępna", minLevel: 1, minLeague: 1),
        .init(code: "bronze", name: "Brązowa", requirement: "Dostępna", minLevel: 1, minLeague: 1),
        .init(code: "silver", name: "Srebrna", requirement: "Liga Srebro", minLevel: 1, minLeague: 2),
        .init(code: "gold", name: "Złota", requirement: "Liga Złoto", minLevel: 1, minLeague: 3),
        .init(code: "platinum", name: "Platynowa", requirement: "Liga Platyna", minLevel: 1, minLeague: 4),
        .init(code: "legend", name: "Legendarna", requirement: "Liga Legenda", minLevel: 1, minLeague: 5),
        .init(code: "orbit", name: "Orbita", requirement: "Poziom 10", minLevel: 10, minLeague: 1),
        .init(code: "supernova", name: "Supernowa", requirement: "Poziom 50", minLevel: 50, minLeague: 1),
        .init(code: "singularity", name: "Osobliwość", requirement: "Poziom 100", minLevel: 100, minLeague: 1),
    ]

    static let backgrounds: [Cosmetic] = [
        .init(code: "nebula", name: "Mgławica", requirement: "Dostępne", minLevel: 1, minLeague: 1),
        .init(code: "galaxy", name: "Galaktyka", requirement: "Poziom 5", minLevel: 5, minLeague: 1),
        .init(code: "aurora", name: "Zorza", requirement: "Poziom 20", minLevel: 20, minLeague: 1),
        .init(code: "blackhole", name: "Czarna dziura", requirement: "Poziom 40", minLevel: 40, minLeague: 1),
        .init(code: "goldendust", name: "Złoty pył", requirement: "Liga Złoto", minLevel: 1, minLeague: 3),
        .init(code: "legendvoid", name: "Pustka Legendy", requirement: "Liga Legenda", minLevel: 1, minLeague: 5),
    ]

    static let avatars = ["atom", "brain.head.profile", "book.fill", "globe.europe.africa.fill", "moon.stars.fill",
                          "flask.fill", "music.note", "building.columns.fill", "leaf.fill", "bolt.fill",
                          "sparkles", "gamecontroller.fill", "paintpalette.fill", "figure.run", "crown.fill"]
    static let avatarColors = ["#8B5CF6", "#7DD3FC", "#F5C542", "#2DD4BF", "#F43F5E", "#F97316", "#EC4899", "#22C55E"]
}
