// Генерация упражнений из карточки слова (её отдаёт start_session).
// Чистые функции без DOM — их легко проверить и переиспользовать в мобильном приложении.
import { keyRu, keyUz } from './normalize.js';

// Типы по уровню слова (см. документ: «Упражнения»): от узнавания к вспоминанию
export const TYPES_BY_LEVEL = [
  ['uz_ru_choice'],                                                                  // 0 → 1
  ['ru_uz_choice', 'audio_choice'],                                                  // 1 → 2
  ['letters', 'fill_choice', 'find_error', 'uz_ru_choice', 'sentence_choice', 'suffix_choice'],   // 2 → 3
  ['letters', 'fill_choice', 'find_error', 'ru_uz_choice', 'sentence_choice', 'sentence_build', 'suffix_choice'], // 3 → 4
  ['ru_uz_input', 'uz_ru_input', 'fill_input', 'dictation', 'letters', 'fix_error', 'sentence_build', 'audio_sentence'], // 4+
];

// Все виды — для режима «Тренировка»
export const ALL_TYPES = [...new Set(TYPES_BY_LEVEL.flat())];

export function typesForLevel(level) {
  return TYPES_BY_LEVEL[Math.min(Math.max(level, 0), TYPES_BY_LEVEL.length - 1)];
}

export function shuffle(arr, rnd = Math.random) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

// Позиция верного ответа: не больше 2 раз подряд на одном месте
const recentPositions = [];
function placeCorrect(correct, wrong, rnd) {
  const all = shuffle([correct, ...wrong], rnd);
  let idx = all.indexOf(correct);
  const n = recentPositions.length;
  if (n >= 2 && recentPositions[n - 1] === idx && recentPositions[n - 2] === idx) {
    const swap = (idx + 1 + Math.floor(rnd() * (all.length - 1))) % all.length;
    [all[idx], all[swap]] = [all[swap], all[idx]];
    idx = swap;
  }
  recentPositions.push(idx);
  if (recentPositions.length > 10) recentPositions.shift();
  return { options: all, correctIndex: idx };
}

// ---------------------------------------------------------------- буквы
// Плитки: каждая буква отдельно (sh, ch, ng тоже), но oʻ и gʻ — одна плитка; ʼ прилипает к предыдущей букве.
// Примеры по силам: пока слово только учится — короткие предложения, потом длиннее.
// уровень слова 0–2 → до 6 слов в предложении, 3–6 → до 9, дальше — любые. Если подходящих нет — самое короткое.
export function examplesFor(item) {
  const all = item.examples || [];
  const level = item.level || 0;
  const max = level <= 2 ? 6 : level <= 6 ? 9 : Infinity;
  const words = (e) => String(e.uz || '').split(/\s+/).filter(Boolean).length;
  const fit = all.filter((e) => words(e) <= max);
  if (fit.length || !all.length) return fit;
  return [all.reduce((a, b) => (words(b) < words(a) ? b : a))];
}

export function tilesOf(text) {
  const tiles = [];
  const chars = [...text];
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i];
    if (ch === ' ') { tiles.push({ space: true }); continue; }
    if (ch === 'ʻ' && tiles.length && /[oOgG]$/.test(tiles[tiles.length - 1].ch || '')) {
      tiles[tiles.length - 1].ch += ch;
      continue;
    }
    // sh, ch, ng — одна буква узбекского алфавита, одна плитка (решение владельца, шаг 11)
    if (/[hgHG]/.test(ch) && tiles.length && /^[scnSCN]$/.test(tiles[tiles.length - 1].ch || '')
        && /^(sh|ch|ng)$/i.test(tiles[tiles.length - 1].ch + ch)) {
      tiles[tiles.length - 1].ch += ch;
      continue;
    }
    if (ch === 'ʼ' && tiles.length && !tiles[tiles.length - 1].space) {
      tiles[tiles.length - 1].ch += ch;
      continue;
    }
    tiles.push({ ch });
  }
  return tiles;
}

function isLetterTile(t) { return !t.space && /[a-zA-Z]/.test(t.ch); }

// ---------------------------------------------------------------- найди ошибку
// Реалистичные замены одной буквы (типичные ошибки): oʻ↔o, gʻ↔g, x↔h, q↔k, a↔o, i↔e, u↔oʻ
const SUBS = {
  'oʻ': ['o', 'u'], 'gʻ': ['g'], o: ['a', 'oʻ'], g: ['gʻ'], a: ['o'],
  x: ['h'], h: ['x'], q: ['k', 'gʻ'], k: ['q'], i: ['e'], e: ['i'], u: ['oʻ'], sh: ['s'], ch: ['sh'], ng: ['n'],
};

export function distort(word, forbiddenKeys = new Set(), rnd = Math.random) {
  const tiles = tilesOf(word);
  const candidates = [];
  tiles.forEach((t, i) => {
    if (t.space) return;
    const base = t.ch.toLowerCase().replace('ʼ', '');
    const upper = t.ch[0] !== t.ch[0].toLowerCase();
    for (const rep of SUBS[base] || []) candidates.push({ i, rep: upper ? rep[0].toUpperCase() + rep.slice(1) : rep });
  });
  for (const c of shuffle(candidates, rnd)) {
    const wrongTiles = tiles.map((t, i) => (i === c.i ? { ch: c.rep + (t.ch.endsWith('ʼ') ? 'ʼ' : '') } : t));
    const text = wrongTiles.map((t) => (t.space ? ' ' : t.ch)).join('');
    const k = keyUz(text);
    if (k !== keyUz(word) && !forbiddenKeys.has(k)) return { tiles: wrongTiles, wrongIndex: c.i, text };
  }
  return null;
}

// ---------------------------------------------------------------- окончания и предложения
// Падежные окончания (с вариантами после глухих: -ka/-qa, -ta, -tan) и они же после -lar
const SUFFIX_GROUP = {
  ga: 'dat', ka: 'dat', qa: 'dat', da: 'loc', ta: 'loc', dan: 'abl', tan: 'abl', ni: 'acc', ning: 'gen',
  larga: 'dat', larda: 'loc', lardan: 'abl', larni: 'acc', larning: 'gen',
};
const BASE_SUFFIXES = ['ga', 'da', 'dan', 'ni', 'ning'];
const PLURAL_SUFFIXES = ['larga', 'larda', 'lardan', 'larni', 'larning'];

// Предложение → «фишки»-слова без знаков препинания по краям; конечный знак показывается отдельно
export function chipsOf(sentence) {
  const text = String(sentence).trim();
  const endMatch = text.match(/[.!?…]+$/);
  const end = endMatch ? endMatch[0] : '';
  const chips = text.slice(0, text.length - end.length).split(/\s+/)
    .map((w) => w.replace(/^[«"“(]+|[»"”),;:.!?]+$/g, ''))
    .filter((w) => keyUz(w) !== '');
  return { chips, end };
}

// ---------------------------------------------------------------- построение упражнения
function firstUpper(s) { return s ? s[0].toUpperCase() + s.slice(1) : s; }

function uniqueBy(list, keyFn, exclude) {
  const seen = new Set(exclude);
  const out = [];
  for (const x of list) {
    const k = keyFn(x);
    if (!k || seen.has(k)) continue;
    seen.add(k);
    out.push(x);
  }
  return out;
}

function verbStem(uz) { return uz.replace(/(moq|mak)$/i, ''); }

// Возвращает упражнение или null, если этот тип для слова построить нельзя
export function buildExercise(item, type, opts = {}) {
  const rnd = opts.rnd || Math.random;
  const audioOn = opts.audio !== false && item.audio_ok;
  const ds = item.distractors || [];
  const base = { type, wordId: item.id, word: item };

  switch (type) {
    case 'uz_ru_choice': {
      const wrong = uniqueBy(shuffle(ds, rnd), (d) => keyRu(d.ru), [keyRu(item.ru), ...item.accept_ru])
        .filter((d) => !d.ru.split(',').some((p) => item.accept_ru.includes(keyRu(p))))
        .slice(0, 3).map((d) => d.ru);
      if (wrong.length < 3) return null;
      const { options, correctIndex } = placeCorrect(item.ru, wrong, rnd);
      return { ...base, target: 'ru', prompt: item.uz, promptKind: 'uz', audio: audioOn, options, correctIndex };
    }
    case 'ru_uz_choice':
    case 'audio_choice': {
      if (type === 'audio_choice' && !audioOn) return null;
      const wrong = uniqueBy(shuffle(ds, rnd), (d) => keyUz(d.uz), [item.uz_key || keyUz(item.uz), ...item.accept_uz])
        .slice(0, 3).map((d) => d.uz);
      if (wrong.length < 3) return null;
      const { options, correctIndex } = placeCorrect(item.uz, wrong, rnd);
      return { ...base, target: 'uz', prompt: type === 'audio_choice' ? null : item.ru,
               promptKind: type === 'audio_choice' ? 'audio' : 'ru', audio: audioOn, options, correctIndex };
    }
    case 'letters': {
      const tiles = tilesOf(item.uz);
      const letters = tiles.filter((t) => !t.space);
      if (letters.length < 3 || letters.length > 14 || !letters.every(isLetterTile)) return null;
      let bank = shuffle(letters.map((t) => t.ch), rnd);
      for (let k = 0; k < 5 && bank.join('') === letters.map((t) => t.ch).join(''); k++) bank = shuffle(bank, rnd);
      return { ...base, target: 'uz', prompt: item.ru, promptKind: 'ru', tiles, bank };
    }
    case 'fill_choice':
    case 'fill_input': {
      const exs = shuffle(examplesFor(item).filter((e) => e.blank_start !== null && e.blank_start !== undefined), rnd);
      const ex = exs[0];
      if (!ex) return null;
      const chars = [...ex.uz];
      const answer = chars.slice(ex.blank_start, ex.blank_start + ex.blank_len).join('');
      const before = chars.slice(0, ex.blank_start).join('');
      const after = chars.slice(ex.blank_start + ex.blank_len).join('');
      const fill = { before, after, ru: ex.ru, example: { word_id: ex.word_id, n: ex.n }, exampleAudio: ex.audio_ok };
      if (type === 'fill_input') return { ...base, target: 'blank', ...fill, answer };
      const cap = ex.blank_start === 0;
      const isStem = keyUz(answer) !== keyUz(item.uz);
      let pool = ds.map((d) => d.uz).filter((u) => !u.includes(' '));
      if (isStem) pool = pool.filter((u) => /(moq|mak)$/i.test(u)).map(verbStem);
      const wrong = uniqueBy(shuffle(pool, rnd), keyUz, [keyUz(answer)])
        .filter((u) => keyUz(u).length >= 2).slice(0, 3)
        .map((u) => (cap ? firstUpper(u) : u.toLowerCase()));
      if (wrong.length < 3) return null;
      const { options, correctIndex } = placeCorrect(answer, wrong, rnd);
      return { ...base, target: 'blank', ...fill, answer, options, correctIndex };
    }
    case 'find_error': {
      if (item.uz.length < 3) return null;
      const forbidden = new Set(ds.map((d) => keyUz(d.uz)));
      const d = distort(item.uz, forbidden, rnd);
      if (!d) return null;
      return { ...base, target: 'uz', prompt: item.ru, promptKind: 'ru', wrongTiles: d.tiles, wrongIndex: d.wrongIndex, distorted: d.text };
    }
    case 'fix_error': {
      if (item.uz.length < 3) return null;
      const forbidden = new Set(ds.map((d) => keyUz(d.uz)));
      const d = distort(item.uz, forbidden, rnd);
      if (!d) return null;
      return { ...base, target: 'uz', prompt: item.ru, promptKind: 'ru', input: 'uz', distorted: d.text };
    }
    case 'sentence_choice': {
      const exs = shuffle(examplesFor(item).filter((e) => e.ru && e.uz), rnd);
      const ex = exs[0];
      if (!ex) return null;
      const own = new Set(examplesFor(item).map((e) => keyRu(e.ru)));
      const wrong = uniqueBy(shuffle(opts.sentencePool || [], rnd), keyRu, [...own])
        .filter((ru) => ru.length < 140).slice(0, 3);
      if (wrong.length < 3) return null;
      const { options, correctIndex } = placeCorrect(ex.ru, wrong, rnd);
      return { ...base, target: 'sentence_ru', prompt: ex.uz, promptKind: 'uz_sentence', answer: ex.ru,
               example: { word_id: ex.word_id, n: ex.n }, exampleAudio: ex.audio_ok && audioOn, options, correctIndex };
    }
    case 'sentence_build': {
      const candidates = shuffle(examplesFor(item).filter((e) => {
        const n = chipsOf(e.uz).chips.length;
        return n >= 3 && n <= 8;
      }), rnd);
      const ex = candidates[0];
      if (!ex) return null;
      const { chips, end } = chipsOf(ex.uz);
      let bank = shuffle(chips, rnd);
      for (let k = 0; k < 6 && keyUz(bank.join(' ')) === keyUz(chips.join(' ')); k++) bank = shuffle(chips, rnd);
      return { ...base, target: 'sentence_uz', ru: ex.ru, answer: ex.uz, chips, bank, end,
               example: { word_id: ex.word_id, n: ex.n }, exampleAudio: ex.audio_ok && audioOn };
    }
    case 'suffix_choice': {
      if (item.word_class !== 'other') return null;
      const found = [];
      for (const e of item.examples || []) {
        if (e.blank_start === null || e.blank_start === undefined) continue;
        const chars = [...e.uz];
        const stem = chars.slice(e.blank_start, e.blank_start + e.blank_len).join('');
        if (keyUz(stem) !== keyUz(item.uz)) continue;
        const rest = chars.slice(e.blank_start + e.blank_len).join('');
        const m = rest.match(/^([a-zA-Zʻʼ']+)/);
        if (!m || !SUFFIX_GROUP[m[1].toLowerCase()]) continue;
        found.push({ e, stem, suffix: m[1].toLowerCase(), before: chars.slice(0, e.blank_start).join(''), after: rest.slice(m[1].length) });
      }
      const f = shuffle(found, rnd)[0];
      if (!f) return null;
      const group = SUFFIX_GROUP[f.suffix];
      const plural = f.suffix.startsWith('lar');
      const pool = (plural ? PLURAL_SUFFIXES : BASE_SUFFIXES).filter((s) => SUFFIX_GROUP[s] !== group);
      const wrong = shuffle(pool, rnd).slice(0, 3);
      const { options, correctIndex } = placeCorrect(f.suffix, wrong, rnd);
      return { ...base, target: 'token', stem: f.stem, before: f.before, after: f.after, ru: f.e.ru,
               answer: f.stem + f.suffix, suffixes: options, options: options.map((s) => f.stem + s), correctIndex,
               example: { word_id: f.e.word_id, n: f.e.n }, exampleAudio: f.e.audio_ok };
    }
    case 'audio_sentence': {
      if (!audioOn) return null;
      const exs = shuffle(examplesFor(item).filter((e) => e.audio_ok && e.blank_start !== null && e.blank_start !== undefined), rnd);
      const ex = exs[0];
      if (!ex) return null;
      const chars = [...ex.uz];
      return { ...base, target: 'blank', input: 'uz', ru: ex.ru,
               before: chars.slice(0, ex.blank_start).join(''),
               after: chars.slice(ex.blank_start + ex.blank_len).join(''),
               answer: chars.slice(ex.blank_start, ex.blank_start + ex.blank_len).join(''),
               example: { word_id: ex.word_id, n: ex.n }, exampleAudio: true, audio: true };
    }
    case 'ru_uz_input':
      return { ...base, target: 'uz', prompt: item.ru, promptKind: 'ru', input: 'uz' };
    case 'uz_ru_input':
      return { ...base, target: 'ru', prompt: item.uz, promptKind: 'uz', audio: audioOn, input: 'ru' };
    case 'dictation':
      if (!audioOn) return null;
      return { ...base, target: 'uz', prompt: null, promptKind: 'audio', audio: true, input: 'uz' };
    default:
      return null;
  }
}

// Подбор упражнения: тип по уровню, не повторяя прошлый тип этого слова; с запасными вариантами
export function pickExercise(item, level, lastType, opts = {}) {
  const rnd = opts.rnd || Math.random;
  const primary = shuffle(opts.types || typesForLevel(level), rnd).filter((t) => t !== lastType);
  const fallback = ['uz_ru_choice', 'ru_uz_choice', 'ru_uz_input', 'uz_ru_input'].filter((t) => t !== lastType);
  for (const type of [...primary, ...fallback]) {
    const ex = buildExercise(item, type, opts);
    if (ex) return ex;
  }
  return buildExercise(item, 'ru_uz_input', opts);
}

// Проверка ответа на устройстве (окончательно проверяет сервер теми же правилами)
export function checkAnswer(ex, answer) {
  if (ex.target === 'ru') return keyRu(answer) !== '' && ex.word.accept_ru.includes(keyRu(answer));
  if (ex.target === 'uz') {
    const k = keyUz(answer);
    return k !== '' && (k === keyUz(ex.word.uz) || ex.word.accept_uz.includes(k));
  }
  if (ex.target === 'blank' || ex.target === 'token' || ex.target === 'sentence_uz') {
    return keyUz(answer) !== '' && keyUz(answer) === keyUz(ex.answer);
  }
  if (ex.target === 'sentence_ru') return keyRu(answer) !== '' && keyRu(answer) === keyRu(ex.answer);
  return false;
}

// Правильный ответ для показа после ошибки
export function correctAnswerText(ex) {
  if (ex.target === 'ru') return ex.word.ru;
  if (ex.target === 'blank' || ex.target === 'token' || ex.target === 'sentence_uz' || ex.target === 'sentence_ru') return ex.answer;
  return ex.word.uz;
}
