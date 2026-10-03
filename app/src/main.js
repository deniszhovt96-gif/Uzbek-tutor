// Страница-проверка инфраструктуры (шаги 1–4). Будет заменена интерфейсом обучения на шаге 6.
//  1) приложение открывается (GitHub Pages)
//  2) база отвечает (таблица цен plans открыта для чтения всем)
//  3) аудио играет с GitHub Pages (репозиторий uzbek-audio)
//  4) вход через Telegram: подпись проверяется на сервере, создаётся профиль,
//     дальше запросы идут от имени пользователя; можно активировать код подписки.

const SUPABASE_URL = 'https://jjvtkvritnmwqfpvlxrs.supabase.co';
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_KEY || '';
export const AUDIO_BASE = 'https://deniszhovt96-gif.github.io/uzbek-audio/audio/';

const TIER_NAMES = { free: 'Бесплатная', basic: 'Базовая', advanced: 'Продвинутая' };
const CODE_ERRORS = {
  invalid_code: 'Код не найден.',
  code_expired: 'Срок действия кода истёк.',
  code_used_up: 'Код уже использован максимальное число раз.',
  already_redeemed: 'Вы уже активировали этот код.',
  too_many_attempts: 'Слишком много неверных попыток. Попробуйте через час.',
  not_authenticated: 'Нужно войти через Telegram.',
};

let session = null;

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

async function rpc(name, args) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_KEY,
      Authorization: `Bearer ${session.access_token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args || {}),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${res.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

// ---------------------------------------------------------------- Telegram + вход
async function login() {
  const tg = window.Telegram && window.Telegram.WebApp;
  if (!tg || !tg.initData) {
    setStatus('tg-status', 'Открыто в обычном браузере. Вход и профиль проверяются только внутри Telegram.', 'warn');
    return;
  }
  tg.ready();
  tg.expand();
  setStatus('tg-status', 'Проверяю подпись Telegram на сервере…');
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/auth-telegram`, {
      method: 'POST',
      headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ initData: tg.initData }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.access_token) {
      setStatus('tg-status', `Вход не выполнен: ${data.error || res.status}${data.detail ? ' — ' + data.detail : ''}`, 'err');
      return;
    }
    session = data;
    await showProfile();
  } catch (err) {
    setStatus('tg-status', `Нет связи с сервером входа: ${err.message || err}`, 'err');
  }
}

async function showProfile() {
  const me = await rpc('get_me');
  if (!me) {
    setStatus('tg-status', 'Вход выполнен, но профиль не найден.', 'err');
    return;
  }
  const until = me.tier_ends_at ? ` до ${new Date(me.tier_ends_at).toLocaleDateString('ru-RU')}` : '';
  setStatus('tg-status', `Вход выполнен: ${me.first_name || me.username || 'пользователь'} (Telegram ID ${me.tg_id}).`, 'ok');
  document.getElementById('profile').innerHTML =
    `<p>Подписка: <b>${escapeHtml(TIER_NAMES[me.tier] || me.tier)}</b>${escapeHtml(until)}</p>` +
    `<p>Слов в словаре: <b>${formatNumber(me.words_total)}</b></p>` +
    (me.is_admin ? '<p class="ok">Вы администратор: команда /gencode в боте доступна.</p>' : '');
  document.getElementById('code-card').hidden = false;
}

async function redeem(event) {
  event.preventDefault();
  const input = document.getElementById('code-input');
  const code = input.value.trim();
  if (!code || !session) return;
  setStatus('code-status', 'Проверяю код…');
  try {
    const r = await rpc('redeem_code', { p_code: code });
    if (r && r.ok) {
      setStatus('code-status', `Код активирован: ${TIER_NAMES[r.tier]} до ${new Date(r.ends_at).toLocaleDateString('ru-RU')}.`, 'ok');
      input.value = '';
      await showProfile();
    } else {
      setStatus('code-status', CODE_ERRORS[r && r.error] || `Ошибка: ${r && r.error}`, 'err');
    }
  } catch (err) {
    setStatus('code-status', `Ошибка: ${err.message || err}`, 'err');
  }
}

// ---------------------------------------------------------------- база (цены)
async function checkDatabase() {
  if (!SUPABASE_KEY) {
    setStatus('db-status', 'Не задан публичный ключ: переменная SUPABASE_PUBLISHABLE_KEY в настройках GitHub (Variables).', 'err');
    return;
  }
  const url = `${SUPABASE_URL}/rest/v1/plans?select=tier,months,price_stars,price_uzs,price_usd&order=tier.desc,months.asc`;
  try {
    const res = await fetch(url, { headers: { apikey: SUPABASE_KEY } });
    if (!res.ok) {
      setStatus('db-status', `Ошибка ${res.status}: ${(await res.text()).slice(0, 200)}`, 'err');
      return;
    }
    const plans = await res.json();
    setStatus('db-status', `Подключено. Тарифов в базе: ${plans.length}.`, plans.length ? 'ok' : 'warn');
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
    setStatus('db-status', `Нет связи с базой: ${err.message || err}`, 'err');
  }
}

// ---------------------------------------------------------------- аудио
function playAudio(file) {
  const audio = new Audio(AUDIO_BASE + file);
  setStatus('audio-status', `Воспроизвожу ${file}…`);
  audio.addEventListener('ended', () => setStatus('audio-status', `${file}: воспроизведено.`, 'ok'));
  audio.addEventListener('error', () => setStatus('audio-status', `${file}: не удалось загрузить.`, 'err'));
  audio.play().catch((err) => setStatus('audio-status', `${file}: ${err.message || err}`, 'err'));
}

document.getElementById('play-word').addEventListener('click', () => playAudio('word_1.mp3'));
document.getElementById('play-example').addEventListener('click', () => playAudio('word_1_ex1.mp3'));
document.getElementById('code-form').addEventListener('submit', redeem);
document.getElementById('build-info').textContent = `Сборка: ${new Date(__BUILD_TIME__).toLocaleString('ru-RU')}`;

checkDatabase();
login();
