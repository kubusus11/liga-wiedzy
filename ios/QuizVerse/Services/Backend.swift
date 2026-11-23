import Foundation

/// Konfiguracja z Info.plist (wartości z Config/Secrets.xcconfig). Brak kluczy = tryb demo.
enum AppConfig {
    static var supabaseURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              !s.isEmpty, !s.contains("$("), let url = URL(string: s), url.host != nil else { return nil }
        return url
    }
    static var supabaseAnonKey: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              !s.isEmpty, !s.contains("$(") else { return nil }
        return s
    }
    static var isBackendConfigured: Bool { supabaseURL != nil && supabaseAnonKey != nil }
}

struct BackendError: LocalizedError, Equatable {
    let code: String
    var detail: String? = nil

    var errorDescription: String? {
        switch code {
        case "not_authenticated": return "Sesja wygasła. Zaloguj się ponownie."
        case "invalid_credentials", "invalid_grant": return "Nieprawidłowy e-mail lub hasło."
        case "user_already_exists": return "Konto z tym adresem e-mail już istnieje."
        case "weak_password": return "Hasło jest za słabe (min. 8 znaków)."
        case "email_not_confirmed": return "Potwierdź adres e-mail, klikając link w wiadomości."
        case "daily_already_played": return "Quiz dnia został już dziś rozwiązany. Wróć jutro!"
        case "not_enough_questions": return "Za mało pytań w tej kategorii. Wybierz inny poziom lub kategorię."
        case "no_reviews_due": return "Brak pytań do powtórki – świetna robota!"
        case "subcategory_locked": return "Ta specjalizacja jest jeszcze zablokowana w drzewku wiedzy."
        case "category_required": return "Wybierz kategorię."
        case "attempt_closed", "attempt_expired": return "Ten quiz został już zakończony."
        case "ai_not_configured": return "Generator AI nie jest skonfigurowany na serwerze."
        case "ai_daily_limit": return "Dzienny limit generowania pytań AI został wykorzystany."
        case "mentor_daily_limit": return "Dzienny limit rozmów z Mentorem został wykorzystany."
        case "ai_refused": return "AI odmówiło przygotowania tych pytań. Spróbuj innego tematu."
        case "frame_locked", "background_locked", "title_locked": return "Ten element personalizacji jest jeszcze zablokowany."
        case "network": return "Brak połączenia z serwerem."
        case "question_not_answered": return "Możesz zgłosić tylko pytanie, na które odpowiadałeś."
        default: return detail ?? "Wystąpił błąd (\(code))."
        }
    }
}

/// Wspólny interfejs backendu: Supabase (produkcja) lub lokalny tryb demonstracyjny.
protocol GameBackend: AnyObject {
    var isDemo: Bool { get }
    var isSignedIn: Bool { get }

    // Konto
    func restoreSession() async -> Bool
    func signUp(email: String, password: String, username: String) async throws -> Bool // true = zalogowano od razu
    func signIn(email: String, password: String) async throws
    func resetPassword(email: String) async throws
    func signOut() async
    func deleteAccount() async throws

    // Quizy
    func categories() async throws -> [CategoryInfo]
    func knowledgeTree(categoryId: Int) async throws -> [TreeNode]
    func startQuiz(_ request: QuizRequest) async throws -> QuizSession
    func submitAnswer(attemptId: String, questionId: String, answerId: String?, timeMs: Int) async throws -> AnswerResult
    func finishQuiz(attemptId: String) async throws -> QuizResult
    func attemptReview(attemptId: String) async throws -> [AttemptReviewItem]
    func reportQuestion(questionId: String, reason: String, comment: String?) async throws
    func generateAIQuestions(categoryId: Int, subcategoryId: Int?, difficulty: Int, count: Int) async throws -> AIGenerationResult

    // Gracz i progresja
    func player() async throws -> Player
    func updateProfile(_ update: ProfileUpdate) async throws
    func leagueOverview() async throws -> LeagueOverview
    func leaderboard(kind: String, categoryId: Int?) async throws -> Leaderboard
    func stats() async throws -> Stats
    func missions() async throws -> [Mission]
    func achievements() async throws -> [AchievementItem]
    func cards() async throws -> [CardItem]

    // Encyklopedia, mentor, powiadomienia
    func articles() async throws -> [Article]
    func favoriteArticleIds() async throws -> Set<Int>
    func toggleFavorite(articleId: Int) async throws -> Bool
    func mentor(message: String) async throws -> MentorReply
    func notifications() async throws -> [AppNotification]
    func markNotificationsRead() async throws
    func registerDeviceToken(_ token: String) async throws
}

extension JSONDecoder {
    static let qv: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension JSONEncoder {
    static let qv: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
