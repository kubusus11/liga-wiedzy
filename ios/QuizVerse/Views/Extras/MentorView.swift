import SwiftUI

struct MentorMessage: Identifiable {
    let id = UUID()
    let fromUser: Bool
    let text: String
    var reply: MentorReply? = nil
}

struct MentorView: View {
    @Environment(AppState.self) private var app
    @State private var messages: [MentorMessage] = []
    @State private var input = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    private let prompts = [
        "Jakie są moje słabe strony?",
        "Ułóż mi plan nauki na 5 dni",
        "Jak awansować do wyższej ligi?",
        "Co powtórzyć przed weekendem?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        intro
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        if busy {
                            HStack(spacing: 8) { ProgressView().tint(QV.blue); Text("Mentor analizuje Twoje wyniki…").font(.footnote).foregroundStyle(QV.textSecondary) }
                                .id("busy")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) {
                    if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            inputBar
        }
        .screenChrome("Mentor AI")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill").font(.title).foregroundStyle(QV.blue)
                    .frame(width: 52, height: 52).background(Circle().fill(QV.blue.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Twój Mentor").font(.headline).foregroundStyle(.white)
                    Text("Analizuje statystyki, wskazuje słabe punkty i proponuje plan nauki.").font(.caption).foregroundStyle(QV.textSecondary)
                }
            }
            if app.isDemo {
                Label("Tryb demonstracyjny: Mentor działa offline – analizuje wyniki lokalnie, bez modelu AI.", systemImage: "flask.fill")
                    .font(.caption).foregroundStyle(QV.gold)
            }
            if messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(prompts, id: \.self) { p in
                            Chip(title: p, selected: false) { Task { await send(p) } }
                        }
                    }
                }
            }
        }
        .glassCard(glow: QV.blue)
    }

    @ViewBuilder private func bubble(_ m: MentorMessage) -> some View {
        if m.fromUser {
            HStack {
                Spacer(minLength: 50)
                Text(m.text).font(.subheadline).foregroundStyle(.white)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(QV.brandGradient))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(m.text).font(.subheadline).foregroundStyle(.white)
                if let r = m.reply {
                    if !r.weakPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DO POPRAWY").font(.caption2.weight(.heavy)).foregroundStyle(QV.red)
                            ForEach(r.weakPoints, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.white.opacity(0.9)) }
                        }
                    }
                    if !r.plan.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PLAN NAUKI").font(.caption2.weight(.heavy)).foregroundStyle(QV.teal)
                            ForEach(r.plan, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(item.day).font(.caption.weight(.bold)).foregroundStyle(QV.teal).frame(width: 60, alignment: .leading)
                                    Text(item.task).font(.caption).foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    ForEach(r.suggestions, id: \.self) { s in
                        Button {
                            start(s)
                        } label: {
                            HStack {
                                Image(systemName: s.mode == "review" ? "arrow.triangle.2.circlepath" : "play.fill")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestionTitle(s)).font(.caption.weight(.bold))
                                    Text(s.reason).font(.caption2).foregroundStyle(QV.textSecondary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(QV.blue)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(QV.blue.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(QV.surfaceHigh))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(QV.stroke))
            .padding(.trailing, 30)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Zapytaj mentora…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.07)))
                .foregroundStyle(.white)
            Button {
                let text = input
                input = ""
                Task { await send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(QV.violet)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            .accessibilityLabel("Wyślij")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(QV.background.opacity(0.95))
    }

    private func suggestionTitle(_ s: MentorSuggestion) -> String {
        let cat = app.category(s.categoryId)?.name ?? "Kategoria"
        switch s.mode {
        case "review": return "Inteligentne powtórki"
        case "sprint": return "Sprint · \(cat)"
        case "marathon": return "Maraton · \(cat)"
        default: return "Quiz: \(cat) · \(QV.difficultyName(s.difficulty))"
        }
    }

    private func start(_ s: MentorSuggestion) {
        let mode = QuizMode(rawValue: s.mode) ?? .thematic
        switch mode {
        case .review: app.startQuiz(QuizRequest(mode: .review, count: 20))
        case .sprint: app.startQuiz(QuizRequest(mode: .sprint, categoryId: s.categoryId, difficulty: s.difficulty, count: 40, timeLimit: 60))
        case .marathon: app.startQuiz(QuizRequest(mode: .marathon, categoryId: s.categoryId, difficulty: s.difficulty, count: 50))
        default: app.startQuiz(QuizRequest(mode: .thematic, categoryId: s.categoryId, subcategoryId: s.subcategoryId, difficulty: s.difficulty, count: 10))
        }
    }

    private func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        messages.append(MentorMessage(fromUser: true, text: trimmed))
        busy = true
        defer { busy = false }
        do {
            let r = try await app.backend.mentor(message: trimmed)
            messages.append(MentorMessage(fromUser: false, text: r.reply, reply: r))
        } catch {
            messages.append(MentorMessage(fromUser: false, text: app.message(for: error)))
        }
    }
}
