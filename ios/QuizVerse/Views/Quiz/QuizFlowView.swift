import SwiftUI
import Combine
import UIKit

/// Zapis odpowiedzi do przeglądu po quizie (lokalnie – bez ujawniania poprawnych odpowiedzi przed udzieleniem własnej).
struct AnsweredItem: Identifiable {
    var id: String { question.id }
    let question: QuizQuestion
    let chosenId: String?
    let result: AnswerResult
}

struct QuizFlowView: View {
    @State var request: QuizRequest
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Phase { case loading, playing, finishing, result(QuizResult), failed(String) }

    @State private var phase: Phase = .loading
    @State private var session: QuizSession?
    @State private var index = 0
    @State private var selected: String?
    @State private var feedback: AnswerResult?
    @State private var submitting = false
    @State private var questionStart = Date()
    @State private var quizDeadline: Date?
    @State private var now = Date()
    @State private var log: [AnsweredItem] = []
    @State private var confirmQuit = false
    @State private var reportQuestion: QuizQuestion?
    @State private var articleSlug: String?
    @State private var revealedClues = 1

    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private var mode: QuizMode { session?.mode ?? request.mode }
    private var perQuestionLimit: Double? {
        switch mode {
        case .sprint: return nil
        case .detective: return 60
        default: return 30
        }
    }
    private var currentQuestion: QuizQuestion? {
        guard let s = session, index < s.questions.count else { return nil }
        return s.questions[index]
    }
    private var correctSoFar: Int { log.filter { $0.result.correct == true }.count }

    var body: some View {
        ZStack {
            StarfieldBackground(intensity: 0.7)
            switch phase {
            case .loading:
                LoadingView(text: "Przygotowuję pytania…")
            case .failed(let message):
                failedView(message)
            case .playing:
                if let q = currentQuestion { playing(q) } else { LoadingView() }
            case .finishing:
                LoadingView(text: "Liczę punkty…")
            case .result(let r):
                QuizResultView(result: r, log: log, isDemo: app.isDemo,
                               onClose: { dismiss() },
                               onAgain: againAction,
                               onOpenArticle: { articleSlug = $0 })
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if app.isDemo { DemoBanner() } }
        .task { await start() }
        .onReceive(ticker) { tick($0) }
        .confirmationDialog("Przerwać quiz?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Zakończ teraz", role: .destructive) { Task { await finish() } }
            Button("Wyjdź bez podsumowania", role: .destructive) { dismiss() }
            Button("Graj dalej", role: .cancel) {}
        } message: {
            Text("Nieukończony quiz daje tylko XP za poprawne odpowiedzi – bez bonusu za ukończenie i bez LP (poza maratonem, przetrwaniem i sprintem).")
        }
        .sheet(item: $reportQuestion) { ReportQuestionSheet(question: $0) }
        .sheet(item: Binding(get: { articleSlug.map { SlugRef(slug: $0) } }, set: { articleSlug = $0?.slug })) { ref in
            NavigationStack { ArticleLoaderView(slug: ref.slug) }
        }
    }

    /// Quiz dnia i powtórki nie mają opcji „zagraj ponownie”.
    private var againAction: (() -> Void)? {
        if request.mode == .daily || request.mode == .review { return nil }
        return { restart() }
    }

    // MARK: - Przebieg

    private func start() async {
        phase = .loading
        log = []; index = 0; selected = nil; feedback = nil; revealedClues = 1
        do {
            let s = try await app.backend.startQuiz(request)
            guard !s.questions.isEmpty else { phase = .failed(BackendError(code: "not_enough_questions").localizedDescription); return }
            session = s
            if let limit = s.timeLimitS { quizDeadline = Date().addingTimeInterval(Double(limit)) }
            questionStart = Date()
            phase = .playing
        } catch {
            if (error as? BackendError)?.code == "daily_already_played" { app.markDailyDone() }
            phase = .failed(app.message(for: error))
        }
    }

    private func restart() {
        session = nil; quizDeadline = nil
        Task { await start() }
    }

    private func tick(_ date: Date) {
        now = date
        guard case .playing = phase, feedback == nil, !submitting, let q = currentQuestion else { return }
        if let deadline = quizDeadline, date >= deadline {
            Task { await finish() }
            return
        }
        if let limit = perQuestionLimit, date.timeIntervalSince(questionStart) >= limit {
            Task { await answer(q, nil) } // brak odpowiedzi w czasie = błędna odpowiedź
        }
    }

    private func answer(_ q: QuizQuestion, _ answerId: String?) async {
        guard let s = session, feedback == nil, !submitting else { return }
        submitting = true
        selected = answerId
        let ms = Int(Date().timeIntervalSince(questionStart) * 1000)
        defer { submitting = false }
        do {
            let r = try await app.backend.submitAnswer(attemptId: s.attemptId, questionId: q.id, answerId: answerId, timeMs: ms)
            if r.timeOver == true {
                await finish()
                return
            }
            log.append(AnsweredItem(question: q, chosenId: answerId, result: r))
            feedback = r
            if r.correct == true {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            if mode == .sprint {
                try? await Task.sleep(for: .milliseconds(650))
                if r.endsQuiz { await finish() } else { next() }
            }
        } catch {
            if let e = error as? BackendError, ["attempt_closed", "attempt_expired"].contains(e.code) {
                await finish()
            } else {
                selected = nil
                app.showToast(app.message(for: error))
            }
        }
    }

    private func next() {
        guard let s = session else { return }
        if feedback?.endsQuiz == true || index + 1 >= s.questions.count {
            Task { await finish() }
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            index += 1
            selected = nil
            feedback = nil
            revealedClues = 1
        }
        questionStart = Date()
    }

    private func finish() async {
        guard let s = session else { dismiss(); return }
        if case .finishing = phase { return }
        if case .result = phase { return }
        phase = .finishing
        do {
            let r = try await app.backend.finishQuiz(attemptId: s.attemptId)
            if s.mode == .daily { app.markDailyDone() }
            phase = .result(r)
        } catch {
            phase = .failed(app.message(for: error))
        }
    }

    // MARK: - Widoki

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(QV.gold)
            Text(message).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
            Button("Zamknij") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(32)
    }

    private func playing(_ q: QuizQuestion) -> some View {
        VStack(spacing: 14) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    questionHeader(q)
                    if q.kind == "detective", let clues = q.clues, !clues.isEmpty {
                        cluesView(clues)
                    }
                    Text(q.prompt)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 10) {
                        ForEach(Array(q.answers.enumerated()), id: \.element.id) { i, a in
                            AnswerButton(letter: ["A", "B", "C", "D", "E", "F"][min(i, 5)], text: a.body,
                                         state: answerState(a.id), disabled: feedback != nil || submitting) {
                                Task { await answer(q, a.id) }
                            }
                        }
                    }
                    if let fb = feedback, mode != .sprint { feedbackCard(q, fb) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            if feedback != nil && mode != .sprint {
                Button(feedback?.endsQuiz == true || index + 1 >= (session?.questions.count ?? 0) ? "Zobacz wynik" : "Dalej") { next() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button { confirmQuit = true } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .accessibilityLabel("Przerwij quiz")
                Spacer()
                VStack(spacing: 0) {
                    Text(mode.title.uppercased()).font(.caption.weight(.heavy)).tracking(1.4).foregroundStyle(QV.blue)
                    Text(progressText).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                }
                Spacer()
                timerBadge
            }
            if let s = session, mode != .survival, mode != .sprint {
                ProgressBar(value: Double(index + (feedback == nil ? 0 : 1)) / Double(max(1, s.questions.count)), height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var progressText: String {
        guard let s = session else { return "" }
        switch mode {
        case .survival: return "Seria: \(correctSoFar)"
        case .sprint: return "Poprawne: \(correctSoFar)"
        default: return "Pytanie \(min(index + 1, s.questions.count)) / \(s.questions.count)"
        }
    }

    @ViewBuilder private var timerBadge: some View {
        let remaining: Double? = {
            if let deadline = quizDeadline { return deadline.timeIntervalSince(now) }
            if let limit = perQuestionLimit, feedback == nil { return limit - now.timeIntervalSince(questionStart) }
            return nil
        }()
        if let remaining {
            let secs = max(0, Int(remaining.rounded(.up)))
            let urgent = remaining < 6
            Text("\(secs)s")
                .font(.system(.headline, design: .monospaced).weight(.bold))
                .foregroundStyle(urgent ? QV.red : QV.gold)
                .frame(width: 56, height: 36)
                .background(Capsule().fill((urgent ? QV.red : QV.gold).opacity(0.14)))
                .accessibilityLabel("Pozostało \(secs) sekund")
        } else {
            Color.clear.frame(width: 56, height: 36)
        }
    }

    private func questionHeader(_ q: QuizQuestion) -> some View {
        HStack(spacing: 8) {
            if let c = app.category(q.categoryId) {
                Label(c.name, systemImage: c.icon).font(.caption.weight(.semibold)).foregroundStyle(Color(hex: c.colorHex))
            }
            Spacer()
            Text(QV.difficultyName(q.difficulty)).font(.caption2.weight(.bold)).foregroundStyle(QV.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().stroke(QV.stroke))
            if q.source == "ai" {
                Label("AI", systemImage: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(QV.blue)
            }
        }
        .padding(.top, 6)
    }

    private func cluesView(_ clues: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("WSKAZÓWKI", systemImage: "magnifyingglass").font(.caption.weight(.heavy)).foregroundStyle(QV.gold)
            ForEach(Array(clues.prefix(feedback == nil ? revealedClues : clues.count).enumerated()), id: \.offset) { i, clue in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1).").font(.subheadline.weight(.bold)).foregroundStyle(QV.gold)
                    Text(clue).font(.subheadline).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if feedback == nil && revealedClues < clues.count {
                Button("Odkryj kolejną wskazówkę") { withAnimation { revealedClues += 1 } }
                    .font(.footnote.weight(.semibold)).foregroundStyle(QV.blue)
            }
        }
        .glassCard(padding: 14, glow: QV.gold)
    }

    private func answerState(_ id: String) -> AnswerButton.Look {
        guard let fb = feedback else { return selected == id ? .pending : .idle }
        if id == fb.correctAnswerId { return .correct }
        if id == selected { return .wrong }
        return .dimmed
    }

    private func feedbackCard(_ q: QuizQuestion, _ fb: AnswerResult) -> some View {
        let ok = fb.correct == true
        return VStack(alignment: .leading, spacing: 10) {
            Label(ok ? "Dobrze!" : (selected == nil ? "Koniec czasu" : "Niestety, błędna odpowiedź"),
                  systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.headline).foregroundStyle(ok ? QV.teal : QV.red)
            if let e = fb.explanation, !e.isEmpty {
                Text(e).font(.subheadline).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
            if let sources = fb.sources, !sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Źródła").font(.caption.weight(.heavy)).foregroundStyle(QV.textSecondary)
                    ForEach(sources, id: \.self) { s in
                        if let u = s.url, let url = URL(string: u) {
                            Link(destination: url) { Label(s.title, systemImage: "link").font(.caption) }.foregroundStyle(QV.blue)
                        } else {
                            Label(s.title, systemImage: "book.closed").font(.caption).foregroundStyle(QV.textSecondary)
                        }
                    }
                }
            }
            HStack {
                if let slug = fb.articleSlug {
                    Button { articleSlug = slug } label: { Label("Czytaj w encyklopedii", systemImage: "book.fill") }
                        .font(.footnote.weight(.semibold)).foregroundStyle(QV.violet)
                }
                Spacer()
                Button { reportQuestion = q } label: { Label("Zgłoś", systemImage: "flag") }
                    .font(.footnote).foregroundStyle(QV.textSecondary)
            }
            if fb.endsQuiz && mode == .survival && !ok {
                Text("Przetrwanie zakończone – seria: \(correctSoFar)").font(.footnote.weight(.bold)).foregroundStyle(QV.gold)
            }
        }
        .glassCard(padding: 14, glow: ok ? QV.teal : QV.red)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

struct SlugRef: Identifiable { let slug: String; var id: String { slug } }

struct AnswerButton: View {
    enum Look { case idle, pending, correct, wrong, dimmed }
    let letter: String
    let text: String
    let state: Look
    let disabled: Bool
    let action: () -> Void

    private var tint: Color {
        switch state {
        case .correct: return QV.teal
        case .wrong: return QV.red
        case .pending: return QV.violet
        default: return .white
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(letter)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(state == .idle || state == .dimmed ? QV.blue : .white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(state == .idle || state == .dimmed ? QV.blue.opacity(0.12) : tint.opacity(0.6)))
                Text(text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if state == .correct { Image(systemName: "checkmark.circle.fill").foregroundStyle(QV.teal) }
                if state == .wrong { Image(systemName: "xmark.circle.fill").foregroundStyle(QV.red) }
                if state == .pending { ProgressView().tint(.white) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(state == .correct || state == .wrong ? tint.opacity(0.16) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(state == .idle || state == .dimmed ? QV.stroke : tint, lineWidth: state == .idle ? 1 : 2))
            .opacity(state == .dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(.easeInOut(duration: 0.2), value: state)
        .accessibilityLabel("Odpowiedź \(letter): \(text)")
        .accessibilityValue(state == .correct ? "poprawna" : state == .wrong ? "błędna" : "")
    }
}

// MARK: - Zgłoszenie pytania

struct ReportQuestionSheet: View {
    let question: QuizQuestion
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "wrong_answer"
    @State private var comment = ""
    @State private var busy = false
    @State private var error: String?

    private let reasons: [(String, String)] = [
        ("wrong_answer", "Błędna odpowiedź"), ("unclear", "Niejasne pytanie"), ("outdated", "Nieaktualne informacje"),
        ("typo", "Literówka lub błąd językowy"), ("offensive", "Treść niestosowna"), ("other", "Inny problem"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(question.prompt).font(.subheadline)
                }
                Section("Powód") {
                    Picker("Powód", selection: $reason) {
                        ForEach(reasons, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Komentarz (opcjonalnie)") {
                    TextField("Co jest nie tak?", text: $comment, axis: .vertical).lineLimit(3...6)
                }
                if let error { Section { Text(error).foregroundStyle(QV.red) } }
                Section {
                    Text("Pytanie zgłoszone przez 3 graczy trafia do weryfikacji redakcji i jest wstrzymywane.")
                        .font(.caption).foregroundStyle(QV.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(QV.background)
            .navigationTitle("Zgłoś pytanie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Wyślij") { Task { await send() } }.disabled(busy)
                }
            }
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        do {
            try await app.backend.reportQuestion(questionId: question.id, reason: reason, comment: comment.isEmpty ? nil : comment)
            app.showToast("Dziękujemy! Zgłoszenie zostało wysłane.")
            dismiss()
        } catch {
            self.error = app.message(for: error)
        }
    }
}
