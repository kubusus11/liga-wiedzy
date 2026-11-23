// Generator pytań AI z kontrolą jakości.
//
// Przepływ:
// 1. Najpierw wykorzystujemy wspólną pulę (bufor) pytań zatwierdzonych i zweryfikowanych
//    dla wybranej kategorii/podkategorii/trudności – AI wołamy tylko po brakujące pytania.
// 2. Limit: 5 generowań na gracza dziennie (kontrola kosztów).
// 3. Każde wygenerowane pytanie przechodzi automatyczne testy (4 różne odpowiedzi,
//    1 poprawna, długości, deduplikacja) oraz niezależną weryfikację drugim wywołaniem
//    modelu, który rozwiązuje pytanie bez klucza. Zgodne → status `ai_verified`
//    (gra w trybie AI, bez LP), niezgodne → `pending_review` (tylko po akceptacji redakcji).
// 4. Do rankingowych trybów trafiają wyłącznie pytania zatwierdzone przez administratora.
import { handle, json, requireUser, serviceClient, HttpError } from "../_shared/http.ts";
import { aiConfigured, claudeJson, CLAUDE_MODEL } from "../_shared/claude.ts";
import { normalize, validateGenerated, type GeneratedQuestion } from "./validate.ts";

const DIFFICULTY = ["Początkujący", "Łatwy", "Średni", "Trudny", "Ekspercki", "Akademicki"];
const DAILY_LIMIT = 5;
const MAX_PER_CALL = 10;


const generationSchema = {
  type: "object",
  additionalProperties: false,
  required: ["questions"],
  properties: {
    questions: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["prompt", "answers", "correct_index", "explanation", "sources"],
        properties: {
          prompt: { type: "string" },
          answers: { type: "array", items: { type: "string" } },
          correct_index: { type: "integer" },
          explanation: { type: "string" },
          sources: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              required: ["title", "url"],
              properties: { title: { type: "string" }, url: { type: "string" } },
            },
          },
        },
      },
    },
  },
};

const verificationSchema = {
  type: "object",
  additionalProperties: false,
  required: ["results"],
  properties: {
    results: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["index", "chosen_index", "confident", "issue"],
        properties: {
          index: { type: "integer" },
          chosen_index: { type: "integer" },
          confident: { type: "boolean" },
          issue: { type: "string" },
        },
      },
    },
  },
};


async function md5(text: string): Promise<string> {
  // Ten sam hash co w scripts/build_content.py (md5 znormalizowanej treści)
  const { crypto } = await import("jsr:@std/crypto@1.0.3");
  const buf = await crypto.subtle.digest("MD5", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(handle(async (req) => {
  const { id: userId } = await requireUser(req);
  const body = await req.json().catch(() => ({}));
  const categoryId = Number(body.category_id);
  const subcategoryId = body.subcategory_id == null ? null : Number(body.subcategory_id);
  const difficulty = Math.min(6, Math.max(1, Number(body.difficulty ?? 3)));
  const count = [5, 10, 20].includes(Number(body.count)) ? Number(body.count) : 10;
  if (!Number.isInteger(categoryId)) throw new HttpError(400, "category_required");

  const admin = serviceClient();

  // Kategoria i podkategoria (nazwy do promptu)
  const { data: cat } = await admin.from("categories").select("id,name").eq("id", categoryId).single();
  if (!cat) throw new HttpError(400, "invalid_category");
  let subName: string | null = null;
  if (subcategoryId != null) {
    const { data: sub } = await admin.from("subcategories").select("id,name,category_id").eq("id", subcategoryId).single();
    if (!sub || sub.category_id !== categoryId) throw new HttpError(400, "invalid_subcategory");
    subName = sub.name;
  }

  // 1. Bufor: ile pytań już mamy w puli (approved + ai_verified)?
  let pool = admin.from("questions").select("id", { count: "exact", head: true })
    .eq("category_id", categoryId).eq("kind", "standard").in("status", ["approved", "ai_verified"])
    .gte("difficulty", Math.max(1, difficulty - 1)).lte("difficulty", Math.min(6, difficulty + 1));
  if (subcategoryId != null) pool = pool.eq("subcategory_id", subcategoryId);
  const { count: available } = await pool;
  const missing = Math.max(0, count - (available ?? 0));

  if (missing === 0) {
    return json({ ready: true, reused: available, generated: 0, ai_configured: aiConfigured() });
  }
  if (!aiConfigured()) {
    // Tryb demonstracyjny backendu: brak klucza AI – gra z dostępnej puli
    return json({ ready: (available ?? 0) >= 5, reused: available, generated: 0, ai_configured: false,
                  message: "Generator AI nie jest skonfigurowany (brak ANTHROPIC_API_KEY). Używam bazy pytań." });
  }

  // 2. Limit dzienny
  const today = new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Warsaw" });
  const { data: ledger } = await admin.from("daily_reward_ledger").select("ai_generations")
    .eq("user_id", userId).eq("day", today).maybeSingle();
  if ((ledger?.ai_generations ?? 0) >= DAILY_LIMIT) throw new HttpError(429, "ai_daily_limit");
  await admin.from("daily_reward_ledger").upsert(
    { user_id: userId, day: today, ai_generations: (ledger?.ai_generations ?? 0) + 1 },
    { onConflict: "user_id,day" },
  );

  const toGenerate = Math.min(MAX_PER_CALL, missing + 2); // +2 zapasu na odrzucone
  const { data: job } = await admin.from("ai_generation_jobs").insert({
    user_id: userId, category_id: categoryId, subcategory_id: subcategoryId, difficulty,
    requested: count, reused: available ?? 0, model: CLAUDE_MODEL,
  }).select("id").single();

  // Przykłady istniejących pytań – by uniknąć powtórzeń
  const { data: existing } = await admin.from("questions").select("prompt")
    .eq("category_id", categoryId).limit(40);
  const avoid = (existing ?? []).map((q) => `- ${q.prompt}`).join("\n");

  const topic = subName ? `${cat.name} → ${subName}` : cat.name;
  const generated = await claudeJson<{ questions: GeneratedQuestion[] }>({
    system:
      "Jesteś redaktorem merytorycznym polskiej aplikacji edukacyjnej QuizVerse. Tworzysz pytania jednokrotnego wyboru " +
      "po polsku: dokładnie 4 odpowiedzi, dokładnie jedna poprawna i jednoznaczna, błędne odpowiedzi wiarygodne, ale " +
      "jednoznacznie fałszywe. Unikasz faktów spornych, zmiennych w czasie (chyba że podajesz datę) i pytań-pułapek. " +
      "Wyjaśnienie (1–3 zdania) uzasadnia poprawną odpowiedź. Podaj 1–2 źródła (tytuł i adres URL renomowanego źródła, " +
      "np. encyklopedii); jeśli nie znasz dokładnego adresu, podaj stronę główną źródła.",
    user:
      `Temat: ${topic}\nPoziom trudności: ${difficulty}/6 (${DIFFICULTY[difficulty - 1]})\n` +
      `Liczba pytań: ${toGenerate}\n\nNie powtarzaj tych pytań:\n${avoid || "(brak)"}`,
    schema: generationSchema,
    effort: "medium",
  });

  // 3a. Testy automatyczne + deduplikacja
  const candidates: (GeneratedQuestion & { hash: string })[] = [];
  const rejected: { prompt: string; reason: string }[] = [];
  for (const q of generated.questions ?? []) {
    const reason = validateGenerated(q);
    if (reason) { rejected.push({ prompt: q.prompt, reason }); continue; }
    const hash = await md5(normalize(q.prompt) + "|");
    const { count: dup } = await admin.from("questions").select("id", { count: "exact", head: true }).eq("content_hash", hash);
    if (dup) { rejected.push({ prompt: q.prompt, reason: "duplicate" }); continue; }
    candidates.push({ ...q, hash });
  }

  // 3b. Niezależna weryfikacja: model rozwiązuje pytania bez klucza
  let verification: { results: { index: number; chosen_index: number; confident: boolean; issue: string }[] } = { results: [] };
  if (candidates.length) {
    verification = await claudeJson({
      system:
        "Jesteś niezależnym weryfikatorem faktów. Rozwiąż każde pytanie samodzielnie. Ustaw confident=false, jeśli pytanie " +
        "jest niejednoznaczne, ma więcej niż jedną poprawną odpowiedź, zawiera błąd lub nieaktualną informację; opisz problem w polu issue.",
      user: candidates.map((q, i) =>
        `#${i} ${q.prompt}\n` + q.answers.map((a, j) => `  ${j}) ${a}`).join("\n")).join("\n\n"),
      schema: verificationSchema,
      effort: "medium",
    });
  }

  let accepted = 0;
  for (const [i, q] of candidates.entries()) {
    const v = verification.results.find((r) => r.index === i);
    const agrees = !!v && v.chosen_index === q.correct_index && v.confident;
    const status = agrees ? "ai_verified" : "pending_review";
    const { data: inserted, error } = await admin.from("questions").insert({
      category_id: categoryId, subcategory_id: subcategoryId, difficulty, kind: "standard",
      prompt: q.prompt, explanation: q.explanation, source: "ai", status,
      sources: q.sources?.slice(0, 3) ?? [], content_hash: q.hash, created_by: userId,
      quality_score: agrees ? 0.9 : 0.4,
    }).select("id").single();
    if (error || !inserted) { rejected.push({ prompt: q.prompt, reason: "insert_failed" }); continue; }
    await admin.from("answers").insert(q.answers.map((body, position) => ({
      question_id: inserted.id, body, position, is_correct: position === q.correct_index,
    })));
    if (agrees) accepted++;
    else rejected.push({ prompt: q.prompt, reason: "verification:" + (v?.issue || "disagreement") });
  }

  await admin.from("ai_generation_jobs").update({ generated: candidates.length, accepted }).eq("id", job?.id);

  const total = (available ?? 0) + accepted;
  return json({
    ready: total >= 5,
    reused: available ?? 0,
    generated: candidates.length,
    accepted,
    sent_to_review: candidates.length - accepted,
    rejected: rejected.length,
    ai_configured: true,
    note: "Pytania AI oznaczone jako 'AI – zweryfikowane automatycznie' dają XP, ale nie LP, dopóki redakcja ich nie zatwierdzi.",
  });
}));
