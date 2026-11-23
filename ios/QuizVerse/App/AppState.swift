import SwiftUI
import Observation
import UserNotifications
import UIKit

enum AppPhase { case launching, onboarding, main }

enum AppTab: String, CaseIterable, Identifiable {
    case home, leagues, quizzes, stats, missions, profile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "START"
        case .leagues: return "LIGI"
        case .quizzes: return "QUIZY"
        case .stats: return "STATYSTYKI"
        case .missions: return "MISJE"
        case .profile: return "PROFIL"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .leagues: return "trophy.fill"
        case .quizzes: return "brain.head.profile"
        case .stats: return "chart.bar.xaxis"
        case .missions: return "target"
        case .profile: return "person.crop.circle.fill"
        }
    }
}

/// Uruchomienie quizu – prezentowane jako pełnoekranowa nakładka.
struct QuizLaunch: Identifiable {
    let id = UUID()
    let request: QuizRequest
}

/// Globalny stan aplikacji: wybrany backend (Supabase lub demo), sesja, gracz i nawigacja.
@MainActor
@Observable
final class AppState {
    let backend: GameBackend
    let content: ContentBundle

    var phase: AppPhase = .launching
    var tab: AppTab = .home
    var player: Player?
    var unreadNotifications = 0
    var activeQuiz: QuizLaunch?
    var toast: String?
    /// Zwiększane po każdym zakończonym quizie – ekrany obserwują i odświeżają dane.
    var refreshToken = 0

    var isDemo: Bool { backend.isDemo }

    init() {
        let content = ContentBundle.load()
        self.content = content
        if let url = AppConfig.supabaseURL, let key = AppConfig.supabaseAnonKey {
            backend = SupabaseBackend(url: url, anonKey: key)
        } else {
            backend = DemoBackend(content: content)
        }
    }

    // MARK: - Sesja

    func launch() async {
        let restored = await backend.restoreSession()
        if restored {
            await refreshPlayer()
            phase = player == nil ? .onboarding : .main
        } else {
            phase = .onboarding
        }
    }

    func didSignIn() async {
        await refreshPlayer()
        tab = .home
        phase = .main
        await registerForPushIfAllowed()
    }

    func signOut() async {
        await backend.signOut()
        player = nil
        phase = .onboarding
    }

    func refreshPlayer() async {
        do {
            player = try await backend.player()
            let notes = try await backend.notifications()
            unreadNotifications = notes.filter { $0.readAt == nil }.count
        } catch {
            _ = message(for: error)
        }
    }

    /// Zamienia błąd na komunikat; wygaśnięcie sesji przenosi do logowania.
    func message(for error: Error) -> String {
        if let e = error as? BackendError {
            if e.code == "not_authenticated" { player = nil; phase = .onboarding }
            return e.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: - Quizy

    func startQuiz(_ request: QuizRequest) {
        activeQuiz = QuizLaunch(request: request)
    }

    func quizDismissed() {
        refreshToken += 1
        Task { await refreshPlayer() }
    }

    /// Czy quiz dnia został już rozwiązany (zapamiętywane lokalnie; serwer i tak blokuje powtórkę).
    var dailyDoneToday: Bool {
        _ = refreshToken
        return UserDefaults.standard.string(forKey: dailyKey) == QVDate.dayString(Date())
    }

    func markDailyDone() {
        UserDefaults.standard.set(QVDate.dayString(Date()), forKey: dailyKey)
    }

    private var dailyKey: String { "qv.dailyDone.\(player?.id ?? "anon")" }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == text { toast = nil }
        }
    }

    // MARK: - Treści lokalne

    func category(_ id: Int) -> ContentBundle.CategoryDTO? { content.categories.first { $0.id == id } }
    func league(_ id: Int) -> League { content.league(id) }

    // MARK: - Powiadomienia push

    func requestPushPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    func registerForPushIfAllowed() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegisterDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard !isDemo, phase == .main else { return }
        Task { try? await backend.registerDeviceToken(hex) }
    }
}
