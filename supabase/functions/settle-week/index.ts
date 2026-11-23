// Rozliczenie tygodni ligowych i sezonów. Wywoływane przez harmonogram
// (pg_cron w bazie lub zewnętrzny cron z nagłówkiem x-cron-secret).
import { handle, json, serviceClient, env, HttpError } from "../_shared/http.ts";

Deno.serve(handle(async (req) => {
  const secret = env("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) throw new HttpError(401, "unauthorized");
  const admin = serviceClient();
  const { data, error } = await admin.rpc("settle_due_weeks");
  if (error) throw new HttpError(500, error.message);
  await admin.rpc("ensure_daily_quiz");
  return json({ ok: true, settled: data });
}));
