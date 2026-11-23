import Foundation

/// Lokalny katalog treści (content.json generowany przez scripts/build_content.py).
/// Używany w trybie demonstracyjnym oraz jako cache katalogu kategorii/lig.
struct ContentBundle: Decodable {
    struct LeagueDTO: Decodable { let id: Int; let code: String; let name: String; let roman: String; let colorHex: String; let emblem: String; let description: String }
    struct CategoryDTO: Decodable { let id: Int; let slug: String; let name: String; let icon: String; let colorHex: String; let description: String; let sortOrder: Int }
    struct SubcategoryDTO: Decodable { let id: Int; let categoryId: Int; let slug: String; let name: String; let description: String; let treeParentId: Int?; let unlockCorrect: Int; let sortOrder: Int }
    struct AnswerDTO: Decodable { let id: String; let body: String; let isCorrect: Bool; let position: Int }
    struct QuestionDTO: Decodable {
        let id: String; let categoryId: Int; let subcategoryId: Int?; let difficulty: Int; let kind: String
        let prompt: String; let clues: [String]?; let explanation: String; let articleSlug: String?
        let sources: [SourceRef]; let answers: [AnswerDTO]
    }
    struct MissionDTO: Decodable { let id: Int; let code: String; let period: String; let title: String; let description: String; let icon: String; let metric: String; let param: String?; let target: Int; let xpReward: Int; let lpReward: Int }
    struct AchievementDTO: Decodable { let id: Int; let code: String; let category: String; let name: String; let description: String; let icon: String; let rarity: String; let tier: String; let metric: String; let threshold: Int; let xpReward: Int }
    struct CardDTO: Decodable { let id: Int; let code: String; let name: String; let description: String; let kind: String; let categoryId: Int; let rarity: String; let art: String; let era: String? }

    let leagues: [LeagueDTO]
    let categories: [CategoryDTO]
    let subcategories: [SubcategoryDTO]
    let articles: [Article]
    let questions: [QuestionDTO]
    let missions: [MissionDTO]
    let achievements: [AchievementDTO]
    let cards: [CardDTO]

    static func load() -> ContentBundle {
        guard let url = Bundle.main.url(forResource: "content", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Brak content.json w zasobach aplikacji – uruchom scripts/build_content.py")
        }
        do { return try JSONDecoder.qv.decode(ContentBundle.self, from: data) } catch {
            fatalError("content.json uszkodzony: \(error)")
        }
    }

    func league(_ id: Int) -> League {
        let l = leagues.first { $0.id == id } ?? leagues[0]
        return League(id: l.id, code: l.code, name: l.name, roman: l.roman, colorHex: l.colorHex, emblem: l.emblem, description: l.description)
    }

    var allLeagues: [League] { leagues.map { league($0.id) } }
}
