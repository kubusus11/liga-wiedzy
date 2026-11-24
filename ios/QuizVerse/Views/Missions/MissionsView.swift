import SwiftUI

struct MissionsView: View {
    enum Pane: String, CaseIterable { case missions = "Misje", achievements = "Osiągnięcia" }

    @Environment(AppState.self) private var app
    @State private var pane: Pane = .missions
    @State private var missions: Loadable<[Mission]> = .idle
    @State private var achievements: Loadable<[AchievementItem]> = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Sekcja", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch pane {
                case .missions: missionsSection
                case .achievements: AchievementsSection(items: achievements) { Task { await load() } }
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Misje")
        .task(id: app.refreshToken) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if missions.value == nil { missions = .loading }
        if achievements.value == nil { achievements = .loading }
        do { missions = .loaded(try await app.backend.missions()) } catch { missions = .failed(app.message(for: error)) }
        do { achievements = .loaded(try await app.backend.achievements()) } catch { achievements = .failed(app.message(for: error)) }
    }

    @ViewBuilder private var missionsSection: some View {
        switch missions {
        case .idle, .loading: LoadingView()
        case .failed(let e): ErrorBanner(message: e) { Task { await load() } }
        case .loaded(let list):
            group(list, period: "daily", title: "Misje dzienne", reward: "+20 XP za każdą")
            group(list, period: "weekly", title: "Misje tygodniowe", reward: "+50 XP i +30 LP za każdą")
            group(list, period: "special", title: "Misje specjalne", reward: "Duże nagrody za wielkie wyczyny")
        }
    }

    private func group(_ list: [Mission], period: String, title: String, reward: String) -> some View {
        let items = list.filter { $0.period == period }
        let resets = items.first?.resetsAt
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: title, subtitle: reward)
                if let resets {
                    Label(QVDate.countdown(to: QVDate.parse(resets)), systemImage: "clock")
                        .font(.caption.weight(.semibold)).foregroundStyle(QV.textSecondary)
                        .accessibilityLabel("Odnowienie za \(QVDate.countdown(to: QVDate.parse(resets)))")
                }
            }
            ForEach(items) { MissionRow(mission: $0) }
        }
    }
}

struct MissionRow: View {
    let mission: Mission

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mission.isCompleted ? "checkmark.circle.fill" : mission.icon)
                .font(.title2)
                .foregroundStyle(mission.isCompleted ? QV.teal : QV.violet)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(mission.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    Spacer()
                    if mission.xpReward > 0 { Text("+\(mission.xpReward) XP").font(.caption2.bold()).foregroundStyle(QV.violet) }
                    if mission.lpReward > 0 { Text("+\(mission.lpReward) LP").font(.caption2.bold()).foregroundStyle(QV.gold) }
                }
                Text(mission.description).font(.caption).foregroundStyle(QV.textSecondary)
                HStack(spacing: 8) {
                    ProgressBar(value: Double(mission.progress) / Double(max(1, mission.target)),
                                gradient: mission.isCompleted ? QV.successGradient : QV.brandGradient, height: 6)
                    Text("\(min(mission.progress, mission.target))/\(mission.target)").font(.caption2.monospacedDigit()).foregroundStyle(QV.textSecondary)
                }
            }
        }
        .glassCard(padding: 12, glow: mission.isCompleted ? QV.teal : nil)
        .opacity(mission.isCompleted ? 0.85 : 1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Osiągnięcia

struct AchievementsSection: View {
    let items: Loadable<[AchievementItem]>
    var retry: () -> Void
    @State private var selected: AchievementItem?

    private let categoryNames: [String: String] = [
        "knowledge": "Wiedza", "perfection": "Perfekcja", "regularity": "Regularność", "leagues": "Ligi",
        "season": "Sezony", "exploration": "Odkrywanie", "history": "Historia", "geography": "Geografia", "science": "Nauka",
    ]

    var body: some View {
        switch items {
        case .idle, .loading: LoadingView()
        case .failed(let e): ErrorBanner(message: e, retry: retry)
        case .loaded(let list):
            let unlocked = list.filter { $0.unlockedAt != nil }.count
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Odblokowane: \(unlocked) / \(list.count)").font(.headline).foregroundStyle(.white)
                    Spacer()
                }
                ProgressBar(value: Double(unlocked) / Double(max(1, list.count)), gradient: QV.goldGradient)
                ForEach(groups(list), id: \.0) { cat, items in
                    SectionHeader(title: categoryNames[cat] ?? cat.capitalized)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(items) { a in
                            Button { selected = a } label: { AchievementTile(item: a) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .sheet(item: $selected) { a in
                AchievementDetail(item: a).presentationDetents([.medium])
            }
        }
    }

    private func groups(_ list: [AchievementItem]) -> [(String, [AchievementItem])] {
        var order: [String] = []
        var dict: [String: [AchievementItem]] = [:]
        for a in list {
            if dict[a.category] == nil { order.append(a.category) }
            dict[a.category, default: []].append(a)
        }
        return order.map { ($0, dict[$0] ?? []) }
    }
}

struct AchievementTile: View {
    let item: AchievementItem
    var body: some View {
        let unlocked = item.unlockedAt != nil
        let color = QV.tierColor(item.tier)
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(unlocked ? color.opacity(0.2) : Color.white.opacity(0.04)).frame(width: 54, height: 54)
                Circle().stroke(unlocked ? color : QV.stroke, lineWidth: 2).frame(width: 54, height: 54)
                Image(systemName: unlocked ? item.icon : "lock.fill").font(.title3)
                    .foregroundStyle(unlocked ? color : QV.textSecondary)
            }
            .shadow(color: unlocked ? color.opacity(0.6) : .clear, radius: 8)
            Text(item.name).font(.caption2.weight(.semibold)).foregroundStyle(unlocked ? .white : QV.textSecondary)
                .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.03)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(unlocked ? "odblokowane" : "zablokowane")")
    }
}

struct AchievementDetail: View {
    let item: AchievementItem
    var body: some View {
        let color = QV.tierColor(item.tier)
        VStack(spacing: 14) {
            Image(systemName: item.icon).font(.system(size: 54)).foregroundStyle(color)
                .shadow(color: color, radius: 16).padding(.top, 24)
            Text(item.name).font(.title2.weight(.heavy)).foregroundStyle(.white)
            HStack(spacing: 8) {
                RewardBadge(text: QV.tierName(item.tier), color: color, icon: "medal.fill")
                RewardBadge(text: QV.rarityName(item.rarity), color: QV.rarityColor(item.rarity), icon: "diamond.fill")
                RewardBadge(text: "+\(item.xpReward) XP", color: QV.violet, icon: "sparkle")
            }
            Text(item.description).font(.body).foregroundStyle(QV.textSecondary).multilineTextAlignment(.center).padding(.horizontal)
            if let at = item.unlockedAt {
                Label("Odblokowano \(QVDate.short(at))", systemImage: "checkmark.seal.fill").foregroundStyle(QV.teal)
            } else {
                Label("Jeszcze zablokowane", systemImage: "lock.fill").foregroundStyle(QV.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(StarfieldBackground(intensity: 0.6))
    }
}
