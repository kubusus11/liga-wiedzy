import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    var onDeviceToken: ((Data) -> Void)?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        onDeviceToken?(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Brak uprawnienia Push Notifications w profilu podpisywania – aplikacja działa dalej bez push.
    }
}

@main
struct QuizVerseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(QV.violet)
                .onAppear {
                    delegate.onDeviceToken = { [app] token in
                        Task { @MainActor in app.didRegisterDeviceToken(token) }
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching:
                SplashView()
            case .onboarding:
                OnboardingFlow()
                    .transition(.opacity)
            case .main:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: app.phase)
        .task { await app.launch() }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(QV.surfaceHigh).overlay(Capsule().stroke(QV.violet.opacity(0.5))))
                    .shadow(color: QV.violet.opacity(0.4), radius: 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: app.toast)
    }
}
