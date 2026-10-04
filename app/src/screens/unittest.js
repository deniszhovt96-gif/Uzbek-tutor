// Тест по теме курса: 5 вопросов с выбором ответа, итог и разбор с цитатами из текста темы.
import { rpc } from '../api.js';
import { t, getLang } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { pick } from './course.js';

export async function renderUnitTest(app, { id, title }) {
  mount(spinner(t('loading')));
  const data = await rpc('start_unit_test', { p_unit: id });
  if (data.error) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('test'),
      h('p', {}, (t('unitTestErrors') || {})[data.error] || data.error),
      h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
    return;
  }
  const L = getLang();
  const answers = [];
  let i = 0;

  const show = () => {
    if (i >= data.questions.length) return finish();
    const q = data.questions[i];
    const opts = q[`options_${L}`] || q.options_ru;
    let done = false;
    const buttons = opts.map((o, k) => h('button', { class: 'option', type: 'button', onClick: () => {
      if (done) return;
      done = true;
      haptic();
      buttons[k].classList.add('chosen');
      answers[i] = k;
      i++;
      setTimeout(show, 220);
    } }, o));
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((i / data.total) * 100)}%` } })),
        h('span', { class: 'counter' }, `${i + 1}/${data.total}`)),
      h('div', { class: 'label' }, title || t('unitTest')),
      h('div', { class: 'card ex-card' }, h('div', { class: 'prompt' }, h('div', { class: 'sentence-uz' }, pick(q, 'prompt', L))),
        h('div', { class: 'options' }, buttons)),
      h('button', { class: 'btn btn-ghost', type: 'button', onClick: () => { if (done) return; done = true; answers[i] = -1; i++; show(); } }, t('skip'))));
  };

  async function finish() {
    mount(spinner(t('loading')));
    const r = await rpc('finish_unit_test', { p_attempt: data.attempt_id, p_answers: answers });
    if (r.error) throw new Error(r.error);
    haptic(r.passed ? 'success' : 'warning');
    const review = data.questions.map((q, k) => {
      const res = r.results[k];
      const opts = q[`options_${L}`] || q.options_ru;
      return h('div', { class: 'mistake' },
        h('div', { class: 'row' }, h('span', { class: res.correct ? 'ok' : 'err' }, icon(res.correct ? 'check' : 'close')), h('b', {}, pick(q, 'prompt', L))),
        res.correct ? null : h('div', { class: 'small' },
          h('span', { class: 'err' }, res.picked >= 0 ? opts[res.picked] : t('noAnswer')), ' → ', h('b', { class: 'ok' }, opts[res.right_index])),
        res.correct || !res.quote_ru ? null : h('div', { class: 'quote small muted' }, `«${res.quote_ru}»`));
    });
    mount(h('div', { class: 'screen' },
      h('div', { class: 'card result-hero' },
        h('div', { class: `result-icon ${r.passed ? 'ok' : 'bad'}` }, icon(r.passed ? 'trophy' : 'review')),
        h('h1', {}, r.passed ? t('unitTestPassed') : t('unitTestFailed')),
        h('div', { class: 'big' }, `${r.score}/${r.total}`),
        h('p', { class: 'muted' }, t('testNeed', r.need))),
      h('button', { class: 'btn btn-big', onClick: () => app.back() }, t('backToTopic')),
      h('button', { class: 'btn btn-secondary', onClick: () => app.replace('unittest', { id, title }) }, t('again')),
      h('h2', {}, t('unitTestReview')),
      h('div', { class: 'card' }, review)));
  }

  show();
}
