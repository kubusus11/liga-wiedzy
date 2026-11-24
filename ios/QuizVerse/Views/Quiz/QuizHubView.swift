import SwiftUI

struct QuizHubView: View {
    @Environment(AppState.self) private var app
    @State private var categories: Loadable<[CategoryInfo]> = .idle
    @State private var setup: SetupTarget?
    @State private var search = ""

    private let modes: [QuizMode] = [.daily, .quick, .marathon, .survival, .sprint, .detective, .review, .ai]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Tryby gry", subtitle: "Bez pojedynków – liczy się Twoja wiedza")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(modes) { mode in modeTile(mode) }
                }

                SectionHeader(title: "Kategorie", subtitle: "28 dziedzin wiedzy · quizy tematyczne")
                TextField("Szukaj kategorii", text: $search)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                    .foregroundStyle(.white)

                switch categories {
                case .idle, .loading: LoadingView()
                case .failed(let e): ErrorBanner(message: e) { Task { await load() } }
                case .loaded(let list):
                    let filtered = search.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(search) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { c in
                            NavigationLink { CategoryDetailView(category: c) } label: { CategoryTile(category: c) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Quizy")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { EncyclopediaView() } label: { Image(systemName: "books.vertical.fill") }
                    .accessibilityLabel("Encyklopedia")
            }
        }
        .sheet(item: $setup) { target in QuizSetupSheet(target: target) }
        .task(id: app.refreshToken) { await load() }
    }

    private func load() async {
        if categories.value == nil { categories = .loading }
        do { categories = .loaded(try await app.backend.categories()) } catch { categories = .failed(app.message(for: error)) }
    }

    private func modeTile(_ mode: QuizMode) -> some View {
        Group {
            if mode == .ai {
                NavigationLink { AIGeneratorView() } label: { modeLabel(mode) }
            } else {
                Button {
                    switch mode {
                    case .daily:
                        app.startQuiz(QuizRequest(mode: .daily, count: 10))
                    case .review:
                        app.startQuiz(QuizRequest(mode: .review, count: 20))
                    default:
                        setup = SetupTarget(mode: mode)
                    }
                } label: { modeLabel(mode) }
            }
        }
        .buttonStyle(.plain)
    }

    private func modeLabel(_ mode: QuizMode) -> some View {
        let color: Color = {
            switch mode {
            case .daily: return QV.gold
            case .survival: return QV.red
            case .review: return QV.teal
            case .ai, .sprint: return QV.blue
            default: return QV.violet
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: mode.icon).font(.title2).foregroundStyle(color)
            Text(mode.title).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            Text(mode.subtitle).font(.caption2).foregroundStyle(QV.textSecondary).lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14, glow: color)
    }
}

struct CategoryTile: View {
    let category: CategoryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CategoryIcon(icon: category.icon, colorHex: category.colorHex, size: 38)
                Spacer()
                if category.answered > 0 {
                    Text(Fmt.percent(category.accuracy)).font(.caption.weight(.bold)).foregroundStyle(QV.teal)
                }
            }
            Text(category.name).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(2, reservesSpace: true)
            Text("\(category.questions) pytań · \(category.subcategories.count) działów").font(.caption2).foregroundStyle(QV.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 12, glow: Color(hex: category.colorHex))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Konfiguracja quizu

struct SetupTarget: Identifiable {
    let id = UUID()
    let mode: QuizMode
    var categoryId: Int? = nil
    var subcategoryId: Int? = nil
    var subcategoryName: String? = nil
}

struct QuizSetupSheet: View {
    let target: SetupTarget
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var difficulty: Int = 0 // 0 = mieszany
    @State private var count: Int = 10
    @State private var sprintSeconds = 60
    @State private var categoryId: Int = 0 // 0 = wszystkie

    private var countOptions: [Int] {
        switch target.mode {
        case .marathon: return [50, 100]
        case .thematic: return [5, 10, 20]
        default: return []
        }
    }

    private var categoryRequired: Bool { target.mode == .thematic }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: target.mode.icon).font(.largeTitle).foregroundStyle(QV.violet)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.mode.title).font(.title2.weight(.heavy)).foregroundStyle(.white)
                            Text(target.mode.subtitle).font(.subheadline).foregroundStyle(QV.textSecondary)
                        }
                    }
                    Text(modeRules).font(.footnote).foregroundStyle(QV.textSecondary).glassCard(padding: 12)

                    if target.categoryId == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Kategoria")
                            Picker("Kategoria", selection: $categoryId) {
                                if !categoryRequired { Text("Wszystkie kategorie").tag(0) }
                                ForEach(app.content.categories, id: \.id) { c in Text(c.name).tag(c.id) }
                            }
                            .pickerStyle(.menu).tint(QV.blue)
                        }
                    } else if let name = target.subcategoryName ?? target.categoryId.flatMap({ app.category($0)?.name }) {
                        Label(name, systemImage: "square.grid.2x2.fill").font(.headline).foregroundStyle(QV.blue)
                    }

                    if target.mode != .detective {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Poziom trudności")
                            ChipRow(items: Array(0...6), selection: $difficulty) { $0 == 0 ? "Mieszany" : QV.difficultyName($0) }
                            if difficulty >= 5 {
                                Text("Quiz ekspercki: +30 XP przy min. 50% poprawnych odpowiedzi.").font(.caption).foregroundStyle(QV.gold)
                            }
                        }
                    }

                    if !countOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Liczba pytań")
                            ChipRow(items: countOptions, selection: $count) { "\($0)" }
                        }
                    }

                    if target.mode == .sprint {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Czas")
                            ChipRow(items: [60, 120], selection: $sprintSeconds) { "\($0) s" }
                        }
                    }

                    Button("Start") { start() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(categoryRequired && categoryId == 0 && target.categoryId == nil)
                }
                .padding(20)
            }
            .screenChrome("Nowy quiz")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } } }
            .onAppear {
                if let first = countOptions.first { count = countOptions.contains(10) ? 10 : first }
                if categoryRequired, target.categoryId == nil { categoryId = app.content.categories.first?.id ?? 1 }
            }
        }
        .presentationDetents([.large])
    }

    private var modeRules: String {
        switch target.mode {
        case .quick: return "10 losowych pytań z dowolnych kategorii. Ukończenie daje 20 LP (przy min. 40% poprawnych)."
        case .marathon: return "Długa sesja 50 lub 100 pytań. 10 LP za każde 5 pytań. Bezbłędny maraton odblokowuje misję specjalną."
        case .survival: return "Odpowiadaj, dopóki się nie pomylisz. 10 LP za każde 5 poprawnych odpowiedzi (maks. 60 LP)."
        case .sprint: return "Jak najwięcej poprawnych odpowiedzi w limicie czasu. 10 LP za każde 5 poprawnych (maks. 60 LP)."
        case .thematic: return "Quiz z wybranej kategorii lub działu. 5 pytań: 10 LP · 10 pytań: 20 LP · 20 pytań: 40 LP."
        case .detective: return "5 zagadek. Każda składa się z kilku wskazówek – połącz fakty i wskaż właściwą odpowiedź. 10 LP."
        default: return target.mode.subtitle
        }
    }

    private func start() {
        let cat = target.categoryId ?? (categoryId == 0 ? nil : categoryId)
        var req = QuizRequest(mode: target.mode, categoryId: cat, subcategoryId: target.subcategoryId,
                              difficulty: difficulty == 0 ? nil : difficulty)
        switch target.mode {
        case .quick: req.count = 10
        case .marathon, .thematic: req.count = count
        case .detective: req.count = 5
        case .sprint: req.timeLimit = sprintSeconds; req.count = sprintSeconds == 60 ? 40 : 80
        case .survival: req.count = 100
        default: break
        }
        dismiss()
        // Krótkie opóźnienie, aby arkusz zdążył się zamknąć przed pełnoekranowym quizem.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            app.startQuiz(req)
        }
    }
}

// MARK: - Szczegóły kategorii

struct CategoryDetailView: View {
    let category: CategoryInfo
    @Environment(AppState.self) private var app
    @State private var tree: [TreeNode] = []
    @State private var setup: SetupTarget?
    @State private var articles: [Article] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    CategoryIcon(icon: category.icon, colorHex: category.colorHex, size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.name).font(.title2.weight(.heavy)).foregroundStyle(.white)
                        Text(category.description).font(.footnote).foregroundStyle(QV.textSecondary)
                    }
                }
                HStack(spacing: 8) {
                    StatPill(icon: "questionmark.circle.fill", value: "\(category.questions)", label: "Pytań")
                    StatPill(icon: "checkmark.seal.fill", value: "\(category.correct)", label: "Trafień", color: QV.teal)
                    StatPill(icon: "scope", value: category.answered > 0 ? Fmt.percent(category.accuracy) : "—", label: "Skuteczność", color: QV.gold)
                }
                Button("Quiz z całej kategorii") {
                    setup = SetupTarget(mode: .thematic, categoryId: category.id)
                }
                .buttonStyle(PrimaryButtonStyle())

                HStack(spacing: 10) {
                    NavigationLink { KnowledgeTreeView(category: category) } label: {
                        Label("Drzewko wiedzy", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    NavigationLink { AIGeneratorView(initialCategory: category.id) } label: {
                        Label("Pytania AI", systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                SectionHeader(title: "Działy", subtitle: "Odblokowuj kolejne działy poprawnymi odpowiedziami")
                ForEach(tree) { node in
                    Button {
                        if node.unlocked {
                            setup = SetupTarget(mode: .thematic, categoryId: category.id, subcategoryId: node.id, subcategoryName: node.name)
                        } else {
                            app.showToast("Dział zablokowany – zdobądź \(node.unlockCorrect) poprawne w poprzednim dziale")
                        }
                    } label: { SubcategoryRow(node: node, colorHex: category.colorHex) }
                    .buttonStyle(.plain)
                }

                if !articles.isEmpty {
                    SectionHeader(title: "Encyklopedia")
                    ForEach(articles) { a in
                        NavigationLink { ArticleView(article: a) } label: { ArticleRow(article: a) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome(category.name)
        .sheet(item: $setup) { QuizSetupSheet(target: $0) }
        .task(id: app.refreshToken) {
            tree = (try? await app.backend.knowledgeTree(categoryId: category.id)) ?? []
            articles = ((try? await app.backend.articles()) ?? []).filter { $0.categoryId == category.id }
        }
    }
}

struct SubcategoryRow: View {
    let node: TreeNode
    let colorHex: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.unlocked ? "circle.hexagongrid.fill" : "lock.fill")
                .foregroundStyle(node.unlocked ? Color(hex: colorHex) : QV.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name).font(.subheadline.weight(.semibold)).foregroundStyle(node.unlocked ? .white : QV.textSecondary)
                if node.unlocked {
                    Text("\(node.questions) pytań · \(node.correct)/\(node.answered) poprawnych").font(.caption2).foregroundStyle(QV.textSecondary)
                } else {
                    Text("Odblokowanie: \(min(node.parentCorrect, node.unlockCorrect))/\(node.unlockCorrect) poprawnych w poprzednim dziale")
                        .font(.caption2).foregroundStyle(QV.gold)
                }
            }
            Spacer()
            if node.unlocked { Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(QV.violet) }
        }
        .glassCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Drzewko wiedzy

struct KnowledgeTreeView: View {
    let category: CategoryInfo
    @Environment(AppState.self) private var app
    @State private var nodes: [TreeNode] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Każdy dział otwiera kolejny. Zdobądź wymaganą liczbę poprawnych odpowiedzi w dziale nadrzędnym, aby przejść dalej.")
                    .font(.footnote).foregroundStyle(QV.textSecondary).padding(.bottom, 16)
                ForEach(roots) { root in
                    branch(root, depth: 0)
                }
            }
            .padding(16)
        }
        .screenChrome("Drzewko: \(category.name)")
        .task { nodes = (try? await app.backend.knowledgeTree(categoryId: category.id)) ?? [] }
    }

    private var roots: [TreeNode] { nodes.filter { $0.parentId == nil } }

    private func children(of id: Int) -> [TreeNode] { nodes.filter { $0.parentId == id } }

    private func branch(_ node: TreeNode, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if depth > 0 {
                        Rectangle().fill(node.unlocked ? QV.violet : QV.stroke).frame(width: 2, height: 30)
                            .padding(.leading, CGFloat(depth - 1) * 22 + 12)
                    }
                    ZStack {
                        Circle().fill(node.unlocked ? AnyShapeStyle(QV.brandGradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                            .frame(width: 34, height: 34)
                        Image(systemName: node.unlocked ? (node.correct >= node.unlockCorrect ? "star.fill" : "circle.fill") : "lock.fill")
                            .font(.caption.bold()).foregroundStyle(.white)
                    }
                    .shadow(color: node.unlocked ? QV.violet.opacity(0.6) : .clear, radius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.subheadline.weight(.semibold)).foregroundStyle(node.unlocked ? .white : QV.textSecondary)
                        Text(node.unlocked ? "\(node.correct) poprawnych" : "Wymaga \(node.unlockCorrect) poprawnych wyżej")
                            .font(.caption2).foregroundStyle(node.unlocked ? QV.teal : QV.gold)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                ForEach(children(of: node.id)) { child in branch(child, depth: depth + 1) }
            }
        )
    }
}
