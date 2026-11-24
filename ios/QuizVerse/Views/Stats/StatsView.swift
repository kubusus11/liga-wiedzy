import SwiftUI
import Charts

struct StatsView: View {
    enum Span: Int, CaseIterable { case week = 7, month = 30, twoMonths = 60
        var title: String { self == .week ? "7 dni" : self == .month ? "30 dni" : "60 dni" }
    }

    @Environment(AppState.self) private var app
    @State private var stats: Loadable<Stats> = .idle
    @State private var range: Span = .week

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch stats {
                case .idle, .loading: LoadingView()
                case .failed(let e): ErrorBanner(message: e) { Task { await load() } }
                case .loaded(let s):
                    if s.answered == 0 {
                        EmptyStateView(icon: "chart.bar.xaxis", title: "Brak statystyk",
                                       message: "Rozwiąż pierwszy quiz – tutaj zobaczysz skuteczność, postępy w kategoriach i wykresy aktywności.")
                            .glassCard()
                    }
                    summary(s)
                    activityChart(s)
                    xpChart(s)
                    categoryChart(s)
                    bestWorst(s)
                    reviews(s)
                    categoryTable(s)
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Statystyki")
        .task(id: app.refreshToken) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if stats.value == nil { stats = .loading }
        do { stats = .loaded(try await app.backend.stats()) } catch { stats = .failed(app.message(for: error)) }
    }

    private func summary(_ s: Stats) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatPill(icon: "checkmark.seal.fill", value: Fmt.number(s.correct), label: "Poprawne", color: QV.teal)
                StatPill(icon: "scope", value: Fmt.percent(s.accuracy), label: "Skuteczność", color: QV.gold)
                StatPill(icon: "list.bullet.rectangle.fill", value: Fmt.number(s.quizzes), label: "Quizy", color: QV.violet)
            }
            HStack(spacing: 8) {
                StatPill(icon: "star.circle.fill", value: "\(s.perfectQuizzes)", label: "Perfekcyjne", color: QV.gold)
                StatPill(icon: "timer", value: Fmt.seconds(s.avgTimeMs), label: "Śr. czas", color: QV.blue)
                StatPill(icon: "flame.fill", value: "\(s.currentStreak)/\(s.bestStreak)", label: "Seria dni", color: QV.red)
            }
            HStack(spacing: 8) {
                StatPill(icon: "bolt.fill", value: "\(s.currentAnswerStreak)", label: "Seria trafień", color: QV.teal)
                StatPill(icon: "bolt.badge.checkmark.fill", value: "\(s.bestAnswerStreak)", label: "Rekord trafień", color: QV.violet)
                StatPill(icon: "questionmark.circle.fill", value: Fmt.number(s.answered), label: "Odpowiedzi", color: QV.blue)
            }
        }
    }

    private func days(_ s: Stats) -> [DailyStat] { Array(s.daily.suffix(range.rawValue)) }

    private func activityChart(_ s: Stats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Aktywność", subtitle: "Odpowiedzi poprawne i błędne")
            Picker("Zakres", selection: $range) {
                ForEach(Span.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Chart {
                ForEach(days(s)) { d in
                    let date = QVDate.parse(d.day) ?? Date()
                    BarMark(x: .value("Dzień", date, unit: .day), y: .value("Odpowiedzi", d.correct))
                        .foregroundStyle(by: .value("Typ", "Poprawne"))
                    BarMark(x: .value("Dzień", date, unit: .day), y: .value("Odpowiedzi", d.answered - d.correct))
                        .foregroundStyle(by: .value("Typ", "Błędne"))
                }
            }
            .chartForegroundStyleScale(["Poprawne": QV.teal, "Błędne": QV.red.opacity(0.7)])
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine().foregroundStyle(QV.stroke); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(QV.stroke); AxisValueLabel() } }
            .frame(height: 190)
        }
        .glassCard()
    }

    private func xpChart(_ s: Stats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Zdobyte XP", subtitle: "\(Fmt.number(days(s).reduce(0) { $0 + $1.xp })) XP w okresie: \(range.title)")
            Chart {
                ForEach(days(s)) { d in
                    let date = QVDate.parse(d.day) ?? Date()
                    AreaMark(x: .value("Dzień", date, unit: .day), y: .value("XP", d.xp))
                        .foregroundStyle(LinearGradient(colors: [QV.violet.opacity(0.6), QV.violet.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Dzień", date, unit: .day), y: .value("XP", d.xp))
                        .foregroundStyle(QV.violet)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine().foregroundStyle(QV.stroke); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(QV.stroke); AxisValueLabel() } }
            .frame(height: 160)
        }
        .glassCard()
    }

    @ViewBuilder private func categoryChart(_ s: Stats) -> some View {
        let top = Array(s.categories.prefix(8))
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Skuteczność w kategoriach", subtitle: "Najczęściej grane dziedziny")
                Chart(top) { c in
                    BarMark(x: .value("Skuteczność", c.accuracy * 100), y: .value("Kategoria", c.name))
                        .foregroundStyle(Color(hex: c.colorHex))
                        .annotation(position: .trailing) {
                            Text(Fmt.percent(c.accuracy)).font(.caption2.bold()).foregroundStyle(.white)
                        }
                }
                .chartXScale(domain: 0...110)
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white) } }
                .frame(height: CGFloat(top.count) * 34 + 10)
            }
            .glassCard()
        }
    }

    @ViewBuilder private func bestWorst(_ s: Stats) -> some View {
        if s.bestCategory != nil || s.worstCategory != nil {
            HStack(spacing: 10) {
                if let b = s.bestCategory { highlight("Najmocniejsza", b, QV.teal, "arrow.up.right") }
                if let w = s.worstCategory, w.categoryId != s.bestCategory?.categoryId { highlight("Do poprawy", w, QV.red, "arrow.down.right") }
            }
        }
    }

    private func highlight(_ title: String, _ c: CategoryRef, _ color: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title.uppercased(), systemImage: icon).font(.caption2.weight(.heavy)).foregroundStyle(color)
            Text(c.name).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(2)
            Text(Fmt.percent(c.accuracy)).font(.title3.weight(.black)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14, glow: color)
    }

    private func reviews(_ s: Stats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Inteligentne powtórki", subtitle: "Błędne odpowiedzi wracają po 1, 3, 7 i 30 dniach")
            HStack(spacing: 8) {
                StatPill(icon: "exclamationmark.circle.fill", value: "\(s.reviews.due)", label: "Do powtórki", color: QV.gold)
                StatPill(icon: "calendar", value: "\(s.reviews.scheduled)", label: "Zaplanowane", color: QV.blue)
                StatPill(icon: "checkmark.seal.fill", value: "\(s.reviews.mastered)", label: "Opanowane", color: QV.teal)
            }
            if s.reviews.due > 0 {
                Button("Powtórz teraz (\(s.reviews.due))") { app.startQuiz(QuizRequest(mode: .review, count: 20)) }
                    .buttonStyle(PrimaryButtonStyle())
            } else if let next = s.reviews.nextDueAt {
                Text("Następna powtórka za \(QVDate.countdown(to: QVDate.parse(next)))").font(.caption).foregroundStyle(QV.textSecondary)
            }
        }
        .glassCard()
    }

    @ViewBuilder private func categoryTable(_ s: Stats) -> some View {
        if !s.categories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Wszystkie kategorie")
                ForEach(s.categories) { c in
                    HStack(spacing: 12) {
                        CategoryIcon(icon: c.icon, colorHex: c.colorHex, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Spacer()
                                Text("\(c.correct)/\(c.answered)").font(.caption.bold()).foregroundStyle(QV.textSecondary)
                            }
                            ProgressBar(value: c.accuracy, gradient: QV.successGradient, height: 6)
                            Text("Działy: \(c.subcategoriesPlayed)/\(c.subcategoriesTotal) · \(c.quizzes) quizów · \(c.xp) XP")
                                .font(.caption2).foregroundStyle(QV.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .glassCard()
        }
    }
}
