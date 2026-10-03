// Экран сеанса: карточки новых слов и упражнения.
import { rpc, tg } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner, haptic, audioButton } from '../ui.js';
import { Session } from '../session.js';
import { play, wordAudio, exampleAudio } from '../audio.js';
import { correctAnswerText } from '../exercises.js';
import { diffChars, displayUz } from '../normalize.js';

const PROMPT_KEY = {
  uz_ru_choice: 'exUzRu', ru_uz_choice: 'exRuUz', audio_choice: 'exAudio', letters: 'exLetters',
  fill_choice: 'exFillChoice', fill_input: 'exFillInput', find_error: 'exFindError',
  ru_uz_input: 'exRuUzInput', uz_ru_input: 'exUzRuInput', dictation: 'exDictation',
};

export async function renderLearn(app, { mode = 'normal', topicId = null }) {
  mount(spinner(t('loading')));
  const data = await rpc('start_session', { p_mode: mode, p_topic_id: topicId });
  if (data.error === 'daily_limit') {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card' },
      h('p', {}, t('dailyLimit')),
      h('button', { class: 'btn', onClick: () => app.go('settings') }, t('toSubscription')),
      h('button', { class: 'btn btn-secondary', onClick: () => app.home() }, t('toHome')))));
    return;
  }
  if (data.error) throw new Error(data.error);
  if (!data.items.length) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card' },
      h('p', {}, t('emptySession')),
      h('button', { class: 'btn', onClick: () => app.home() }, t('toHome')))));
    return;
  }

  const audioEnabled = !(app.me.settings && app.me.settings.audio_exercises === false);
  const session = new Session(data, { audio: audioEnabled });
  const webApp = tg();
  if (webApp && webApp.enableClosingConfirmation) webApp.enableClosingConfirmation();
  app.cleanup = () => {
    session.flush();
    if (webApp && webApp.disableClosingConfirmation) webApp.disableClosingConfirmation();
  };

  const step = () => {
    const task = session.next();
    if (!task) return finish();
    if (task.kind === 'card') return showCard(task.item);
    return showExercise(task);
  };

  const frame = (...content) => {
    const pct = Math.round((session.done / Math.max(session.total, 1)) * 100);
    return h('div', { class: 'screen session' },
      h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${pct}%` } })),
      session.saveFailed ? h('p', { class: 'warn small' }, t('saveError')) : null,
      ...content);
  };

  // ---------------------------------------------------------------- карточка нового слова
  function showCard(item) {
    session.cardShown(item);
    if (item.audio_ok && audioEnabled) play(wordAudio(item.id));
    const examples = item.examples.slice(0, 3).map((ex) =>
      h('div', { class: 'example' },
        h('div', { class: 'ex-uz' }, ex.uz, ex.audio_ok ? audioButton(() => play(exampleAudio(ex.word_id, ex.n))) : null),
        h('div', { class: 'ex-ru muted' }, ex.ru)));
    mount(frame(
      h('div', { class: 'label' }, t('newWord')),
      h('div', { class: 'card word-card' },
        h('div', { class: 'word-uz' }, item.uz, item.audio_ok ? audioButton(() => play(wordAudio(item.id))) : null),
        h('div', { class: 'word-ru' }, item.ru),
        examples.length ? h('div', { class: 'examples' }, h('div', { class: 'label' }, t('examples')), examples) : null),
      h('button', { class: 'btn btn-big', onClick: step }, t('gotIt'))));
  }

  // ---------------------------------------------------------------- упражнение
  function showExercise(task) {
    const { ex } = task;
    if (window.__TEST__) window.__ex = ex;   // только для автотестов
    let answered = false;
    const body = h('div', { class: 'ex-body' });
    const feedback = h('div', { class: 'feedback' });

    const submit = (answerText, extra = {}) => {
      if (answered) return;
      answered = true;
      const r = session.answer(task, answerText);
      haptic(r.correct ? 'success' : 'error');
      if (extra.mark) extra.mark(r.correct);
      showFeedback(r.correct, answerText, extra);
    };

    const showFeedback = (correct, answerText, extra) => {
      const right = correctAnswerText(ex);
      const word = ex.word;
      const parts = [h('div', { class: correct ? 'fb-title ok' : 'fb-title err' }, correct ? t('correct') : t('wrong'))];
      if (!correct) {
        if (extra.typed && answerText) {
          parts.push(h('div', { class: 'small muted' }, t('yourAnswer')));
          parts.push(h('div', { class: 'diff' }, diffChars(answerText, right).map((d) =>
            h('span', { class: `d-${d.kind}` }, d.ch === ' ' ? ' ' : d.ch))));
        }
        parts.push(h('div', { class: 'small muted' }, t('rightAnswer')));
        parts.push(h('div', { class: 'right-answer' }, right));
      }
      parts.push(h('div', { class: 'pair' }, `${word.uz} — ${word.ru}`,
        word.audio_ok && audioEnabled ? audioButton(() => play(wordAudio(word.id))) : null,
        ex.example && ex.exampleAudio && audioEnabled ? audioButton(() => play(exampleAudio(ex.example.word_id, ex.example.n))) : null));
      const nextBtn = h('button', { class: 'btn btn-big', onClick: step }, t('next'));
      feedback.className = `feedback show ${correct ? 'good' : 'bad'}`;
      feedback.replaceChildren(...parts, nextBtn);
      nextBtn.focus();
    };

    // заголовок задания
    const promptEl = (() => {
      if (ex.promptKind === 'audio') {
        setTimeout(() => play(wordAudio(ex.wordId)), 200);
        return h('div', { class: 'prompt' }, h('button', { class: 'btn btn-audio-big', onClick: () => play(wordAudio(ex.wordId)) }, '🔊'));
      }
      if (ex.type.startsWith('fill')) {
        return h('div', { class: 'prompt' },
          h('div', { class: 'sentence' }, ex.before,
            h('span', { class: 'nowrap' }, h('span', { class: 'blank' }, '\u00a0'.repeat(6)), ex.after.match(/^\S*/)[0]),
            ex.after.replace(/^\S*/, '')),
          h('div', { class: 'muted small' }, ex.ru));
      }
      if (ex.type === 'find_error') return h('div', { class: 'prompt' }, h('div', { class: 'word-ru' }, ex.prompt));
      return h('div', { class: 'prompt' },
        h('div', { class: ex.promptKind === 'uz' ? 'word-uz' : 'word-ru' }, ex.prompt,
          ex.promptKind === 'uz' && ex.audio ? audioButton(() => play(wordAudio(ex.wordId))) : null));
    })();
    if (ex.promptKind === 'uz' && ex.audio) play(wordAudio(ex.wordId));

    // варианты ответа
    if (ex.options) {
      const buttons = ex.options.map((opt, i) =>
        h('button', { class: 'option', type: 'button', onClick: () => submit(opt, {
          mark: (correct) => {
            buttons[ex.correctIndex].classList.add('right');
            if (!correct) buttons[i].classList.add('wrong');
            buttons.forEach((b) => (b.disabled = true));
          },
        }) }, opt));
      body.append(h('div', { class: 'options' }, buttons));
    } else if (ex.type === 'letters') {
      body.append(lettersWidget(ex, submit));
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
      // ввод с клавиатуры
      const isUz = ex.input === 'uz' || ex.target === 'blank';
      const input = h('input', {
        class: 'answer-input', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
        placeholder: isUz ? t('placeholderUz') : t('placeholderRu'),
        onKeydown: (e) => { if (e.key === 'Enter') go(); },
      });
      const go = () => {
        const value = input.value.trim();
        if (!value) return;
        input.disabled = true;
        submit(isUz ? displayUz(value) : value, { typed: true });
      };
      body.append(input, isUz ? apostropheHelper(input) : null, h('button', { class: 'btn', onClick: go }, t('check')));
      setTimeout(() => input.focus(), 50);
    }

    mount(frame(h('div', { class: 'label' }, t(PROMPT_KEY[ex.type])), h('div', { class: 'card ex-card' }, promptEl, body), feedback));
  }

  // ---------------------------------------------------------------- конец сеанса
  async function finish() {
    mount(spinner(t('loading')));
    const r = await session.finish();
    app.cleanup && app.cleanup();
    app.cleanup = null;
    mount(h('div', { class: 'screen' },
      h('h1', {}, t('sessionDone')),
      h('div', { class: 'card' },
        h('p', {}, t('doneStats', r.correct, r.answers)),
        r.newWords ? h('p', {}, t('doneNew', r.newWords)) : null,
        r.reviewed ? h('p', {}, t('doneReviewed', r.reviewed)) : null),
      app.me.tier !== 'free'
        ? h('button', { class: 'btn btn-big', onClick: () => app.go('learn', { mode: 'normal' }) }, t('anotherSession'))
        : null,
      h('button', { class: 'btn btn-secondary', onClick: () => app.home() }, t('toHome'))));
  }

  step();
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

// «Собери слово»: нажатие на букву ставит её в первую свободную клетку, нажатие на клетку возвращает букву
function lettersWidget(ex, submit) {
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
    const value = assembled();
    submit(value, {
      typed: true,
      mark: (correct) => {
        row.classList.add(correct ? 'right' : 'wrong');
        bankEls.forEach((b) => (b.disabled = true));
        slotEls.forEach((b) => (b.disabled = true));
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
  return h('div', {}, row, h('div', { class: 'bank' }, bankEls), erase);
}
