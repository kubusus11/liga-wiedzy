import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var league: LeagueOverview?
    @State private var missions: [Mission] = []
    @State private var reviewsDue = 0
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let player = app.player {
                    header(player)
                    levelCard(player)
                    dailyCard
                    leagueCard(player)
                    quickActions
                    missionsPreview
                    seasonCard(player)
                } else if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                } else {
                    LoadingView()
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("QUIZVERSE")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { NotificationsView() } label: {
                    Image(systemName: app.unreadNotifications > 0 ? "bell.badge.fill" : "bell.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(app.unreadNotifications > 0 ? QV.gold : .white, .white)
                }
                .accessibilityLabel(app.unreadNotifications > 0 ? "Powiadomienia, \(app.unreadNotifications) nowych" : "Powiadomienia")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { EncyclopediaView() } label: { Image(systemName: "books.vertical.fill") }
                    .accessibilityLabel("Encyklopedia")
            }
        }
        .task(id: app.refreshToken) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await app.refreshPlayer()
        do {
            async let l = app.backend.leagueOverview()
            async let m = app.backend.missions()
            async let s = app.backend.stats()
            league = try await l
            missions = try await m
            reviewsDue = try await s.reviews.due
            error = nil
        } catch {
            self.error = app.message(for: error)
        }
    }

    // MARK: - Sekcje

    private func header(_ p: Player) -> some View {
        HStack(spacing: 14) {
            AvatarView(symbol: p.avatar, colorHex: p.avatarColor, frame: p.frame, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cześć, \(p.displayName?.isEmpty == false ? p.displayName! : p.username)!")
                    .font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(p.title.uppercased()).font(.caption.weight(.heavy)).tracking(1.4).foregroundStyle(QV.gold)
            }
            Spacer()
            VStack(spacing: 2) {
                Image(systemName: "flame.fill").font(.title2)
                    .foregroundStyle(p.currentStreak > 0 ? QV.gold : QV.textSecondary)
                Text("\(p.currentStreak)").font(.headline.weight(.heavy)).foregroundStyle(.white)
                Text("dni").font(.caption2).foregroundStyle(QV.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Seria: \(Fmt.plural(p.currentStreak, "dzień", "dni", "dni"))")
        }
    }

    private func levelCard(_ p: Player) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("POZIOM \(p.level)").font(.system(.headline, design: .rounded).weight(.black)).foregroundStyle(.white)
                Text(p.levelTitle).font(.subheadline).foregroundStyle(QV.blue)
                Spacer()
                Text("\(Fmt.number(p.xp)) XP").font(.subheadline.weight(.bold)).foregroundStyle(QV.gold)
            }
            ProgressBar(value: p.levelProgress)
            if let next = p.levelXpNext {
                Text("Do poziomu \(p.level + 1): \(Fmt.number(next - p.xp)) XP")
                    .font(.caption).foregroundStyle(QV.textSecondary)
            } else {
                Text("Maksymalny poziom osiągnięty!").font(.caption).foregroundStyle(QV.gold)
            }
        }
        .glassCard(glow: QV.violet)
    }

    private var dailyCard: some View {
        let dailyDone = app.dailyDoneToday
        return Button {
            app.startQuiz(QuizRequest(mode: .daily, count: 10))
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(QV.goldGradient).frame(width: 54, height: 54)
                    Image(systemName: dailyDone ? "checkmark" : "sun.max.fill").font(.title2.bold()).foregroundStyle(.black)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("QUIZ DNIA").font(.caption.weight(.heavy)).tracking(1.5).foregroundStyle(QV.gold)
                    Text(dailyDone ? "Rozwiązany – wróć jutro!" : "10 pytań z różnych dziedzin")
                        .font(.headline).foregroundStyle(.white)
                    HStack(spacing: 6) {
                        RewardBadge(text: "+25 XP", color: QV.violet, icon: "sparkle")
                        RewardBadge(text: "+25 LP", color: QV.gold, icon: "trophy.fill")
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(QV.textSecondary)
            }
            .glassCard(glow: QV.gold)
        }
        .buttonStyle(.plain)
        .disabled(dailyDone)
        .opacity(dailyDone ? 0.7 : 1)
    }

    private func leagueCard(_ p: Player) -> some View {
        let lg = league?.league ?? app.league(p.leagueId)
        let me = league?.standings.first { $0.isMe }
        return Button { app.tab = .leagues } label: {
            HStack(spacing: 16) {
                LeagueEmblem(league: lg, size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIGA \(lg.name.uppercased())").font(.caption.weight(.heavy)).tracking(1.5).foregroundStyle(Color(hex: lg.colorHex))
                    if let me {
                        Text("Miejsce \(me.rank) z \(league?.standings.count ?? 30) · \(me.lp) LP")
                            .font(.headline).foregroundStyle(.white)
                        Text(zoneText(rank: me.rank)).font(.caption).foregroundStyle(zoneColor(rank: me.rank))
                    } else {
                        Text("Zagraj quiz, aby dołączyć do grupy tygodnia").font(.subheadline).foregroundStyle(.white)
                    }
                    Text("Koniec tygodnia za \(QVDate.countdown(to: QVDate.parse(league?.weekEndsAt ?? p.weekEndsAt)))")
                        .font(.caption2).foregroundStyle(QV.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(QV.textSecondary)
            }
            .glassCard(glow: Color(hex: lg.colorHex))
        }
        .buttonStyle(.plain)
    }

    private func zoneText(rank: Int) -> String {
        guard let z = league?.zones else { return "" }
        if rank <= z.promotionMax { return "Strefa awansu" }
        if rank >= z.relegationMin { return "Strefa spadku" }
        return "Strefa utrzymania"
    }

    private func zoneColor(rank: Int) -> Color {
        guard let z = league?.zones else { return QV.textSecondary }
        if rank <= z.promotionMax { return QV.teal }
        if rank >= z.relegationMin { return QV.red }
        return QV.blue
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Graj teraz")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                actionTile("Szybki quiz", "10 pytań · 20 LP", "bolt.fill", QV.violet) {
                    app.startQuiz(QuizRequest(mode: .quick, count: 10))
                }
                actionTile("Powtórki", reviewsDue > 0 ? "\(reviewsDue) do powtórki" : "Brak zaległych", "arrow.triangle.2.circlepath", QV.teal) {
                    app.startQuiz(QuizRequest(mode: .review, count: 20))
                }
                NavigationLink { MentorView() } label: {
                    tileLabel("Mentor AI", "Plan nauki", "graduationcap.fill", QV.blue)
                }
                .buttonStyle(.plain)
                actionTile("Wszystkie tryby", "Maraton, sprint…", "square.grid.2x2.fill", QV.gold) {
                    app.tab = .quizzes
                }
            }
        }
    }

    private func actionTile(_ title: String, _ sub: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, sub, icon, color) }.buttonStyle(.plain)
    }

    private func tileLabel(_ title: String, _ sub: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
            Text(sub).font(.caption).foregroundStyle(QV.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14, glow: color)
    }

    private var missionsPreview: some View {
        let daily = missions.filter { $0.period == "daily" }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Misje dnia", subtitle: "\(daily.filter(\.isCompleted).count) z \(daily.count) ukończonych") {
                app.tab = .missions
            }
            ForEach(daily.prefix(3)) { m in MissionRow(mission: m) }
        }
    }

    private func seasonCard(_ p: Player) -> some View {
        Group {
            if let s = p.season {
                HStack {
                    Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(QV.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.name.uppercased()) · TYDZIEŃ \(min(s.week, 8)) Z 8").font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(QV.blue)
                        Text("Sezon kończy się za \(QVDate.countdown(to: QVDate.parse(s.endsAt)))").font(.subheadline).foregroundStyle(.white)
                    }
                    Spacer()
                }
                .glassCard()
            }
        }
    }
}
