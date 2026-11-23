import SwiftUI

/// Identyfikacja wizualna QUIZVERSE: głęboka czerń, fiolet (przewodni), jasny błękit (akcent),
/// złoto (nagrody), turkus (sukces), czerwień (ostrzeżenia).
enum QV {
    static let background = Color(hex: "#05040A")
    static let surface = Color(hex: "#110E1C")
    static let surfaceHigh = Color(hex: "#1B1630")
    static let violet = Color(hex: "#8B5CF6")
    static let violetDeep = Color(hex: "#5B21B6")
    static let blue = Color(hex: "#7DD3FC")
    static let gold = Color(hex: "#F5C542")
    static let teal = Color(hex: "#2DD4BF")
    static let red = Color(hex: "#F43F5E")
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let stroke = Color.white.opacity(0.08)

    static let brandGradient = LinearGradient(colors: [violet, Color(hex: "#6D28D9"), blue.opacity(0.9)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    static let goldGradient = LinearGradient(colors: [Color(hex: "#FDE68A"), gold, Color(hex: "#B45309")],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let successGradient = LinearGradient(colors: [teal, Color(hex: "#0EA5E9")],
                                                startPoint: .leading, endPoint: .trailing)

    static let difficultyNames = ["Początkujący", "Łatwy", "Średni", "Trudny", "Ekspercki", "Akademicki"]
    static func difficultyName(_ d: Int) -> String { difficultyNames[max(1, min(6, d)) - 1] }

    static func rarityColor(_ rarity: String) -> Color {
        switch rarity {
        case "legendary": return gold
        case "epic": return violet
        case "rare": return blue
        default: return Color.white.opacity(0.7)
        }
    }

    static func rarityName(_ rarity: String) -> String {
        switch rarity {
        case "legendary": return "Legendarna"
        case "epic": return "Epicka"
        case "rare": return "Rzadka"
        default: return "Zwykła"
        }
    }

    static func tierColor(_ tier: String) -> Color {
        switch tier {
        case "platinum": return Color(hex: "#7FE7F2")
        case "gold": return gold
        case "silver": return Color(hex: "#C0C7D1")
        default: return Color(hex: "#CD7F32")
        }
    }

    static func tierName(_ tier: String) -> String {
        switch tier {
        case "platinum": return "Platynowa"
        case "gold": return "Złota"
        case "silver": return "Srebrna"
        default: return "Brązowa"
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
        } else {
            r = 1; g = 1; b = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Tło kosmiczne

struct StarfieldBackground: View {
    var intensity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var rng = SeededRandom(seed: 42)
                for _ in 0..<110 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height
                    let r = 0.4 + rng.next() * 1.4
                    let phase = rng.next() * .pi * 2
                    let twinkle = reduceMotion ? 0.7 : 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (0.6 + rng.next()) + phase))
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                             with: .color(.white.opacity(twinkle * 0.8 * intensity)))
                }
            }
        }
        .background(
            ZStack {
                QV.background
                RadialGradient(colors: [QV.violetDeep.opacity(0.45 * intensity), .clear],
                               center: .topTrailing, startRadius: 10, endRadius: 520)
                RadialGradient(colors: [QV.blue.opacity(0.14 * intensity), .clear],
                               center: .bottomLeading, startRadius: 10, endRadius: 460)
            }
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) % 1_000_000) / 1_000_000
    }
}

// MARK: - Karty i przyciski

struct GlassCard: ViewModifier {
    var padding: CGFloat = 16
    var glow: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [QV.surfaceHigh.opacity(0.92), QV.surface.opacity(0.92)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(LinearGradient(colors: [(glow ?? .white).opacity(0.35), QV.stroke],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: (glow ?? .clear).opacity(0.25), radius: 18, y: 6)
    }
}

extension View {
    func glassCard(padding: CGFloat = 16, glow: Color? = nil) -> some View {
        modifier(GlassCard(padding: padding, glow: glow))
    }

    func screenBackground() -> some View {
        background(StarfieldBackground())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var gradient: LinearGradient = QV.brandGradient
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(gradient))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.18)))
            .shadow(color: QV.violet.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(QV.blue)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(QV.blue.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(QV.blue.opacity(0.35)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var actionTitle: String = "Wszystko"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(QV.blue)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(QV.textSecondary)
                }
            }
            Spacer()
            if let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(QV.violet)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProgressBar: View {
    var value: Double
    var gradient: LinearGradient = QV.brandGradient
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(gradient)
                    .frame(width: max(height, geo.size.width * min(1, max(0, value))))
                    .shadow(color: QV.violet.opacity(0.5), radius: 6)
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int(value * 100)) procent")
    }
}

struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    var color: Color = QV.blue

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(value).font(.system(.headline, design: .rounded).weight(.bold)).foregroundStyle(.white)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(QV.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
        .accessibilityElement(children: .combine)
    }
}

struct DemoBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flask.fill")
            Text("TRYB DEMONSTRACYJNY").fontWeight(.heavy).tracking(1.2)
            Text("· dane lokalne, rywale symulowani").foregroundStyle(.black.opacity(0.7))
        }
        .font(.caption2)
        .foregroundStyle(.black)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(QV.gold)
        .accessibilityLabel("Tryb demonstracyjny. Backend nie jest skonfigurowany, dane są lokalne, rywale w lidze są symulowani.")
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(QV.violet)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(message).font(.subheadline).foregroundStyle(QV.textSecondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(QV.red)
            Text(message).font(.footnote).foregroundStyle(.white)
            Spacer()
            if let retry { Button("Ponów", action: retry).font(.footnote.bold()).foregroundStyle(QV.blue) }
        }
        .glassCard(padding: 12, glow: QV.red)
    }
}
