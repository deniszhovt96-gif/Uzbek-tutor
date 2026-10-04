// «Верно или нет»: 60 секунд — правильный ли перевод показан под словом.
import { t } from '../../i18n.js';
import { h, mount, haptic } from '../../ui.js';
import { icon } from '../../icons.js';
import { shuffle } from '../../exercises.js';
import { keyRu } from '../../normalize.js';
import { gameResult, setBest } from '../games.js';

const SECONDS = 60;
const seconds = () => (window.__TEST__ && window.__TF_SECONDS) || SECONDS;

export function playTrueFalse({ app, items, key, again }) {
  let pool = shuffle(items);
  let i = 0;
  let right = 0;
  let wrong = 0;
  let left = seconds();
  let over = false;

  const card = h('div', { class: 'card tf-card' });
  const bar = h('div', {}, null);
  bar.style.width = '100%';
  const scoreEl = h('span', { class: 'hud-item ok' }, icon('check'), '0');
  const timeEl = h('span', { class: 'hud-item' }, icon('clock'), String(left));
  const yes = h('button', { class: 'btn btn-ok', type: 'button', onClick: () => answer(true) }, icon('check'), t('tfTrue'));
  const no = h('button', { class: 'btn btn-no', type: 'button', onClick: () => answer(false) }, icon('close'), t('tfFalse'));
  let current = null;

  const nextCard = () => {
    if (i >= pool.length) { pool = shuffle(items); i = 0; }
    const it = pool[i++];
    const wrongs = (it.distractors || []).filter((d) => !it.accept_ru.includes(keyRu(d.ru)));
    const truth = Math.random() < 0.5 || !wrongs.length;
    const shown = truth ? it.ru : wrongs[Math.floor(Math.random() * wrongs.length)].ru;
    current = { truth };
    if (window.__TEST__) window.__tf = current;
    card.replaceChildren(h('div', { class: 'word-uz' }, it.uz), h('div', { class: 'word-ru' }, shown));
    card.style.animation = 'none';
    void card.offsetWidth;
    card.style.animation = 'pop .25s';
  };

  const answer = (said) => {
    if (over || !current) return;
    const ok = said === current.truth;
    haptic(ok ? 'success' : 'error');
    if (ok) right++; else wrong++;
    scoreEl.lastChild.textContent = String(right);
    card.style.background = ok ? 'var(--ok-soft)' : 'var(--err-soft)';
    setTimeout(() => { card.style.background = ''; }, 180);
    nextCard();
  };

  const tick = setInterval(() => {
    left--;
    timeEl.lastChild.textContent = String(left);
    bar.style.width = `${(left / seconds()) * 100}%`;
    if (left <= 0) end();
  }, 1000);
  app.cleanup = () => clearInterval(tick);

  const end = () => {
    over = true;
    clearInterval(tick);
    app.cleanup = null;
    const score = Math.max(0, right - wrong);
    const record = setBest(key, score, (a, b) => a > b);
    gameResult({ app, again, title: t('gameTF'), big: String(score), text: t('tfResult', right, wrong), record });
  };

  mount(h('div', { class: 'screen' },
    h('div', { class: 'game-hud' }, h('b', {}, t('gameTF')), scoreEl, timeEl),
    h('div', { class: 'timer-bar' }, bar),
    card,
    h('div', { class: 'tf-buttons' }, no, yes)));
  nextCard();
}
