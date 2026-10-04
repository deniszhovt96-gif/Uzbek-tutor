// Знакомство с приложением: 4 коротких экрана при первом входе. Из «Настроек» открывается как «Как пользоваться».
import { rpc } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, haptic, openLink } from '../ui.js';
import { icon, art } from '../icons.js';

const SLIDES = [
  { art: 'tvtower', key: 'w1' },
  { art: 'choynak', key: 'w2' },
  { art: 'gate', key: 'w3' },
  { art: 'suzani', key: 'w4' },
];

export function renderWelcome(app, params = {}) {
  const replay = Boolean(params.replay);
  let i = 0;
  let remind = !(app.me && app.me.settings && app.me.settings.remind === false);

  const finish = async () => {
    haptic('success');
    if (!replay) {
      app.me = await rpc('update_settings', { p_ui_lang: null, p_settings: { onboarded: true, remind } }).catch(() => app.me);
      app.home();
    } else {
      app.back();
    }
  };

  const draw = () => {
    const s = SLIDES[i];
    const last = i === SLIDES.length - 1;
    const list = t(`${s.key}Points`);
    const points = (Array.isArray(list) ? list : []).map((p) => h('li', {}, icon('check'), h('span', {}, p)));
    const extra = [];
    if (last) {
      // напоминания — сразу здесь, чтобы не искать в настройках
      extra.push(h('button', { type: 'button', class: `card remind-toggle ${remind ? 'on' : ''}`, onClick: () => { remind = !remind; haptic(); draw(); } },
        h('span', { class: 'tile-icon' }, icon('clock')),
        h('div', {}, h('b', {}, t('wRemind')), h('div', { class: 'small muted' }, t('wRemindHint'))),
        h('span', { class: `switch ${remind ? 'on' : ''}` }, h('i'))));
      if (app.info && app.info.community_url) {
        extra.push(h('button', { type: 'button', class: 'btn btn-secondary', onClick: () => openLink(app.info.community_url) },
          icon('users'), t('wJoinGroup')));
      }
    }
    mount(h('div', { class: 'screen welcome' },
      h('div', { class: 'dots' }, SLIDES.map((_, k) => h('i', { class: k === i ? 'on' : '' }))),
      h('div', { class: 'welcome-art' }, art(s.art)),
      h('h1', {}, t(`${s.key}Title`)),
      h('p', { class: 'muted' }, t(`${s.key}Text`)),
      points.length ? h('ul', { class: 'feature-list' }, points) : null,
      ...extra,
      h('div', { class: 'welcome-nav' },
        i > 0 ? h('button', { type: 'button', class: 'btn btn-ghost', onClick: () => { i--; draw(); } }, t('back')) : h('span'),
        h('button', { type: 'button', class: 'btn btn-big', onClick: () => { haptic(); if (last) finish(); else { i++; draw(); } } },
          last ? (replay ? t('wDone') : t('wStart')) : t('next'))),
      !last && !replay ? h('button', { type: 'button', class: 'btn btn-ghost small', onClick: finish }, t('wSkip')) : null));
  };
  draw();
}
