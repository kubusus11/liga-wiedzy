// Wspólne narzędzia Edge Functions QuizVerse.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.119.0";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

export function env(name: string): string | undefined {
  const v = Deno.env.get(name);
  return v && v.length > 0 ? v : undefined;
}

/** Klient działający w imieniu zalogowanego gracza (RLS + auth.uid()). */
export function userClient(req: Request): SupabaseClient {
  return createClient(env("SUPABASE_URL")!, env("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });
}

/** Klient serwisowy (omija RLS) – używać wyłącznie po weryfikacji uprawnień. */
export function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
}

export async function requireUser(req: Request): Promise<{ id: string; client: SupabaseClient }> {
  const client = userClient(req);
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new HttpError(401, "not_authenticated");
  return { id: data.user.id, client };
}

export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export function handle(fn: (req: Request) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    try {
      return await fn(req);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error(e);
      return json({ error: "internal_error" }, 500);
    }
  };
}
