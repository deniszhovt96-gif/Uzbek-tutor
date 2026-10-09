import { rpc } from '../api.js';
import { t, setLang, tierName, formatDate } from '../i18n.js';
import { h, mount, spinner, haptic, openLink } from '../ui.js';
import { icon } from '../icons.js';
import { applyTheme, currentTheme } from '../theme.js';
import { lockedSheet } from './home.js';

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

export async function renderSettings(app, params = {}) {
  // после изменения настройки — перерисовка на месте: без экрана загрузки и без прокрутки наверх
  const keep = Boolean(params.keep && app.me);
  if (!keep) mount(spinner(t('loading')));
  const me = keep ? app.me : await app.refreshMe();
  const settings = me.settings || {};
  // «Базовая» — только лёгкая интенсивность; средняя и интенсивная — в «Продвинутой»
  const intensity = me.tier === 'advanced' ? settings.intensity || 'light' : 'light';
  const audioOn = settings.audio_exercises !== false;
  const remindOn = settings.remind !== false;
  const remindHour = Number(settings.remind_hour || 19);
  const weeklyOn = settings.weekly !== false;
  const weekGoal = Number(settings.week_goal || 5);

  const save = async (lang, patch) => {
    app.me = await rpc('update_settings', { p_ui_lang: lang, p_settings: patch });
    if (lang) setLang(lang);
    haptic('success');
    renderSettings(app, { keep: true });
  };

  const seg = (items, current, onPick) => h('div', { class: 'segmented' }, items.map(([value, label]) =>
    h('button', { type: 'button', class: value === current ? 'active' : '', onClick: () => value !== current && onPick(value) }, label)));

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
          h('button', { type: 'button', class: `radio ${v === intensity ? 'active' : ''} ${v !== 'light' && me.tier !== 'advanced' ? 'locked' : ''}`,
            onClick: () => {
              if (v === intensity) return;
              if (v !== 'light' && me.tier !== 'advanced') return lockedSheet(app, 'advanced');
              return save(null, { intensity: v, ...INTENSITY[v] });
            } },
            h('span', { class: 'spacer' }, t(v === 'light' ? 'intLight' : v === 'medium' ? 'intMedium' : 'intIntense')),
            v !== 'light' && me.tier !== 'advanced' ? icon('lock') : null))),
    me.tier === 'basic' ? h('p', { class: 'small muted' }, t('basicIntensityNote')) : null,

    h('h2', {}, t('remindTitle')),
    h('div', { class: 'card remind-card' },
      h('button', { type: 'button', class: `remind-toggle ${remindOn ? 'on' : ''}`, onClick: () => save(null, { remind: !remindOn }) },
        h('div', {}, h('b', {}, t('remindDaily')), h('div', { class: 'small muted' }, t('remindHint'))),
        h('span', { class: `switch ${remindOn ? 'on' : ''}` }, h('i'))),
      remindOn ? h('label', { class: 'remind-hour' }, h('span', {}, t('remindAt')),
        h('select', { onChange: (e) => save(null, { remind_hour: Number(e.target.value) }) },
          Array.from({ length: 18 }, (_, k) => k + 6).map((hh) => h('option', { value: String(hh), selected: hh === remindHour }, `${String(hh).padStart(2, '0')}:00`)))) : null,
      h('button', { type: 'button', class: `remind-toggle ${weeklyOn ? 'on' : ''}`, onClick: () => save(null, { weekly: !weeklyOn }) },
        h('div', {}, h('b', {}, t('weeklyMsg')), h('div', { class: 'small muted' }, t('weeklyMsgHint'))),
        h('span', { class: `switch ${weeklyOn ? 'on' : ''}` }, h('i')))),

    h('h2', {}, t('weekGoalTitle')),
    seg([3, 4, 5, 6, 7].map((n) => [n, String(n)]), weekGoal, (v) => save(null, { week_goal: v })),
    h('p', { class: 'small muted' }, t('weekGoalHint')),

    h('h2', {}, t('audioEx')),
    seg([['on', t('on')], ['off', t('off')]], audioOn ? 'on' : 'off', (v) => save(null, { audio_exercises: v === 'on' })),

    h('h2', {}, t('helpTitle')),
    h('button', { class: 'card sub-card', type: 'button', onClick: () => app.go('welcome', { replay: true }) },
      h('span', { class: 'tile-icon' }, icon('learn')),
      h('div', {}, h('b', {}, t('guideTitle')), h('div', { class: 'small muted' }, t('guideShort'))),
      icon('chevron', 'ic chev')),

    app.info && app.info.community_url ? [
      h('h2', {}, t('community')),
      h('button', { class: 'card sub-card', type: 'button', onClick: () => openLink(app.info.community_url) },
        h('span', { class: 'tile-icon' }, icon('users')),
        h('div', {}, h('b', {}, t('communityTitle')), h('div', { class: 'small muted' }, t('communityText'))),
        icon('chevron', 'ic chev'))] : null,

    me.is_admin ? [
      h('h2', {}, t('adminSection')),
      h('button', { class: 'card sub-card', type: 'button', onClick: () => app.go('review') },
        h('span', { class: 'tile-icon gold' }, icon('test')),
        h('div', {}, h('b', {}, t('reviewTitle')), h('div', { class: 'small muted' }, t('reviewShort'))),
        icon('chevron', 'ic chev')),
      h('button', { class: 'card sub-card', type: 'button', onClick: () => app.go('wordflags') },
        h('span', { class: 'tile-icon gold' }, icon('learn')),
        h('div', {}, h('b', {}, t('flagsTitle')), h('div', { class: 'small muted' }, t('flagsShort'))),
        icon('chevron', 'ic chev')),
      h('button', { class: 'card sub-card', type: 'button', onClick: () => app.go('formreports') },
        h('span', { class: 'tile-icon gold' }, icon('flag')),
        h('div', {}, h('b', {}, t('frTitle')), h('div', { class: 'small muted' }, t('frShort'))),
        icon('chevron', 'ic chev')),
      h('button', { class: 'card sub-card', type: 'button', onClick: () => app.go('analytics') },
        h('span', { class: 'tile-icon gold' }, icon('chart')),
        h('div', {}, h('b', {}, t('anTitle')), h('div', { class: 'small muted' }, t('anShort'))),
        icon('chevron', 'ic chev'))] : null,

    h('h2', {}, t('subscription')),
    h('button', { class: 'card sub-card', type: 'button', onClick: () => app.go('subscription') },
      h('span', { class: `tile-icon ${me.tier === 'advanced' ? 'gold' : ''}` }, icon('star')),
      h('div', {},
        h('b', {}, tierName(me.tier)),
        h('div', { class: 'small muted' }, me.tier === 'free' ? t('freeLimits') : t('tierUntil', formatDate(me.tier_ends_at)))),
      h('span', { class: 'chip accent' }, t(me.tier === 'free' ? 'upgrade' : 'manageSub')))), { keepScroll: keep });
}
