// «Тренировка»: задания всех видов по уже начатым словам. Проверка на телефоне, на уровни слов не влияет.
import { rpc } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner } from '../ui.js';
import { icon } from '../icons.js';
import { pickExercise, checkAnswer, ALL_TYPES, shuffle } from '../exercises.js';
import { renderExercise } from '../exercise-view.js';
import { lockedSheet } from './home.js';

const MIN_WORDS = 8;
const SIZE = 20;

export async function renderPractice(app) {
  mount(spinner(t('loading')));
  const data = await rpc('start_practice', { p_feature: 'practice', p_count: SIZE });
  if (data.error === 'locked_tier') { app.back(); lockedSheet(app, data.need); return; }
  if (data.error) throw new Error(data.error);
  const items = data.items || [];
  if (items.length < MIN_WORDS) {
    mount(h('div', { class: 'screen' }, h('h1', {}, t('practiceTitle')),
      h('div', { class: 'card empty' }, icon('practice'), h('p', {}, t('practiceNotEnough', MIN_WORDS)),
        h('button', { class: 'btn', onClick: () => app.replace('learn', { mode: 'normal' }) }, t('secLearn')))));
    return;
  }

  const audioEnabled = !(app.me.settings && app.me.settings.audio_exercises === false);
  const sentencePool = items.flatMap((it) => (it.examples || []).map((e) => e.ru));
  const queue = shuffle(items).map((item) => ({ item, retry: false }));
  const total = queue.length;
  let done = 0;
  let correctN = 0;
  let lastType = null;

  const step = () => {
    const task = queue.shift();
    if (!task) return finish();
    const ex = pickExercise(task.item, 4, lastType, { audio: audioEnabled, sentencePool, types: (window.__TEST__ && window.__TYPES) || ALL_TYPES });
    lastType = ex.type;
    const pct = Math.round((done / total) * 100);
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${pct}%` } })),
        h('span', { class: 'counter' }, `${done}/${total}`)),
      renderExercise(ex, {
        audioEnabled,
        onAnswer: (answer) => {
          const ok = checkAnswer(ex, answer);
          if (!task.retry) { done++; if (ok) correctN++; }
          if (!ok && !task.retry) queue.splice(Math.min(3, queue.length), 0, { item: task.item, retry: true });
          return ok;
        },
        onNext: step,
      })));
  };

  const finish = () => {
    mount(h('div', { class: 'screen' },
      h('div', { class: 'card result-hero' },
        h('div', { class: 'result-icon' }, icon('practice')),
        h('h1', {}, t('practiceDone')),
        h('div', { class: 'big' }, `${correctN}/${total}`),
        h('p', { class: 'muted small' }, t('practiceHint'))),
      h('button', { class: 'btn btn-big', onClick: () => app.replace('practice') }, t('again')),
      h('button', { class: 'btn btn-secondary', onClick: () => app.home() }, t('toHome'))));
  };

  step();
}
