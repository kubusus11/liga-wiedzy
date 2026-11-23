import SwiftUI

/// Generator pytań AI: wybór tematu i poziomu, generowanie z niezależną weryfikacją po stronie serwera.
struct AIGeneratorView: View {
    var initialCategory: Int? = nil
    @Environment(AppState.self) private var app

    @State private var categoryId = 1
    @State private var subcategoryId = 0
    @State private var difficulty = 3
    @State private var count = 10
    @State private var busy = false
    @State private var result: AIGenerationResult?
    @State private var error: String?

    private var subcategories: [ContentBundle.SubcategoryDTO] {
        app.content.subcategories.filter { $0.categoryId == categoryId }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(QV.blue)
                        .shadow(color: QV.blue, radius: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Generator pytań AI").font(.title2.weight(.heavy)).foregroundStyle(.white)
                        Text("Nowe pytania z wyjaśnieniem i źródłami, sprawdzane przez drugi, niezależny model.")
                            .font(.footnote).foregroundStyle(QV.textSecondary)
                    }
                }

                if app.isDemo {
                    Label("Tryb demonstracyjny: generator AI wymaga skonfigurowanego backendu z kluczem API. Quiz zostanie zbudowany z wbudowanej bazy pytań.",
                          systemImage: "flask.fill")
                        .font(.caption).foregroundStyle(QV.gold).glassCard(padding: 12, glow: QV.gold)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Temat")
                    Picker("Kategoria", selection: $categoryId) {
                        ForEach(app.content.categories, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu).tint(QV.blue)
                    Picker("Dział", selection: $subcategoryId) {
                        Text("Cała kategoria").tag(0)
                        ForEach(subcategories, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu).tint(QV.blue)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Poziom trudności")
                    ChipRow(items: Array(1...6), selection: $difficulty) { QV.difficultyName($0) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Liczba pytań")
                    ChipRow(items: [5, 10], selection: $count) { "\($0)" }
                }

                Text("Pytania AI nie dają punktów ligowych, dopóki nie zostaną zaakceptowane przez redakcję. Limit: 5 generowań dziennie. Błędne pytanie możesz zgłosić w trakcie quizu.")
                    .font(.caption).foregroundStyle(QV.textSecondary)

                if let error { ErrorBanner(message: error) }

                if let result {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(result.ready ? "Pytania gotowe" : "Za mało pytań", systemImage: result.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(result.ready ? QV.teal : QV.gold)
                        if let msg = result.message { Text(msg).font(.footnote).foregroundStyle(QV.textSecondary) }
                        HStack(spacing: 8) {
                            if let n = result.generated, n > 0 { RewardBadge(text: "\(n) wygenerowanych", color: QV.blue, icon: "sparkles") }
                            if let n = result.accepted, n > 0 { RewardBadge(text: "\(n) zweryfikowanych", color: QV.teal, icon: "checkmark") }
                            if let n = result.sentToReview, n > 0 { RewardBadge(text: "\(n) do redakcji", color: QV.gold, icon: "eye") }
                        }
                        if result.ready {
                            Button("Rozpocznij quiz") {
                                app.startQuiz(QuizRequest(mode: .ai, categoryId: categoryId,
                                                          subcategoryId: subcategoryId == 0 ? nil : subcategoryId,
                                                          difficulty: difficulty, count: count))
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .glassCard(glow: result.ready ? QV.teal : QV.gold)
                }

                Button {
                    Task { await generate() }
                } label: {
                    if busy {
                        HStack(spacing: 10) { ProgressView().tint(.white); Text("Generuję i weryfikuję…") }
                    } else {
                        Label("Przygotuj pytania", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Quiz AI")
        .onAppear { if let initialCategory { categoryId = initialCategory } }
        .onChange(of: categoryId) { subcategoryId = 0; result = nil }
    }

    private func generate() async {
        busy = true; error = nil; result = nil
        defer { busy = false }
        do {
            result = try await app.backend.generateAIQuestions(categoryId: categoryId, subcategoryId: subcategoryId == 0 ? nil : subcategoryId,
                                                               difficulty: difficulty, count: count)
        } catch {
            self.error = app.message(for: error)
        }
    }
}
