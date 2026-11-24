import SwiftUI

struct BrandLogo: View {
    var size: CGFloat = 1
    @State private var spin = false

    var body: some View {
        VStack(spacing: 10 * size) {
            ZStack {
                Circle().stroke(QV.violet.opacity(0.35), lineWidth: 1.5 * size).frame(width: 120 * size, height: 120 * size)
                Ellipse().stroke(QV.blue.opacity(0.7), lineWidth: 1.5 * size)
                    .frame(width: 150 * size, height: 50 * size)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                Circle().fill(QV.brandGradient).frame(width: 70 * size, height: 70 * size)
                    .shadow(color: QV.violet, radius: 24 * size)
                Image(systemName: "sparkles").font(.system(size: 30 * size, weight: .bold)).foregroundStyle(.white)
            }
            .frame(height: 130 * size)
            Text("QUIZVERSE")
                .font(.system(size: 34 * size, weight: .black, design: .rounded))
                .tracking(4 * size)
                .foregroundStyle(QV.brandGradient)
            Text("UNIVERSE OF KNOWLEDGE")
                .font(.system(size: 11 * size, weight: .bold, design: .rounded))
                .tracking(3 * size)
                .foregroundStyle(QV.textSecondary)
        }
        .onAppear { withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("QUIZVERSE – Universe of Knowledge")
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 28) {
            BrandLogo()
            Text("KNOWLEDGE IS POWER")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .tracking(3)
                .foregroundStyle(QV.gold)
            ProgressView().tint(QV.blue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StarfieldBackground())
    }
}

// MARK: - Powitanie

struct OnboardingFlow: View {
    enum Step { case intro, register, login, reset }
    @State private var step: Step = .intro

    var body: some View {
        ZStack {
            StarfieldBackground()
            switch step {
            case .intro: IntroPager { step = .register } onLogin: { step = .login }
            case .register: AuthView(mode: .register, step: $step)
            case .login: AuthView(mode: .login, step: $step)
            case .reset: AuthView(mode: .reset, step: $step)
            }
        }
        .animation(.easeInOut, value: step)
    }
}

private struct IntroPage: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let text: String
    let color: Color
}

struct IntroPager: View {
    var onStart: () -> Void
    var onLogin: () -> Void
    @Environment(AppState.self) private var app
    @State private var page = 0

    private let pages: [IntroPage] = [
        .init(id: 0, icon: "sparkles", title: "Wszechświat wiedzy",
              text: "28 kategorii – od historii i nauki po kosmos, sztukę i technologię. Każde pytanie z wyjaśnieniem i źródłem.", color: QV.violet),
        .init(id: 1, icon: "trophy.fill", title: "5 lig, 30 graczy, 7 dni",
              text: "Zdobywaj punkty ligowe (LP) w tygodniowej grupie. Miejsca 1–10 awansują, 24–30 spadają. Co tydzień nowy start.", color: QV.gold),
        .init(id: 2, icon: "brain.head.profile", title: "Ucz się mądrze",
              text: "Inteligentne powtórki, drzewko wiedzy, encyklopedia i Mentor AI, który pomoże zaplanować naukę.", color: QV.blue),
        .init(id: 3, icon: "gift.fill", title: "W pełni darmowe",
              text: "Bez reklam, bez zakupów, bez płatnych przewag. O wyniku decyduje wyłącznie wiedza.", color: QV.teal),
    ]

    var body: some View {
        VStack(spacing: 20) {
            BrandLogo(size: 0.7).padding(.top, 30)
            TabView(selection: $page) {
                ForEach(pages) { p in
                    VStack(spacing: 18) {
                        Image(systemName: p.icon)
                            .font(.system(size: 56, weight: .bold))
                            .foregroundStyle(p.color)
                            .shadow(color: p.color.opacity(0.7), radius: 20)
                        Text(p.title).font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(.white)
                        Text(p.text).font(.body).foregroundStyle(QV.textSecondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 28)
                    }
                    .tag(p.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(maxHeight: 340)

            if app.isDemo {
                Label("Tryb demonstracyjny: backend nie jest skonfigurowany. Konto i postępy zostaną zapisane tylko na tym urządzeniu, a rywale w lidze są symulowani.",
                      systemImage: "flask.fill")
                    .font(.caption)
                    .foregroundStyle(QV.gold)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(QV.gold.opacity(0.1)))
                    .padding(.horizontal, 24)
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Button("Rozpocznij przygodę", action: onStart).buttonStyle(PrimaryButtonStyle())
                Button("Mam już konto", action: onLogin).buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            Text("KNOWLEDGE IS POWER").font(.caption2.weight(.heavy)).tracking(3).foregroundStyle(QV.gold.opacity(0.8))
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Rejestracja, logowanie, reset hasła

struct AuthView: View {
    enum Mode { case register, login, reset }
    let mode: Mode
    @Binding var step: OnboardingFlow.Step
    @Environment(AppState.self) private var app

    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var acceptedRules = false
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @FocusState private var focus: Field?

    enum Field { case username, email, password }

    private var title: String {
        switch mode {
        case .register: return "Utwórz konto"
        case .login: return "Zaloguj się"
        case .reset: return "Reset hasła"
        }
    }

    private var isValid: Bool {
        let emailOK = email.contains("@") && email.contains(".") && email.count >= 5
        switch mode {
        case .register:
            return emailOK && password.count >= 8 && acceptedRules &&
                username.range(of: "^[A-Za-z0-9_.]{3,20}$", options: .regularExpression) != nil
        case .login: return emailOK && !password.isEmpty
        case .reset: return emailOK
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    step = mode == .reset ? .login : .intro
                } label: {
                    Label("Wstecz", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(QV.blue)

                BrandLogo(size: 0.5).frame(maxWidth: .infinity)
                Text(title).font(.system(.largeTitle, design: .rounded).weight(.heavy)).foregroundStyle(.white)

                if mode == .register {
                    field("Nazwa gracza", text: $username, icon: "person.fill", field: .username)
                    Text("3–20 znaków: litery, cyfry, _ lub kropka. Widoczna w rankingach.")
                        .font(.caption).foregroundStyle(QV.textSecondary)
                }
                field("E-mail", text: $email, icon: "envelope.fill", field: .email)
                    .keyboardType(.emailAddress)
                if mode != .reset {
                    field("Hasło", text: $password, icon: "lock.fill", field: .password, secure: true)
                    if mode == .register {
                        Text("Minimum 8 znaków.").font(.caption).foregroundStyle(QV.textSecondary)
                    }
                }

                if mode == .register {
                    Toggle(isOn: $acceptedRules) {
                        Text("Akceptuję zasady fair play: jedno konto na osobę, bez botów i zautomatyzowanych odpowiedzi.")
                            .font(.footnote).foregroundStyle(QV.textSecondary)
                    }
                    .toggleStyle(.switch).tint(QV.violet)
                }

                if let error { ErrorBanner(message: error) }
                if let info {
                    Label(info, systemImage: "checkmark.seal.fill").font(.footnote).foregroundStyle(QV.teal)
                        .glassCard(padding: 12, glow: QV.teal)
                }

                Button {
                    Task { await submit() }
                } label: {
                    if busy { ProgressView().tint(.white) } else {
                        Text(mode == .register ? "Załóż konto" : mode == .login ? "Zaloguj" : "Wyślij link resetujący")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isValid || busy)
                .opacity(isValid ? 1 : 0.5)

                switch mode {
                case .register:
                    Button("Masz konto? Zaloguj się") { step = .login }.foregroundStyle(QV.blue).frame(maxWidth: .infinity)
                case .login:
                    HStack {
                        Button("Nie pamiętam hasła") { step = .reset }
                        Spacer()
                        Button("Załóż konto") { step = .register }
                    }
                    .font(.subheadline).foregroundStyle(QV.blue)
                case .reset:
                    EmptyView()
                }

                if app.isDemo {
                    Label("Tryb demonstracyjny – dane logowania nie są nigdzie wysyłane.", systemImage: "flask.fill")
                        .font(.caption).foregroundStyle(QV.gold)
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focus = mode == .register ? .username : .email }
    }

    private func field(_ placeholder: String, text: Binding<String>, icon: String, field: Field, secure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(QV.violet).frame(width: 20)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: field)
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(focus == field ? QV.violet : QV.stroke))
    }

    private func submit() async {
        busy = true; error = nil; info = nil
        defer { busy = false }
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            switch mode {
            case .register:
                let signedIn = try await app.backend.signUp(email: mail, password: password, username: username)
                if signedIn { await app.didSignIn() } else {
                    info = "Konto utworzone. Sprawdź skrzynkę i potwierdź adres e-mail, a potem zaloguj się."
                }
            case .login:
                try await app.backend.signIn(email: mail, password: password)
                await app.didSignIn()
            case .reset:
                try await app.backend.resetPassword(email: mail)
                info = "Jeśli konto istnieje, wysłaliśmy link do ustawienia nowego hasła."
            }
        } catch {
            self.error = app.message(for: error)
        }
    }
}
