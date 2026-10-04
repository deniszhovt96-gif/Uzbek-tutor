// Тест уровня (A1 → A2 → B1 → B2): 35 вопросов без подсказок, итог и разбор ошибок в конце.
import { rpc, tg } from '../api.js';
import { t, formatDate } from '../i18n.js';
import { h, mount, spinner, haptic, audioButton } from '../ui.js';
import { icon, art } from '../icons.js';
import { play, wordAudio, exampleAudio } from '../audio.js';
import { displayUz } from '../normalize.js';

const PROMPT = {
  uz_ru_choice: 'exUzRu', ru_uz_choice: 'exRuUz', audio_choice: 'exAudio', ru_uz_input: 'exRuUzInput',
  uz_ru_input: 'exUzRuInput', fill_choice: 'exFillChoice', sentence_choice: 'exSentenceChoice',
};

export async function renderTest(app, { cefr }) {
  mount(spinner(t('loading')));
  const home = await rpc('get_home');
  app.homeData = home;
  const lv = (home.levels || []).find((l) => l.cefr === cefr) || {};
  const audioEnabled = !(app.me.settings && app.me.settings.audio_exercises === false);

  // ---------------------------------------------------------------- вступление
  const cooldown = lv.retry_at && new Date(lv.retry_at) > new Date();
  const passed = lv.state === 'passed';
  const locked = lv.state === 'locked';
  mount(h('div', { class: 'screen' },
    h('div', { class: 'card result-hero' },
      art('gate'),
      h('h1', {}, t('testTitle', cefr)),
      h('p', { class: 'muted' }, `${t(`city${cefr}`)} · ${t(`levelName${cefr}`)}`)),
    h('div', { class: 'card' },
      h('p', {}, t('testIntro', home.test_questions || 35, home.test_pass_pct || 80)),
      h('ul', { class: 'small', style: { paddingLeft: '18px', margin: '8px 0' } }, (t('testRules') || []).map((r) => h('li', { style: { margin: '6px 0' } }, r))),
      h('p', { class: 'small muted' }, t('testReadiness', lv.ready || 0, lv.total || 0)),
      !lv.recommended && !passed && !locked ? h('p', { class: 'small warn' }, t('testNotReady')) : null),
    passed ? h('p', { class: 'ok' }, `${t('gatePassed')}: ${lv.best_score}/${lv.best_total}`)
      : locked ? h('p', { class: 'muted' }, t('testErrors').level_locked)
      : cooldown ? h('p', { class: 'warn' }, t('testRetryAt', formatDate(lv.retry_at)))
      : h('button', { class: 'btn btn-big', onClick: () => begin() }, icon('test'), lv.in_progress ? t('continueTest') : t('startTest')),
    h('button', { class: 'btn btn-secondary', onClick: () => app.back() }, t('back'))));

  // ---------------------------------------------------------------- прохождение
  async function begin() {
    mount(spinner(t('loading')));
    const data = await rpc('start_level_test', { p_cefr: cefr });
    if (data.error) {
      const msg = (t('testErrors') || {})[data.error] || data.error;
      mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('lock'),
        h('p', {}, msg, data.retry_at ? ` ${t('testRetryAt', formatDate(data.retry_at))}` : ''),
        h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
      return;
    }
    const questions = data.questions;
    const answers = { ...(data.answers || {}) };
    let idx = questions.findIndex((q) => !(String(q.i) in answers));
    if (idx < 0) idx = questions.length;
    let chain = Promise.resolve();
    const webApp = tg();
    if (webApp && webApp.enableClosingConfirmation) webApp.enableClosingConfirmation();
    app.cleanup = () => { if (webApp && webApp.disableClosingConfirmation) webApp.disableClosingConfirmation(); };

    const send = (q, answer) => {
      answers[q.i] = answer;
      chain = chain.then(() => rpc('answer_level_test', { p_attempt: data.attempt_id, p_index: q.i, p_answer: answer })
        .catch(() => rpc('answer_level_test', { p_attempt: data.attempt_id, p_index: q.i, p_answer: answer }))
        .catch((e) => console.warn('[test] answer not saved', e)));
    };

    const show = () => {
      if (idx >= questions.length) return finish();
      const q = questions[idx];
      if (window.__TEST__) window.__tq = q;
      let done = false;
      const answer = (value) => {
        if (done) return;
        done = true;
        send(q, value);
        idx++;
        setTimeout(show, 220);
      };
      const pct = Math.round((idx / questions.length) * 100);
      const body = [];
      let prompt;
      if (q.prompt_kind === 'audio') {
        const p = () => play(wordAudio(q.audio_id));
        if (audioEnabled) setTimeout(p, 200);
        prompt = h('button', { class: 'btn btn-audio-big', type: 'button', onClick: p }, icon('sound'));
      } else if (q.type === 'fill_choice') {
        const after = q.sentence.after || '';
        prompt = h('div', {},
          h('div', { class: 'sentence' }, q.sentence.before,
            h('span', { class: 'nowrap' }, h('span', { class: 'blank' }, ' '.repeat(6)), after.match(/^\S*/)[0]),
            after.replace(/^\S*/, '')),
          h('div', { class: 'muted small' }, q.sentence.ru));
      } else if (q.type === 'sentence_choice') {
        const p = () => q.audio_example && play(exampleAudio(q.audio_example.word_id, q.audio_example.n));
        prompt = h('div', { class: 'sentence-uz' }, q.prompt, q.audio_example && audioEnabled ? h('span', {}, ' ', audioButton(p)) : null);
      } else {
        const p = () => q.audio_id && play(wordAudio(q.audio_id));
        prompt = h('div', { class: q.prompt_kind === 'uz' ? 'word-uz' : 'word-ru' }, q.prompt,
          q.prompt_kind === 'uz' && q.audio_id && audioEnabled ? audioButton(p) : null);
      }
      if (q.options) {
        const buttons = q.options.map((opt) => h('button', { class: 'option', type: 'button', onClick: (e) => {
          if (done) return;
          haptic();
          e.currentTarget.classList.add('chosen');
          buttons.forEach((b) => (b.disabled = true));
          answer(opt);
        } }, opt));
        body.push(h('div', { class: 'options' }, buttons));
      } else {
        const isUz = q.input === 'uz';
        const input = h('input', { class: 'answer-input', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
          placeholder: isUz ? t('placeholderUz') : t('placeholderRu'), onKeydown: (e) => { if (e.key === 'Enter') go(); } });
        const go = () => { const v = input.value.trim(); if (v) answer(isUz ? displayUz(v) : v); };
        body.push(input);
        if (isUz) {
          body.push(h('div', { class: 'helper-row' }, ['oʻ', 'gʻ', 'ʼ'].map((s) =>
            h('button', { class: 'chip-btn', type: 'button', onClick: () => { input.value += s; input.focus(); } }, s))));
        }
        body.push(h('button', { class: 'btn', onClick: go }, t('next')));
        setTimeout(() => input.focus(), 50);
      }
      mount(h('div', { class: 'screen session' },
        h('div', { class: 'session-top' },
          h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${pct}%` } })),
          h('span', { class: 'counter' }, `${idx + 1}/${questions.length}`)),
        h('div', { class: 'label' }, t(PROMPT[q.type] || 'exUzRu')),
        h('div', { class: 'card ex-card' }, h('div', { class: 'prompt' }, prompt), ...body),
        h('button', { class: 'btn btn-ghost', type: 'button', onClick: () => answer('') }, t('skip'))));
    };

    async function finish() {
      mount(spinner(t('loading')));
      await chain;
      const r = await rpc('finish_level_test', { p_attempt: data.attempt_id });
      app.cleanup && app.cleanup();
      app.cleanup = null;
      haptic(r.passed ? 'success' : 'warning');
      const mistakes = (r.mistakes || []).map((m) => h('div', { class: 'mistake' },
        h('div', {}, m.prompt || t('exAudio')),
        m.hint ? h('div', { class: 'small muted' }, m.hint) : null,
        h('div', { class: 'small' }, h('span', { class: 'err' }, m.your ? m.your : t('noAnswer')), ' → ', h('b', { class: 'ok' }, m.correct))));
      mount(h('div', { class: 'screen' },
        h('div', { class: 'card result-hero' },
          h('div', { class: `result-icon ${r.passed ? 'ok' : 'bad'}` }, icon(r.passed ? 'trophy' : 'review')),
          h('h1', {}, r.passed ? t('testPassed') : t('testFailed')),
          h('div', { class: 'big' }, `${r.score}/${r.total}`),
          h('p', { class: 'muted' }, t('testNeed', r.need)),
          h('p', {}, r.passed ? (r.course_done ? t('testCourseDone') : t('testUnlocked', r.next_cefr)) : t('testRetryAt', formatDate(r.retry_at)))),
        h('button', { class: 'btn btn-big', onClick: () => app.tab('path') }, icon('map'), t('toPath')),
        h('button', { class: 'btn btn-secondary', onClick: () => app.home() }, t('toHome')),
        mistakes.length ? h('h2', {}, `${t('testMistakes')} (${mistakes.length})`) : null,
        mistakes.length ? h('div', { class: 'card' }, mistakes) : null));
    }

    show();
  }
}
