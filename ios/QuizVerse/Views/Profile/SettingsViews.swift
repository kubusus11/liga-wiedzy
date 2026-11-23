import SwiftUI

// MARK: - Personalizacja profilu

struct CustomizeProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bio = ""
    @State private var avatar = "atom"
    @State private var avatarColor = "#8B5CF6"
    @State private var frame = "none"
    @State private var background = "nebula"
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let level = app.player?.level ?? 1
        let highest = app.player?.highestLeagueId ?? 1
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Podgląd
                VStack(spacing: 8) {
                    AvatarView(symbol: avatar, colorHex: avatarColor, frame: frame, size: 86).padding(.top, 18)
                    Text(displayName.isEmpty ? (app.player?.username ?? "") : displayName).font(.title3.weight(.heavy)).foregroundStyle(.white)
                    Text(title.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(QV.gold).padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity)
                .background(ProfileBackdrop(code: background).opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Nazwa i opis")
                    TextField("Wyświetlana nazwa", text: $displayName)
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                    TextField("Krótki opis (do 160 znaków)", text: $bio, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                        .onChange(of: bio) { if bio.count > 160 { bio = String(bio.prefix(160)) } }
                }
                .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Awatar")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                        ForEach(Rules.avatars, id: \.self) { a in
                            Button { avatar = a } label: {
                                AvatarView(symbol: a, colorHex: avatarColor, size: 48)
                                    .overlay(Circle().stroke(avatar == a ? QV.blue : .clear, lineWidth: 3).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Awatar \(a)")
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(Rules.avatarColors, id: \.self) { c in
                            Button { avatarColor = c } label: {
                                Circle().fill(Color(hex: c)).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(.white, lineWidth: avatarColor == c ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Kolor \(c)")
                        }
                    }
                }

                cosmeticPicker("Ramka", Rules.frames, selection: $frame, level: level, highest: highest)
                cosmeticPicker("Tło profilu", Rules.backgrounds, selection: $background, level: level, highest: highest)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Tytuł", subtitle: "Kolejne tytuły odblokowujesz poziomami")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Rules.titles, id: \.title) { t in
                                let unlocked = Rules.unlockedTitles(level: level).contains(t.title)
                                Chip(title: unlocked ? t.title : "🔒 \(t.title)", selected: title == t.title) {
                                    if unlocked { title = t.title }
                                }
                                .disabled(!unlocked)
                            }
                        }
                    }
                }

                if let error { ErrorBanner(message: error) }

                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().tint(.white) } else { Text("Zapisz zmiany") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .screenChrome("Personalizacja")
        .onAppear(perform: fill)
    }

    private func cosmeticPicker(_ header: String, _ items: [Rules.Cosmetic], selection: Binding<String>, level: Int, highest: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: header)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    let unlocked = item.unlocked(level: level, highestLeague: highest)
                    Button { if unlocked { selection.wrappedValue = item.code } } label: {
                        VStack(spacing: 4) {
                            Text(item.name).font(.footnote.weight(.bold)).foregroundStyle(unlocked ? .white : QV.textSecondary)
                            Text(unlocked ? "Odblokowane" : item.requirement).font(.caption2)
                                .foregroundStyle(unlocked ? QV.teal : QV.gold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selection.wrappedValue == item.code ? QV.violet : QV.stroke, lineWidth: 2))
                        .opacity(unlocked ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func fill() {
        guard let p = app.player else { return }
        displayName = p.displayName ?? ""
        bio = p.bio ?? ""
        avatar = p.avatar
        avatarColor = p.avatarColor
        frame = p.frame
        background = p.background
        title = p.title
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await app.backend.updateProfile(ProfileUpdate(displayName: displayName.trimmingCharacters(in: .whitespaces), avatar: avatar,
                                                              avatarColor: avatarColor, frame: frame, background: background,
                                                              selectedTitle: title, bio: bio))
            await app.refreshPlayer()
            app.showToast("Profil zapisany")
            dismiss()
        } catch {
            self.error = app.message(for: error)
        }
    }
}

// MARK: - Ustawienia

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var prefs: [String: Bool] = [:]
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var error: String?
    @State private var pushStatus = ""

    // Klucze zgodne z profiles.notifications i PREF_BY_KIND w funkcji send-push.
    private let prefLabels: [(String, String)] = [
        ("daily", "Quiz dnia i przypomnienia"),
        ("league", "Wyniki tygodnia, awanse i spadki"),
        ("missions", "Misje, osiągnięcia i nagrody"),
        ("reviews", "Pytania do powtórki"),
    ]

    var body: some View {
        Form {
            if app.isDemo {
                Section {
                    Label("Aplikacja działa w trybie demonstracyjnym. Aby korzystać z kont online, prawdziwych lig i generatora AI, uzupełnij plik Config/Secrets.xcconfig (instrukcja w README).",
                          systemImage: "flask.fill")
                        .font(.footnote).foregroundStyle(QV.gold)
                }
            }
            Section("Powiadomienia") {
                ForEach(prefLabels, id: \.0) { pref in
                    Toggle(pref.1, isOn: Binding(get: { prefs[pref.0] ?? true }, set: { prefs[pref.0] = $0; Task { await savePrefs() } }))
                        .tint(QV.violet)
                }
                Button("Zezwól na powiadomienia push") {
                    Task {
                        let ok = await app.requestPushPermission()
                        pushStatus = ok ? "Powiadomienia włączone." : "Brak zgody – możesz ją nadać w Ustawieniach iOS."
                    }
                }
                if !pushStatus.isEmpty { Text(pushStatus).font(.caption).foregroundStyle(QV.textSecondary) }
            }
            Section("Zasady") {
                NavigationLink("Zasady lig i punktacji") { LeagueRulesContent() }
                NavigationLink("Prywatność i dane") { PrivacyView() }
                LabeledContent("Model biznesowy", value: "100% za darmo")
                LabeledContent("Wersja", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            }
            Section("Konto") {
                Button("Wyloguj się") { confirmSignOut = true }
                Button("Usuń konto", role: .destructive) { confirmDelete = true }
                if let error { Text(error).foregroundStyle(QV.red).font(.footnote) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(StarfieldBackground(intensity: 0.5))
        .navigationTitle("Ustawienia")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { prefs = app.player?.notifications ?? [:] }
        .confirmationDialog("Wylogować się?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Wyloguj", role: .destructive) { Task { await app.signOut() } }
        }
        .alert("Usunąć konto?", isPresented: $confirmDelete) {
            Button("Usuń na zawsze", role: .destructive) { Task { await deleteAccount() } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Wszystkie dane – postępy, statystyki, karty i historia lig – zostaną trwale usunięte. Tej operacji nie można cofnąć.")
        }
    }

    private func savePrefs() async {
        do { try await app.backend.updateProfile(ProfileUpdate(notifications: prefs)) } catch { self.error = app.message(for: error) }
    }

    private func deleteAccount() async {
        do {
            try await app.backend.deleteAccount()
            await app.signOut()
        } catch {
            self.error = app.message(for: error)
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                item("Jakie dane przechowujemy", "Adres e-mail (logowanie), nazwę gracza, ustawienia profilu, wyniki quizów, statystyki, postępy w ligach i zdobyte nagrody.")
                item("Po co", "Wyłącznie do działania gry: rankingów, lig, misji, powtórek i rekomendacji Mentora AI. Nie wyświetlamy reklam i nie sprzedajemy danych.")
                item("Bezpieczeństwo", "Punkty liczy wyłącznie serwer. Poprawne odpowiedzi nie są wysyłane do aplikacji przed udzieleniem odpowiedzi. Dostęp do danych chronią reguły Row Level Security.")
                item("Mentor i generator AI", "Do modelu AI trafiają tylko zagregowane statystyki nauki (skuteczność w kategoriach) i Twoja wiadomość – bez adresu e-mail.")
                item("Usunięcie konta", "W Ustawieniach możesz w każdej chwili trwale usunąć konto wraz ze wszystkimi danymi.")
            }
            .padding(16)
        }
        .background(StarfieldBackground(intensity: 0.5))
        .navigationTitle("Prywatność")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(text).font(.subheadline).foregroundStyle(QV.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}
