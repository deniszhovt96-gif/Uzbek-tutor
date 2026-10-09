// «Мои ошибки»: слова, в которых чаще всего ошибались, — задания всех видов, ошибка повторяется ещё раз.
// На уровни слов не влияет (как и остальные игры).
import { rpc } from '../../api.js';
import { t } from '../../i18n.js';
import { h, mount, spinner } from '../../ui.js';
import { icon } from '../../icons.js';
import { pickExercise, checkAnswer, ALL_TYPES, shuffle } from '../../exercises.js';
import { renderExercise } from '../../exercise-view.js';
import { gameResult, setBest } from '../games.js';

export async function playMistakes({ app, again, audioEnabled }) {
  mount(spinner(t('loading')));
  const data = await rpc('start_mistakes');
  const items = (data && data.items) || [];
  if (items.length < 4) {
    mount(h('div', { class: 'screen' }, h('h1', {}, t('gameMistakes')),
      h('div', { class: 'card empty' }, icon('mistakes'), h('p', {}, t('mistakesEmpty')),
        h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
    return;
  }
  const sentencePool = items.flatMap((it) => (it.examples || []).map((e) => e.ru));
  const queue = shuffle(items).map((item) => ({ item, retry: false }));
  const total = queue.length;
  let done = 0;
  let correct = 0;
  let lastType = null;
  const step = () => {
    const task = queue.shift();
    if (!task) {
      const pct = Math.round((correct / total) * 100);
      return gameResult({ app, again, title: t('gameMistakes'), big: `${correct}/${total}`, text: t('mistakesDone'),
        record: setBest('mistakes', pct, (a, b) => a > b) });
    }
    const ex = pickExercise(task.item, 5, lastType, { audio: audioEnabled, sentencePool, types: ALL_TYPES });
    lastType = ex.type;
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((done / total) * 100)}%` } })),
        h('span', { class: 'counter' }, `${done}/${total}`)),
      renderExercise(ex, {
        audioEnabled,
        onAnswer: (answer) => {
          const ok = checkAnswer(ex, answer);
          if (!task.retry) { done++; if (ok) correct++; }
          if (!ok) queue.splice(Math.min(2, queue.length), 0, { item: task.item, retry: true });
          return ok;
        },
        onNext: step,
      })));
  };
  step();
}
