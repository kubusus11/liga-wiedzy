// Wywołania Claude (Anthropic Messages API) z odpowiedzią w formacie JSON Schema.
import Anthropic from "npm:@anthropic-ai/sdk@1.6.0";
import { env, HttpError } from "./http.ts";

export const CLAUDE_MODEL = env("QUIZVERSE_AI_MODEL") ?? "claude-opus-5-5";

export function aiConfigured(): boolean {
  return !!env("ANTHROPIC_API_KEY");
}

let client: Anthropic | null = null;
function anthropic(): Anthropic {
  if (!aiConfigured()) throw new HttpError(503, "ai_not_configured");
  client ??= new Anthropic({ apiKey: env("ANTHROPIC_API_KEY") });
  return client;
}

/**
 * Zwraca obiekt JSON zgodny ze schematem. Odmowa modelu (stop_reason "refusal")
 * jest najpierw ponawiana po stronie serwera (fallbacks: "default"), a gdy cały
 * łańcuch odmówi – zgłaszana jako błąd 422.
 */
export async function claudeJson<T>(opts: {
  system: string;
  user: string;
  schema: Record<string, unknown>;
  effort?: "low" | "medium" | "high";
  maxTokens?: number;
}): Promise<T> {
  const response = await anthropic().beta.messages.create({
    model: CLAUDE_MODEL,
    max_tokens: opts.maxTokens ?? 16000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: opts.system,
    messages: [{ role: "user", content: opts.user }],
    output_config: {
      effort: opts.effort ?? "medium",
      format: { type: "json_schema", schema: opts.schema },
    },
  } as any);

  if (response.stop_reason === "refusal") throw new HttpError(422, "ai_refused");
  if (response.stop_reason === "max_tokens") throw new HttpError(502, "ai_truncated");
  const text = response.content
    .filter((b: any) => b.type === "text")
    .map((b: any) => b.text)
    .join("");
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new HttpError(502, "ai_invalid_json");
  }
}
