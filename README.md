# QUIZVERSE – Universe of Knowledge

**KNOWLEDGE IS POWER.** Darmowa aplikacja quizowa na iPhone'a: 5 lig, tygodniowe grupy po 30 graczy, sezony, misje,
osiągnięcia, karty kolekcjonerskie, inteligentne powtórki, encyklopedia, drzewko wiedzy, generator pytań AI i Mentor AI.
Bez reklam, bez zakupów, bez pojedynków.

| Warstwa | Technologia |
|---|---|
| Aplikacja | Swift 5, SwiftUI (iOS 17+), Swift Charts, bez zewnętrznych zależności |
| Backend | Supabase: Postgres (logika gry w funkcjach SQL), Auth, RLS, Edge Functions (Deno) |
| AI | Claude (generator pytań z niezależną weryfikacją, Mentor) – klucz tylko po stronie serwera |
| Powiadomienia | APNs (funkcja `send-push`) |

## Struktura repozytorium

```
ios/
  QuizVerse.xcodeproj       projekt Xcode 16+ (foldery synchronizowane)
  QuizVerse/                kod aplikacji: App, Core, Services, Views, Resources/content.json
  QuizVerseTests/           testy jednostkowe reguł gry i treści
  Config/                   Base.xcconfig + Secrets.example.xcconfig (Secrets.xcconfig jest w .gitignore)
  Support/Info.plist
supabase/
  migrations/               schemat, reguły XP/LP, ligi, sezony, misje, osiągnięcia, RLS, cron
  functions/                generate-questions, ai-mentor, settle-week, send-push
  seed.sql                  ligi, 28 kategorii, 115 działów, 314 pytań, misje, osiągnięcia, karty, artykuły
  tests/                    testy SQL (reguły, przebieg quizu, ligi, bezpieczeństwo)
content/                    źródło treści (Python) → scripts/build_content.py
scripts/                    build_content.py, gen_xcodeproj.py, test_db.sh
```

## Szybki start: tryb demonstracyjny (bez backendu)

1. Otwórz `ios/QuizVerse.xcodeproj` w Xcode 16 lub nowszym.
2. W *Signing & Capabilities* wybierz swój zespół (wystarczy darmowe Apple ID). Jeśli identyfikator jest zajęty,
   ustaw własny `QV_BUNDLE_ID` w `ios/Config/Secrets.xcconfig` (patrz niżej).
3. Uruchom na symulatorze lub iPhonie.

Bez skonfigurowanego Supabase aplikacja działa w **trybie demonstracyjnym**, wyraźnie oznaczonym złotym paskiem
„TRYB DEMONSTRACYJNY” na każdym ekranie:
- konto i postępy są zapisywane tylko na urządzeniu,
- 29 rywali w grupie ligowej jest symulowanych lokalnie (oznaczeni w interfejsie),
- generator AI nie tworzy nowych pytań (używa wbudowanej bazy), a Mentor działa offline (analiza lokalna, bez AI),
- wszystkie reguły punktacji, lig, misji i osiągnięć działają tak samo jak na serwerze (port w `Core/Rules.swift`).

## Konfiguracja produkcyjna

### 1. Supabase

```bash
supabase link --project-ref TWOJ_PROJEKT
supabase db push                 # migracje z supabase/migrations
psql "$DATABASE_URL" -f supabase/seed.sql
```

W panelu Supabase włącz rozszerzenie **pg_cron** (migracja `…08_cron.sql` sama zaplanuje rozliczanie tygodni co godzinę
i quiz dnia o północy; bez pg_cron można wywoływać funkcję `settle-week` z zewnętrznego harmonogramu).

### 2. Edge Functions i sekrety

```bash
supabase secrets set ANTHROPIC_API_KEY=...        # generator pytań i Mentor AI
supabase secrets set CRON_SECRET=$(openssl rand -hex 32)
# opcjonalnie: model AI (domyślnie claude-opus-5-5)
supabase secrets set QUIZVERSE_AI_MODEL=claude-opus-5-5
# opcjonalnie: powiadomienia push (klucz .p8 z Apple Developer)
supabase secrets set APNS_KEY_ID=... APNS_TEAM_ID=... APNS_BUNDLE_ID=... APNS_PRIVATE_KEY="$(cat AuthKey.p8)" APNS_SANDBOX=true
supabase functions deploy generate-questions ai-mentor settle-week send-push
```

Bez `ANTHROPIC_API_KEY` generator zwraca komunikat „Generator AI nie jest skonfigurowany”, a reszta gry działa normalnie.
Funkcje `settle-week` i `send-push` wymagają nagłówka `x-cron-secret`.

### 3. Aplikacja

```bash
cp ios/Config/Secrets.example.xcconfig ios/Config/Secrets.xcconfig
```

Uzupełnij `SUPABASE_URL` (zapis `https:/$()/projekt.supabase.co` – w plikach xcconfig `//` to komentarz)
i `SUPABASE_ANON_KEY`. Po ponownym uruchomieniu pasek trybu demo zniknie.

Powiadomienia push wymagają płatnego konta Apple Developer: dodaj capability *Push Notifications* w Xcode.
Bez niej aplikacja działa, tylko nie rejestruje tokenu urządzenia.

## Zasady gry (skrót)

- **Ligi:** Brąz → Srebro → Złoto → Platyna → Legenda. Grupa 30 graczy, tydzień od poniedziałku 00:00 (czas polski).
  Miejsca 1–10 awans (min. 1 LP), 11–23 utrzymanie, 24–30 spadek. Brąz nie spada, Legenda nie awansuje. LP zerują się co tydzień.
- **XP:** 5 za poprawną odpowiedź, 15 za ukończenie, +20 za komplet, +30 za quiz ekspercki, 25 za quiz dnia, 20 za misję dzienną.
- **LP:** quiz 5/10/20 pytań → 10/20/40, quiz dnia 25, misja tygodniowa 30, maraton 10 za każde 5 pytań.
  Wymagane min. 40% skuteczności, limit 300 LP dziennie. XP nigdy nie zamienia się w LP.
- **Fair play:** punkty liczy wyłącznie serwer, poprawne odpowiedzi nie trafiają do aplikacji przed odpowiedzią,
  nagrody są idempotentne, zbyt szybkie odpowiedzi (śr. < 0,8 s) blokują nagrody.
- **Sezon:** 8 tygodni, odznaka i bonus XP za najwyższą osiągniętą ligę.
- **Poziomy:** 1–151, 9 tytułów (Nowicjusz … Wszechwiedzący).

## Testy

```bash
# Baza danych (lokalny PostgreSQL 15+, bez Dockera)
PGHOST=/tmp PGPORT=5432 scripts/test_db.sh

# Edge Functions
cd supabase/functions && deno test generate-questions/validate_test.ts && deno check */index.ts

# Aplikacja iOS
xcodebuild test -project ios/QuizVerse.xcodeproj -scheme QuizVerse \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Treści

Pytania, kategorie, misje, osiągnięcia, karty i artykuły są w `content/*.py`. Po zmianach:

```bash
python3 scripts/build_content.py   # waliduje i generuje supabase/seed.sql + ios/QuizVerse/Resources/content.json
```

Administrator (rola `admin` w tabeli `users`) zatwierdza lub odrzuca pytania AI i zgłoszone pytania funkcjami
`admin_review_queue()` i `admin_review_question()`.
