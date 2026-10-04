// «Угадай слово»: перевод известен, узбекское слово отгадывается по буквам; 6 жизней на слово.
import { t } from '../../i18n.js';
import { h, mount, haptic } from '../../ui.js';
import { icon } from '../../icons.js';
import { shuffle, tilesOf } from '../../exercises.js';
import { gameResult, setBest } from '../games.js';

const LIVES = 6;
const WORDS = 10;
const KEYS = ['a', 'b', 'd', 'e', 'f', 'g', 'gʻ', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'oʻ', 'p', 'q', 'r', 's', 't', 'u', 'v', 'x', 'y', 'z', 'sh', 'ch', 'ng'];

const norm = (ch) => ch.toLowerCase().replace('ʼ', '');

export function playGuess({ app, items, key, again }) {
  const words = shuffle(items.filter((it) => {
    const letters = tilesOf(it.uz).filter((x) => !x.space);
    return letters.length >= 3 && letters.length <= 12 && letters.every((x) => /^[a-zA-Zʻʼ-]+$/.test(x.ch));
  })).slice(0, WORDS);
  let w = 0;
  let solved = 0;

  const playWord = () => {
    const it = words[w];
    const tiles = tilesOf(it.uz);
    if (window.__TEST__) window.__guess = it;
    const guessed = new Set();
    let lives = LIVES;
    let done = false;
    const cells = tiles.map((tile) => (tile.space ? h('span', { class: 'gap' }) : h('span', { class: 'guess-cell' }, tile.ch === '-' ? '-' : '')));
    const isOpen = (tile) => tile.space || tile.ch === '-' || guessed.has(norm(tile.ch));
    const livesEl = h('span', { class: 'lives' });
    const drawLives = () => livesEl.replaceChildren(...Array.from({ length: LIVES }, (_, i) => icon('heart', `ic ${i < lives ? '' : 'lost'}`)));
    const status = h('div', {});
    const keys = KEYS.map((k) => h('button', { type: 'button', onClick: () => press(k, keys[KEYS.indexOf(k)]) }, k));

    const reveal = (all) => tiles.forEach((tile, i) => {
      if (tile.space) return;
      if (isOpen(tile) || all) {
        cells[i].textContent = tile.ch;
        cells[i].classList.add('open');
        if (all && !isOpen(tile)) cells[i].classList.add('miss');
      }
    });

    const press = (k, btn) => {
      if (done || guessed.has(k)) return;
      guessed.add(k);
      const hit = tiles.some((tile) => !tile.space && norm(tile.ch) === k);
      btn.classList.add(hit ? 'hit' : 'miss');
      btn.disabled = true;
      haptic(hit ? undefined : 'warning');
      if (!hit) { lives--; drawLives(); }
      reveal(false);
      const win = tiles.every(isOpen);
      if (win || lives <= 0) {
        done = true;
        if (win) solved++;
        haptic(win ? 'success' : 'error');
        if (!win) reveal(true);
        status.replaceChildren(
          h('div', { class: `fb-title ${win ? 'ok' : 'err'}` }, icon(win ? 'check' : 'close'), win ? t('guessWin') : t('guessLose')),
          h('div', { class: 'pair' }, `${it.uz} — ${it.ru}`),
          h('button', { class: 'btn btn-big', onClick: next }, w + 1 < words.length ? t('guessNext') : t('finishGame')));
        status.className = `feedback show ${win ? 'good' : 'bad'}`;
      }
    };

    drawLives();
    mount(h('div', { class: 'screen' },
      h('div', { class: 'game-hud' }, h('b', {}, `${w + 1} / ${words.length}`), livesEl),
      h('div', { class: 'card' },
        h('div', { class: 'word-ru', style: { textAlign: 'center' } }, it.ru),
        h('div', { class: 'guess-word' }, cells)),
      status,
      h('div', { class: 'kb' }, keys)));
  };

  const next = () => {
    w++;
    if (w < words.length) return playWord();
    const record = setBest(key, solved, (a, b) => a > b);
    gameResult({ app, again, title: t('gameGuess'), big: `${solved}/${words.length}`, text: t('guessScore', solved), record });
  };

  playWord();
}
