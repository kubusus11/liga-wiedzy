import Foundation
import Security

/// Backend produkcyjny: Supabase Auth (GoTrue), PostgREST (RPC + tabele z RLS) i Edge Functions.
/// Bez zewnętrznych zależności – czyste URLSession.
final class SupabaseBackend: GameBackend {
    let isDemo = false
    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private var auth: AuthSession? {
        didSet { Keychain.save(auth, key: "qv.auth") }
    }

    struct AuthSession: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
        var userId: String
    }

    init(url: URL, anonKey: String) {
        self.baseURL = url
        self.anonKey = anonKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        self.auth = Keychain.load(AuthSession.self, key: "qv.auth")
    }

    var isSignedIn: Bool { auth != nil }

    // MARK: - HTTP

    private enum Auth { case none, user }

    private func request(_ path: String, method: String = "POST", query: [URLQueryItem] = [],
                         body: Data? = nil, auth needsAuth: Auth = .user, extraHeaders: [String: String] = [:]) async throws -> Data {
        if needsAuth == .user { try await refreshIfNeeded() }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = needsAuth == .user ? (auth?.accessToken ?? anonKey) : anonKey
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        extraHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw BackendError(code: "network") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.parseError(data, status: status) }
        return data
    }

    private static func parseError(_ data: Data, status: Int) -> BackendError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // PostgREST: {"message": "daily_already_played", "code": "P0001"}; GoTrue: {"error_code": "...", "msg": "..."}
        // Edge Functions: {"error": "ai_daily_limit"}
        let code = (obj["error_code"] as? String) ?? (obj["error"] as? String) ?? (obj["message"] as? String)
            ?? (status == 401 ? "not_authenticated" : "http_\(status)")
        let detail = (obj["msg"] as? String) ?? (obj["message"] as? String) ?? (obj["error_description"] as? String)
        return BackendError(code: code, detail: detail)
    }

    private func rpc<T: Decodable>(_ name: String, _ params: [String: Any?] = [:]) async throws -> T {
        let clean = params.compactMapValues { $0 }
        let body = try JSONSerialization.data(withJSONObject: clean)
        let data = try await request("rest/v1/rpc/\(name)", body: body)
        return try JSONDecoder.qv.decode(T.self, from: data)
    }

    private func rpcVoid(_ name: String, _ params: [String: Any?] = [:]) async throws {
        let body = try JSONSerialization.data(withJSONObject: params.compactMapValues { $0 })
        _ = try await request("rest/v1/rpc/\(name)", body: body)
    }

    private func select<T: Decodable>(_ table: String, _ query: [String: String]) async throws -> [T] {
        let items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = try await request("rest/v1/\(table)", method: "GET", query: items)
        return try JSONDecoder.qv.decode([T].self, from: data)
    }

    private func function<T: Decodable>(_ name: String, _ body: [String: Any?]) async throws -> T {
        let data = try await request("functions/v1/\(name)", body: try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 }))
        return try JSONDecoder.qv.decode(T.self, from: data)
    }

    // MARK: - Auth

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let user: User?
        let id: String?
        struct User: Decodable { let id: String }
    }

    private func store(_ t: TokenResponse) -> Bool {
        guard let at = t.accessToken, let rt = t.refreshToken, let uid = t.user?.id else { return false }
        auth = AuthSession(accessToken: at, refreshToken: rt,
                           expiresAt: Date().timeIntervalSince1970 + (t.expiresIn ?? 3600), userId: uid)
        return true
    }

    private func refreshIfNeeded() async throws {
        guard let a = auth, Date().timeIntervalSince1970 > a.expiresAt - 60 else { return }
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": a.refreshToken])
        do {
            let data = try await request("auth/v1/token", query: [.init(name: "grant_type", value: "refresh_token")],
                                         body: body, auth: .none)
            _ = store(try JSONDecoder.qv.decode(TokenResponse.self, from: data))
        } catch let e as BackendError where e.code != "network" {
            auth = nil
            throw BackendError(code: "not_authenticated")
        }
    }

    func restoreSession() async -> Bool {
        guard auth != nil else { return false }
        do { try await refreshIfNeeded(); return auth != nil } catch { return false }
    }

    func signUp(email: String, password: String, username: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password, "data": ["username": username, "display_name": username],
        ])
        let data = try await request("auth/v1/signup", body: body, auth: .none)
        return store(try JSONDecoder.qv.decode(TokenResponse.self, from: data))
    }

    func signIn(email: String, password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let data = try await request("auth/v1/token", query: [.init(name: "grant_type", value: "password")], body: body, auth: .none)
        guard store(try JSONDecoder.qv.decode(TokenResponse.self, from: data)) else { throw BackendError(code: "invalid_credentials") }
    }

    func resetPassword(email: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email])
        _ = try await request("auth/v1/recover", body: body, auth: .none)
    }

    func signOut() async {
        _ = try? await request("auth/v1/logout", body: Data("{}".utf8))
        auth = nil
    }

    func deleteAccount() async throws {
        try await rpcVoid("delete_my_account")
        auth = nil
    }

    // MARK: - Quizy

    func categories() async throws -> [CategoryInfo] { try await rpc("get_categories") }

    func knowledgeTree(categoryId: Int) async throws -> [TreeNode] {
        try await rpc("get_knowledge_tree", ["p_category": categoryId])
    }

    func startQuiz(_ r: QuizRequest) async throws -> QuizSession {
        try await rpc("start_quiz", [
            "p_mode": r.mode.rawValue, "p_category": r.categoryId, "p_subcategory": r.subcategoryId,
            "p_difficulty": r.difficulty, "p_count": r.count, "p_time_limit": r.timeLimit,
        ])
    }

    func submitAnswer(attemptId: String, questionId: String, answerId: String?, timeMs: Int) async throws -> AnswerResult {
        try await rpc("submit_answer", ["p_attempt": attemptId, "p_question": questionId,
                                        "p_answer": answerId.map { $0 as Any } ?? NSNull(), "p_time_ms": timeMs])
    }

    func finishQuiz(attemptId: String) async throws -> QuizResult {
        try await rpc("finish_quiz", ["p_attempt": attemptId])
    }

    func attemptReview(attemptId: String) async throws -> [AttemptReviewItem] {
        try await rpc("get_attempt_review", ["p_attempt": attemptId])
    }

    func reportQuestion(questionId: String, reason: String, comment: String?) async throws {
        try await rpcVoid("report_question", ["p_question": questionId, "p_reason": reason, "p_comment": comment])
    }

    func generateAIQuestions(categoryId: Int, subcategoryId: Int?, difficulty: Int, count: Int) async throws -> AIGenerationResult {
        try await function("generate-questions", ["category_id": categoryId, "subcategory_id": subcategoryId,
                                                   "difficulty": difficulty, "count": count])
    }

    // MARK: - Gracz

    func player() async throws -> Player { try await rpc("get_player") }

    func updateProfile(_ update: ProfileUpdate) async throws {
        guard let uid = auth?.userId else { throw BackendError(code: "not_authenticated") }
        _ = try await request("rest/v1/profiles", method: "PATCH", query: [.init(name: "id", value: "eq.\(uid)")],
                              body: try JSONEncoder.qv.encode(update), extraHeaders: ["Prefer": "return=minimal"])
    }

    func leagueOverview() async throws -> LeagueOverview { try await rpc("get_league_overview") }

    func leaderboard(kind: String, categoryId: Int?) async throws -> Leaderboard {
        try await rpc("get_leaderboard", ["p_kind": kind, "p_category": categoryId, "p_limit": 50])
    }

    func stats() async throws -> Stats { try await rpc("get_my_stats") }
    func missions() async throws -> [Mission] { try await rpc("get_missions") }

    private struct UserAchievementRow: Decodable { let achievementId: Int; let unlockedAt: String }
    private struct UserCardRow: Decodable { let cardId: Int; let copies: Int; let obtainedAt: String }

    func achievements() async throws -> [AchievementItem] {
        async let all: [AchievementItem] = select("achievements", ["select": "id,code,category,name,description,icon,rarity,tier,threshold,xp_reward", "order": "id"])
        async let mine: [UserAchievementRow] = select("user_achievements", ["select": "achievement_id,unlocked_at"])
        let unlocked = Dictionary(uniqueKeysWithValues: try await mine.map { ($0.achievementId, $0.unlockedAt) })
        return try await all.map { var a = $0; a.unlockedAt = unlocked[a.id]; return a }
    }

    func cards() async throws -> [CardItem] {
        async let all: [CardItem] = select("collectible_cards", ["select": "id,code,name,description,kind,category_id,rarity,art,era", "order": "id"])
        async let mine: [UserCardRow] = select("user_cards", ["select": "card_id,copies,obtained_at"])
        let owned = Dictionary(uniqueKeysWithValues: try await mine.map { ($0.cardId, $0) })
        return try await all.map { c in
            var c = c
            if let o = owned[c.id] { c.copies = o.copies; c.obtainedAt = o.obtainedAt }
            return c
        }
    }

    // MARK: - Encyklopedia, mentor, powiadomienia

    func articles() async throws -> [Article] {
        try await select("knowledge_articles", ["select": "id,slug,category_id,subcategory_id,title,summary,body,key_facts,dates,terms,related_slugs,sources", "order": "title"])
    }

    private struct FavoriteRow: Decodable { let articleId: Int }
    func favoriteArticleIds() async throws -> Set<Int> {
        let rows: [FavoriteRow] = try await select("user_favorite_articles", ["select": "article_id"])
        return Set(rows.map(\.articleId))
    }

    func toggleFavorite(articleId: Int) async throws -> Bool {
        try await rpc("toggle_favorite_article", ["p_article": articleId])
    }

    func mentor(message: String) async throws -> MentorReply {
        try await function("ai-mentor", ["message": message])
    }

    func notifications() async throws -> [AppNotification] {
        try await select("notifications", ["select": "id,kind,title,body,read_at,created_at", "order": "created_at.desc", "limit": "50"])
    }

    func markNotificationsRead() async throws { try await rpcVoid("mark_notifications_read") }

    func registerDeviceToken(_ token: String) async throws {
        try await rpcVoid("register_device_token", ["p_token": token])
    }
}

/// Minimalny wrapper Keychain do przechowywania sesji.
enum Keychain {
    static func save<T: Encodable>(_ value: T?, key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
