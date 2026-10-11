// «Марафон»: все слова уровня по порядку изучения, без пропусков. Место остановки сохраняется на сервере.
// На уровни слов не влияет (как и остальные игры).
import { rpc } from '../../api.js';
import { t } from '../../i18n.js';
import { h, mount, spinner, haptic } from '../../ui.js';
import { icon } from '../../icons.js';
import { pickExercise, checkAnswer } from '../../exercises.js';
import { renderExercise } from '../../exercise-view.js';
import { gameResult } from '../games.js';

const TYPES = ['uz_ru_choice', 'ru_uz_choice', 'audio_choice'];

export async function playMarathon({ app, again, audioEnabled }) {
  mount(spinner(t('loading')));
  const data = await rpc('get_marathon');
  const levels = (data && data.levels) || [];
  const pct = (l) => (l.correct + l.wrong ? Math.round((100 * l.correct) / (l.correct + l.wrong)) : null);
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('gameMarathon')),
    h('p', { class: 'muted small' }, t('marathonHint')),
    levels.map((l) => {
      const started = l.pos > 0 && !l.finished;
      const p = pct(l);
      return h('div', { class: `card marathon-level ${l.locked ? 'dim' : ''}` },
        h('div', { class: 'row-between' },
          h('div', {}, h('b', {}, l.cefr), ' ', h('span', { class: 'small muted' }, t('marathonWords', l.total))),
          l.locked ? icon('lock') : l.best_pct != null ? h('span', { class: 'chip gold' }, icon('trophy'), `${l.best_pct}%`) : null),
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((100 * l.pos) / Math.max(l.total, 1))}%` } })),
        h('div', { class: 'tiny muted' }, t('marathonPos', l.pos, l.total), p != null ? ` · ${t('marathonRight', p)}` : ''),
        l.locked ? h('div', { class: 'tiny muted' }, t('marathonLocked')) : h('div', { class: 'row-gap' },
          h('button', { class: 'btn', type: 'button', onClick: () => run(l.cefr, !started) }, started ? t('marathonContinue') : t('marathonStart')),
          started ? h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => run(l.cefr, true) }, t('marathonRestart')) : null));
    })));

  async function run(cefr, restart) {
    haptic();
    mount(spinner(t('loading')));
    const st = await rpc('start_marathon', { p_cefr: cefr, p_restart: restart });
    if (st.error) { app.back(); return; }
    let { pos, correct, wrong } = st;
    const total = st.total;
    let queue = [];
    let lastType = null;
    let pending = Promise.resolve();
    const load = async () => {
      const b = await rpc('marathon_batch', { p_cefr: cefr, p_n: 20 });
      queue = (b && b.items) || [];
    };
    const finish = () => {
      const p = Math.round((100 * correct) / Math.max(correct + wrong, 1));
      gameResult({ app, again, title: t('gameMarathon'), big: `${correct}/${correct + wrong}`,
        sub: `${cefr} · ${p}%`, text: pos >= total ? t('marathonDone') : t('marathonPaused') });
    };
    const step = async () => {
      if (pos >= total) return finish();
      if (!queue.length) { mount(spinner(t('loading'))); await pending; await load(); }
      const item = queue.shift();
      if (!item) return finish();
      const ex = pickExercise(item, 1, lastType, { audio: audioEnabled, types: TYPES });
      lastType = ex.type;
      mount(h('div', { class: 'screen session' },
        h('div', { class: 'session-top' },
          h('button', { class: 'icon-btn', type: 'button', title: t('marathonPause'), onClick: finish }, icon('close')),
          h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((100 * pos) / Math.max(total, 1))}%` } })),
          h('span', { class: 'counter' }, `${pos}/${total}`)),
        renderExercise(ex, {
          audioEnabled,
          onAnswer: (answer) => {
            const ok = checkAnswer(ex, answer);
            if (ok) correct++; else wrong++;
            pos = item.mpos + 1;
            pending = pending.then(() => rpc('marathon_answer', { p_cefr: cefr, p_pos: item.mpos, p_correct: ok })).catch(() => {});
            return ok;
          },
          onNext: step,
        })));
    };
    step();
  }
}
