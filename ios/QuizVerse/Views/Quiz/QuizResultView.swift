import SwiftUI

struct QuizResultView: View {
    let result: QuizResult
    let log: [AnsweredItem]
    let isDemo: Bool
    var onClose: () -> Void
    var onAgain: (() -> Void)?
    var onOpenArticle: (String) -> Void

    @Environment(AppState.self) private var app
    @State private var appear = false
    @State private var showReview = false

    private var leveledUp: Bool { result.levelAfter > result.levelBefore }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                scoreRing.padding(.top, 20)
                Text(headline).font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if result.flagged {
                    warning("Wykryto nienaturalnie szybkie odpowiedzi. Zgodnie z zasadami fair play ten quiz nie przyznaje nagród.")
                }
                if result.lpBlockedLowAccuracy == true {
                    warning("Punkty ligowe wymagają min. 40% poprawnych odpowiedzi. XP zostało przyznane.")
                }
                if result.alreadyFinished == true {
                    warning("Ten quiz był już rozliczony – nagrody nie są przyznawane ponownie.")
                }

                HStack(spacing: 10) {
                    rewardTotal(value: result.xp, unit: "XP", color: QV.violet, icon: "sparkle")
                    rewardTotal(value: result.lp, unit: "LP", color: QV.gold, icon: "trophy.fill")
                }

                if !result.xpItems.isEmpty || !result.lpItems.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(result.xpItems, id: \.self) { itemRow($0, unit: "XP", color: QV.violet) }
                        ForEach(result.lpItems, id: \.self) { itemRow($0, unit: "LP", color: QV.gold) }
                    }
                    .glassCard(padding: 14)
                }

                if leveledUp {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.forward.circle.fill").font(.largeTitle).foregroundStyle(QV.goldGradient)
                        VStack(alignment: .leading) {
                            Text("NOWY POZIOM \(result.levelAfter)!").font(.headline.weight(.black)).foregroundStyle(QV.gold)
                            Text(result.title).font(.subheadline).foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .glassCard(glow: QV.gold)
                }

                if let league = result.league {
                    HStack {
                        Image(systemName: "trophy.fill").foregroundStyle(QV.gold)
                        Text("Liga: miejsce \(league.rank) · \(league.weekLp) LP w tym tygodniu").font(.subheadline).foregroundStyle(.white)
                        Spacer()
                    }
                    .glassCard(padding: 12)
                }

                ForEach(result.missionsCompleted, id: \.self) { m in
                    HStack(spacing: 12) {
                        Image(systemName: "target").font(.title2).foregroundStyle(QV.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MISJA UKOŃCZONA").font(.caption.weight(.heavy)).foregroundStyle(QV.teal)
                            Text(m.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            if m.xp > 0 { Text("+\(m.xp) XP").font(.caption.bold()).foregroundStyle(QV.violet) }
                            if m.lp > 0 { Text("+\(m.lp) LP").font(.caption.bold()).foregroundStyle(QV.gold) }
                        }
                    }
                    .glassCard(padding: 12, glow: QV.teal)
                }

                ForEach(result.achievementsUnlocked, id: \.self) { a in
                    HStack(spacing: 12) {
                        Image(systemName: a.icon).font(.title2).foregroundStyle(QV.tierColor(a.tier))
                            .frame(width: 44, height: 44).background(Circle().fill(QV.tierColor(a.tier).opacity(0.15)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OSIĄGNIĘCIE ODBLOKOWANE").font(.caption.weight(.heavy)).foregroundStyle(QV.gold)
                            Text(a.name).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            Text(a.description).font(.caption).foregroundStyle(QV.textSecondary)
                        }
                        Spacer()
                    }
                    .glassCard(padding: 12, glow: QV.gold)
                }

                if let card = result.card {
                    VStack(spacing: 10) {
                        Text(card.duplicate == true ? "KARTA (DUPLIKAT)" : "NOWA KARTA KOLEKCJONERSKA")
                            .font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(QV.rarityColor(card.rarity))
                        CollectibleCardView(name: card.name, description: card.description, rarity: card.rarity,
                                            art: card.art, kind: card.kind, categoryId: card.categoryId, owned: true)
                            .frame(width: 180)
                        if let reason = card.reason { Text(reason).font(.caption).foregroundStyle(QV.textSecondary) }
                    }
                    .frame(maxWidth: .infinity)
                    .glassCard(glow: QV.rarityColor(card.rarity))
                }

                if !log.isEmpty {
                    Button(showReview ? "Ukryj przegląd odpowiedzi" : "Przejrzyj odpowiedzi") { withAnimation { showReview.toggle() } }
                        .buttonStyle(SecondaryButtonStyle())
                    if showReview {
                        ForEach(log) { item in reviewRow(item) }
                    }
                }

                VStack(spacing: 10) {
                    if let onAgain { Button("Zagraj ponownie", action: onAgain).buttonStyle(PrimaryButtonStyle()) }
                    Button("Zamknij", action: onClose).buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 6)
            }
            .padding(16)
            .padding(.bottom, 30)
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.15)) { appear = true } }
    }

    private var headline: String {
        if result.flagged { return "Quiz zakończony" }
        switch result.mode {
        case .survival: return "Przetrwałeś \(Fmt.plural(result.correct, "pytanie", "pytania", "pytań"))!"
        case .sprint: return "Sprint: \(Fmt.plural(result.correct, "poprawna", "poprawne", "poprawnych"))!"
        default:
            if result.answered > 0 && result.correct == result.answered && result.completed { return "Perfekcyjnie!" }
            if result.accuracy >= 0.8 { return "Świetny wynik!" }
            if result.accuracy >= 0.5 { return "Dobra robota!" }
            return "Każda odpowiedź to nauka!"
        }
    }

    private var scoreRing: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 14)
            Circle()
                .trim(from: 0, to: appear ? result.accuracy : 0)
                .stroke(AngularGradient(colors: [QV.violet, QV.blue, QV.teal, QV.violet], center: .center),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: QV.violet.opacity(0.6), radius: 10)
            VStack(spacing: 2) {
                Text("\(result.correct)/\(result.answered)").font(.system(size: 38, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text(Fmt.percent(result.accuracy)).font(.headline).foregroundStyle(QV.teal)
            }
        }
        .frame(width: 170, height: 170)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.correct) poprawnych z \(result.answered), skuteczność \(Fmt.percent(result.accuracy))")
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.shield.fill").font(.footnote).foregroundStyle(QV.gold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 12, glow: QV.gold)
    }

    private func rewardTotal(value: Int, unit: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text("+\(value)").font(.system(.title, design: .rounded).weight(.black)).foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(unit).font(.caption.weight(.heavy)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .glassCard(padding: 14, glow: color)
    }

    private func itemRow(_ item: RewardItem, unit: String, color: Color) -> some View {
        HStack {
            Text(item.label).font(.subheadline).foregroundStyle(QV.textSecondary)
            Spacer()
            Text("+\(item.value) \(unit)").font(.subheadline.weight(.bold)).foregroundStyle(color)
        }
    }

    private func reviewRow(_ item: AnsweredItem) -> some View {
        let ok = item.result.correct == true
        let correct = item.question.answers.first { $0.id == item.result.correctAnswerId }?.body
        let chosen = item.question.answers.first { $0.id == item.chosenId }?.body
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? QV.teal : QV.red)
                Text(item.question.prompt).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
            if !ok {
                Text("Twoja odpowiedź: \(chosen ?? "brak (czas minął)")").font(.caption).foregroundStyle(QV.red)
            }
            if let correct { Text("Poprawna: \(correct)").font(.caption).foregroundStyle(QV.teal) }
            if let e = item.result.explanation { Text(e).font(.caption).foregroundStyle(QV.textSecondary) }
            if let slug = item.result.articleSlug {
                Button { onOpenArticle(slug) } label: { Label("Encyklopedia", systemImage: "book.fill").font(.caption.weight(.semibold)) }
                    .foregroundStyle(QV.violet)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 12)
    }
}
