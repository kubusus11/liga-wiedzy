// Wysyłka powiadomień push (Apple Push Notification Service) dla nowych wpisów
// w tabeli notifications. Wywoływane z harmonogramu (x-cron-secret).
// Wymagane sekrety: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (zawartość pliku .p8),
// APNS_BUNDLE_ID, opcjonalnie APNS_SANDBOX=true. Bez nich funkcja nic nie wysyła
// i zwraca { configured: false } – powiadomienia są nadal widoczne w aplikacji.
import { handle, json, serviceClient, env, HttpError } from "../_shared/http.ts";

const PREF_BY_KIND: Record<string, string> = {
  league_result: "league", season_end: "league", mission: "missions", achievement: "missions",
  level_up: "missions", review_due: "reviews", daily: "daily",
};

function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data as ArrayBuffer);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function apnsJwt(keyId: string, teamId: string, p8: string): Promise<string> {
  const pem = p8.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${b64url(sig)}`;
}

Deno.serve(handle(async (req) => {
  const secret = env("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) throw new HttpError(401, "unauthorized");

  const keyId = env("APNS_KEY_ID"), teamId = env("APNS_TEAM_ID"), p8 = env("APNS_PRIVATE_KEY"), topic = env("APNS_BUNDLE_ID");
  if (!keyId || !teamId || !p8 || !topic) return json({ configured: false, sent: 0 });

  const host = env("APNS_SANDBOX") === "true" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const admin = serviceClient();
  const { data: pending } = await admin.from("notifications")
    .select("id,user_id,kind,title,body,payload")
    .is("pushed_at", null).gte("created_at", new Date(Date.now() - 6 * 3600 * 1000).toISOString())
    .order("created_at").limit(500);
  if (!pending?.length) return json({ configured: true, sent: 0 });

  const userIds = [...new Set(pending.map((n) => n.user_id))];
  const [{ data: tokens }, { data: prefs }] = await Promise.all([
    admin.from("device_tokens").select("user_id,token").in("user_id", userIds),
    admin.from("profiles").select("id,notifications").in("id", userIds),
  ]);
  const prefMap = new Map((prefs ?? []).map((p) => [p.id, p.notifications ?? {}]));
  const jwt = await apnsJwt(keyId, teamId, p8);
  let sent = 0;
  const dead: string[] = [];

  for (const n of pending) {
    const pref = PREF_BY_KIND[n.kind];
    const allowed = !pref || (prefMap.get(n.user_id) as Record<string, boolean>)?.[pref] !== false;
    if (allowed) {
      for (const t of (tokens ?? []).filter((t) => t.user_id === n.user_id)) {
        const res = await fetch(`${host}/3/device/${t.token}`, {
          method: "POST",
          headers: { authorization: `bearer ${jwt}`, "apns-topic": topic, "apns-push-type": "alert", "content-type": "application/json" },
          body: JSON.stringify({ aps: { alert: { title: n.title, body: n.body }, sound: "default" }, kind: n.kind, payload: n.payload }),
        });
        if (res.ok) sent++;
        else if (res.status === 410 || res.status === 400) dead.push(t.token);
        await res.body?.cancel();
      }
    }
  }
  await admin.from("notifications").update({ pushed_at: new Date().toISOString() }).in("id", pending.map((n) => n.id));
  if (dead.length) await admin.from("device_tokens").delete().in("token", dead);
  return json({ configured: true, sent, removed_tokens: dead.length });
}));
