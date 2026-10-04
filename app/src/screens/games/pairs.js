// «Найди пары»: 4 раунда по 5 пар слово — перевод на время.
import { t } from '../../i18n.js';
import { h, mount, haptic } from '../../ui.js';
import { icon } from '../../icons.js';
import { shuffle } from '../../exercises.js';
import { keyRu, keyUz } from '../../normalize.js';
import { gameResult, setBest } from '../games.js';

export function playPairs({ app, items, key, again }) {
  // раунды по 5 слов без совпадающих переводов внутри раунда
  const rounds = [];
  let cur = [];
  for (const it of shuffle(items)) {
    if (cur.some((x) => keyRu(x.ru) === keyRu(it.ru) || keyUz(x.uz) === keyUz(it.uz))) continue;
    cur.push(it);
    if (cur.length === 5) { rounds.push(cur); cur = []; }
    if (rounds.length === 4) break;
  }
  if (!rounds.length) rounds.push(items.slice(0, 5));
  const started = Date.now();
  let mistakes = 0;
  let r = 0;
  const timer = h('span', { class: 'hud-item' }, icon('clock'), '0');
  const tick = setInterval(() => { timer.lastChild.textContent = String(Math.round((Date.now() - started) / 1000)); }, 500);
  app.cleanup = () => clearInterval(tick);

  const playRound = () => {
    const words = rounds[r];
    let left = words.length;
    let sel = null;
    const btn = (it, side) => {
      const b = h('button', { class: 'pair-btn', type: 'button', onClick: () => {
        haptic();
        if (!sel) { sel = { it, side, b }; b.classList.add('sel'); return; }
        if (sel.b === b) { b.classList.remove('sel'); sel = null; return; }
        if (sel.side === side) { sel.b.classList.remove('sel'); sel = { it, side, b }; b.classList.add('sel'); return; }
        if (sel.it.id === it.id) {
          haptic('success');
          sel.b.classList.add('done'); b.classList.add('done');
          sel = null;
          if (--left === 0) setTimeout(next, 250);
        } else {
          haptic('error');
          mistakes++;
          const a = sel.b;
          a.classList.remove('sel');
          a.classList.add('bad'); b.classList.add('bad');
          setTimeout(() => { a.classList.remove('bad'); b.classList.remove('bad'); }, 350);
          sel = null;
          mistakesEl.textContent = String(mistakes);
        }
      } }, side === 'uz' ? it.uz : it.ru);
      return b;
    };
    if (window.__TEST__) window.__pairs = words.map((x) => [x.uz, x.ru]);
    const lefts = shuffle(words).map((it) => btn(it, 'uz'));
    const rights = shuffle(words).map((it) => btn(it, 'ru'));
    const grid = h('div', { class: 'pairs-grid' });
    lefts.forEach((b, i) => grid.append(b, rights[i]));
    const mistakesEl = h('span', {}, String(mistakes));
    mount(h('div', { class: 'screen' },
      h('div', { class: 'game-hud' },
        h('b', {}, t('round', r + 1, rounds.length)),
        h('span', { class: 'hud-item err' }, icon('close'), mistakesEl),
        timer),
      grid));
  };

  const next = () => {
    r++;
    if (r < rounds.length) return playRound();
    clearInterval(tick);
    app.cleanup = null;
    const secs = Math.round((Date.now() - started) / 1000);
    const score = secs + mistakes * 3;   // штраф 3 с за ошибку
    const record = setBest(key, score, (a, b) => a < b);
    gameResult({ app, again, title: t('gamePairs'), big: `${secs} c`, text: t('pairsDone', secs, mistakes), record });
  };

  playRound();
}
