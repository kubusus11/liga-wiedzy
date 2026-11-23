import Foundation

// Modele odpowiadają strukturom JSON zwracanym przez funkcje RPC Supabase
// (klucze snake_case są konwertowane automatycznie na camelCase).

enum QuizMode: String, Codable, CaseIterable, Identifiable {
    case daily, quick, marathon, survival, sprint, thematic, detective, review, ai
    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Quiz dnia"
        case .quick: return "Szybki quiz"
        case .marathon: return "Maraton wiedzy"
        case .survival: return "Tryb przetrwania"
        case .sprint: return "Sprint"
        case .thematic: return "Quiz tematyczny"
        case .detective: return "Tryb detektywa"
        case .review: return "Inteligentne powtórki"
        case .ai: return "Quiz AI"
        }
    }

    var subtitle: String {
        switch self {
        case .daily: return "10 pytań · raz dziennie · 25 LP"
        case .quick: return "10 pytań · 20 LP"
        case .marathon: return "50 lub 100 pytań · 10 LP / 5 pytań"
        case .survival: return "Jeden błąd kończy grę"
        case .sprint: return "60 lub 120 sekund"
        case .thematic: return "Dowolna kategoria · 5/10/20 pytań"
        case .detective: return "Wskazówki i łączenie faktów"
        case .review: return "Powtórki po 1/3/7/30 dniach · bez LP"
        case .ai: return "Pytania generowane przez AI · bez LP"
        }
    }

    var icon: String {
        switch self {
        case .daily: return "sun.max.fill"
        case .quick: return "bolt.fill"
        case .marathon: return "figure.run"
        case .survival: return "heart.fill"
        case .sprint: return "timer"
        case .thematic: return "square.grid.2x2.fill"
        case .detective: return "magnifyingglass"
        case .review: return "arrow.triangle.2.circlepath"
        case .ai: return "sparkles"
        }
    }
}

struct QuizRequest: Equatable {
    var mode: QuizMode
    var categoryId: Int? = nil
    var subcategoryId: Int? = nil
    var difficulty: Int? = nil
    var count: Int = 10
    var timeLimit: Int? = nil
}

struct AnswerOption: Codable, Identifiable, Hashable {
    let id: String
    let body: String
}

struct QuizQuestion: Codable, Identifiable, Hashable {
    let id: String
    let prompt: String
    let kind: String
    let clues: [String]?
    let difficulty: Int
    let categoryId: Int
    let subcategoryId: Int?
    let source: String?
    let status: String?
    let answers: [AnswerOption]
}

struct QuizSession: Codable {
    let attemptId: String
    let mode: QuizMode
    let questionCount: Int
    let timeLimitS: Int?
    let startedAt: String?
    let questions: [QuizQuestion]
}

struct SourceRef: Codable, Hashable {
    let title: String
    let url: String?
}

struct AnswerResult: Codable {
    let correct: Bool?
    let correctAnswerId: String?
    let explanation: String?
    let articleSlug: String?
    let sources: [SourceRef]?
    let answered: Int?
    let correctTotal: Int?
    let endsQuiz: Bool
    let timeOver: Bool?
}

struct RewardItem: Codable, Hashable {
    let key: String
    let label: String
    let value: Int
}

struct CompletedMission: Codable, Hashable {
    let code: String
    let title: String
    let period: String
    let xp: Int
    let lp: Int
}

struct UnlockedAchievement: Codable, Hashable {
    let code: String
    let name: String
    let description: String
    let icon: String
    let rarity: String
    let tier: String
    let xp: Int?
}

struct AwardedCard: Codable, Hashable {
    let id: Int
    let code: String
    let name: String
    let description: String
    let rarity: String
    let kind: String
    let art: String
    let categoryId: Int
    let duplicate: Bool?
    let reason: String?
}

struct LeagueUpdate: Codable, Hashable {
    let weekLp: Int
    let rank: Int
}

struct QuizResult: Codable {
    let attemptId: String
    let mode: QuizMode
    let answered: Int
    let correct: Int
    let questionCount: Int
    let accuracy: Double
    let completed: Bool
    let flagged: Bool
    let xp: Int
    let lp: Int
    let xpItems: [RewardItem]
    let lpItems: [RewardItem]
    let lpBlockedLowAccuracy: Bool?
    let levelBefore: Int
    let levelAfter: Int
    let title: String
    let missionsCompleted: [CompletedMission]
    let achievementsUnlocked: [UnlockedAchievement]
    let card: AwardedCard?
    let league: LeagueUpdate?
    let alreadyFinished: Bool?
}

struct SeasonInfo: Codable, Hashable {
    let id: Int
    let name: String
    let startsAt: String
    let endsAt: String
    let week: Int
}

struct PlayerStatsSummary: Codable, Hashable {
    let answered: Int
    let correct: Int
    let quizzes: Int
    let cards: Int
    let achievements: Int
}

struct TopCategory: Codable, Hashable, Identifiable {
    var id: Int { categoryId }
    let categoryId: Int
    let name: String
    let icon: String
    let colorHex: String
    let correct: Int
    let answered: Int
    let accuracy: Double
}

struct BadgeRef: Codable, Hashable, Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let icon: String
    let tier: String
    let rarity: String
    let unlockedAt: String?
}

struct Player: Codable {
    let id: String
    let isMe: Bool
    let role: String?
    let username: String
    let displayName: String?
    let avatar: String
    let avatarColor: String
    let frame: String
    let background: String
    let bio: String?
    let notifications: [String: Bool]?
    let xp: Int
    let level: Int
    let levelXpStart: Int
    let levelXpNext: Int?
    let title: String
    let levelTitle: String
    let leagueId: Int
    let highestLeagueId: Int
    let currentStreak: Int
    let bestStreak: Int
    let bestAnswerStreak: Int
    let createdAt: String?
    let season: SeasonInfo?
    let weekEndsAt: String?
    let stats: PlayerStatsSummary
    let topCategories: [TopCategory]
    let badges: [BadgeRef]

    var levelProgress: Double {
        guard let next = levelXpNext, next > levelXpStart else { return 1 }
        return Double(xp - levelXpStart) / Double(next - levelXpStart)
    }
}

struct League: Codable, Hashable, Identifiable {
    let id: Int
    let code: String
    let name: String
    let roman: String
    let colorHex: String
    let emblem: String
    let description: String
}

struct Standing: Codable, Hashable, Identifiable {
    var id: String { userId }
    let rank: Int
    let userId: String
    let username: String
    let avatar: String
    let avatarColor: String
    let frame: String?
    let level: Int
    let lp: Int
    let isMe: Bool
    var simulated: Bool? = nil
}

struct LeagueZones: Codable, Hashable {
    let promotionMax: Int
    let relegationMin: Int
}

struct LeagueHistoryEntry: Codable, Hashable, Identifiable {
    var id: String { weekStart }
    let weekStart: String
    let leagueId: Int
    let newLeagueId: Int
    let rank: Int
    let lp: Int
    let outcome: String
}

struct LeagueOverview: Codable {
    let league: League
    let weekStart: String
    let weekEndsAt: String
    let joined: Bool
    let zones: LeagueZones
    let standings: [Standing]
    let history: [LeagueHistoryEntry]
}

struct LeaderboardRow: Codable, Hashable, Identifiable {
    var id: String { userId }
    let rank: Int
    let userId: String
    let username: String
    let avatar: String
    let avatarColor: String
    let level: Int
    let leagueId: Int
    let value: Int
    let isMe: Bool
}

struct LeaderboardMe: Codable, Hashable {
    let rank: Int
    let value: Int
}

struct Leaderboard: Codable {
    let kind: String
    let total: Int
    let me: LeaderboardMe?
    let rows: [LeaderboardRow]
}

struct CategoryStat: Codable, Hashable, Identifiable {
    var id: Int { categoryId }
    let categoryId: Int
    let name: String
    let icon: String
    let colorHex: String
    let answered: Int
    let correct: Int
    let quizzes: Int
    let xp: Int
    let accuracy: Double
    let subcategoriesTotal: Int
    let subcategoriesPlayed: Int
}

struct CategoryRef: Codable, Hashable {
    let categoryId: Int
    let name: String
    let accuracy: Double
}

struct DailyStat: Codable, Hashable, Identifiable {
    var id: String { day }
    let day: String
    let answered: Int
    let correct: Int
    let xp: Int
}

struct SeasonResult: Codable, Hashable, Identifiable {
    var id: Int { seasonId }
    let seasonId: Int
    let name: String?
    let finalLeagueId: Int
    let highestLeagueId: Int
    let totalLp: Int
    let promotions: Int
    let relegations: Int
    let quizzes: Int
    let xpEarned: Int
    let rewardBadge: String?
}

struct ReviewSummary: Codable, Hashable {
    let due: Int
    let scheduled: Int
    let mastered: Int
    let nextDueAt: String?
}

struct Stats: Codable {
    let answered: Int
    let correct: Int
    let quizzes: Int
    let perfectQuizzes: Int
    let avgTimeMs: Double?
    let currentStreak: Int
    let bestStreak: Int
    let currentAnswerStreak: Int
    let bestAnswerStreak: Int
    let categories: [CategoryStat]
    let bestCategory: CategoryRef?
    let worstCategory: CategoryRef?
    let daily: [DailyStat]
    let seasons: [SeasonResult]
    let reviews: ReviewSummary

    var accuracy: Double { answered > 0 ? Double(correct) / Double(answered) : 0 }
}

struct Mission: Codable, Hashable, Identifiable {
    let id: Int
    let code: String
    let period: String
    let title: String
    let description: String
    let icon: String
    let target: Int
    let xpReward: Int
    let lpReward: Int
    let progress: Int
    let completedAt: String?
    let resetsAt: String?

    var isCompleted: Bool { completedAt != nil || progress >= target }
}

struct SubcategoryRef: Codable, Hashable, Identifiable {
    let id: Int
    let slug: String
    let name: String
    let parentId: Int?
    let unlockCorrect: Int
}

struct CategoryInfo: Codable, Hashable, Identifiable {
    let id: Int
    let slug: String
    let name: String
    let icon: String
    let colorHex: String
    let description: String
    let questions: Int
    let answered: Int
    let correct: Int
    let subcategories: [SubcategoryRef]

    var accuracy: Double { answered > 0 ? Double(correct) / Double(answered) : 0 }
}

struct TreeNode: Codable, Hashable, Identifiable {
    let id: Int
    let slug: String
    let name: String
    let description: String
    let parentId: Int?
    let unlockCorrect: Int
    let unlocked: Bool
    let parentCorrect: Int
    let answered: Int
    let correct: Int
    let questions: Int
}

struct AchievementItem: Codable, Hashable, Identifiable {
    let id: Int
    let code: String
    let category: String
    let name: String
    let description: String
    let icon: String
    let rarity: String
    let tier: String
    let threshold: Int
    let xpReward: Int
    var unlockedAt: String?
}

struct CardItem: Codable, Hashable, Identifiable {
    let id: Int
    let code: String
    let name: String
    let description: String
    let kind: String
    let categoryId: Int
    let rarity: String
    let art: String
    let era: String?
    var copies: Int = 0
    var obtainedAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, code, name, description, kind, categoryId, rarity, art, era, obtainedAt
    }

    var kindName: String {
        switch kind {
        case "person": return "Postać"
        case "event": return "Wydarzenie"
        case "invention": return "Wynalazek"
        case "discovery": return "Odkrycie"
        case "artwork": return "Dzieło sztuki"
        case "place": return "Miejsce"
        default: return "Pojęcie"
        }
    }
}

struct DatedLabel: Codable, Hashable { let date: String; let label: String }
struct TermDef: Codable, Hashable { let term: String; let definition: String }

struct Article: Codable, Hashable, Identifiable {
    let id: Int
    let slug: String
    let categoryId: Int
    let subcategoryId: Int?
    let title: String
    let summary: String
    let body: String
    let keyFacts: [String]
    let dates: [DatedLabel]
    let terms: [TermDef]
    let relatedSlugs: [String]
    let sources: [SourceRef]
}

struct AppNotification: Codable, Hashable, Identifiable {
    let id: Int
    let kind: String
    let title: String
    let body: String
    let readAt: String?
    let createdAt: String
}

struct ProfileUpdate: Encodable {
    var displayName: String?
    var avatar: String?
    var avatarColor: String?
    var frame: String?
    var background: String?
    var selectedTitle: String?
    var bio: String?
    var notifications: [String: Bool]?
}

struct AIGenerationResult: Codable {
    let ready: Bool
    let reused: Int?
    let generated: Int?
    let accepted: Int?
    let sentToReview: Int?
    let aiConfigured: Bool
    let message: String?
    let note: String?
}

struct MentorPlanItem: Codable, Hashable { let day: String; let task: String }
struct MentorSuggestion: Codable, Hashable {
    let categoryId: Int
    let subcategoryId: Int?
    let difficulty: Int
    let mode: String
    let reason: String
}

struct MentorReply: Codable {
    let reply: String
    let weakPoints: [String]
    let plan: [MentorPlanItem]
    let suggestions: [MentorSuggestion]
    var offline: Bool? = nil
}

struct AttemptReviewItem: Codable, Hashable, Identifiable {
    var id: String { questionId }
    struct Option: Codable, Hashable { let id: String; let body: String; let isCorrect: Bool }
    let questionId: String
    let prompt: String
    let explanation: String
    let yourAnswerId: String?
    let isCorrect: Bool
    let timeMs: Int
    let answers: [Option]
    let articleSlug: String?
}

// MARK: - Daty

enum QVDate {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let warsaw = TimeZone(identifier: "Europe/Warsaw") ?? .current

    static func parse(_ s: String?) -> Date? {
        guard var s else { return nil }
        if s.count == 10 { // yyyy-MM-dd
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = warsaw; f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: s)
        }
        s = s.replacingOccurrences(of: " ", with: "T")
        if let d = isoFrac.date(from: s) ?? iso.date(from: s) { return d }
        // Postgres zwraca do 6 cyfr ułamka i strefę "+00:00" – przytnij ułamek do 3 cyfr
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s[s.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            let rest = afterDot.dropFirst(digits.count)
            let trimmed = String(s[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
            return isoFrac.date(from: trimmed)
        }
        return nil
    }

    static func string(_ d: Date) -> String { isoFrac.string(from: d) }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = warsaw; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }

    static func short(_ s: String?) -> String {
        guard let d = parse(s) else { return "" }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "pl_PL"); f.timeZone = warsaw
        return f.string(from: d)
    }
}
