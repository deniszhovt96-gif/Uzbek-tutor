import { rpc } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner } from '../ui.js';

export async function renderProgress() {
  mount(spinner(t('loading')));
  const s = await rpc('get_stats', { p_days: 14 });
  const tot = s.totals || {};
  const answers = (tot.correct || 0) + (tot.wrong || 0);
  const accuracy = answers ? Math.round((tot.correct / answers) * 100) : 0;

  const stat = (value, label) => h('div', { class: 'stat' }, h('b', {}, String(value)), h('span', {}, label));

  // активность за 14 дней: столбик = число ответов
  const days = s.days || [];
  const maxAnswers = Math.max(1, ...days.map((d) => d.correct + d.wrong));
  const bars = h('div', { class: 'bars' }, days.map((d) => {
    const n = d.correct + d.wrong;
    return h('div', { class: 'bar-col', title: `${d.day}: ${n}` },
      h('div', { class: 'bar-val' }, n ? String(n) : ''),
      h('div', { class: 'bar-fill', style: { height: `${Math.round((n / maxAnswers) * 100)}%` } }),
      h('div', { class: 'bar-day' }, String(d.day).slice(8, 10)));
  }));

  // слова по уровням 0–15
  const levels = s.levels || {};
  const maxLevel = Math.max(1, ...Object.values(levels));
  const levelRows = h('div', { class: 'levels' }, Array.from({ length: 16 }, (_, l) => {
    const n = levels[l] || 0;
    return h('div', { class: `level-row ${l >= 7 ? 'learned' : ''}` },
      h('span', { class: 'level-n' }, String(l)),
      h('div', { class: 'level-track' }, h('div', { class: 'level-fill', style: { width: `${Math.round((n / maxLevel) * 100)}%` } })),
      h('span', { class: 'level-count' }, String(n)));
  }));

  mount(h('div', { class: 'screen' },
    h('h1', {}, t('progressTitle')),
    h('div', { class: 'stats' },
      stat(tot.learning || 0, t('pLearning')),
      stat(tot.basic || 0, t('pBasic')),
      stat(tot.strong || 0, t('pStrong'))),
    h('div', { class: 'stats two' },
      stat(tot.due_today || 0, t('pDue')),
      stat(`${accuracy}%`, t('pAccuracy'))),
    h('h2', {}, t('pLast14')),
    h('div', { class: 'card' }, bars),
    h('h2', {}, t('pLevels')),
    h('div', { class: 'card' }, levelRows)));
}
