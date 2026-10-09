// Рекомендуемый порядок занятий: слова → тема курса (по очереди грамматика, культура, обществознание,
// история) → диалог → закрепление. Компактная карточка на главной и кнопка «Дальше» после сессии слов.
import { rpc } from './api.js';
import { t } from './i18n.js';
import { h, haptic, sheet } from './ui.js';
import { icon } from './icons.js';
import { pick } from './screens/course.js';

const STEPS = ['words', 'course', 'dialog', 'consolidate'];
const STEP_ICON = { words: 'learn', course: 'grammar', dialog: 'dialog', consolidate: 'review' };

export function goStep(app, next) {
  haptic();
  if (!next) return;
  if (next.kind === 'words') return app.go('learn', { mode: 'normal' });
  if (next.kind === 'course' || next.kind === 'dialog') return app.go('unit', { id: next.unit_id });
  if (next.kind === 'consolidate') {
    if (next.what === 'sentences') return app.go('sentences');
    if (next.what === 'quiz') return app.go('wordcheck', { mode: 'review' });
    return app.go('conj', { train: 'table', verbs: null, mine: true });
  }
  return null;
}

export function stepLabel(next) {
  if (!next) return '';
  if (next.kind === 'words') return t('recWords');
  if (next.kind === 'course') return `${t(`recCourse_${next.course}`)}: ${pick(next, 'title')} (${next.cefr})`;
  if (next.kind === 'dialog') return `${t('recDialog')}: ${pick(next, 'title')} (${next.cefr})`;
  if (next.kind === 'consolidate') return t(`recCons_${next.what}`);
  return t('recDone');
}

// Карточка на главной: 4 точки-шага и одна кнопка
export function recommendCard(app, data) {
  if (!data || data.error) return null;
  const steps = data.steps || {};
  const next = data.next || {};
  const dots = h('div', { class: 'rec-steps' }, STEPS.map((s) => h('span', {
    class: `rec-step ${steps[s] ? 'done' : ''} ${next.kind === s ? 'cur' : ''}`, title: t(`recStep_${s}`) },
    steps[s] ? icon('check') : icon(STEP_ICON[s]), h('span', { class: 'rec-step-l' }, t(`recStep_${s}`)))));
  return h('div', { class: 'card rec-card' },
    h('div', { class: 'row', style: { justifyContent: 'space-between' } }, h('div', { class: 'label' }, t('recTitle')),
      h('button', { class: 'link-btn tiny', type: 'button', onClick: () => sheet(h('h3', {}, t('recTitle')), ...t('recAbout').map((p) => h('p', { class: 'small' }, p))) }, t('recHow'))),
    dots,
    next.kind === 'done'
      ? h('p', { class: 'small muted' }, t('recDone'))
      : h('button', { class: 'btn', type: 'button', onClick: () => goStep(app, next) }, icon(STEP_ICON[next.kind] || 'learn'), stepLabel(next)));
}

// Кнопка «Дальше по плану» на экранах результата
export async function nextButton(app) {
  const data = await rpc('get_next_step').catch(() => null);
  if (!data || !data.next || data.next.kind === 'done' || data.next.kind === 'words') return null;
  return h('button', { class: 'btn btn-big', type: 'button', onClick: () => goStep(app, data.next) },
    t('recNext'), ' ', h('span', { class: 'small' }, `· ${stepLabel(data.next)}`));
}
