// Отображение карточки слова и всех видов упражнений. Используется в сеансе и в тренировке.
import { t } from './i18n.js';
import { h, haptic, audioButton } from './ui.js';
import { icon } from './icons.js';
import { play, wordAudio, exampleAudio } from './audio.js';
import { correctAnswerText } from './exercises.js';
import { diffChars, displayUz } from './normalize.js';

export const PROMPT_KEY = {
  uz_ru_choice: 'exUzRu', ru_uz_choice: 'exRuUz', audio_choice: 'exAudio', letters: 'exLetters',
  fill_choice: 'exFillChoice', fill_input: 'exFillInput', find_error: 'exFindError',
  ru_uz_input: 'exRuUzInput', uz_ru_input: 'exUzRuInput', dictation: 'exDictation',
  sentence_choice: 'exSentenceChoice', sentence_build: 'exSentenceBuild', suffix_choice: 'exSuffix',
  audio_sentence: 'exAudioSentence', fix_error: 'exFixError',
};

// ---------------------------------------------------------------- карточка нового слова
export function renderCard(item, { audioEnabled, onNext }) {
  if (item.audio_ok && audioEnabled) play(wordAudio(item.id));
  const examples = (item.examples || []).slice(0, 3).map((ex) =>
    h('div', { class: 'example' },
      h('div', { class: 'ex-uz' }, h('span', {}, ex.uz), ex.audio_ok && audioEnabled ? audioButton(() => play(exampleAudio(ex.word_id, ex.n))) : null),
      h('div', { class: 'ex-ru muted' }, ex.ru)));
  return h('div', {},
    h('div', { class: 'label' }, t('newWord')),
    h('div', { class: 'card word-card' },
      h('div', { class: 'word-uz' }, item.uz, item.audio_ok && audioEnabled ? audioButton(() => play(wordAudio(item.id))) : null),
      h('div', { class: 'word-ru' }, item.ru),
      examples.length ? h('div', { class: 'examples' }, h('div', { class: 'label' }, t('examples')), examples) : null),
    h('button', { class: 'btn btn-big', onClick: onNext }, t('gotIt')));
}

// ---------------------------------------------------------------- упражнение
// onAnswer(answerText) → true/false (верно ли); onNext() — переход дальше
export function renderExercise(ex, { audioEnabled, onAnswer, onNext }) {
  if (window.__TEST__) window.__ex = ex;   // только для автотестов
  let answered = false;
  const body = h('div', { class: 'ex-body' });
  const feedback = h('div', { class: 'feedback' });
  const exAudio = () => ex.example && play(exampleAudio(ex.example.word_id, ex.example.n));

  const submit = (answerText, extra = {}) => {
    if (answered) return;
    answered = true;
    const correct = onAnswer(answerText);
    haptic(correct ? 'success' : 'error');
    if (extra.mark) extra.mark(correct);
    showFeedback(correct, answerText, extra);
  };

  const showFeedback = (correct, answerText, extra) => {
    const right = correctAnswerText(ex);
    const word = ex.word;
    const parts = [h('div', { class: correct ? 'fb-title ok' : 'fb-title err' },
      icon(correct ? 'check' : 'close'), correct ? t('correct') : t('wrong'))];
    if (!correct) {
      if (extra.typed && answerText) {
        parts.push(h('div', { class: 'small muted' }, t('yourAnswer')));
        parts.push(h('div', { class: 'diff' }, diffChars(answerText, right).map((d) =>
          h('span', { class: `d-${d.kind}` }, d.ch === ' ' ? ' ' : d.ch))));
      }
      parts.push(h('div', { class: 'small muted' }, t('rightAnswer')));
      parts.push(h('div', { class: 'right-answer' }, right));
    }
    if ((ex.type === 'audio_sentence' || ex.type === 'sentence_build') && ex.ru) parts.push(h('div', { class: 'small' }, ex.ru));
    parts.push(h('div', { class: 'pair' }, `${word.uz} — ${word.ru}`,
      word.audio_ok && audioEnabled ? audioButton(() => play(wordAudio(word.id))) : null,
      ex.example && ex.exampleAudio && audioEnabled ? audioButton(exAudio) : null));
    const nextBtn = h('button', { class: 'btn btn-big', onClick: onNext }, t('next'));
    feedback.className = `feedback show ${correct ? 'good' : 'bad'}`;
    feedback.replaceChildren(...parts, nextBtn);
    setTimeout(() => nextBtn.scrollIntoView({ block: 'nearest', behavior: 'smooth' }), 60);
  };

  // ---- заголовок задания
  const sentenceWithBlank = (before, after, stem) => h('div', { class: 'sentence' }, before,
    h('span', { class: 'nowrap' }, stem ? h('span', { class: 'stem' }, stem) : null,
      h('span', { class: 'blank' }, ' '.repeat(stem ? 3 : 6)), after.match(/^\S*/)[0]),
    after.replace(/^\S*/, ''));

  let promptEl;
  if (ex.type === 'audio_sentence') {
    setTimeout(exAudio, 250);
    promptEl = h('div', { class: 'prompt' },
      h('button', { class: 'btn btn-audio-big', type: 'button', onClick: exAudio }, icon('sound')),
      sentenceWithBlank(ex.before, ex.after));
  } else if (ex.promptKind === 'audio') {
    setTimeout(() => play(wordAudio(ex.wordId)), 200);
    promptEl = h('div', { class: 'prompt' },
      h('button', { class: 'btn btn-audio-big', type: 'button', onClick: () => play(wordAudio(ex.wordId)) }, icon('sound')));
  } else if (ex.type === 'fill_choice' || ex.type === 'fill_input') {
    promptEl = h('div', { class: 'prompt' }, sentenceWithBlank(ex.before, ex.after), h('div', { class: 'muted small' }, ex.ru));
  } else if (ex.type === 'suffix_choice') {
    promptEl = h('div', { class: 'prompt' }, sentenceWithBlank(ex.before, ex.after, ex.stem), h('div', { class: 'muted small' }, ex.ru));
  } else if (ex.type === 'sentence_choice') {
    if (ex.exampleAudio && audioEnabled) setTimeout(exAudio, 200);
    promptEl = h('div', { class: 'prompt' }, h('div', { class: 'sentence-uz' }, ex.prompt,
      ex.exampleAudio && audioEnabled ? h('span', {}, ' ', audioButton(exAudio)) : null));
  } else if (ex.type === 'sentence_build') {
    promptEl = h('div', { class: 'prompt' }, h('div', { class: 'word-ru' }, ex.ru));
  } else if (ex.type === 'fix_error') {
    promptEl = h('div', { class: 'prompt' }, h('div', { class: 'word-ru' }, ex.prompt));
  } else if (ex.type === 'find_error') {
    promptEl = h('div', { class: 'prompt' }, h('div', { class: 'word-ru' }, ex.prompt));
  } else {
    promptEl = h('div', { class: 'prompt' },
      h('div', { class: ex.promptKind === 'uz' ? 'word-uz' : 'word-ru' }, ex.prompt,
        ex.promptKind === 'uz' && ex.audio && audioEnabled ? audioButton(() => play(wordAudio(ex.wordId))) : null));
    if (ex.promptKind === 'uz' && ex.audio && audioEnabled) play(wordAudio(ex.wordId));
  }

  // ---- ответ
  if (ex.options) {
    const labels = ex.type === 'suffix_choice' ? ex.suffixes.map((s) => `-${s}`) : ex.options;
    const buttons = ex.options.map((opt, i) =>
      h('button', { class: 'option', type: 'button', onClick: () => submit(opt, {
        mark: (correct) => {
          buttons[ex.correctIndex].classList.add('right');
          if (!correct) buttons[i].classList.add('wrong');
          buttons.forEach((b) => (b.disabled = true));
        },
      }) }, labels[i]));
    body.append(h('div', { class: `options ${ex.type === 'suffix_choice' ? 'suffixes' : ''}` }, buttons));
  } else if (ex.type === 'letters') {
    body.append(lettersWidget(ex, submit));
  } else if (ex.type === 'sentence_build') {
    body.append(buildWidget(ex, submit));
  } else if (ex.type === 'find_error') {
    const tiles = ex.wrongTiles.map((tile, i) => tile.space
      ? h('span', { class: 'gap' })
      : !/[a-zA-Z]/.test(tile.ch)
      ? h('span', { class: 'punct' }, tile.ch)
      : h('button', { class: 'letter', type: 'button', onClick: () => {
          const correct = i === ex.wrongIndex;
          submit(correct ? ex.word.uz : ex.distorted, {
            mark: () => {
              tiles[ex.wrongIndex].classList.add('right');
              if (!correct) tiles[i].classList.add('wrong');
              tiles.forEach((b) => b.tagName === 'BUTTON' && (b.disabled = true));
            },
          });
        } }, tile.ch));
    body.append(h('div', { class: 'letters-row' }, tiles));
  } else {
    body.append(...typedInput(ex, submit, ex.type === 'fix_error' ? ex.distorted : ''));
  }

  return h('div', {},
    h('div', { class: 'label' }, t(PROMPT_KEY[ex.type])),
    h('div', { class: 'card ex-card' }, promptEl, body),
    feedback);
}

// ---------------------------------------------------------------- ввод с клавиатуры
function typedInput(ex, submit, initial = '') {
  const isUz = ex.input === 'uz' || ex.target === 'blank' || ex.target === 'uz';
  const input = h('input', {
    class: 'answer-input', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
    placeholder: isUz ? t('placeholderUz') : t('placeholderRu'),
    onKeydown: (e) => { if (e.key === 'Enter') go(); },
  });
  input.value = initial;
  const go = () => {
    const value = input.value.trim();
    if (!value) return;
    input.disabled = true;
    btn.disabled = true;
    submit(isUz ? displayUz(value) : value, { typed: true });
  };
  const btn = h('button', { class: 'btn', onClick: go }, t('check'));
  setTimeout(() => input.focus(), 50);
  return [input, isUz ? apostropheHelper(input) : null, btn];
}

// Кнопки oʻ, gʻ, ʼ — на телефонной клавиатуре их обычно нет
function apostropheHelper(input) {
  const add = (s) => () => {
    input.value += s;
    input.focus();
  };
  return h('div', { class: 'helper-row' },
    h('button', { class: 'chip-btn', type: 'button', onClick: add('oʻ') }, 'oʻ'),
    h('button', { class: 'chip-btn', type: 'button', onClick: add('gʻ') }, 'gʻ'),
    h('button', { class: 'chip-btn', type: 'button', onClick: add('ʼ') }, 'ʼ'));
}

// ---------------------------------------------------------------- «Собери слово»: буквы или ввод с клавиатуры
function lettersWidget(ex, submit) {
  const box = h('div', {});
  const tilesMode = () => {
    const slotsCount = ex.tiles.filter((x) => !x.space).length;
    const filled = new Array(slotsCount).fill(null);
    const slotEls = [];
    const row = h('div', { class: 'slots' });
    let k = 0;
    for (const tile of ex.tiles) {
      if (tile.space) { row.append(h('span', { class: 'gap' })); continue; }
      const idx = k++;
      const el = h('button', { class: 'slot', type: 'button', onClick: () => {
        if (filled[idx] === null) return;
        bankEls[filled[idx]].disabled = false;
        filled[idx] = null;
        redraw();
      } });
      slotEls.push(el);
      row.append(el);
    }
    const bankEls = ex.bank.map((ch, bi) => h('button', { class: 'letter', type: 'button', onClick: () => {
      const free = filled.indexOf(null);
      if (free < 0) return;
      haptic();
      filled[free] = bi;
      bankEls[bi].disabled = true;
      redraw();
      if (filled.every((x) => x !== null)) check();
    } }, ch));
    const redraw = () => slotEls.forEach((el, i) => (el.textContent = filled[i] === null ? '' : ex.bank[filled[i]]));
    const assembled = () => {
      let i = 0;
      return ex.tiles.map((tile) => (tile.space ? ' ' : ex.bank[filled[i++]] || '')).join('');
    };
    const check = () => {
      submit(assembled(), {
        typed: true,
        mark: (correct) => {
          row.classList.add(correct ? 'right' : 'wrong');
          bankEls.forEach((b) => (b.disabled = true));
          slotEls.forEach((b) => (b.disabled = true));
          switcher.remove();
        },
      });
    };
    const erase = h('button', { class: 'btn btn-secondary btn-small', type: 'button', onClick: () => {
      const last = filled.map((x, i) => (x === null ? -1 : i)).filter((i) => i >= 0).pop();
      if (last === undefined) return;
      bankEls[filled[last]].disabled = false;
      filled[last] = null;
      redraw();
    } }, t('erase'));
    const switcher = h('button', { class: 'btn btn-ghost btn-small', type: 'button', onClick: () => box.replaceChildren(...typedMode()) },
      icon('keyboard'), t('typeMode'));
    return [row, h('div', { class: 'bank' }, bankEls), h('div', { class: 'mode-switch' }, erase, switcher)];
  };
  const typedMode = () => {
    const parts = typedInput({ ...ex, input: 'uz' }, submit);
    const switcher = h('button', { class: 'btn btn-ghost btn-small', type: 'button', onClick: () => box.replaceChildren(...tilesMode()) },
      icon('tiles'), t('tileMode'));
    return [...parts, h('div', { class: 'mode-switch' }, switcher)];
  };
  box.replaceChildren(...tilesMode());
  return box;
}

// ---------------------------------------------------------------- «Собери предложение»
function buildWidget(ex, submit) {
  const placed = [];    // индексы в ex.bank
  const line = h('div', { class: 'build-line' });
  const endMark = ex.end ? h('span', { class: 'punct' }, ex.end) : null;
  const bankEls = ex.bank.map((w, bi) => h('button', { class: 'chip-word', type: 'button', onClick: () => {
    haptic();
    placed.push(bi);
    bankEls[bi].disabled = true;
    redraw();
    if (placed.length === ex.bank.length) check();
  } }, w));
  let locked = false;
  const redraw = () => {
    line.replaceChildren(...placed.map((bi, pos) => h('button', { class: 'chip-word', type: 'button', onClick: () => {
      if (locked) return;
      placed.splice(pos, 1);
      bankEls[bi].disabled = false;
      redraw();
    } }, ex.bank[bi])), endMark || '');
  };
  const check = () => {
    locked = true;
    const sentence = placed.map((bi) => ex.bank[bi]).join(' ') + (ex.end || '');
    submit(sentence, {
      typed: true,
      mark: (correct) => {
        line.classList.add(correct ? 'right' : 'wrong');
        bankEls.forEach((b) => (b.disabled = true));
      },
    });
  };
  redraw();
  return h('div', {}, line, h('div', { class: 'bank' }, bankEls));
}
