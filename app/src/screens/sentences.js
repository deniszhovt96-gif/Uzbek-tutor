// «Предложения»: длинные примеры (4+ слова) становятся отдельной лексикой, когда пользователь знает
// большую часть их слов. Задания: перевод (выбор), сборка предложения, предложение на слух, пропуск.
// У каждого предложения своё интервальное повторение (sentence_progress).
import { rpc } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { renderExercise } from '../exercise-view.js';
import { buildExercise, checkAnswer } from '../exercises.js';

const TYPES = ['sentence_choice', 'sentence_build', 'audio_sentence', 'fill_choice'];

// Выбор уровня: по каждому уровню — длинные предложения (готовые к изучению) и бонусные короткие фразы
async function renderLevels(app) {
  mount(spinner(t('loading')));
  const data = await rpc('get_sentence_levels');
  if (data.error) throw new Error(data.error);
  const levels = data.levels || [];
  const unlockedRank = ['A1', 'A2', 'B1', 'B2'].indexOf(data.unlocked);
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('sentTitle')),
    h('p', { class: 'muted small' }, t('sentLevelsSub')),
    levels.map((l, k) => {
      const locked = k > unlockedRank;
      return h('div', { class: `card sent-level ${locked ? 'locked' : ''}` },
        h('div', { class: 'row', style: { justifyContent: 'space-between' } }, h('h3', {}, l.cefr), locked ? icon('lock') : null),
        h('button', { class: 'link-row', type: 'button', disabled: locked || !l.long_ready ? true : null,
          onClick: () => app.go('sentences', { cefr: l.cefr, kind: 'long' }) },
          icon('sentences'), h('span', { class: 'spacer' }, h('b', {}, t('sentLong')), h('div', { class: 'tiny muted' },
            l.long_ready ? t('sentReadyN', l.long_ready) : t('sentLongNone'), ' · ', t('sentLearnedN', l.long_learned))),
          icon('chevron')),
        h('button', { class: 'link-row', type: 'button', disabled: locked ? true : null,
          onClick: () => app.go('sentences', { cefr: l.cefr, kind: 'bonus' }) },
          icon('star'), h('span', { class: 'spacer' }, h('b', {}, t('sentBonus')), h('div', { class: 'tiny muted' },
            t('sentBonusN', l.bonus_started, l.bonus_total), l.bonus_due ? ` · ${t('sentDueN', l.bonus_due)}` : '')),
          icon('chevron')));
    }),
    h('p', { class: 'tiny muted' }, t('sentBonusHint'))));
}

export async function renderSentences(app, params = {}) {
  if (!params.kind) return renderLevels(app);
  mount(spinner(t('loading')));
  const data = await rpc('start_sentences', { p_cefr: params.cefr || null, p_kind: params.kind });
  if (data.error) throw new Error(data.error);
  const items = data.items || [];
  const audioOn = !(app.me && app.me.settings && app.me.settings.audio_exercises === false);
  if (!items.length) {
    mount(h('div', { class: 'screen' }, h('h1', {}, t('sentTitle')),
      h('div', { class: 'card empty' }, icon('learn'), h('p', {}, params.kind === 'bonus' ? t('sentBonusEmpty') : t('sentEmpty')),
        h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
    return;
  }
  const pool = data.pool || [];
  let i = 0;
  let correct = 0;
  let lastType = null;

  const show = () => {
    if (i >= items.length) {
      haptic('success');
      mount(h('div', { class: 'screen' },
        h('div', { class: 'card result-hero' }, h('div', { class: 'result-icon ok' }, icon('trophy')),
          h('h1', {}, t('sentDone')), h('div', { class: 'big' }, `${correct}/${items.length}`),
          h('p', { class: 'muted' }, t('sentDoneText'))),
        h('button', { class: 'btn btn-big', onClick: () => app.replace('sentences', params) }, t('again')),
        h('button', { class: 'btn btn-secondary', onClick: () => app.home() }, t('toHome'))));
      return;
    }
    const s = items[i];
    // предложение как «слово»: упражнения на предложения берут его из examples
    const item = { ...s.word, accept_ru: [], accept_uz: [], level: 9, audio_ok: false,
      examples: [{ word_id: s.word_id, n: s.n, uz: s.uz, ru: s.ru, audio_ok: s.audio_ok, blank_start: s.blank_start,
                   blank_len: s.blank_len, nw: s.nw, ready: true }], distractors: [] };
    const order = TYPES.filter((x) => x !== lastType).sort(() => Math.random() - 0.5);
    let ex = null;
    for (const type of order) {
      if (type === 'audio_sentence' && (!s.audio_ok || !audioOn)) continue;
      ex = buildExercise(item, type, { sentencePool: pool, audio: audioOn });
      if (ex) break;
    }
    if (!ex) { i++; show(); return; }
    lastType = ex.type;
    const pct = Math.round((i / items.length) * 100);
    const body = renderExercise(ex, {
      audioEnabled: audioOn,
      onAnswer: (answer) => {
        const ok = checkAnswer(ex, answer);
        if (ok) correct++;
        rpc('answer_sentence', { p_word: s.word_id, p_n: s.n, p_correct: ok }).catch(() => {});
        return ok;
      },
      onNext: () => { i++; show(); },
    });
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${pct}%` } })),
        h('span', { class: 'counter' }, `${i + 1}/${items.length}`)),
      body));
  };
  show();
}
