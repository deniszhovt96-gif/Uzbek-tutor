// Экспресс-проверка темы и контрольная по пройденному.
//   topic  — все ещё не выученные слова темы; ответ вводится с клавиатуры; верно → уровень 15 (повтор через 85 дней).
//   review — 20 начатых слов (выбор и ввод); на уровни не влияет, ошибки уходят в повторение сегодня.
// Каждый ответ проверяется сразу: пользователь видит верный вариант.
import { rpc, tg } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner, haptic, audioButton } from '../ui.js';
import { icon } from '../icons.js';
import { play, wordAudio } from '../audio.js';
import { displayUz } from '../normalize.js';

const PROMPT = { ru_uz_input: 'exRuUzInput', uz_ru_input: 'exUzRuInput', uz_ru_choice: 'exUzRu', ru_uz_choice: 'exRuUz' };

export async function renderWordCheck(app, { mode, topicId, topicName }) {
  const isTopic = mode === 'topic';
  const audioEnabled = !(app.me.settings && app.me.settings.audio_exercises === false);

  // ---------------------------------------------------------------- вступление
  mount(h('div', { class: 'screen' },
    h('div', { class: 'card result-hero' },
      h('div', { class: 'result-icon ok' }, icon(isTopic ? 'sparkle' : 'test')),
      h('h1', {}, t(isTopic ? 'checkTitle' : 'quizTitle')),
      topicName ? h('p', { class: 'muted' }, topicName) : null),
    h('div', { class: 'card' },
      h('ul', { class: 'small', style: { paddingLeft: '18px', margin: '0' } },
        (t(isTopic ? 'checkRules' : 'quizRules') || []).map((r) => h('li', { style: { margin: '6px 0' } }, r)))),
    h('button', { class: 'btn btn-big', onClick: () => begin() }, icon(isTopic ? 'sparkle' : 'test'), t('checkStart')),
    h('button', { class: 'btn btn-secondary', onClick: () => app.back() }, t('back'))));

  async function begin() {
    mount(spinner(t('loading')));
    const data = isTopic ? await rpc('start_topic_check', { p_topic: topicId }) : await rpc('start_review_quiz');
    if (data.error) {
      mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon(data.error === 'all_known' ? 'check' : 'lock'),
        h('p', {}, (t('checkErrors') || {})[data.error] || data.error),
        h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
      return;
    }
    const questions = data.questions;
    const done = new Set(data.done || []);
    let correct = data.correct || 0;
    let idx = questions.findIndex((q) => !done.has(q.i));
    if (idx < 0) idx = questions.length;
    const webApp = tg();
    if (webApp && webApp.enableClosingConfirmation) webApp.enableClosingConfirmation();
    app.cleanup = () => { if (webApp && webApp.disableClosingConfirmation) webApp.disableClosingConfirmation(); };

    const show = () => {
      if (idx >= questions.length) return finish();
      const q = questions[idx];
      if (window.__TEST__) window.__wq = q;
      let locked = false;
      const feedback = h('div', {});
      const controls = h('div', { class: 'ex-controls' });

      const answer = async (value, chosenBtn) => {
        if (locked) return;
        locked = true;
        controls.querySelectorAll('button, input').forEach((el) => (el.disabled = true));
        let r;
        try {
          r = await rpc('answer_word_check', { p_attempt: data.attempt_id, p_index: q.i, p_answer: value });
        } catch (e) {
          r = await rpc('answer_word_check', { p_attempt: data.attempt_id, p_index: q.i, p_answer: value });
        }
        if (r.correct) correct++;
        finishBtn.textContent = t('checkFinishEarly', correct);
        haptic(r.correct ? 'success' : 'error');
        if (chosenBtn) chosenBtn.classList.add(r.correct ? 'right' : 'wrong');
        if (q.options) {
          controls.querySelectorAll('.option').forEach((b) => { if (b.textContent === r.right) b.classList.add('right'); });
        }
        feedback.replaceChildren(h('div', { class: `feedback show ${r.correct ? 'good' : 'bad'}` },
          h('b', {}, r.correct ? (isTopic ? t('checkKnown') : t('correct')) : value ? t('wrong') : t('checkUnknown')),
          r.correct ? null : h('div', {}, t('rightAnswerIs'), ' ', h('b', {}, r.right))));
        idx++;
        const next = h('button', { class: 'btn btn-big', type: 'button', onClick: show }, t('next'));
        controls.replaceChildren(next);
        next.focus();
        if (r.correct) setTimeout(() => { if (next.isConnected && idx < questions.length + 1) show(); }, 900);
      };

      let prompt;
      const p = () => q.audio_id && play(wordAudio(q.audio_id));
      prompt = h('div', { class: q.prompt_kind === 'uz' ? 'word-uz' : 'word-ru' }, q.prompt,
        q.prompt_kind === 'uz' && q.audio_id && audioEnabled ? audioButton(p) : null);

      if (q.options) {
        const buttons = q.options.map((opt) => h('button', { class: 'option', type: 'button', onClick: (e) => answer(opt, e.currentTarget) }, opt));
        controls.append(h('div', { class: 'options' }, buttons));
      } else {
        const isUz = q.input === 'uz';
        const input = h('input', { class: 'answer-input', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
          placeholder: isUz ? t('placeholderUz') : t('placeholderRu'), onKeydown: (e) => { if (e.key === 'Enter') go(); } });
        const go = () => { const v = input.value.trim(); if (v) answer(isUz ? displayUz(v) : v); };
        controls.append(input);
        if (isUz) {
          controls.append(h('div', { class: 'helper-row' }, ['oʻ', 'gʻ', 'ʼ'].map((s) =>
            h('button', { class: 'chip-btn', type: 'button', onClick: () => { input.value += s; input.focus(); } }, s))));
        }
        controls.append(h('button', { class: 'btn', onClick: go }, t('check')));
        setTimeout(() => input.focus(), 50);
      }
      controls.append(h('button', { class: 'btn btn-ghost', type: 'button', onClick: () => answer('') }, t('dontKnow')));

      const finishBtn = h('button', { class: 'btn btn-ghost small', type: 'button', onClick: finish }, t('checkFinishEarly', correct));
      const pct = Math.round((idx / questions.length) * 100);
      mount(h('div', { class: 'screen session' },
        h('div', { class: 'session-top' },
          h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${pct}%` } })),
          h('span', { class: 'counter' }, `${idx + 1}/${questions.length}`)),
        h('div', { class: 'label' }, t(PROMPT[q.type] || 'exUzRu')),
        h('div', { class: 'card ex-card' }, h('div', { class: 'prompt' }, prompt), feedback, controls),
        finishBtn));
    };

    async function finish() {
      mount(spinner(t('loading')));
      const r = await rpc('finish_word_check', { p_attempt: data.attempt_id });
      app.cleanup && app.cleanup();
      app.cleanup = null;
      haptic('success');
      const mistakes = (r.mistakes || []).map((m) => h('div', { class: 'mistake' },
        h('div', {}, m.prompt),
        h('div', { class: 'small' }, h('span', { class: 'err' }, m.your ? m.your : t('noAnswer')), ' → ', h('b', { class: 'ok' }, m.correct))));
      mount(h('div', { class: 'screen' },
        h('div', { class: 'card result-hero' },
          h('div', { class: 'result-icon ok' }, icon('trophy')),
          h('h1', {}, t('checkDone')),
          h('div', { class: 'big' }, `${r.correct}/${r.answered}`),
          h('p', {}, isTopic ? t('checkResultTopic', r.correct) : t('checkResultQuiz', r.answered - r.correct))),
        h('button', { class: 'btn btn-big', onClick: () => app.home() }, t('toHome')),
        isTopic ? h('button', { class: 'btn btn-secondary', onClick: () => app.tab('path') }, icon('map'), t('toPath')) : null,
        mistakes.length ? h('h2', {}, `${t('testMistakes')} (${mistakes.length})`) : null,
        mistakes.length ? h('div', { class: 'card' }, mistakes) : null));
    }

    show();
  }
}
