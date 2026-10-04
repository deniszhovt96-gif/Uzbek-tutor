// Экран сеанса: карточки новых слов и упражнения (уровни слов меняются по правилам сервера).
import { rpc, tg } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner } from '../ui.js';
import { icon } from '../icons.js';
import { Session } from '../session.js';
import { renderCard, renderExercise } from '../exercise-view.js';

export async function renderLearn(app, { mode = 'normal', topicId = null }) {
  mount(spinner(t('loading')));
  const data = await rpc('start_session', { p_mode: mode, p_topic_id: topicId });
  const message = (text, ...buttons) => mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' },
    icon('sparkle'), h('p', {}, text), ...buttons)));

  if (data.error === 'daily_limit') {
    message(t('dailyLimit'),
      h('button', { class: 'btn', onClick: () => app.tab('settings') }, t('toSubscription')),
      h('button', { class: 'btn btn-secondary', onClick: () => app.home() }, t('toHome')));
    return;
  }
  if (data.error === 'level_locked' || data.error === 'locked_tier') {
    message((t('topicErr') || {})[data.error], h('button', { class: 'btn', onClick: () => app.back() }, t('back')));
    return;
  }
  if (data.error) throw new Error(data.error);
  if (!data.items.length) {
    message(t('emptySession'), h('button', { class: 'btn', onClick: () => app.home() }, t('toHome')));
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

  const frame = (content) => {
    const pct = Math.round((session.done / Math.max(session.total, 1)) * 100);
    return h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${pct}%` } })),
        h('span', { class: 'counter' }, `${session.done}/${session.total}`)),
      session.saveFailed ? h('p', { class: 'warn small' }, t('saveError')) : null,
      content);
  };

  const step = () => {
    const task = session.next();
    if (!task) return finish();
    if (task.kind === 'card') {
      session.cardShown(task.item);
      return mount(frame(renderCard(task.item, { audioEnabled, onNext: step })));
    }
    return mount(frame(renderExercise(task.ex, {
      audioEnabled,
      onAnswer: (answerText) => session.answer(task, answerText).correct,
      onNext: step,
    })));
  };

  async function finish() {
    mount(spinner(t('loading')));
    const r = await session.finish();
    app.cleanup && app.cleanup();
    app.cleanup = null;
    const pct = r.answers ? Math.round((r.correct / r.answers) * 100) : 0;
    mount(h('div', { class: 'screen' },
      h('div', { class: 'card result-hero' },
        h('div', { class: 'result-icon ok' }, icon('trophy')),
        h('h1', {}, t('sessionDone')),
        h('div', { class: 'big' }, `${pct}%`),
        h('p', { class: 'muted' }, t('doneStats', r.correct, r.answers)),
        h('div', { class: 'stats two' },
          h('div', { class: 'stat' }, h('b', {}, String(r.newWords)), h('span', {}, t('planNew'))),
          h('div', { class: 'stat' }, h('b', {}, String(r.reviewed)), h('span', {}, t('planReview'))))),
      app.me.tier !== 'free'
        ? h('button', { class: 'btn btn-big', onClick: () => app.replace('learn', { mode: 'normal' }) }, t('anotherSession'))
        : null,
      h('button', { class: 'btn btn-secondary', onClick: () => app.home() }, t('toHome'))));
  }

  step();
}
