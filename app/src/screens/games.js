// «Игры»: меню и запуск игр по уже начатым словам. На уровни слов не влияют.
import { rpc } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { allowed, lockedSheet } from './home.js';
import { playPairs } from './games/pairs.js';
import { playTrueFalse } from './games/truefalse.js';
import { playGuess } from './games/guess.js';
import { playFilword } from './games/filword.js';

export const GAMES = {
  pairs: { icon: 'pairs', title: 'gamePairs', desc: 'gamePairsDesc', feature: 'games', min: 5, run: playPairs },
  truefalse: { icon: 'truefalse', title: 'gameTF', desc: 'gameTFDesc', feature: 'games', min: 6, run: playTrueFalse },
  guess: { icon: 'guess', title: 'gameGuess', desc: 'gameGuessDesc', feature: 'games', min: 3, run: playGuess },
  filword: { icon: 'filword', title: 'gameFilword', desc: 'gameFilwordDesc', feature: 'filword', min: 6, run: playFilword },
};

// Рекорды хранятся на телефоне
export function getBest(game) {
  try { const v = localStorage.getItem(`ut_best_${game}`); return v === null ? null : Number(v); } catch { return null; }
}
export function setBest(game, value, better) {
  const old = getBest(game);
  if (old === null || better(value, old)) {
    try { localStorage.setItem(`ut_best_${game}`, String(value)); } catch { /* нет доступа */ }
    return true;
  }
  return false;
}

export async function renderGames(app, { game } = {}) {
  if (game) return runGame(app, game);
  mount(spinner(t('loading')));
  const home = app.homeData || await rpc('get_home');
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('gamesTitle')),
    h('p', { class: 'muted small' }, t('gamesHint')),
    h('div', { class: 'game-list' }, Object.entries(GAMES).map(([key, g]) => {
      const ok = allowed(home, g.feature);
      const best = getBest(key);
      return h('button', { class: 'game-card', type: 'button', onClick: () => {
        haptic();
        if (!ok) return lockedSheet(app, home.features[g.feature].min_tier);
        app.go('games', { game: key });
      } },
        h('span', { class: `tile-icon ${key === 'filword' ? 'gold' : ''}` }, icon(g.icon)),
        h('div', {}, h('h3', {}, t(g.title)), h('div', { class: 'small muted' }, t(g.desc)),
          best !== null ? h('div', { class: 'tiny muted' }, t('best', best)) : null),
        ok ? icon('chevron', 'ic chev') : icon('lock', 'ic chev'));
    }))));
}

async function runGame(app, key) {
  const g = GAMES[key];
  mount(spinner(t('loading')));
  const data = await rpc('start_practice', { p_feature: g.feature, p_count: 60 });
  if (data.error === 'locked_tier') { app.back(); lockedSheet(app, data.need); return; }
  if (data.error) throw new Error(data.error);
  const items = data.items || [];
  if (items.length < g.min) {
    mount(h('div', { class: 'screen' }, h('h1', {}, t(g.title)),
      h('div', { class: 'card empty' }, icon(g.icon), h('p', {}, t('practiceNotEnough', g.min)),
        h('button', { class: 'btn', onClick: () => app.replace('learn', { mode: 'normal' }) }, t('secLearn')))));
    return;
  }
  const audioEnabled = !(app.me.settings && app.me.settings.audio_exercises === false);
  g.run({ app, items, key, audioEnabled, again: () => app.replace('games', { game: key }) });
}

// Общий экран результата игры
export function gameResult({ app, again, title, big, sub, text, record }) {
  mount(h('div', { class: 'screen' },
    h('div', { class: 'card result-hero' },
      h('div', { class: 'result-icon ok' }, icon('trophy')),
      h('h1', {}, title),
      h('div', { class: 'big' }, big),
      sub ? h('div', { class: 'small muted' }, sub) : null,
      text ? h('p', { class: 'muted' }, text) : null,
      record ? h('span', { class: 'chip gold' }, icon('star'), t('newRecord')) : null),
    h('button', { class: 'btn btn-big', onClick: again }, t('again')),
    h('button', { class: 'btn btn-secondary', onClick: () => app.back() }, t('gamesTitle'))));
}
