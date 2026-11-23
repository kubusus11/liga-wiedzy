import SwiftUI

struct LeaguesView: View {
    enum Pane: String, CaseIterable { case group = "Moja grupa", rankings = "Rankingi", history = "Historia" }

    @Environment(AppState.self) private var app
    @State private var section: Pane = .group
    @State private var overview: Loadable<LeagueOverview> = .idle
    @State private var showRules = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Sekcja", selection: $section) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch section {
                case .group: groupSection
                case .rankings: RankingsSection()
                case .history: HistorySection(overview: overview.value)
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Ligi")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showRules = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Zasady lig")
            }
        }
        .sheet(isPresented: $showRules) { LeagueRulesSheet() }
        .task(id: app.refreshToken) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if overview.value == nil { overview = .loading }
        do { overview = .loaded(try await app.backend.leagueOverview()) } catch { overview = .failed(app.message(for: error)) }
    }

    @ViewBuilder private var groupSection: some View {
        switch overview {
        case .idle, .loading: LoadingView()
        case .failed(let e): ErrorBanner(message: e) { Task { await load() } }
        case .loaded(let o):
            LeagueLadder(current: o.league.id, leagues: app.content.allLeagues)
            leagueHeader(o)
            if !o.joined || o.standings.isEmpty {
                EmptyStateView(icon: "person.3.fill", title: "Nie jesteś jeszcze w grupie",
                               message: "Rozwiąż dowolny quiz punktowany (np. szybki quiz), aby dołączyć do tygodniowej grupy 30 graczy.")
                    .glassCard()
                Button("Zagraj szybki quiz") { app.startQuiz(QuizRequest(mode: .quick, count: 10)) }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                standings(o)
            }
        }
    }

    private func leagueHeader(_ o: LeagueOverview) -> some View {
        let me = o.standings.first { $0.isMe }
        let color = Color(hex: o.league.colorHex)
        return VStack(spacing: 12) {
            HStack(spacing: 16) {
                LeagueEmblem(league: o.league, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIGA \(o.league.name.uppercased())").font(.system(.title3, design: .rounded).weight(.black)).foregroundStyle(color)
                    Text(o.league.description).font(.caption).foregroundStyle(QV.textSecondary).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                StatPill(icon: "number", value: me.map { "#\($0.rank)" } ?? "—", label: "Miejsce", color: color)
                StatPill(icon: "trophy.fill", value: "\(me?.lp ?? 0)", label: "LP w tygodniu", color: QV.gold)
                StatPill(icon: "clock.fill", value: QVDate.countdown(to: QVDate.parse(o.weekEndsAt)), label: "Do końca", color: QV.blue)
            }
        }
        .glassCard(glow: color)
    }

    private func standings(_ o: LeagueOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Grupa tygodnia", subtitle: zonesLegend(o))
            if app.isDemo {
                Label("Rywale w trybie demonstracyjnym są symulowani lokalnie.", systemImage: "flask.fill")
                    .font(.caption).foregroundStyle(QV.gold)
            }
            VStack(spacing: 0) {
                ForEach(o.standings) { s in
                    if s.rank == o.zones.promotionMax + 1 && o.zones.promotionMax > 0 {
                        zoneDivider("Strefa awansu ↑", QV.teal)
                    }
                    if s.rank == o.zones.relegationMin && o.zones.relegationMin <= 30 {
                        zoneDivider("Strefa spadku ↓", QV.red)
                    }
                    StandingRow(standing: s, zones: o.zones)
                }
            }
            .glassCard(padding: 6)
        }
    }

    private func zonesLegend(_ o: LeagueOverview) -> String {
        var parts: [String] = []
        if o.zones.promotionMax > 0 { parts.append("1–\(o.zones.promotionMax) awans") }
        parts.append("utrzymanie")
        if o.zones.relegationMin <= 30 { parts.append("\(o.zones.relegationMin)–30 spadek") }
        return parts.joined(separator: " · ")
    }

    private func zoneDivider(_ text: String, _ color: Color) -> some View {
        HStack {
            Rectangle().fill(color.opacity(0.5)).frame(height: 1)
            Text(text).font(.caption2.weight(.heavy)).foregroundStyle(color)
            Rectangle().fill(color.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
    }
}

struct StandingRow: View {
    let standing: Standing
    let zones: LeagueZones

    private var zoneColor: Color {
        if standing.rank <= zones.promotionMax { return QV.teal }
        if standing.rank >= zones.relegationMin { return QV.red }
        return QV.textSecondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(standing.rank)")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .foregroundStyle(zoneColor)
                .frame(width: 28)
            AvatarView(symbol: standing.avatar, colorHex: standing.avatarColor, frame: standing.frame ?? "none", size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(standing.username).font(.subheadline.weight(standing.isMe ? .heavy : .medium))
                    .foregroundStyle(standing.isMe ? QV.blue : .white).lineLimit(1)
                Text("Poziom \(standing.level)").font(.caption2).foregroundStyle(QV.textSecondary)
            }
            Spacer()
            Text("\(standing.lp) LP").font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(QV.gold)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(standing.isMe ? QV.violet.opacity(0.22) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Miejsce \(standing.rank), \(standing.username), \(standing.lp) punktów ligowych\(standing.isMe ? ", to ty" : "")")
    }
}

struct LeagueLadder: View {
    let current: Int
    let leagues: [League]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(leagues) { l in
                VStack(spacing: 6) {
                    LeagueEmblem(league: l, size: l.id == current ? 46 : 32)
                        .opacity(l.id <= current ? 1 : 0.35)
                    Text(l.name).font(.caption2.weight(l.id == current ? .heavy : .regular))
                        .foregroundStyle(l.id == current ? .white : QV.textSecondary)
                }
                .frame(maxWidth: .infinity)
                if l.id < leagues.count {
                    Rectangle().fill(l.id < current ? QV.violet : QV.stroke).frame(width: 10, height: 2).padding(.bottom, 18)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Twoja liga: \(leagues.first { $0.id == current }?.name ?? "")")
    }
}

// MARK: - Rankingi

struct RankingsSection: View {
    enum Kind: String, CaseIterable { case weekly, global, season, category, activity
        var title: String {
            switch self {
            case .weekly: return "Tydzień"
            case .global: return "Globalny"
            case .season: return "Sezon"
            case .category: return "Kategoria"
            case .activity: return "Aktywność"
            }
        }
        var valueLabel: String {
            switch self {
            case .weekly: return "LP"
            case .global: return "XP"
            case .season: return "LP"
            case .category: return "trafień"
            case .activity: return "quizów"
            }
        }
        var explanation: String {
            switch self {
            case .weekly: return "Punkty ligowe w bieżącym tygodniu w Twojej grupie."
            case .global: return "Łączne doświadczenie wszystkich graczy."
            case .season: return "Suma LP zdobytych w bieżącym sezonie."
            case .category: return "Poprawne odpowiedzi w wybranej kategorii."
            case .activity: return "Ukończone quizy w ostatnich 7 dniach."
            }
        }
    }

    @Environment(AppState.self) private var app
    @State private var kind: Kind = .weekly
    @State private var categoryId = 1
    @State private var board: Loadable<Leaderboard> = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChipRow(items: Kind.allCases, selection: $kind) { $0.title }
            if kind == .category {
                Picker("Kategoria", selection: $categoryId) {
                    ForEach(app.content.categories, id: \.id) { c in Text(c.name).tag(c.id) }
                }
                .pickerStyle(.menu)
                .tint(QV.blue)
            }
            Text(kind.explanation).font(.caption).foregroundStyle(QV.textSecondary)

            switch board {
            case .idle, .loading: LoadingView()
            case .failed(let e): ErrorBanner(message: e) { Task { await load() } }
            case .loaded(let b):
                if let me = b.me {
                    HStack {
                        Text("Twoja pozycja").font(.subheadline).foregroundStyle(QV.textSecondary)
                        Spacer()
                        Text("#\(me.rank) · \(Fmt.number(me.value)) \(kind.valueLabel)")
                            .font(.subheadline.weight(.heavy)).foregroundStyle(QV.blue)
                    }
                    .glassCard(padding: 12, glow: QV.blue)
                }
                if b.rows.isEmpty {
                    EmptyStateView(icon: "list.number", title: "Ranking jest pusty", message: "Rozwiąż quiz, aby pojawić się w rankingu.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(b.rows) { r in
                            HStack(spacing: 12) {
                                Text("\(r.rank)").font(.subheadline.weight(.heavy))
                                    .foregroundStyle(r.rank <= 3 ? QV.gold : QV.textSecondary).frame(width: 34)
                                AvatarView(symbol: r.avatar, colorHex: r.avatarColor, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.username).font(.subheadline.weight(r.isMe ? .heavy : .medium))
                                        .foregroundStyle(r.isMe ? QV.blue : .white).lineLimit(1)
                                    Text("Poz. \(r.level) · \(app.league(r.leagueId).name)").font(.caption2).foregroundStyle(QV.textSecondary)
                                }
                                Spacer()
                                Text("\(Fmt.number(r.value)) \(kind.valueLabel)").font(.subheadline.weight(.bold)).foregroundStyle(QV.gold)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(r.isMe ? QV.violet.opacity(0.22) : .clear))
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .glassCard(padding: 6)
                    if app.isDemo && kind != .weekly {
                        Text("W trybie demonstracyjnym rankingi globalne zawierają tylko Ciebie – pełne rankingi wymagają backendu.")
                            .font(.caption).foregroundStyle(QV.gold)
                    }
                }
            }
        }
        .task(id: "\(kind.rawValue)-\(categoryId)-\(app.refreshToken)") { await load() }
    }

    private func load() async {
        board = .loading
        do { board = .loaded(try await app.backend.leaderboard(kind: kind.rawValue, categoryId: kind == .category ? categoryId : nil)) }
        catch { board = .failed(app.message(for: error)) }
    }
}

// MARK: - Historia lig i sezonów

struct HistorySection: View {
    let overview: LeagueOverview?
    @Environment(AppState.self) private var app
    @State private var seasons: [SeasonResult] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Ostatnie tygodnie")
            if let history = overview?.history, !history.isEmpty {
                ForEach(history) { h in
                    HStack(spacing: 12) {
                        Image(systemName: icon(h.outcome)).font(.title3).foregroundStyle(color(h.outcome)).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tydzień od \(QVDate.short(h.weekStart))").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text("\(app.league(h.leagueId).name) · miejsce \(h.rank) · \(h.lp) LP")
                                .font(.caption).foregroundStyle(QV.textSecondary)
                        }
                        Spacer()
                        Text(label(h.outcome)).font(.caption.weight(.heavy)).foregroundStyle(color(h.outcome))
                    }
                    .glassCard(padding: 12)
                }
            } else {
                EmptyStateView(icon: "clock.arrow.circlepath", title: "Brak historii", message: "Wyniki pojawią się po zakończeniu pierwszego tygodnia ligowego.")
            }

            SectionHeader(title: "Sezony", subtitle: "8 tygodni · nagrody za najwyższą ligę")
            if seasons.isEmpty {
                Text("Pierwszy sezon w toku. Po jego zakończeniu otrzymasz odznakę i bonus XP zależny od najwyższej osiągniętej ligi.")
                    .font(.footnote).foregroundStyle(QV.textSecondary).glassCard(padding: 12)
            } else {
                ForEach(seasons) { s in SeasonResultRow(result: s) }
            }
        }
        .task(id: app.refreshToken) {
            seasons = (try? await app.backend.stats().seasons) ?? []
        }
    }

    private func icon(_ o: String) -> String { o == "promoted" ? "arrow.up.circle.fill" : o == "relegated" ? "arrow.down.circle.fill" : "equal.circle.fill" }
    private func color(_ o: String) -> Color { o == "promoted" ? QV.teal : o == "relegated" ? QV.red : QV.blue }
    private func label(_ o: String) -> String { o == "promoted" ? "AWANS" : o == "relegated" ? "SPADEK" : "UTRZYMANIE" }
}

struct SeasonResultRow: View {
    let result: SeasonResult
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            LeagueEmblem(league: app.league(result.highestLeagueId), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name ?? "Sezon \(result.seasonId)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                Text("Najwyżej: \(app.league(result.highestLeagueId).name) · koniec: \(app.league(result.finalLeagueId).name)")
                    .font(.caption).foregroundStyle(QV.textSecondary)
                Text("\(result.totalLp) LP · \(result.quizzes) quizów · ↑\(result.promotions) ↓\(result.relegations)")
                    .font(.caption2).foregroundStyle(QV.textSecondary)
            }
            Spacer()
            RewardBadge(text: "+\(result.xpEarned) XP", color: QV.violet, icon: "sparkle")
        }
        .glassCard(padding: 12)
    }
}

struct LeagueRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LeagueRulesContent()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Gotowe") { dismiss() } } }
        }
    }
}

struct LeagueRulesContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LeagueLadder(current: 5, leagues: app.content.allLeagues)
                    rule("person.3.fill", "Grupy po 30 graczy", "Co tydzień trafiasz do grupy 30 graczy z tej samej ligi.")
                    rule("calendar", "Tydzień = 7 dni", "Tydzień ligowy trwa od poniedziałku 00:00 do niedzieli 23:59 (czas polski). Punkty LP zerują się co tydzień.")
                    rule("arrow.up.circle.fill", "Miejsca 1–10: awans", "Najlepsza dziesiątka awansuje o jedną ligę (wymagane min. 1 LP). Z Legendy nie ma awansu.")
                    rule("equal.circle.fill", "Miejsca 11–23: utrzymanie", "Zostajesz w obecnej lidze.")
                    rule("arrow.down.circle.fill", "Miejsca 24–30: spadek", "Ostatnie siedem miejsc spada o jedną ligę. Z Brązu nie można spaść.")
                    rule("trophy.fill", "Punkty LP", "Quiz 5 pytań: 10 LP · 10 pytań: 20 LP · 20 pytań: 40 LP · quiz dnia: 25 LP · maraton: 10 LP za każde 5 pytań · misja tygodniowa: 30 LP.")
                    rule("shield.lefthalf.filled", "Fair play", "LP wymaga min. 40% skuteczności. Dzienny limit to 300 LP. Zbyt szybkie, zautomatyzowane odpowiedzi blokują nagrody. XP nigdy nie zamienia się w LP.")
                    rule("calendar.badge.clock", "Sezony", "Sezon trwa 8 tygodni. Na koniec otrzymujesz odznakę sezonu i bonus XP za najwyższą osiągniętą ligę.")
                }
                .padding(20)
            }
            .screenChrome("Zasady lig")
    }

    private func rule(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(QV.violet).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(text).font(.subheadline).foregroundStyle(QV.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}
