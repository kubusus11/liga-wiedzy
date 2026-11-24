// Osobisty Mentor AI: analizuje wyniki gracza, wskazuje słabe strony, układa plan nauki,
// wyjaśnia błędy i proponuje kolejne quizy. Dane gracza pobierane są przez RPC
// get_mentor_context() w kontekście zalogowanego użytkownika (RLS).
import { handle, json, requireUser, serviceClient, HttpError } from "../_shared/http.ts";
import { aiConfigured, claudeJson } from "../_shared/claude.ts";

interface MentorReply {
  reply: string;
  weak_points: string[];
  plan: { day: string; task: string }[];
  suggestions: { category_id: number; subcategory_id: number | null; difficulty: number; mode: string; reason: string }[];
}

const schema = {
  type: "object",
  additionalProperties: false,
  required: ["reply", "weak_points", "plan", "suggestions"],
  properties: {
    reply: { type: "string" },
    weak_points: { type: "array", items: { type: "string" } },
    plan: {
      type: "array",
      items: { type: "object", additionalProperties: false, required: ["day", "task"],
               properties: { day: { type: "string" }, task: { type: "string" } } },
    },
    suggestions: {
      type: "array",
      items: {
        type: "object", additionalProperties: false,
        required: ["category_id", "subcategory_id", "difficulty", "mode", "reason"],
        properties: {
          category_id: { type: "integer" },
          subcategory_id: { type: ["integer", "null"] },
          difficulty: { type: "integer" },
          mode: { type: "string", enum: ["thematic", "quick", "review", "survival", "sprint", "detective"] },
          reason: { type: "string" },
        },
      },
    },
  },
};

const MAX_MESSAGES_PER_DAY = 30;

Deno.serve(handle(async (req) => {
  const { id: userId, client } = await requireUser(req);
  const body = await req.json().catch(() => ({}));
  const message = String(body.message ?? "Przeanalizuj moje wyniki i zaproponuj plan nauki na ten tydzień.").slice(0, 1000);

  if (!aiConfigured()) {
    return json({ error: "ai_not_configured",
                  message: "Mentor AI wymaga klucza ANTHROPIC_API_KEY w ustawieniach Edge Functions." }, 503);
  }

  const admin = serviceClient();
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count } = await admin.from("mentor_messages").select("id", { count: "exact", head: true })
    .eq("user_id", userId).eq("role", "user").gte("created_at", since);
  if ((count ?? 0) >= MAX_MESSAGES_PER_DAY) throw new HttpError(429, "mentor_daily_limit");

  const [{ data: context, error }, { data: categories }, { data: history }] = await Promise.all([
    client.rpc("get_mentor_context"),
    admin.from("categories").select("id,name"),
    admin.from("mentor_messages").select("role,content").eq("user_id", userId)
      .order("created_at", { ascending: false }).limit(8),
  ]);
  if (error) throw new HttpError(400, error.message);

  const transcript = (history ?? []).reverse().map((m) => `${m.role === "user" ? "Gracz" : "Mentor"}: ${m.content}`).join("\n");

  const result = await claudeJson<MentorReply>({
    system:
      "Jesteś Mentorem w aplikacji QuizVerse – życzliwym, konkretnym nauczycielem. Odpowiadasz po polsku, zwracasz się " +
      "do gracza bezpośrednio. Opierasz się WYŁĄCZNIE na przekazanych danych o wynikach – nie wymyślaj statystyk. " +
      "Gdy danych jest mało, powiedz to i zaproponuj quizy diagnostyczne. Wyjaśniając błędne odpowiedzi, odwołuj się " +
      "do podanej poprawnej odpowiedzi i wyjaśnienia. Propozycje quizów muszą używać category_id z listy kategorii " +
      "(subcategory_id tylko z danych gracza lub null), trudność 1–6. Plan: 3–7 krótkich punktów. Odpowiedź (reply) " +
      "maks. ~150 słów.",
    user:
      `Kategorie: ${JSON.stringify(categories)}\n\nDane gracza: ${JSON.stringify(context)}\n\n` +
      `Ostatnia rozmowa:\n${transcript || "(brak)"}\n\nWiadomość gracza: ${message}`,
    schema,
    effort: "medium",
  });

  const validCats = new Set((categories ?? []).map((c) => c.id));
  result.suggestions = result.suggestions
    .filter((s) => validCats.has(s.category_id))
    .map((s) => ({ ...s, difficulty: Math.min(6, Math.max(1, s.difficulty)) }))
    .slice(0, 4);

  await admin.from("mentor_messages").insert([
    { user_id: userId, role: "user", content: message },
    { user_id: userId, role: "mentor", content: result.reply },
  ]);

  return json(result);
}));
