// Доступ к серверу: вход через Telegram и вызовы функций базы.
// Токен живёт ~1 час; при истечении входим заново по тем же данным Telegram (они действуют 24 ч).
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';

let session = null;
let loginPromise = null;

export function tg() {
  return window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.initData ? window.Telegram.WebApp : null;
}

export class ApiError extends Error {
  constructor(code, detail) {
    super(detail ? `${code}: ${detail}` : code);
    this.code = code;
  }
}

export async function login() {
  if (loginPromise) return loginPromise;
  loginPromise = (async () => {
    const app = tg();
    if (!app) throw new ApiError('not_in_telegram');
    const res = await fetch(`${SUPABASE_URL}/functions/v1/auth-telegram`, {
      method: 'POST',
      headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ initData: app.initData }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.access_token) throw new ApiError(data.error || `http_${res.status}`, data.detail);
    session = data;
    return session;
  })();
  try {
    return await loginPromise;
  } finally {
    loginPromise = null;
  }
}

export async function rpc(name, args = {}, retried = false) {
  if (!session) await login();
  let res;
  try {
    res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: SUPABASE_KEY,
        Authorization: `Bearer ${session.access_token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
    });
  } catch (err) {
    throw new ApiError('network', err && err.message);
  }
  if (res.status === 401 && !retried) {
    session = null;
    return rpc(name, args, true);
  }
  const text = await res.text();
  if (!res.ok) throw new ApiError(`http_${res.status}`, text.slice(0, 200));
  return text ? JSON.parse(text) : null;
}

export async function fetchPlans() {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/plans?select=tier,months,price_stars,price_uzs,price_usd&order=tier.desc,months.asc`,
    { headers: { apikey: SUPABASE_KEY } }
  );
  if (!res.ok) throw new ApiError(`http_${res.status}`);
  return res.json();
}

// Ссылка на счёт в звёздах Telegram (создаёт бот; см. supabase/functions/telegram-bot)
export async function createInvoice(planId, retried = false, coupons = 0) {
  if (!session) await login();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/telegram-bot/invoice`, {
    method: 'POST',
    headers: { apikey: SUPABASE_KEY, Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ plan_id: planId, coupons }),
  }).catch((err) => { throw new ApiError('network', err && err.message); });
  if (res.status === 401 && !retried) {
    session = null;
    return createInvoice(planId, true, coupons);
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.link) throw new ApiError(data.error || `http_${res.status}`);
  return data.link;
}

// Сообщить боту о новых пометках уровня слов — он отправит уведомление администраторам.
// Ошибки не мешают пользователю: пометка уже сохранена, уведомление уйдёт при следующей пометке.
export async function notifyFlags() {
  try {
    if (!session) await login();
    await fetch(`${SUPABASE_URL}/functions/v1/telegram-bot/flags`, {
      method: 'POST',
      headers: { apikey: SUPABASE_KEY, Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' },
      body: '{}',
    });
  } catch { /* не критично */ }
}

// «Поделиться»: бот готовит сообщение с картинкой и реферальной ссылкой → id для WebApp.shareMessage
export async function prepareShare() {
  if (!session) await login();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/telegram-bot/share`, {
    method: 'POST',
    headers: { apikey: SUPABASE_KEY, Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' },
    body: '{}',
  }).catch((err) => { throw new ApiError('network', err && err.message); });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.id) throw new ApiError(data.error || `http_${res.status}`);
  return data;
}
