import SwiftUI

// MARK: - Awatar z ramką

struct AvatarView: View {
    let symbol: String
    let colorHex: String
    var frame: String = "none"
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: colorHex), Color(hex: colorHex).opacity(0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(frameOverlay)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var frameOverlay: some View {
        let w = max(2, size * 0.06)
        switch frame {
        case "bronze": Circle().stroke(QV.tierColor("bronze"), lineWidth: w).padding(-w)
        case "silver": Circle().stroke(QV.tierColor("silver"), lineWidth: w).padding(-w)
        case "gold": Circle().stroke(QV.goldGradient, lineWidth: w).padding(-w)
        case "platinum": Circle().stroke(QV.tierColor("platinum"), lineWidth: w).padding(-w)
        case "legend":
            Circle().stroke(AngularGradient(colors: [QV.gold, QV.violet, QV.blue, QV.gold], center: .center), lineWidth: w * 1.3)
                .padding(-w * 1.3).shadow(color: QV.gold.opacity(0.7), radius: 6)
        case "orbit":
            Circle().stroke(QV.blue.opacity(0.8), style: StrokeStyle(lineWidth: w * 0.6, dash: [4, 5])).padding(-w * 1.6)
        case "supernova":
            Circle().stroke(AngularGradient(colors: [QV.red, QV.gold, QV.red], center: .center), lineWidth: w)
                .padding(-w).shadow(color: QV.red.opacity(0.7), radius: 8)
        case "singularity":
            Circle().stroke(AngularGradient(colors: [.black, QV.violet, .white, QV.violet, .black], center: .center), lineWidth: w * 1.4)
                .padding(-w * 1.4).shadow(color: QV.violet, radius: 10)
        default: EmptyView()
        }
    }
}

// MARK: - Emblemat ligi

struct LeagueEmblem: View {
    let league: League
    var size: CGFloat = 64

    var body: some View {
        let color = Color(hex: league.colorHex)
        ZStack {
            Hexagon()
                .fill(LinearGradient(colors: [color, color.opacity(0.35)], startPoint: .top, endPoint: .bottom))
            Hexagon().stroke(.white.opacity(0.35), lineWidth: 1.2)
            VStack(spacing: 0) {
                Image(systemName: league.emblem).font(.system(size: size * 0.32, weight: .bold))
                Text(league.roman).font(.system(size: size * 0.16, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
        }
        .frame(width: size, height: size * 1.08)
        .shadow(color: color.opacity(0.6), radius: size * 0.18)
        .accessibilityLabel("Liga \(league.name)")
    }
}

struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w / 2, y: 0))
        p.addLine(to: CGPoint(x: w, y: h * 0.25))
        p.addLine(to: CGPoint(x: w, y: h * 0.75))
        p.addLine(to: CGPoint(x: w / 2, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.75))
        p.addLine(to: CGPoint(x: 0, y: h * 0.25))
        p.closeSubpath()
        return p
    }
}

// MARK: - Ikona kategorii

struct CategoryIcon: View {
    let icon: String
    let colorHex: String
    var size: CGFloat = 44

    var body: some View {
        let c = Color(hex: colorHex)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(c.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).stroke(c.opacity(0.45)))
            .overlay(Image(systemName: icon).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(c))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Chipy i wybór segmentów

struct Chip: View {
    let title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? .white : QV.textSecondary)
                .background(Capsule().fill(selected ? AnyShapeStyle(QV.brandGradient) : AnyShapeStyle(Color.white.opacity(0.06))))
                .overlay(Capsule().stroke(selected ? Color.white.opacity(0.25) : QV.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChipRow<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Chip(title: label(item), selected: item == selection) {
                        withAnimation(.snappy) { selection = item }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Ładowanie danych

enum Loadable<T> {
    case idle, loading, loaded(T), failed(String)

    var value: T? { if case .loaded(let v) = self { return v } else { return nil } }
    var error: String? { if case .failed(let e) = self { return e } else { return nil } }
}

struct LoadingView: View {
    var text: String = "Ładowanie…"
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(QV.violet).controlSize(.large)
            Text(text).font(.footnote).foregroundStyle(QV.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// Wspólna oprawa ekranu: kosmiczne tło, pasek trybu demo, przezroczysty pasek nawigacji.
struct ScreenChrome: ViewModifier {
    @Environment(AppState.self) private var app
    let title: String

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(StarfieldBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(QV.background.opacity(0.85), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if app.isDemo { DemoBanner() }
            }
    }
}

extension View {
    func screenChrome(_ title: String) -> some View { modifier(ScreenChrome(title: title)) }
}

// MARK: - Drobne formatowanie

enum Fmt {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func number(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "pl_PL")
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func seconds(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return String(format: "%.1f s", ms / 1000).replacingOccurrences(of: ".", with: ",")
    }
    /// Polska odmiana: 1 pytanie, 2 pytania, 5 pytań.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if n == 1 { return "\(n) \(one)" }
        let r10 = n % 10, r100 = n % 100
        if (2...4).contains(r10) && !(12...14).contains(r100) { return "\(n) \(few)" }
        return "\(n) \(many)"
    }
}

struct RewardBadge: View {
    let text: String
    var color: Color = QV.gold
    var icon: String = "star.fill"
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).fontWeight(.bold)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}
