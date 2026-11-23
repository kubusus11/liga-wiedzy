import SwiftUI

/// Tło nagłówka profilu (kosmetyk odblokowywany poziomem lub ligą).
struct ProfileBackdrop: View {
    let code: String
    var body: some View {
        switch code {
        case "galaxy":
            LinearGradient(colors: [Color(hex: "#1E1B4B"), Color(hex: "#7C3AED"), Color(hex: "#0EA5E9")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "aurora":
            LinearGradient(colors: [Color(hex: "#064E3B"), Color(hex: "#2DD4BF"), Color(hex: "#7C3AED")], startPoint: .bottomLeading, endPoint: .topTrailing)
        case "blackhole":
            RadialGradient(colors: [.black, Color(hex: "#F97316").opacity(0.7), Color(hex: "#1E1B4B")], center: .center, startRadius: 10, endRadius: 220)
        case "goldendust":
            LinearGradient(colors: [Color(hex: "#422006"), QV.gold.opacity(0.85), Color(hex: "#1C1917")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "legendvoid":
            AngularGradient(colors: [QV.violetDeep, .black, QV.gold.opacity(0.6), .black, QV.violetDeep], center: .center)
        default:
            LinearGradient(colors: [QV.violetDeep, Color(hex: "#312E81"), QV.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct ProfileView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let p = app.player {
                    header(p)
                    statsRow(p)
                    badges(p)
                    topCategories(p)
                    links
                } else {
                    LoadingView()
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Profil")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Ustawienia")
            }
        }
        .task(id: app.refreshToken) { await app.refreshPlayer() }
        .refreshable { await app.refreshPlayer() }
    }

    private func header(_ p: Player) -> some View {
        let league = app.league(p.leagueId)
        return VStack(spacing: 10) {
            AvatarView(symbol: p.avatar, colorHex: p.avatarColor, frame: p.frame, size: 92)
                .padding(.top, 22)
            Text(p.displayName?.isEmpty == false ? p.displayName! : p.username)
                .font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(.white)
            Text("@\(p.username)").font(.caption).foregroundStyle(.white.opacity(0.7))
            Text(p.title.uppercased()).font(.caption.weight(.heavy)).tracking(1.6).foregroundStyle(QV.gold)
            if let bio = p.bio, !bio.isEmpty {
                Text(bio).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).padding(.horizontal)
            }
            HStack(spacing: 10) {
                RewardBadge(text: "Poziom \(p.level)", color: QV.blue, icon: "star.fill")
                RewardBadge(text: league.name, color: Color(hex: league.colorHex), icon: league.emblem)
                RewardBadge(text: "\(p.currentStreak) dni", color: QV.gold, icon: "flame.fill")
            }
            ProgressBar(value: p.levelProgress, height: 8).padding(.horizontal, 24)
            Text("\(Fmt.number(p.xp)) XP" + (p.levelXpNext.map { " · do następnego poziomu \(Fmt.number($0 - p.xp))" } ?? ""))
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
            NavigationLink { CustomizeProfileView() } label: {
                Label("Personalizuj profil", systemImage: "paintbrush.fill").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(QV.blue)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(ProfileBackdrop(code: p.background).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.15)))
    }

    private func statsRow(_ p: Player) -> some View {
        HStack(spacing: 8) {
            StatPill(icon: "list.bullet.rectangle.fill", value: Fmt.number(p.stats.quizzes), label: "Quizy", color: QV.violet)
            StatPill(icon: "checkmark.seal.fill", value: Fmt.number(p.stats.correct), label: "Poprawne", color: QV.teal)
            StatPill(icon: "rectangle.stack.fill", value: "\(p.stats.cards)", label: "Karty", color: QV.blue)
            StatPill(icon: "medal.fill", value: "\(p.stats.achievements)", label: "Odznaki", color: QV.gold)
        }
    }

    @ViewBuilder private func badges(_ p: Player) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Odznaki", subtitle: p.badges.isEmpty ? "Odblokuj osiągnięcia, aby zdobyć odznaki" : nil) {
                app.tab = .missions
            }
            if !p.badges.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(p.badges) { b in
                            VStack(spacing: 6) {
                                Image(systemName: b.icon).font(.title2).foregroundStyle(QV.tierColor(b.tier))
                                    .frame(width: 52, height: 52)
                                    .background(Circle().fill(QV.tierColor(b.tier).opacity(0.15)))
                                    .overlay(Circle().stroke(QV.tierColor(b.tier).opacity(0.6)))
                                Text(b.name).font(.caption2).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
                                    .frame(width: 76)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func topCategories(_ p: Player) -> some View {
        if !p.topCategories.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Ulubione dziedziny")
                ForEach(p.topCategories) { c in
                    HStack(spacing: 12) {
                        CategoryIcon(icon: c.icon, colorHex: c.colorHex, size: 36)
                        Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        Text("\(c.correct) · \(Fmt.percent(c.accuracy))").font(.caption.bold()).foregroundStyle(QV.teal)
                    }
                }
            }
            .glassCard()
        }
    }

    private var links: some View {
        VStack(spacing: 10) {
            navRow("Kolekcja kart", "rectangle.stack.fill", QV.blue) { CardsCollectionView() }
            navRow("Historia sezonów i lig", "calendar.badge.clock", QV.gold) { SeasonHistoryView() }
            navRow("Encyklopedia i ulubione", "books.vertical.fill", QV.violet) { EncyclopediaView() }
            navRow("Mentor AI", "graduationcap.fill", QV.teal) { MentorView() }
            navRow("Powiadomienia", "bell.fill", QV.blue) { NotificationsView() }
            navRow("Ustawienia i konto", "gearshape.fill", QV.textSecondary) { SettingsView() }
        }
    }

    private func navRow<D: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 26)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(QV.textSecondary)
            }
            .glassCard(padding: 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Historia sezonów

struct SeasonHistoryView: View {
    @Environment(AppState.self) private var app
    @State private var overview: LeagueOverview?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = app.player?.season {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.name.uppercased()).font(.caption.weight(.heavy)).tracking(1.4).foregroundStyle(QV.blue)
                        Text("Tydzień \(min(s.week, 8)) z 8").font(.title3.weight(.bold)).foregroundStyle(.white)
                        ProgressBar(value: Double(min(s.week, 8)) / 8)
                        Text("\(QVDate.short(s.startsAt)) – \(QVDate.short(s.endsAt))").font(.caption).foregroundStyle(QV.textSecondary)
                    }
                    .glassCard(glow: QV.blue)
                }
                HistorySection(overview: overview)
            }
            .padding(16)
        }
        .screenChrome("Sezony")
        .task { overview = try? await app.backend.leagueOverview() }
    }
}

// MARK: - Karty kolekcjonerskie

struct CollectibleCardView: View {
    let name: String
    let description: String
    let rarity: String
    let art: String
    let kind: String
    let categoryId: Int
    var owned: Bool
    var copies: Int = 1
    var era: String? = nil
    @Environment(AppState.self) private var app

    var body: some View {
        let color = QV.rarityColor(rarity)
        let cat = app.category(categoryId)
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(hex: cat?.colorHex ?? "#8B5CF6").opacity(0.55), QV.surface],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: owned ? art : "questionmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(owned ? .white : QV.textSecondary)
                    .shadow(color: color, radius: owned ? 10 : 0)
            }
            .frame(height: 96)
            Text(owned ? name : "???").font(.caption.weight(.heavy)).foregroundStyle(.white).lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
            Text(QV.rarityName(rarity).uppercased()).font(.system(size: 8, weight: .heavy)).tracking(1).foregroundStyle(color)
            if owned, copies > 1 {
                Text("×\(copies)").font(.caption2.bold()).foregroundStyle(QV.gold)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16).fill(QV.surfaceHigh))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(owned ? AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.2)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(QV.stroke), lineWidth: owned ? 2 : 1))
        .opacity(owned ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(owned ? "Karta \(name), \(QV.rarityName(rarity))" : "Nieodkryta karta")
    }
}

struct CardsCollectionView: View {
    @Environment(AppState.self) private var app
    @State private var cards: Loadable<[CardItem]> = .idle
    @State private var filter = "all"
    @State private var selected: CardItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Karty zdobywasz wyłącznie grą: za perfekcyjne quizy, awanse, misje i serie. Nie można ich kupić.")
                    .font(.footnote).foregroundStyle(QV.textSecondary)
                switch cards {
                case .idle, .loading: LoadingView()
                case .failed(let e): ErrorBanner(message: e)
                case .loaded(let list):
                    let owned = list.filter { $0.copies > 0 }.count
                    HStack {
                        Text("Zebrane: \(owned) / \(list.count)").font(.headline).foregroundStyle(.white)
                        Spacer()
                    }
                    ProgressBar(value: Double(owned) / Double(max(1, list.count)))
                    ChipRow(items: ["all", "owned", "legendary", "epic", "rare", "common"], selection: $filter) { f in
                        switch f {
                        case "all": return "Wszystkie"
                        case "owned": return "Zdobyte"
                        default: return QV.rarityName(f)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(filtered(list)) { c in
                            Button { if c.copies > 0 { selected = c } } label: {
                                CollectibleCardView(name: c.name, description: c.description, rarity: c.rarity, art: c.art,
                                                    kind: c.kind, categoryId: c.categoryId, owned: c.copies > 0, copies: c.copies, era: c.era)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .screenChrome("Kolekcja kart")
        .sheet(item: $selected) { c in CardDetailView(card: c).presentationDetents([.medium, .large]) }
        .task {
            do { cards = .loaded(try await app.backend.cards()) } catch { cards = .failed(app.message(for: error)) }
        }
    }

    private func filtered(_ list: [CardItem]) -> [CardItem] {
        switch filter {
        case "all": return list
        case "owned": return list.filter { $0.copies > 0 }
        default: return list.filter { $0.rarity == filter }
        }
    }
}

struct CardDetailView: View {
    let card: CardItem
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                CollectibleCardView(name: card.name, description: card.description, rarity: card.rarity, art: card.art,
                                    kind: card.kind, categoryId: card.categoryId, owned: true, copies: card.copies)
                    .frame(width: 180).padding(.top, 24)
                Text(card.name).font(.title2.weight(.heavy)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    RewardBadge(text: card.kindName, color: QV.blue, icon: "tag.fill")
                    if let era = card.era { RewardBadge(text: era, color: QV.gold, icon: "clock.fill") }
                    if let c = app.category(card.categoryId) { RewardBadge(text: c.name, color: Color(hex: c.colorHex), icon: c.icon) }
                }
                Text(card.description).font(.body).foregroundStyle(QV.textSecondary).multilineTextAlignment(.center).padding(.horizontal)
                if let at = card.obtainedAt {
                    Text("Zdobyta \(QVDate.short(at))").font(.caption).foregroundStyle(QV.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(StarfieldBackground(intensity: 0.6))
    }
}
