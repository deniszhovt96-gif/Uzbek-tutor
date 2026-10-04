import { rpc, fetchPlans } from '../api.js';
import { t, setLang, tierName, formatDate } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { applyTheme, currentTheme } from '../theme.js';

// Превью тем: фон, карточка, акцент, текст
const SWATCH = {
  telegram: ['var(--tg-theme-secondary-bg-color, #eef0f3)', 'var(--tg-theme-bg-color, #ffffff)', 'var(--tg-theme-button-color, #2481cc)', 'var(--tg-theme-text-color, #222)'],
  light: ['#f5f6f8', '#ffffff', '#0e7c86', '#15171c'],
  dark: ['#0f1115', '#181b21', '#2bb3be', '#eceef2'],
  gray: ['#e6e7ea', '#f3f3f5', '#3f6e8c', '#222327'],
  sand: ['#f3ede2', '#fbf8f2', '#1f7a8c', '#2b2620'],
  midnight: ['#0b1424', '#121d31', '#e0a43a', '#e6ecf5'],
};

const INTENSITY = {
  light: { session_size: 30, new_max: 20 },
  medium: { session_size: 45, new_max: 25 },
  intense: { session_size: 60, new_max: 30 },
};

export async function renderSettings(app) {
  mount(spinner(t('loading')));
  const [me, plans] = await Promise.all([app.refreshMe(), fetchPlans().catch(() => [])]);
  const settings = me.settings || {};
  const intensity = settings.intensity || 'light';
  const audioOn = settings.audio_exercises !== false;

  const save = async (lang, patch) => {
    app.me = await rpc('update_settings', { p_ui_lang: lang, p_settings: patch });
    if (lang) setLang(lang);
    haptic('success');
    renderSettings(app);
  };

  const seg = (items, current, onPick) => h('div', { class: 'segmented' }, items.map(([value, label]) =>
    h('button', { type: 'button', class: value === current ? 'active' : '', onClick: () => value !== current && onPick(value) }, label)));

  const codeInput = h('input', { class: 'answer-input', placeholder: 'XXXX-XXXX-XXXX', autocomplete: 'off', autocapitalize: 'characters' });
  const codeStatus = h('p', { class: 'small' });
  const redeem = async () => {
    const code = codeInput.value.trim();
    if (!code) return;
    codeStatus.textContent = t('loading');
    codeStatus.className = 'small';
    try {
      const r = await rpc('redeem_code', { p_code: code });
      if (r.ok) {
        haptic('success');
        codeStatus.textContent = t('codeOk', tierName(r.tier), formatDate(r.ends_at));
        codeStatus.className = 'small ok';
        codeInput.value = '';
        setTimeout(() => renderSettings(app), 1200);
      } else {
        haptic('error');
        codeStatus.textContent = (t('codeErrors') || {})[r.error] || r.error;
        codeStatus.className = 'small err';
      }
    } catch (err) {
      codeStatus.textContent = String(err.message || err);
      codeStatus.className = 'small err';
    }
  };

  const fmt = (n) => (n === null || n === undefined ? '—' : Number(n).toLocaleString('ru-RU'));
  const planRows = plans.map((p) => h('tr', {},
    h('td', {}, tierName(p.tier)), h('td', {}, t('months', p.months)),
    h('td', {}, `${fmt(p.price_stars)} ⭐`), h('td', {}, `${fmt(p.price_uzs)}`), h('td', {}, `$${p.price_usd ?? '—'}`)));

  mount(h('div', { class: 'screen' },
    h('h1', {}, t('settingsTitle')),

    h('h2', {}, t('language')),
    seg([['ru', 'Русский'], ['uz', 'Oʻzbekcha'], ['en', 'English']], me.ui_lang, (v) => save(v, null)),

    h('h2', {}, t('theme')),
    h('div', { class: 'themes' }, Object.entries(SWATCH).map(([name, [bg, card, accent, text]]) =>
      h('button', { type: 'button', class: `theme-opt ${name === currentTheme() ? 'active' : ''}`, onClick: () => {
        if (name === currentTheme()) return;
        applyTheme(name);          // сразу, без ожидания сервера
        save(null, { theme: name });
      } },
        h('div', { class: 'swatch', style: { background: bg } },
          h('i', { style: { background: card, width: '100%' } }),
          h('i', { style: { background: accent, width: '60%' } }),
          h('i', { style: { background: text, width: '40%', opacity: '.7' } })),
        h('span', {}, (t('themeNames') || {})[name] || name)))),

    h('h2', {}, t('intensity')),
    me.tier === 'free'
      ? h('p', { class: 'muted' }, t('freeIntensity'))
      : h('div', { class: 'radio-list' }, ['light', 'medium', 'intense'].map((v) =>
          h('button', { type: 'button', class: `radio ${v === intensity ? 'active' : ''}`,
            onClick: () => v !== intensity && save(null, { intensity: v, ...INTENSITY[v] }) },
            t(v === 'light' ? 'intLight' : v === 'medium' ? 'intMedium' : 'intIntense')))),

    h('h2', {}, t('audioEx')),
    seg([['on', t('on')], ['off', t('off')]], audioOn ? 'on' : 'off', (v) => save(null, { audio_exercises: v === 'on' })),

    h('h2', {}, t('subscription')),
    h('div', { class: 'card' },
      h('p', {}, h('b', {}, tierName(me.tier)), me.tier_ends_at ? ` ${t('tierUntil', formatDate(me.tier_ends_at))}` : ''),
      h('label', { class: 'small muted' }, t('codeLabel')),
      codeInput,
      h('button', { class: 'btn', type: 'button', onClick: redeem }, t('activate')),
      codeStatus),

    h('h2', {}, t('plansTitle')),
    h('div', { class: 'card' },
      h('table', {}, h('tbody', {}, planRows)),
      h('p', { class: 'small muted' }, t('plansNote')))));
}
