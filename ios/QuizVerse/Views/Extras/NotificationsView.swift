import SwiftUI

struct NotificationsView: View {
    @Environment(AppState.self) private var app
    @State private var items: Loadable<[AppNotification]> = .idle

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                switch items {
                case .idle, .loading: LoadingView()
                case .failed(let e): ErrorBanner(message: e) { Task { await load() } }
                case .loaded(let list):
                    if list.isEmpty {
                        EmptyStateView(icon: "bell.slash", title: "Brak powiadomień",
                                       message: "Tu pojawią się wyniki tygodnia, awanse, nowe misje i osiągnięcia.")
                    }
                    ForEach(list) { n in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(n.kind)).font(.title3).foregroundStyle(color(n.kind)).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(n.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                Text(n.body).font(.caption).foregroundStyle(QV.textSecondary)
                                Text(QVDate.short(n.createdAt)).font(.caption2).foregroundStyle(QV.textSecondary.opacity(0.7))
                            }
                            Spacer()
                            if n.readAt == nil { Circle().fill(QV.violet).frame(width: 8, height: 8).accessibilityLabel("Nowe") }
                        }
                        .glassCard(padding: 12)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(16)
        }
        .screenChrome("Powiadomienia")
        .task { await load() }
    }

    private func load() async {
        if items.value == nil { items = .loading }
        do {
            items = .loaded(try await app.backend.notifications())
            try await app.backend.markNotificationsRead()
            app.unreadNotifications = 0
        } catch {
            items = .failed(app.message(for: error))
        }
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "league_result": return "trophy.fill"
        case "level_up": return "arrow.up.forward.circle.fill"
        case "achievement": return "medal.fill"
        case "mission": return "target"
        case "card": return "rectangle.stack.fill"
        case "season_end": return "calendar.badge.clock"
        case "report": return "flag.fill"
        default: return "bell.fill"
        }
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "level_up", "mission": return QV.teal
        case "achievement", "card", "season_end", "league_result": return QV.gold
        default: return QV.blue
        }
    }
}
