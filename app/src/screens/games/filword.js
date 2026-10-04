// «Филворд»: сетка букв целиком заполнена спрятанными словами; слова идут «змейкой» по соседним клеткам.
// Подсказки — русские переводы. Найти слово = провести по его клеткам (или нажимать их по очереди).
import { t } from '../../i18n.js';
import { h, mount, haptic } from '../../ui.js';
import { icon } from '../../icons.js';
import { buildFilword } from './filword-gen.js';
import { gameResult, setBest } from '../games.js';

const COLORS = ['#0e7c86', '#c8962e', '#7a5af5', '#d0393b', '#1d8a4c', '#2f6fd6', '#b5651d', '#c2428a', '#4d7c0f', '#0891b2'];

// ---------------------------------------------------------------- игра
export function playFilword({ app, items, key, again }) {
  const puzzle = buildFilword(items, 5) || buildFilword(items, 4);
  if (!puzzle) {
    mount(h('div', { class: 'screen' }, h('h1', {}, t('gameFilword')),
      h('div', { class: 'card empty' }, icon('filword'), h('p', {}, t('practiceNotEnough', 12)),
        h('button', { class: 'btn', onClick: () => app.replace('learn', { mode: 'normal' }) }, t('secLearn')))));
    return;
  }
  if (window.__TEST__) window.__fw = puzzle;
  const { n, grid, words } = puzzle;
  const found = new Set();
  let sel = [];
  let dragging = false;
  let moved = false;
  const started = Date.now();

  const cells = grid.map((ch, i) => h('div', { class: 'fw-cell', 'data-i': String(i) }, ch));
  const board = h('div', { class: 'fw-grid', style: { gridTemplateColumns: `repeat(${n}, 1fr)`, maxWidth: `${n * 66}px` } }, cells);
  const hints = words.map((w) => h('span', { class: 'fw-hint' }, w.item.ru));
  const counter = h('b', {}, `0 / ${words.length}`);

  const adjacent = (a, b) => (Math.abs(a - b) === n) || (Math.abs(a - b) === 1 && Math.floor(a / n) === Math.floor(b / n));
  const owner = (i) => words.findIndex((w, wi) => found.has(wi) && w.cells.includes(i));
  const paint = () => cells.forEach((el, i) => {
    const o = owner(i);
    el.classList.remove('bad');
    el.classList.toggle('found', o >= 0);
    el.classList.toggle('sel', sel.includes(i));
    el.style.background = o >= 0 ? COLORS[o % COLORS.length] : '';
  });

  const tryMatch = () => {
    const wi = words.findIndex((w, k) => !found.has(k) && w.cells.length === sel.length && w.cells.every((c, j) => c === sel[j]));
    if (wi < 0) return false;
    found.add(wi);
    haptic('success');
    hints[wi].classList.add('found');
    hints[wi].textContent = `${words[wi].item.uz} — ${words[wi].item.ru}`;
    sel = [];
    paint();
    counter.textContent = `${found.size} / ${words.length}`;
    if (found.size === words.length) setTimeout(finish, 500);
    return true;
  };

  const touch = (i) => {
    if (owner(i) >= 0) return;
    const last = sel[sel.length - 1];
    if (sel.length && i === last) return;
    if (sel.length > 1 && i === sel[sel.length - 2]) { sel.pop(); paint(); return; }     // шаг назад
    if (sel.includes(i)) return;
    if (sel.length && adjacent(i, last)) sel.push(i);
    else sel = [i];
    haptic();
    paint();
    tryMatch();
  };

  const cellAt = (x, y) => {
    const el = document.elementFromPoint(x, y);
    return el && el.dataset && el.dataset.i !== undefined ? Number(el.dataset.i) : null;
  };
  board.addEventListener('pointerdown', (e) => {
    const i = cellAt(e.clientX, e.clientY);
    if (i === null) return;
    dragging = true;
    moved = false;
    board.setPointerCapture && board.setPointerCapture(e.pointerId);
    // нажатие на последнюю выбранную клетку снимает её
    if (sel.length && i === sel[sel.length - 1]) { sel.pop(); paint(); return; }
    touch(i);
  });
  board.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    const i = cellAt(e.clientX, e.clientY);
    if (i === null || i === sel[sel.length - 1]) return;
    moved = true;
    touch(i);
  });
  const up = () => {
    if (!dragging) return;
    dragging = false;
    if (moved && sel.length > 1) {           // провели пальцем, но слово не совпало — сбрасываем
      const wrong = sel.slice();
      wrong.forEach((i) => cells[i].classList.add('bad'));
      haptic('error');
      sel = [];
      setTimeout(paint, 200);
    }
  };
  board.addEventListener('pointerup', up);
  board.addEventListener('pointercancel', up);

  const finish = () => {
    const secs = Math.round((Date.now() - started) / 1000);
    const record = setBest(key, secs, (a, b) => a < b);
    gameResult({ app, again, title: t('fwDone'), big: `${secs} c`, text: words.map((w) => w.item.uz).join(', '), record });
  };

  mount(h('div', { class: 'screen' },
    h('div', { class: 'game-hud' }, h('b', {}, t('gameFilword')), counter),
    board,
    h('p', { class: 'small muted' }, t('fwHint')),
    h('div', { class: 'label' }, t('fwFind')),
    h('div', { class: 'fw-hints' }, hints)));
  paint();
}
