import SwiftUI

struct EncyclopediaView: View {
    @Environment(AppState.self) private var app
    @State private var articles: Loadable<[Article]> = .idle
    @State private var favorites: Set<Int> = []
    @State private var search = ""
    @State private var onlyFavorites = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Szukaj hasła", text: $search)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                    .foregroundStyle(.white)
                Toggle("Tylko ulubione", isOn: $onlyFavorites).tint(QV.gold).foregroundStyle(.white)

                switch articles {
                case .idle, .loading: LoadingView()
                case .failed(let e): ErrorBanner(message: e) { Task { await load() } }
                case .loaded(let list):
                    let items = list.filter {
                        (!onlyFavorites || favorites.contains($0.id)) &&
                        (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search))
                    }
                    if items.isEmpty {
                        EmptyStateView(icon: onlyFavorites ? "star" : "magnifyingglass",
                                       title: onlyFavorites ? "Brak ulubionych" : "Nic nie znaleziono",
                                       message: onlyFavorites ? "Dodaj artykuł do ulubionych gwiazdką." : "Spróbuj innego hasła.")
                    }
                    ForEach(items) { a in
                        NavigationLink { ArticleView(article: a) } label: {
                            ArticleRow(article: a, favorite: favorites.contains(a.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Encyklopedia")
        .task { await load() }
    }

    private func load() async {
        if articles.value == nil { articles = .loading }
        do {
            articles = .loaded(try await app.backend.articles())
            favorites = try await app.backend.favoriteArticleIds()
        } catch {
            articles = .failed(app.message(for: error))
        }
    }
}

struct ArticleRow: View {
    let article: Article
    var favorite = false
    @Environment(AppState.self) private var app

    var body: some View {
        let cat = app.category(article.categoryId)
        HStack(spacing: 12) {
            CategoryIcon(icon: cat?.icon ?? "book.fill", colorHex: cat?.colorHex ?? "#8B5CF6", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                Text(article.summary).font(.caption).foregroundStyle(QV.textSecondary).lineLimit(2)
            }
            Spacer()
            if favorite { Image(systemName: "star.fill").foregroundStyle(QV.gold) }
        }
        .glassCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

struct ArticleView: View {
    let article: Article
    @Environment(AppState.self) private var app
    @State private var favorite = false
    @State private var all: [Article] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = app.category(article.categoryId) {
                    Label(c.name, systemImage: c.icon).font(.caption.weight(.heavy)).foregroundStyle(Color(hex: c.colorHex))
                }
                Text(article.title).font(.system(.largeTitle, design: .rounded).weight(.heavy)).foregroundStyle(.white)
                Text(article.summary).font(.headline).foregroundStyle(QV.blue)
                Text(article.body).font(.body).foregroundStyle(.white.opacity(0.9)).lineSpacing(4)

                if !article.keyFacts.isEmpty {
                    block("Najważniejsze fakty", "lightbulb.fill", QV.gold) {
                        ForEach(article.keyFacts, id: \.self) { f in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(QV.gold).frame(width: 6, height: 6).padding(.top, 7)
                                Text(f).font(.subheadline).foregroundStyle(.white)
                            }
                        }
                    }
                }
                if !article.dates.isEmpty {
                    block("Ważne daty", "calendar", QV.blue) {
                        ForEach(article.dates, id: \.self) { d in
                            HStack(alignment: .top, spacing: 12) {
                                Text(d.date).font(.subheadline.weight(.heavy).monospacedDigit()).foregroundStyle(QV.blue).frame(minWidth: 56, alignment: .leading)
                                Text(d.label).font(.subheadline).foregroundStyle(.white)
                            }
                        }
                    }
                }
                if !article.terms.isEmpty {
                    block("Pojęcia", "text.book.closed.fill", QV.violet) {
                        ForEach(article.terms, id: \.self) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.term).font(.subheadline.weight(.bold)).foregroundStyle(QV.violet)
                                Text(t.definition).font(.subheadline).foregroundStyle(.white)
                            }
                        }
                    }
                }
                let related = all.filter { article.relatedSlugs.contains($0.slug) }
                if !related.isEmpty {
                    SectionHeader(title: "Powiązane hasła")
                    ForEach(related) { r in
                        NavigationLink { ArticleView(article: r) } label: { ArticleRow(article: r) }.buttonStyle(.plain)
                    }
                }
                if !article.sources.isEmpty {
                    block("Źródła", "link", QV.teal) {
                        ForEach(article.sources, id: \.self) { s in
                            if let u = s.url, let url = URL(string: u) {
                                Link(s.title, destination: url).font(.subheadline).foregroundStyle(QV.blue)
                            } else {
                                Text(s.title).font(.subheadline).foregroundStyle(QV.textSecondary)
                            }
                        }
                    }
                }
                if app.activeQuiz == nil {
                    Button("Quiz z tej dziedziny") {
                        app.startQuiz(QuizRequest(mode: .thematic, categoryId: article.categoryId, subcategoryId: article.subcategoryId, count: 5))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Encyklopedia")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if let v = try? await app.backend.toggleFavorite(articleId: article.id) { favorite = v }
                    }
                } label: { Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(QV.gold) }
                .accessibilityLabel(favorite ? "Usuń z ulubionych" : "Dodaj do ulubionych")
            }
        }
        .task {
            favorite = (try? await app.backend.favoriteArticleIds().contains(article.id)) ?? false
            all = (try? await app.backend.articles()) ?? []
        }
    }

    private func block<Content: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: icon).font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(color)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}

/// Otwiera artykuł po slugu (np. z ekranu wyjaśnienia pytania).
struct ArticleLoaderView: View {
    let slug: String
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var article: Article?
    @State private var missing = false

    var body: some View {
        Group {
            if let article {
                ArticleView(article: article)
            } else if missing {
                EmptyStateView(icon: "book.closed", title: "Brak artykułu", message: "Ten artykuł nie jest jeszcze dostępny.")
            } else {
                LoadingView()
            }
        }
        .background(StarfieldBackground())
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Zamknij") { dismiss() } } }
        .task {
            let list = (try? await app.backend.articles()) ?? []
            article = list.first { $0.slug == slug }
            missing = article == nil
        }
    }
}
