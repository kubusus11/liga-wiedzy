import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            NavigationStack { HomeView() }.tag(AppTab.home).toolbar(.hidden, for: .tabBar)
            NavigationStack { LeaguesView() }.tag(AppTab.leagues).toolbar(.hidden, for: .tabBar)
            NavigationStack { QuizHubView() }.tag(AppTab.quizzes).toolbar(.hidden, for: .tabBar)
            NavigationStack { StatsView() }.tag(AppTab.stats).toolbar(.hidden, for: .tabBar)
            NavigationStack { MissionsView() }.tag(AppTab.missions).toolbar(.hidden, for: .tabBar)
            NavigationStack { ProfileView() }.tag(AppTab.profile).toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SpaceTabBar(selection: $app.tab) }
        .fullScreenCover(item: $app.activeQuiz, onDismiss: { app.quizDismissed() }) { launch in
            QuizFlowView(request: launch.request)
                .environment(app)
        }
    }
}

/// Dolna nawigacja: 6 sekcji z podświetleniem aktywnej zakładki.
struct SpaceTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let active = tab == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if active {
                                Capsule().fill(QV.brandGradient)
                                    .frame(width: 44, height: 28)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                                    .shadow(color: QV.violet.opacity(0.7), radius: 8)
                            }
                            Image(systemName: tab.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(active ? .white : QV.textSecondary)
                        }
                        .frame(height: 28)
                        Text(tab.title)
                            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(active ? QV.blue : QV.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title.capitalized)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(
            QV.background.opacity(0.94)
                .overlay(alignment: .top) { Rectangle().fill(QV.stroke).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
