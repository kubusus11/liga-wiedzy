import Foundation

/// TRYB DEMONSTRACYJNY – działa bez Supabase i bez AI.
/// Używa wbudowanej, zweryfikowanej bazy pytań i tych samych reguł co serwer (Rules.swift),
/// a postęp zapisuje lokalnie na urządzeniu. Rywale w lidze są SYMULOWANI i wyraźnie tak oznaczeni.
/// Żadne dane z tego trybu nie trafiają do rankingów produkcyjnych.
final class DemoBackend: GameBackend {
    let isDemo = true
    let content: ContentBundle
    private var state: DemoState
    private let fileURL: URL
    private var activeAttempt: DemoAttempt?

    init(content: ContentBundle = .load()) {
        self.content = content
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("quizverse-demo.json")
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(DemoState.self, from: data) {
            state = s
        } else {
            state = DemoState()
        }
        rollPeriods()
    }

    var isSignedIn: Bool { state.signedIn }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: - Czas

    private static var calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = QVDate.warsaw
        return c
    }()

    static func weekStart(_ date: Date = Date()) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private static let seasonAnchor: Date = QVDate.parse("2026-11-23")!

    private func seasonIndex(_ date: Date = Date()) -> Int {
        max(1, Int(floor(date.timeIntervalSince(Self.seasonAnchor) / (56 * 86400))) + 1)
    }

    private func seasonStart(_ index: Int) -> Date { Self.seasonAnchor.addingTimeInterval(Double(index - 1) * 56 * 86400) }

    private var today: String { QVDate.dayString(Date()) }
    private var weekKey: String { QVDate.dayString(Self.weekStart()) }

    // MARK: - Rozliczenia tygodnia i sezonu (lokalnie)

    private func rollPeriods() {
        let currentWeek = weekKey
        if state.weekStart.isEmpty {
            state.weekStart = currentWeek
            state.rivals = Self.makeRivals(league: state.leagueId, seed: SeededRandom.stableHash(currentWeek))
        }
        while state.weekStart != currentWeek {
            guard let ws = QVDate.parse(state.weekStart) else { state.weekStart = currentWeek; break }
            settleWeek(weekStart: ws)
            let next = ws.addingTimeInterval(7 * 86400 + 3600) // +1 h na zmianę czasu
            state.weekStart = QVDate.dayString(Self.weekStart(next))
            if state.weekStart > currentWeek { state.weekStart = currentWeek }
            state.rivals = Self.makeRivals(league: state.leagueId, seed: SeededRandom.stableHash(state.weekStart))
            state.myWeekLP = 0
            state.joinedWeek = false
        }
        let si = seasonIndex()
        if state.seasonId == 0 { state.seasonId = si }
        while state.seasonId < si {
            settleSeason(state.seasonId)
            state.seasonId += 1
        }
        save()
    }

    private func standings(at date: Date = Date()) -> [Standing] {
        let ws = QVDate.parse(state.weekStart) ?? Self.weekStart()
        let hours = max(0, min(168, date.timeIntervalSince(ws) / 3600))
        var rows: [(id: String, name: String, avatar: String, color: String, level: Int, lp: Int, me: Bool, sim: Bool)] = state.rivals.map { r in
            (r.id, r.name, r.avatar, r.color, r.level, r.lp(hours: hours), false, true)
        }
        rows.append((state.userId, state.username, state.avatar, state.avatarColor, level, state.myWeekLP, true, false))
        rows.sort { $0.lp != $1.lp ? $0.lp > $1.lp : ($0.me && !$1.me) }
        return rows.enumerated().map { i, r in
            Standing(rank: i + 1, userId: r.id, username: r.name, avatar: r.avatar, avatarColor: r.color,
                     frame: r.me ? state.frame : "none", level: r.level, lp: r.lp, isMe: r.me, simulated: r.sim)
        }
    }

    private func settleWeek(weekStart ws: Date) {
        guard state.joinedWeek else { state.legendWeeks = 0; return }
        let end = ws.addingTimeInterval(7 * 86400)
        let table = standings(at: end)
        guard let me = table.first(where: { $0.isMe }) else { return }
        let outcome = Rules.leagueOutcome(league: state.leagueId, rank: me.rank, lp: me.lp)
        let newLeague = Rules.leagueAfter(state.leagueId, outcome)
        state.leagueHistory.insert(LeagueHistoryEntry(weekStart: QVDate.dayString(ws), leagueId: state.leagueId,
                                                      newLeagueId: newLeague, rank: me.rank, lp: me.lp,
                                                      outcome: outcome.rawValue), at: 0)
        state.legendWeeks = (state.leagueId == 5 && newLeague == 5) ? state.legendWeeks + 1 : 0
        if me.rank == 1 && me.lp > 0 { state.weekWins += 1 }
        let name = content.league(newLeague).name
        notify(kind: "league_result",
               title: outcome == .promoted ? "Awans! Witaj w lidze \(name)" : outcome == .relegated ? "Spadek do ligi \(name)" : "Utrzymanie w lidze \(name)",
               body: "Tydzień zakończony na \(me.rank). miejscu z wynikiem \(me.lp) LP (demo).")
        state.leagueId = newLeague
        state.highestLeagueId = max(state.highestLeagueId, newLeague)
        _ = checkAchievements()
        refreshSpecialMissions()
    }

    private func settleSeason(_ id: Int) {
        let start = seasonStart(id), end = start.addingTimeInterval(56 * 86400)
        let weeks = state.leagueHistory.filter {
            guard let d = QVDate.parse($0.weekStart) else { return false }
            return d >= start && d < end
        }
        guard !weeks.isEmpty else { return }
        let highest = weeks.map { max($0.leagueId, $0.newLeagueId) }.max() ?? 1
        let codes = ["bronze", "silver", "gold", "platinum", "legend"]
        let bonus = [100, 200, 300, 400, 500][highest - 1]
        let attempts = state.attempts.filter { $0.seasonId == id && $0.status == "finished" }
        state.seasons.insert(SeasonResult(seasonId: id, name: "Sezon \(id)", finalLeagueId: weeks.first?.newLeagueId ?? state.leagueId,
                                          highestLeagueId: highest, totalLp: weeks.reduce(0) { $0 + $1.lp },
                                          promotions: weeks.filter { $0.outcome == "promoted" }.count,
                                          relegations: weeks.filter { $0.outcome == "relegated" }.count,
                                          quizzes: attempts.count, xpEarned: attempts.reduce(0) { $0 + $1.xp },
                                          rewardBadge: "season_\(id)_\(codes[highest - 1])"), at: 0)
        grantXP(bonus)
        notify(kind: "season_end", title: "Sezon \(id) zakończony!", body: "Nagroda: \(bonus) XP i odznaka sezonu.")
    }

    static func makeRivals(league: Int, seed: UInt64) -> [DemoRival] {
        let names = ["Astra", "Kwazar", "Nova_PL", "Orion77", "Lyra", "Mgławica", "Pulsar", "Kometa", "Zenit", "Heliot",
                     "Selena", "Atlas_K", "Wega", "Draco", "Iskra", "Tytan", "Nebula", "Polaris", "Kosmita", "Rigel",
                     "Altair", "Kasjopea", "Andromeda", "Syriusz", "Eris", "Ceres", "Juno", "Fobos", "Deimos"]
        var rng = SeededRandom(seed: seed &+ UInt64(league) &* 7919)
        let activity = [1.0, 1.5, 2.2, 3.0, 4.0][max(1, min(5, league)) - 1]
        return names.enumerated().map { i, n in
            DemoRival(id: "sim-\(i)", name: n,
                      avatar: Rules.avatars[Int(rng.unit() * Double(Rules.avatars.count)) % Rules.avatars.count],
                      color: Rules.avatarColors[Int(rng.unit() * Double(Rules.avatarColors.count)) % Rules.avatarColors.count],
                      level: 1 + Int(rng.unit() * Double(10 * league + 10)),
                      ratePerHour: activity * (0.15 + rng.unit() * 2.2),
                      startDelayHours: rng.unit() * 60)
        }
    }

    // MARK: - Konto

    func restoreSession() async -> Bool { rollPeriods(); return state.signedIn }

    func signUp(email: String, password: String, username: String) async throws -> Bool {
        guard password.count >= 8 else { throw BackendError(code: "weak_password") }
        state.username = username.isEmpty ? "gracz_demo" : username
        state.displayName = state.username
        state.signedIn = true
        save()
        return true
    }

    func signIn(email: String, password: String) async throws {
        state.signedIn = true
        if state.username.isEmpty { state.username = email.split(separator: "@").first.map(String.init) ?? "gracz_demo" }
        save()
    }

    func resetPassword(email: String) async throws {}

    func signOut() async { state.signedIn = false; save() }

    func deleteAccount() async throws {
        state = DemoState()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Katalog

    private func progress(_ cat: Int, _ sub: Int = 0) -> DemoProgress { state.progress["\(cat):\(sub)"] ?? DemoProgress() }

    func categories() async throws -> [CategoryInfo] {
        content.categories.sorted { $0.sortOrder < $1.sortOrder }.map { c in
            let p = progress(c.id)
            return CategoryInfo(id: c.id, slug: c.slug, name: c.name, icon: c.icon, colorHex: c.colorHex, description: c.description,
                                questions: content.questions.filter { $0.categoryId == c.id }.count,
                                answered: p.answered, correct: p.correct,
                                subcategories: content.subcategories.filter { $0.categoryId == c.id }.sorted { $0.sortOrder < $1.sortOrder }
                                    .map { SubcategoryRef(id: $0.id, slug: $0.slug, name: $0.name, parentId: $0.treeParentId, unlockCorrect: $0.unlockCorrect) })
        }
    }

    private func subUnlocked(_ s: ContentBundle.SubcategoryDTO) -> Bool {
        guard let parent = s.treeParentId, s.unlockCorrect > 0 else { return true }
        return progress(s.categoryId, parent).correct >= s.unlockCorrect
    }

    func knowledgeTree(categoryId: Int) async throws -> [TreeNode] {
        content.subcategories.filter { $0.categoryId == categoryId }.sorted { $0.sortOrder < $1.sortOrder }.map { s in
            let p = progress(categoryId, s.id)
            return TreeNode(id: s.id, slug: s.slug, name: s.name, description: s.description, parentId: s.treeParentId,
                            unlockCorrect: s.unlockCorrect, unlocked: subUnlocked(s),
                            parentCorrect: s.treeParentId.map { progress(categoryId, $0).correct } ?? 0,
                            answered: p.answered, correct: p.correct,
                            questions: content.questions.filter { $0.subcategoryId == s.id }.count)
        }
    }

    // MARK: - Quiz

    private func publicQuestion(_ q: ContentBundle.QuestionDTO) -> QuizQuestion {
        QuizQuestion(id: q.id, prompt: q.prompt, kind: q.kind, clues: q.clues, difficulty: q.difficulty,
                     categoryId: q.categoryId, subcategoryId: q.subcategoryId, source: "manual", status: "approved",
                     answers: q.answers.sorted { $0.position < $1.position }.map { AnswerOption(id: $0.id, body: $0.body) })
    }

    private func pick(count: Int, category: Int?, sub: Int?, difficulty: Int?, kind: String) -> [String] {
        let recent = Set(state.answers.filter { Date().timeIntervalSince1970 - $0.at < 7 * 86400 }.map(\.questionId))
        return content.questions
            .filter { $0.kind == kind && (category == nil || $0.categoryId == category) && (sub == nil || $0.subcategoryId == sub) }
            .map { q in (q, recent.contains(q.id) ? 1 : 0, abs(q.difficulty - (difficulty ?? q.difficulty)), Double.random(in: 0..<1)) }
            .sorted { ($0.1, $0.2, $0.3) < ($1.1, $1.2, $1.3) }
            .prefix(count).map { $0.0.id }
    }

    private func dailyQuestionIds(day: String) -> [String] {
        var rng = SeededRandom(stableSeed: "daily:" + day)
        let byCat = Dictionary(grouping: content.questions.filter { $0.kind == "standard" }, by: \.categoryId)
        var picks: [ContentBundle.QuestionDTO] = []
        for cat in byCat.keys.sorted().shuffled(using: &rng).prefix(10) {
            let qs = byCat[cat]!.sorted { $0.id < $1.id }
            picks.append(qs[Int(rng.unit() * Double(qs.count)) % qs.count])
        }
        return picks.sorted { $0.difficulty < $1.difficulty }.map(\.id)
    }

    func startQuiz(_ r: QuizRequest) async throws -> QuizSession {
        rollPeriods()
        var ids: [String] = []
        var count = r.count
        var limit: Int? = nil
        if let sub = r.subcategoryId, let s = content.subcategories.first(where: { $0.id == sub }), !subUnlocked(s) {
            throw BackendError(code: "subcategory_locked")
        }
        switch r.mode {
        case .daily:
            if state.dailyPlayed.contains(today) { throw BackendError(code: "daily_already_played") }
            ids = dailyQuestionIds(day: today)
        case .quick: count = 10; ids = pick(count: 10, category: r.categoryId, sub: r.subcategoryId, difficulty: r.difficulty, kind: "standard")
        case .thematic, .ai:
            guard r.categoryId != nil || r.subcategoryId != nil else { throw BackendError(code: "category_required") }
            ids = pick(count: count, category: r.categoryId, sub: r.subcategoryId, difficulty: r.difficulty, kind: "standard")
        case .marathon: ids = pick(count: count, category: r.categoryId, sub: r.subcategoryId, difficulty: r.difficulty, kind: "standard")
        case .survival: ids = pick(count: 100, category: r.categoryId, sub: r.subcategoryId, difficulty: r.difficulty, kind: "standard")
        case .sprint:
            limit = r.timeLimit ?? 60
            ids = pick(count: limit == 60 ? 40 : 80, category: r.categoryId, sub: r.subcategoryId, difficulty: r.difficulty, kind: "standard")
        case .detective: count = 5; ids = pick(count: 5, category: r.categoryId, sub: nil, difficulty: r.difficulty, kind: "detective")
        case .review:
            ids = state.reviews.values.filter { $0.stage < 4 && $0.dueAt <= Date().timeIntervalSince1970 }
                .sorted { $0.dueAt < $1.dueAt }.prefix(20).map(\.questionId)
            if ids.isEmpty { throw BackendError(code: "no_reviews_due") }
        }
        if ids.isEmpty || ([.quick, .thematic, .ai, .detective, .daily].contains(r.mode) && ids.count < min(count, 5)) {
            throw BackendError(code: "not_enough_questions")
        }
        let attempt = DemoAttempt(id: UUID().uuidString, mode: r.mode.rawValue, categoryId: r.categoryId, subcategoryId: r.subcategoryId,
                                  difficulty: r.difficulty, questionIds: ids, questionCount: ids.count, timeLimit: limit,
                                  startedAt: Date().timeIntervalSince1970, seasonId: seasonIndex(), weekStart: weekKey)
        activeAttempt = attempt
        let byId = Dictionary(uniqueKeysWithValues: content.questions.map { ($0.id, $0) })
        return QuizSession(attemptId: attempt.id, mode: r.mode, questionCount: ids.count, timeLimitS: limit,
                           startedAt: QVDate.string(Date()), questions: ids.compactMap { byId[$0].map(publicQuestion) })
    }

    func submitAnswer(attemptId: String, questionId: String, answerId: String?, timeMs: Int) async throws -> AnswerResult {
        guard var a = activeAttempt, a.id == attemptId, a.status == "in_progress" else { throw BackendError(code: "attempt_closed") }
        guard a.questionIds.contains(questionId), !a.answeredIds.contains(questionId),
              let q = content.questions.first(where: { $0.id == questionId }) else { throw BackendError(code: "already_answered") }
        if let limit = a.timeLimit, Date().timeIntervalSince1970 > a.startedAt + Double(limit) + 3 {
            return AnswerResult(correct: nil, correctAnswerId: nil, explanation: nil, articleSlug: nil, sources: nil,
                                answered: a.answered, correctTotal: a.correct, endsQuiz: true, timeOver: true)
        }
        let correctId = q.answers.first { $0.isCorrect }?.id
        let ok = answerId != nil && answerId == correctId
        a.answeredIds.append(questionId)
        a.answered += 1
        if ok { a.correct += 1 }
        a.timesMs.append(timeMs)
        activeAttempt = a

        state.answers.append(DemoAnswer(questionId: questionId, correct: ok, timeMs: timeMs, at: Date().timeIntervalSince1970, day: today))
        if state.answers.count > 5000 { state.answers.removeFirst(state.answers.count - 5000) }
        state.answerStreak = ok ? state.answerStreak + 1 : 0
        state.bestAnswerStreak = max(state.bestAnswerStreak, state.answerStreak)
        bumpProgress(q.categoryId, 0, ok)
        if let sub = q.subcategoryId { bumpProgress(q.categoryId, sub, ok) }
        updateReview(q, ok)
        save()

        let ends = (a.mode == QuizMode.survival.rawValue && !ok) || a.answered >= a.questionCount
        return AnswerResult(correct: ok, correctAnswerId: correctId, explanation: q.explanation, articleSlug: q.articleSlug,
                            sources: q.sources, answered: a.answered, correctTotal: a.correct, endsQuiz: ends, timeOver: false)
    }

    private func bumpProgress(_ cat: Int, _ sub: Int, _ ok: Bool) {
        var p = progress(cat, sub)
        p.answered += 1
        if ok { p.correct += 1 }
        state.progress["\(cat):\(sub)"] = p
    }

    private func updateReview(_ q: ContentBundle.QuestionDTO, _ ok: Bool) {
        let p = progress(q.categoryId)
        let f = Rules.reviewFactor(answered: p.answered, correct: p.correct)
        let now = Date().timeIntervalSince1970
        if !ok {
            var r = state.reviews[q.id] ?? DemoReview(questionId: q.id, stage: 0, lapses: 0, dueAt: now)
            r.stage = 0; r.lapses += 1; r.dueAt = now + Rules.reviewIntervalsDays[0] * 86400 * f
            state.reviews[q.id] = r
        } else if var r = state.reviews[q.id], r.stage < 4, r.dueAt <= now {
            r.stage += 1
            r.dueAt = r.stage >= 4 ? now + 3650 * 86400 : now + Rules.reviewIntervalsDays[r.stage] * 86400 * f
            state.reviews[q.id] = r
        }
    }

    func finishQuiz(attemptId: String) async throws -> QuizResult {
        if let done = state.attempts.first(where: { $0.id == attemptId }), let result = done.result { return result }
        guard var a = activeAttempt, a.id == attemptId else { throw BackendError(code: "attempt_not_found") }
        let mode = QuizMode(rawValue: a.mode) ?? .quick
        let levelBefore = level
        let completed: Bool = {
            switch mode {
            case .survival, .sprint: return a.answered >= 1
            case .marathon: return a.answered >= 5
            default: return a.answered >= a.questionCount
            }
        }()
        let avg = a.timesMs.isEmpty ? 0 : Double(a.timesMs.reduce(0, +)) / Double(a.timesMs.count)
        let elapsed = (Date().timeIntervalSince1970 - a.startedAt) * 1000 / Double(max(1, a.answered))
        let flagged = a.answered >= 3 && (avg < Rules.minAvgAnswerMs || elapsed < Rules.minAvgAnswerMs)
        let newCategory = a.categoryId.map { progress($0).quizzes == 0 } ?? false
        let difficulty = a.difficulty ?? {
            let ds = a.questionIds.compactMap { id in content.questions.first { $0.id == id }?.difficulty }
            return ds.isEmpty ? 3 : Int((Double(ds.reduce(0, +)) / Double(ds.count)).rounded())
        }()
        let rewards = Rules.computeRewards(mode: mode, count: a.questionCount, answered: a.answered, correct: a.correct,
                                           difficulty: difficulty, completed: completed)
        var xp = flagged ? 0 : rewards.xp
        var lp = flagged ? 0 : rewards.lp
        var ledger = state.ledger[today] ?? DemoLedger()
        lp = max(0, min(lp, Rules.dailyLPCap - ledger.lp))
        xp = max(0, min(xp, Rules.dailyXPCap - ledger.xp))
        ledger.lp += lp; ledger.xp += xp; ledger.quizzes += 1
        state.ledger[today] = ledger

        if let c = a.categoryId {
            var p = progress(c); p.quizzes += 1; p.xp += xp; state.progress["\(c):0"] = p
            if let s = a.subcategoryId { var sp = progress(c, s); sp.quizzes += 1; state.progress["\(c):\(s)"] = sp }
        }
        if mode == .daily { state.dailyPlayed.append(today); state.dailyPlayed = Array(state.dailyPlayed.suffix(60)) }

        // seria dni
        if state.lastActiveDay != today {
            let yesterday = QVDate.dayString(Date().addingTimeInterval(-86400))
            state.currentStreak = state.lastActiveDay == yesterday ? state.currentStreak + 1 : 1
            state.lastActiveDay = today
        }
        state.bestStreak = max(state.bestStreak, state.currentStreak)

        grantXP(xp)
        var leagueUpdate: LeagueUpdate? = nil
        if lp > 0 { leagueUpdate = addLP(lp) }

        a.status = flagged ? "flagged" : "finished"
        a.xp = xp; a.lp = lp; a.finishedAt = Date().timeIntervalSince1970
        a.completed = completed
        state.attempts.append(a)

        var missions: [CompletedMission] = []
        var card: AwardedCard? = nil
        if !flagged {
            missions = progressMissions(a, xp: xp, newCategory: newCategory, completed: completed)
            card = maybeAwardCard(a)
        }
        let achievements = checkAchievements()

        let result = QuizResult(attemptId: a.id, mode: mode, answered: a.answered, correct: a.correct, questionCount: a.questionCount,
                                accuracy: rewards.accuracy, completed: completed, flagged: flagged, xp: xp, lp: lp,
                                xpItems: rewards.xpItems, lpItems: rewards.lpItems, lpBlockedLowAccuracy: rewards.lpBlockedLowAccuracy,
                                levelBefore: levelBefore, levelAfter: level, title: Rules.title(forLevel: level),
                                missionsCompleted: missions, achievementsUnlocked: achievements, card: card,
                                league: leagueUpdate ?? (state.joinedWeek ? currentLeagueUpdate() : nil), alreadyFinished: nil)
        if let i = state.attempts.lastIndex(where: { $0.id == a.id }) { state.attempts[i].result = result }
        if state.attempts.count > 400 { state.attempts.removeFirst(state.attempts.count - 400) }
        activeAttempt = nil
        save()
        return result
    }

    private var level: Int { Rules.level(forXP: state.xp) }

    private func grantXP(_ xp: Int) {
        guard xp > 0 else { return }
        let before = level
        state.xp += xp
        if level > before {
            notify(kind: "level_up", title: "Nowy poziom: \(level)", body: "Twój tytuł: \(Rules.title(forLevel: level)). Tak trzymaj!")
        }
    }

    private func currentLeagueUpdate() -> LeagueUpdate {
        let rank = standings().first { $0.isMe }?.rank ?? 30
        return LeagueUpdate(weekLp: state.myWeekLP, rank: rank)
    }

    private func addLP(_ lp: Int) -> LeagueUpdate {
        state.joinedWeek = true
        state.myWeekLP += lp
        return currentLeagueUpdate()
    }

    private func notify(kind: String, title: String, body: String) {
        state.notificationSeq += 1
        state.notifications.insert(AppNotification(id: state.notificationSeq, kind: kind, title: title, body: body,
                                                   readAt: nil, createdAt: QVDate.string(Date())), at: 0)
        if state.notifications.count > 100 { state.notifications.removeLast(state.notifications.count - 100) }
    }

    // MARK: - Misje

    private func periodKey(_ period: String) -> String {
        switch period {
        case "daily": return "D:\(today)"
        case "weekly": return "W:\(weekKey)"
        default: return "S"
        }
    }

    private func setMission(_ m: ContentBundle.MissionDTO, _ value: Int, delta: Bool) -> CompletedMission? {
        let key = "\(m.code)@\(periodKey(m.period))"
        let current = state.missionProgress[key] ?? 0
        let newValue = min(m.target, delta ? current + value : max(current, value))
        state.missionProgress[key] = newValue
        guard newValue >= m.target, state.missionDone[key] == nil else { return nil }
        state.missionDone[key] = QVDate.string(Date())
        grantXP(m.xpReward)
        if m.lpReward > 0 { _ = addLP(m.lpReward) }
        notify(kind: "mission", title: "Misja wykonana: \(m.title)", body: "Nagroda: \(m.xpReward) XP\(m.lpReward > 0 ? " + \(m.lpReward) LP" : "")")
        return CompletedMission(code: m.code, title: m.title, period: m.period, xp: m.xpReward, lp: m.lpReward)
    }

    private func progressMissions(_ a: DemoAttempt, xp: Int, newCategory: Bool, completed: Bool) -> [CompletedMission] {
        var done: [CompletedMission] = []
        let acc = a.answered > 0 ? Double(a.correct) / Double(a.answered) : 0
        let catSlug = a.categoryId.flatMap { id in content.categories.first { $0.id == id }?.slug }
        let mixedSlugs = a.questionIds.compactMap { id in content.questions.first { $0.id == id } }
            .compactMap { q in content.categories.first { $0.id == q.categoryId }?.slug }
        let counted = a.answered >= min(a.questionCount, 5)
        for m in content.missions where m.period != "special" {
            var r: CompletedMission? = nil
            switch m.metric {
            case "quizzes_completed": if counted { r = setMission(m, 1, delta: true) }
            case "correct_answers": if a.correct > 0 { r = setMission(m, a.correct, delta: true) }
            case "accuracy_quiz":
                if a.answered >= 5 && acc >= (Double(m.param ?? "80") ?? 80) / 100 { r = setMission(m, 1, delta: true) }
            case "category_quiz":
                let share = mixedSlugs.isEmpty ? 0 : Double(mixedSlugs.filter { $0 == m.param }.count) / Double(mixedSlugs.count)
                if counted && (catSlug == m.param || (a.categoryId == nil && share >= 0.5)) { r = setMission(m, 1, delta: true) }
            case "new_category": if newCategory && counted { r = setMission(m, 1, delta: true) }
            case "xp_earned": if xp > 0 { r = setMission(m, xp, delta: true) }
            case "distinct_categories":
                let n = Set(state.attempts.filter { $0.weekStart == weekKey && $0.status == "finished" }.compactMap(\.categoryId)).count
                r = setMission(m, n, delta: false)
            case "expert_quiz": if counted && (a.difficulty ?? 0) >= 5 { r = setMission(m, 1, delta: true) }
            default: break
            }
            if let r { done.append(r) }
        }
        return done + refreshSpecialMissions()
    }

    @discardableResult
    private func refreshSpecialMissions() -> [CompletedMission] {
        content.missions.filter { $0.period == "special" }.compactMap { setMission($0, metric($0.metric), delta: false) }
    }

    func missions() async throws -> [Mission] {
        rollPeriods()
        let resetsDaily = QVDate.string(Self.calendar.startOfDay(for: Date()).addingTimeInterval(86400))
        let resetsWeekly = QVDate.string(Self.weekStart().addingTimeInterval(7 * 86400))
        return content.missions.map { m in
            let key = "\(m.code)@\(periodKey(m.period))"
            let progress = m.period == "special" ? min(m.target, metric(m.metric)) : (state.missionProgress[key] ?? 0)
            return Mission(id: m.id, code: m.code, period: m.period, title: m.title, description: m.description, icon: m.icon,
                           target: m.target, xpReward: m.xpReward, lpReward: m.lpReward, progress: progress,
                           completedAt: state.missionDone[key],
                           resetsAt: m.period == "daily" ? resetsDaily : m.period == "weekly" ? resetsWeekly : nil)
        }
    }

    // MARK: - Osiągnięcia i karty

    private func metric(_ name: String) -> Int {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let finished = state.attempts.filter { $0.status == "finished" }
        let totals = content.categories.map { progress($0.id) }
        switch parts[0] {
        case "total_correct": return totals.reduce(0) { $0 + $1.correct }
        case "total_answered": return totals.reduce(0) { $0 + $1.answered }
        case "quizzes": return finished.count
        case "perfect_quizzes":
            return finished.filter { $0.questionCount >= 5 && $0.correct == $0.questionCount && !["survival", "sprint"].contains($0.mode) }.count
        case "best_streak": return state.bestStreak
        case "answer_streak": return state.bestAnswerStreak
        case "cat_correct":
            let slugs = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init))
            return content.categories.filter { slugs.contains($0.slug) }.reduce(0) { $0 + progress($1.id).correct }
        case "categories_played": return totals.filter { $0.answered > 0 }.count
        case "subcategories_played": return content.subcategories.filter { progress($0.categoryId, $0.id).answered > 0 }.count
        case "highest_league": return state.highestLeagueId
        case "legend_weeks": return state.legendWeeks
        case "promotions": return state.leagueHistory.filter { $0.outcome == "promoted" }.count
        case "top_rank": return state.weekWins
        case "level": return level
        case "cards": return state.cards.count
        case "marathon_perfect": return finished.filter { $0.mode == "marathon" && $0.answered == $0.questionCount && $0.correct == $0.questionCount }.count
        case "survival_best": return finished.filter { $0.mode == "survival" }.map(\.correct).max() ?? 0
        case "sprint_best": return finished.filter { $0.mode == "sprint" }.map(\.correct).max() ?? 0
        case "category_mastery": return totals.filter { $0.correct >= 100 && Double($0.correct) / Double(max(1, $0.answered)) >= 0.8 }.count
        case "daily_quizzes": return finished.filter { $0.mode == "daily" }.count
        case "reviews_mastered": return state.reviews.values.filter { $0.stage == 4 }.count
        case "detective_solved": return finished.filter { $0.mode == "detective" }.reduce(0) { $0 + $1.correct }
        case "expert_quizzes": return finished.filter { ($0.difficulty ?? 0) >= 5 }.count
        case "seasons_played": return state.seasons.count
        case "articles_favorited": return state.favorites.count
        default: return 0
        }
    }

    @discardableResult
    private func checkAchievements() -> [UnlockedAchievement] {
        var out: [UnlockedAchievement] = []
        for a in content.achievements where state.achievements[a.code] == nil {
            if metric(a.metric) >= a.threshold {
                state.achievements[a.code] = QVDate.string(Date())
                grantXP(a.xpReward)
                notify(kind: "achievement", title: "Osiągnięcie: \(a.name)", body: a.description)
                out.append(UnlockedAchievement(code: a.code, name: a.name, description: a.description, icon: a.icon,
                                               rarity: a.rarity, tier: a.tier, xp: a.xpReward))
            }
        }
        return out
    }

    func achievements() async throws -> [AchievementItem] {
        content.achievements.map {
            AchievementItem(id: $0.id, code: $0.code, category: $0.category, name: $0.name, description: $0.description,
                            icon: $0.icon, rarity: $0.rarity, tier: $0.tier, threshold: $0.threshold, xpReward: $0.xpReward,
                            unlockedAt: state.achievements[$0.code])
        }
    }

    private func maybeAwardCard(_ a: DemoAttempt) -> AwardedCard? {
        let finished = state.attempts.filter { $0.status == "finished" }.count
        let reason: String
        if a.questionCount >= 5 && a.correct == a.questionCount && !["survival", "sprint"].contains(a.mode) { reason = "perfect" }
        else if ["survival", "sprint"].contains(a.mode) && a.correct >= 15 { reason = a.mode }
        else if finished > 0 && finished % 5 == 0 { reason = "activity" }
        else { return nil }
        let cat = a.categoryId ?? a.questionIds.compactMap { id in content.questions.first { $0.id == id }?.categoryId }.randomElement()
        let hard = (a.difficulty ?? 0) >= 5
        let roll = Double.random(in: 0..<1)
        let rarity = roll < (hard ? 0.05 : 0.02) ? "legendary" : roll < (hard ? 0.2 : 0.1) ? "epic" : roll < (hard ? 0.55 : 0.38) ? "rare" : "common"
        let pool = content.cards.filter { $0.categoryId == cat }
        let candidates = (pool.filter { $0.rarity == rarity }.isEmpty ? pool : pool.filter { $0.rarity == rarity })
        let fallback = candidates.isEmpty ? content.cards : candidates
        guard let c = fallback.shuffled().sorted(by: { (state.cards[$0.id] != nil ? 1 : 0) < (state.cards[$1.id] != nil ? 1 : 0) }).first
        else { return nil }
        let copies = (state.cards[c.id] ?? 0) + 1
        state.cards[c.id] = copies
        if copies == 1 { state.cardDates[c.id] = QVDate.string(Date()) }
        return AwardedCard(id: c.id, code: c.code, name: c.name, description: c.description, rarity: c.rarity, kind: c.kind,
                           art: c.art, categoryId: c.categoryId, duplicate: copies > 1, reason: reason)
    }

    func cards() async throws -> [CardItem] {
        content.cards.map { c in
            var item = CardItem(id: c.id, code: c.code, name: c.name, description: c.description, kind: c.kind,
                                categoryId: c.categoryId, rarity: c.rarity, art: c.art, era: c.era)
            item.copies = state.cards[c.id] ?? 0
            item.obtainedAt = state.cardDates[c.id]
            return item
        }
    }

    // MARK: - Pozostałe

    func attemptReview(attemptId: String) async throws -> [AttemptReviewItem] { [] }

    func reportQuestion(questionId: String, reason: String, comment: String?) async throws {
        notify(kind: "report", title: "Dziękujemy za zgłoszenie", body: "W trybie demo zgłoszenie zapisano tylko lokalnie.")
        save()
    }

    func generateAIQuestions(categoryId: Int, subcategoryId: Int?, difficulty: Int, count: Int) async throws -> AIGenerationResult {
        let available = content.questions.filter { $0.categoryId == categoryId && (subcategoryId == nil || $0.subcategoryId == subcategoryId) }.count
        return AIGenerationResult(ready: available >= 5, reused: available, generated: 0, accepted: 0, sentToReview: 0, aiConfigured: false,
                                  message: "Tryb demonstracyjny: generator AI wymaga skonfigurowanego backendu. Zagrasz pytaniami z wbudowanej bazy.",
                                  note: nil)
    }

    func player() async throws -> Player {
        rollPeriods()
        let lvl = level
        let finished = state.attempts.filter { $0.status == "finished" }
        let si = seasonIndex()
        let tops = content.categories.map { c in (c, progress(c.id)) }.filter { $0.1.answered >= 5 }
            .sorted { $0.1.correct > $1.1.correct }.prefix(3)
            .map { TopCategory(categoryId: $0.0.id, name: $0.0.name, icon: $0.0.icon, colorHex: $0.0.colorHex, correct: $0.1.correct,
                               answered: $0.1.answered, accuracy: Double($0.1.correct) / Double(max(1, $0.1.answered))) }
        let badges = content.achievements.compactMap { a in
            state.achievements[a.code].map { BadgeRef(code: a.code, name: a.name, icon: a.icon, tier: a.tier, rarity: a.rarity, unlockedAt: $0) }
        }
        let yesterday = QVDate.dayString(Date().addingTimeInterval(-86400))
        return Player(id: state.userId, isMe: true, role: "user", username: state.username, displayName: state.displayName,
                      avatar: state.avatar, avatarColor: state.avatarColor, frame: state.frame, background: state.background,
                      bio: state.bio, notifications: state.notificationPrefs, xp: state.xp, level: lvl,
                      levelXpStart: Rules.xpForLevel(lvl), levelXpNext: lvl >= Rules.maxLevel ? nil : Rules.xpForLevel(lvl + 1),
                      title: state.selectedTitle ?? Rules.title(forLevel: lvl), levelTitle: Rules.title(forLevel: lvl),
                      leagueId: state.leagueId, highestLeagueId: state.highestLeagueId,
                      currentStreak: (state.lastActiveDay == today || state.lastActiveDay == yesterday) ? state.currentStreak : 0,
                      bestStreak: state.bestStreak, bestAnswerStreak: state.bestAnswerStreak,
                      createdAt: state.createdAt,
                      season: SeasonInfo(id: si, name: "Sezon \(si)", startsAt: QVDate.string(seasonStart(si)),
                                         endsAt: QVDate.string(seasonStart(si + 1)),
                                         week: Int(Date().timeIntervalSince(seasonStart(si)) / (7 * 86400)) + 1),
                      weekEndsAt: QVDate.string(Self.weekStart().addingTimeInterval(7 * 86400)),
                      stats: PlayerStatsSummary(answered: metric("total_answered"), correct: metric("total_correct"),
                                                quizzes: finished.count, cards: state.cards.count, achievements: state.achievements.count),
                      topCategories: Array(tops), badges: badges)
    }

    func updateProfile(_ u: ProfileUpdate) async throws {
        let lvl = level
        if let f = u.frame {
            guard Rules.frames.first(where: { $0.code == f })?.unlocked(level: lvl, highestLeague: state.highestLeagueId) == true else { throw BackendError(code: "frame_locked") }
            state.frame = f
        }
        if let b = u.background {
            guard Rules.backgrounds.first(where: { $0.code == b })?.unlocked(level: lvl, highestLeague: state.highestLeagueId) == true else { throw BackendError(code: "background_locked") }
            state.background = b
        }
        if let t = u.selectedTitle {
            guard Rules.unlockedTitles(level: lvl).contains(t) else { throw BackendError(code: "title_locked") }
            state.selectedTitle = t
        }
        if let v = u.displayName { state.displayName = v }
        if let v = u.avatar { state.avatar = v }
        if let v = u.avatarColor { state.avatarColor = v }
        if let v = u.bio { state.bio = String(v.prefix(160)) }
        if let v = u.notifications { state.notificationPrefs = v }
        save()
    }

    func leagueOverview() async throws -> LeagueOverview {
        rollPeriods()
        return LeagueOverview(league: content.league(state.leagueId), weekStart: state.weekStart,
                              weekEndsAt: QVDate.string(Self.weekStart().addingTimeInterval(7 * 86400)),
                              joined: state.joinedWeek,
                              zones: LeagueZones(promotionMax: state.leagueId < 5 ? 10 : 0, relegationMin: state.leagueId > 1 ? 24 : 31),
                              standings: state.joinedWeek ? standings() : [], history: Array(state.leagueHistory.prefix(20)))
    }

    func leaderboard(kind: String, categoryId: Int?) async throws -> Leaderboard {
        // W demo ranking zawiera tylko lokalnego gracza i symulowanych rywali z grupy tygodnia.
        let table = standings()
        let value: Int
        switch kind {
        case "global": value = state.xp
        case "season": value = state.leagueHistory.prefix(8).reduce(state.myWeekLP) { $0 + $1.lp }
        case "category": value = categoryId.map { progress($0).correct } ?? 0
        case "activity": value = state.attempts.filter { Date().timeIntervalSince1970 - ($0.finishedAt ?? 0) < 7 * 86400 && $0.status == "finished" }.count
        default: value = state.myWeekLP
        }
        let me = LeaderboardRow(rank: 1, userId: state.userId, username: state.username, avatar: state.avatar, avatarColor: state.avatarColor,
                                level: level, leagueId: state.leagueId, value: value, isMe: true)
        if kind == "weekly" {
            let rows = table.map { LeaderboardRow(rank: $0.rank, userId: $0.userId, username: $0.username, avatar: $0.avatar,
                                                  avatarColor: $0.avatarColor, level: $0.level, leagueId: state.leagueId, value: $0.lp, isMe: $0.isMe) }
            return Leaderboard(kind: kind, total: rows.count, me: rows.first { $0.isMe }.map { LeaderboardMe(rank: $0.rank, value: $0.value) }, rows: rows)
        }
        return Leaderboard(kind: kind, total: 1, me: LeaderboardMe(rank: 1, value: value), rows: value > 0 ? [me] : [])
    }

    func stats() async throws -> Stats {
        let cats: [CategoryStat] = content.categories.compactMap { c in
            let p = progress(c.id)
            guard p.answered > 0 else { return nil }
            let subs = content.subcategories.filter { $0.categoryId == c.id }
            return CategoryStat(categoryId: c.id, name: c.name, icon: c.icon, colorHex: c.colorHex, answered: p.answered,
                                correct: p.correct, quizzes: p.quizzes, xp: p.xp,
                                accuracy: Double(p.correct) / Double(p.answered), subcategoriesTotal: subs.count,
                                subcategoriesPlayed: subs.filter { progress(c.id, $0.id).answered > 0 }.count)
        }.sorted { $0.correct > $1.correct }
        let eligible = cats.filter { $0.answered >= 10 }
        let best = eligible.max { $0.accuracy < $1.accuracy }.map { CategoryRef(categoryId: $0.categoryId, name: $0.name, accuracy: $0.accuracy) }
        let worst = eligible.min { $0.accuracy < $1.accuracy }.map { CategoryRef(categoryId: $0.categoryId, name: $0.name, accuracy: $0.accuracy) }
        let byDay = Dictionary(grouping: state.answers, by: \.day)
        let xpByDay = Dictionary(grouping: state.attempts.filter { $0.finishedAt != nil }, by: { QVDate.dayString(Date(timeIntervalSince1970: $0.finishedAt!)) })
        let daily: [DailyStat] = (0..<60).reversed().map { offset in
            let d = QVDate.dayString(Date().addingTimeInterval(-Double(offset) * 86400))
            let ans = byDay[d] ?? []
            return DailyStat(day: d, answered: ans.count, correct: ans.filter(\.correct).count, xp: (xpByDay[d] ?? []).reduce(0) { $0 + $1.xp })
        }
        let now = Date().timeIntervalSince1970
        let open = state.reviews.values.filter { $0.stage < 4 }
        let player = try await player()
        return Stats(answered: metric("total_answered"), correct: metric("total_correct"), quizzes: metric("quizzes"),
                     perfectQuizzes: metric("perfect_quizzes"),
                     avgTimeMs: state.answers.isEmpty ? nil : Double(state.answers.reduce(0) { $0 + $1.timeMs }) / Double(state.answers.count),
                     currentStreak: player.currentStreak, bestStreak: state.bestStreak, currentAnswerStreak: state.answerStreak,
                     bestAnswerStreak: state.bestAnswerStreak, categories: cats, bestCategory: best, worstCategory: worst,
                     daily: daily, seasons: state.seasons,
                     reviews: ReviewSummary(due: open.filter { $0.dueAt <= now }.count, scheduled: open.count,
                                            mastered: state.reviews.values.filter { $0.stage == 4 }.count,
                                            nextDueAt: open.map(\.dueAt).min().map { QVDate.string(Date(timeIntervalSince1970: $0)) }))
    }

    func articles() async throws -> [Article] { content.articles.sorted { $0.title < $1.title } }
    func favoriteArticleIds() async throws -> Set<Int> { state.favorites }

    func toggleFavorite(articleId: Int) async throws -> Bool {
        if state.favorites.contains(articleId) { state.favorites.remove(articleId) } else { state.favorites.insert(articleId) }
        checkAchievements()
        save()
        return state.favorites.contains(articleId)
    }

    /// Mentor offline: analiza lokalna (bez AI), wyraźnie oznaczona w interfejsie.
    func mentor(message: String) async throws -> MentorReply {
        let s = try await stats()
        let weakCats = s.categories.filter { $0.answered >= 5 }.sorted { $0.accuracy < $1.accuracy }.prefix(3)
        let unplayed = content.categories.filter { c in !s.categories.contains { $0.categoryId == c.id } }
        var weak = weakCats.map { "\($0.name): \(Int($0.accuracy * 100))% skuteczności (\($0.answered) odp.)" }
        if weak.isEmpty { weak = ["Za mało danych – rozwiąż kilka quizów z różnych kategorii, aby mentor mógł ocenić Twoje mocne i słabe strony."] }
        var suggestions: [MentorSuggestion] = weakCats.map {
            MentorSuggestion(categoryId: $0.categoryId, subcategoryId: nil, difficulty: $0.accuracy < 0.5 ? 2 : 3, mode: "thematic",
                             reason: "Poprawa skuteczności w kategorii \($0.name).")
        }
        if s.reviews.due > 0 {
            suggestions.insert(MentorSuggestion(categoryId: weakCats.first?.categoryId ?? 1, subcategoryId: nil, difficulty: 3, mode: "review",
                                                reason: "Masz \(s.reviews.due) pytań do powtórki – to najszybszy sposób na utrwalenie."), at: 0)
        }
        if let explore = unplayed.randomElement() {
            suggestions.append(MentorSuggestion(categoryId: explore.id, subcategoryId: nil, difficulty: 2, mode: "thematic",
                                                reason: "Nowa kategoria: \(explore.name) – poszerzaj horyzonty."))
        }
        let accText = s.answered > 0 ? "Twoja skuteczność to \(Int(s.accuracy * 100))% przy \(s.answered) odpowiedziach." : "Nie masz jeszcze rozwiązanych quizów."
        return MentorReply(
            reply: "\(accText) Przygotowałem plan na najbliższe dni na podstawie Twoich wyników. (Mentor offline – analiza lokalna, bez AI.)",
            weakPoints: weak,
            plan: [
                MentorPlanItem(day: "Dzień 1", task: s.reviews.due > 0 ? "Powtórka zaległych pytań" : "Quiz dnia + szybki quiz"),
                MentorPlanItem(day: "Dzień 2", task: weakCats.first.map { "Quiz tematyczny: \($0.name) (poziom Łatwy)" } ?? "Quiz tematyczny z nowej kategorii"),
                MentorPlanItem(day: "Dzień 3", task: "Sprint 60 s – trening szybkości"),
                MentorPlanItem(day: "Dzień 4", task: weakCats.dropFirst().first.map { "Quiz tematyczny: \($0.name)" } ?? "Tryb detektywa"),
                MentorPlanItem(day: "Dzień 5", task: "Maraton 50 pytań – sprawdzian tygodnia"),
            ],
            suggestions: Array(suggestions.prefix(4)), offline: true)
    }

    func notifications() async throws -> [AppNotification] { state.notifications }
    func markNotificationsRead() async throws {
        state.notifications = state.notifications.map {
            AppNotification(id: $0.id, kind: $0.kind, title: $0.title, body: $0.body, readAt: $0.readAt ?? QVDate.string(Date()), createdAt: $0.createdAt)
        }
        save()
    }
    func registerDeviceToken(_ token: String) async throws {}
}

// MARK: - Stan trybu demo

struct DemoProgress: Codable { var answered = 0; var correct = 0; var quizzes = 0; var xp = 0 }
struct DemoReview: Codable { let questionId: String; var stage: Int; var lapses: Int; var dueAt: Double }
struct DemoLedger: Codable { var xp = 0; var lp = 0; var quizzes = 0 }
struct DemoAnswer: Codable { let questionId: String; let correct: Bool; let timeMs: Int; let at: Double; let day: String }

struct DemoRival: Codable {
    let id: String
    let name: String
    let avatar: String
    let color: String
    let level: Int
    let ratePerHour: Double
    let startDelayHours: Double

    /// LP symulowanego rywala po `hours` godzinach tygodnia (porcje po 10 LP).
    func lp(hours: Double) -> Int {
        let active = max(0, hours - startDelayHours)
        return Int(active * ratePerHour / 10) * 10
    }
}

struct DemoAttempt: Codable {
    let id: String
    let mode: String
    let categoryId: Int?
    let subcategoryId: Int?
    let difficulty: Int?
    let questionIds: [String]
    let questionCount: Int
    let timeLimit: Int?
    let startedAt: Double
    let seasonId: Int
    let weekStart: String
    var status = "in_progress"
    var answered = 0
    var correct = 0
    var answeredIds: [String] = []
    var timesMs: [Int] = []
    var xp = 0
    var lp = 0
    var completed = false
    var finishedAt: Double? = nil
    var result: QuizResult? = nil
}

struct DemoState: Codable {
    var signedIn = false
    var userId = UUID().uuidString
    var createdAt = QVDate.string(Date())
    var username = ""
    var displayName: String? = nil
    var avatar = "atom"
    var avatarColor = "#8B5CF6"
    var frame = "none"
    var background = "nebula"
    var selectedTitle: String? = nil
    var bio: String? = nil
    var notificationPrefs: [String: Bool] = ["league": true, "missions": true, "reviews": true, "daily": true]
    var xp = 0
    var leagueId = 1
    var highestLeagueId = 1
    var legendWeeks = 0
    var weekWins = 0
    var currentStreak = 0
    var bestStreak = 0
    var lastActiveDay: String? = nil
    var answerStreak = 0
    var bestAnswerStreak = 0
    var progress: [String: DemoProgress] = [:]
    var attempts: [DemoAttempt] = []
    var answers: [DemoAnswer] = []
    var reviews: [String: DemoReview] = [:]
    var missionProgress: [String: Int] = [:]
    var missionDone: [String: String] = [:]
    var achievements: [String: String] = [:]
    var cards: [Int: Int] = [:]
    var cardDates: [Int: String] = [:]
    var favorites: Set<Int> = []
    var notifications: [AppNotification] = []
    var notificationSeq = 0
    var ledger: [String: DemoLedger] = [:]
    var dailyPlayed: [String] = []
    var weekStart = ""
    var joinedWeek = false
    var myWeekLP = 0
    var rivals: [DemoRival] = []
    var leagueHistory: [LeagueHistoryEntry] = []
    var seasons: [SeasonResult] = []
    var seasonId = 0
}
