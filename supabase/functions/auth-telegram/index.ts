// Edge Function: auth-telegram
// Вход через Telegram Mini App.
//   1. Проверяет подпись initData токеном бота (HMAC-SHA256, алгоритм Telegram) и срок (≤ 24 ч).
//   2. Находит или создаёт пользователя и профиль.
//   3. Возвращает сессию Supabase (access_token + refresh_token): дальше приложение
//      работает с базой от имени этого пользователя, RLS видит его через auth.uid().
//
// Секреты функции (Edge Functions → Secrets): TELEGRAM_BOT_TOKEN.
// SUPABASE_URL и SUPABASE_SERVICE_ROLE_KEY Supabase подставляет сам.
// Настройка функции: «Verify JWT» = ВЫКЛ (функцию вызывают до входа).

import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_AGE_SECONDS = 24 * 60 * 60;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

const enc = new TextEncoder();

async function hmac(key: ArrayBuffer | Uint8Array, data: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(data));
}

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export type TelegramUser = {
  id: number;
  first_name?: string;
  last_name?: string;
  username?: string;
  language_code?: string;
};

// Проверка initData по документации Telegram:
// secret_key = HMAC_SHA256(key = "WebAppData", data = bot_token)
// hash       = hex(HMAC_SHA256(key = secret_key, data = data_check_string))
export async function verifyInitData(
  initData: string,
  botToken: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<{ ok: true; user: TelegramUser; authDate: number } | { ok: false; error: string }> {
  if (!initData) return { ok: false, error: "no_init_data" };
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return { ok: false, error: "no_hash" };
  params.delete("hash");
  const pairs: string[] = [];
  params.forEach((value, key) => pairs.push(`${key}=${value}`));
  pairs.sort();
  const dataCheckString = pairs.join("\n");

  const secretKey = await hmac(enc.encode("WebAppData"), botToken);
  const computed = toHex(await hmac(secretKey, dataCheckString));
  if (!safeEqual(computed, hash.toLowerCase())) return { ok: false, error: "bad_signature" };

  const authDate = Number(params.get("auth_date") || 0);
  if (!authDate || nowSeconds - authDate > MAX_AGE_SECONDS) return { ok: false, error: "expired" };

  let user: TelegramUser;
  try {
    user = JSON.parse(params.get("user") || "");
  } catch {
    return { ok: false, error: "bad_user" };
  }
  if (!user || typeof user.id !== "number") return { ok: false, error: "bad_user" };
  return { ok: true, user, authDate };
}

function uiLangFrom(code?: string): "ru" | "uz" | "en" {
  if (!code) return "ru";
  if (code.startsWith("uz")) return "uz";
  if (code.startsWith("ru")) return "ru";
  return "en";
}

// Технический e-mail пользователя в Supabase Auth. Письма на него не отправляются.
function techEmail(tgId: number): string {
  return `tg${tgId}@telegram.uzbek-tutor.app`;
}

async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!botToken || !url || !serviceKey) return json({ error: "server_not_configured" }, 500);

  let body: { initData?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const check = await verifyInitData(body.initData || "", botToken);
  if (!check.ok) return json({ error: check.error }, 401);
  const tg = check.user;

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = techEmail(tg.id);

  // 1. профиль по tg_id
  const { data: existing, error: selErr } = await admin
    .from("profiles").select("id").eq("tg_id", tg.id).maybeSingle();
  if (selErr) return json({ error: "db_error", detail: selErr.message }, 500);

  let userId = existing?.id as string | undefined;

  // 2. новый пользователь: учётная запись Auth + профиль с тем же id
  if (!userId) {
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      email_confirm: true,
      user_metadata: { tg_id: tg.id },
    });
    if (createErr && !/already|registered|exists/i.test(createErr.message)) {
      return json({ error: "auth_create_failed", detail: createErr.message }, 500);
    }
    userId = created?.user?.id;
    if (!userId) {
      // учётная запись уже была (профиль удалили) — найдём её через ссылку входа
      const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: "magiclink", email });
      if (linkErr || !link?.user?.id) return json({ error: "auth_lookup_failed", detail: linkErr?.message }, 500);
      userId = link.user.id;
    }
    const { error: insErr } = await admin.from("profiles").insert({
      id: userId,
      tg_id: tg.id,
      username: tg.username ?? null,
      first_name: tg.first_name ?? null,
      last_name: tg.last_name ?? null,
      language_code: tg.language_code ?? null,
      ui_lang: uiLangFrom(tg.language_code),
    });
    if (insErr && !/duplicate/i.test(insErr.message)) {
      return json({ error: "profile_create_failed", detail: insErr.message }, 500);
    }
  } else {
    await admin.from("profiles").update({
      username: tg.username ?? null,
      first_name: tg.first_name ?? null,
      last_name: tg.last_name ?? null,
      language_code: tg.language_code ?? null,
      last_seen_at: new Date().toISOString(),
    }).eq("id", userId);
  }

  // 3. сессия: одноразовая ссылка входа → обмен на токены (письмо не отправляется)
  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link?.properties?.hashed_token;
  if (linkErr || !tokenHash) return json({ error: "session_link_failed", detail: linkErr?.message }, 500);

  const { data: verified, error: otpErr } = await admin.auth.verifyOtp({ token_hash: tokenHash, type: "email" });
  if (otpErr || !verified?.session) return json({ error: "session_failed", detail: otpErr?.message }, 500);

  const s = verified.session;
  return json({
    access_token: s.access_token,
    refresh_token: s.refresh_token,
    expires_at: s.expires_at,
    user_id: userId,
  });
}

if (typeof Deno !== "undefined" && typeof Deno.serve === "function") {
  Deno.serve(handler);
}
