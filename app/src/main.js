// Шаг 1: страница-проверка. Показывает, что
//  1) приложение открывается (GitHub Pages),
//  2) Telegram передаёт данные Mini App,
//  3) приложение читает базу Supabase (таблица цен plans — открыта для чтения всем).
// Имя пользователя здесь НЕ проверено подписью: проверка появится на шаге 4.

const SUPABASE_URL = 'https://jjvtkvritnmwqfpvlxrs.supabase.co';
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_KEY || '';

const TIER_NAMES = { basic: 'Базовая', advanced: 'Продвинутая' };

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatNumber(value) {
  if (value === null || value === undefined) return '—';
  return Number(value).toLocaleString('ru-RU');
}

function setStatus(id, text, kind) {
  const el = document.getElementById(id);
  el.textContent = text;
  el.className = kind || '';
}

function checkTelegram() {
  const tg = window.Telegram && window.Telegram.WebApp;
  if (!tg || !tg.initData) {
    setStatus('tg-status', 'Открыто в обычном браузере (не в Telegram). Это нормально для проверки.', 'warn');
    return;
  }
  tg.ready();
  tg.expand();
  const user = tg.initDataUnsafe && tg.initDataUnsafe.user;
  const name = user ? [user.first_name, user.last_name].filter(Boolean).join(' ') : 'пользователь';
  setStatus('tg-status', `Открыто в Telegram: ${name}. Данные Mini App получены.`, 'ok');
}

async function checkDatabase() {
  if (!SUPABASE_KEY) {
    setStatus('db-status', 'Не задан публичный ключ: переменная SUPABASE_PUBLISHABLE_KEY в настройках GitHub (Variables).', 'err');
    return;
  }
  const url = `${SUPABASE_URL}/rest/v1/plans?select=tier,months,price_stars,price_uzs,price_usd&order=tier.asc,months.asc`;
  try {
    const res = await fetch(url, { headers: { apikey: SUPABASE_KEY } });
    if (!res.ok) {
      const body = await res.text();
      setStatus('db-status', `Ошибка ${res.status}: ${body.slice(0, 200)}`, 'err');
      return;
    }
    const plans = await res.json();
    if (!plans.length) {
      setStatus('db-status', 'База отвечает, но таблица цен пуста — миграции, вероятно, ещё не применены.', 'warn');
      return;
    }
    setStatus('db-status', `Подключено. Тарифов в базе: ${plans.length}.`, 'ok');
    const rows = plans
      .map(
        (p) =>
          `<tr><td>${escapeHtml(TIER_NAMES[p.tier] || p.tier)}</td><td>${escapeHtml(p.months)} мес.</td>` +
          `<td>${formatNumber(p.price_stars)} ⭐</td><td>${formatNumber(p.price_uzs)} сум</td>` +
          `<td>$${escapeHtml(p.price_usd ?? '—')}</td></tr>`
      )
      .join('');
    document.getElementById('plans').innerHTML =
      `<table><thead><tr><th>Подписка</th><th>Срок</th><th>Stars</th><th>Сумы</th><th>USD</th></tr></thead>` +
      `<tbody>${rows}</tbody></table>`;
  } catch (err) {
    setStatus('db-status', `Нет связи с базой: ${err && err.message ? err.message : err}`, 'err');
  }
}

document.getElementById('build-info').textContent = `Сборка: ${new Date(__BUILD_TIME__).toLocaleString('ru-RU')}`;
checkTelegram();
checkDatabase();
