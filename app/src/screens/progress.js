import { rpc } from '../api.js';
import { t, tierName, formatDate } from '../i18n.js';
import { h, mount, spinner } from '../ui.js';
import { icon } from '../icons.js';
import { wordSheet } from './dictionary.js';

export async function renderProgress(app) {
  mount(spinner(t('loading')));
  const [s, ext] = await Promise.all([rpc('get_stats', { p_days: 14 }), rpc('get_stats_ext').catch(() => ({ error: 'x' }))]);
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
    h('div', { class: 'card' }, levelRows),
    extSection(app, ext)));
}

// ---------------------------------------------------------------- расширенная статистика («Продвинутая»)
function extSection(app, x) {
  if (!x || x.error) {
    if (x && x.error === 'locked_tier') {
      return h('div', { class: 'card ext-locked' },
        h('div', { class: 'row' }, h('span', { class: 'tile-icon gold' }, icon('lock')),
          h('div', {}, h('b', {}, t('extTitle')), h('div', { class: 'small muted' }, t('extLocked', tierName(x.need || 'advanced'))))),
        h('ul', { class: 'small feature-list' }, (t('extList') || []).map((f) => h('li', {}, icon('check'), h('span', {}, f)))),
        h('button', { class: 'btn', onClick: () => app.go('subscription', { tier: 'advanced' }) }, t('toSubscription')));
    }
    return null;
  }
  const stat = (value, label) => h('div', { class: 'stat' }, h('b', {}, String(value)), h('span', {}, label));
  const tot = x.totals || {};

  // прогноз повторений на неделю
  const fc = x.forecast || [];
  const maxF = Math.max(1, ...fc.map((d) => d.due));
  const forecast = h('div', { class: 'bars' }, fc.map((d, i) => h('div', { class: `bar-col ${i === 0 ? 'today' : ''} ${d.due ? '' : 'zero'}` },
    h('div', { class: 'bar-val' }, d.due ? String(d.due) : ''),
    h('div', { class: 'bar-fill', style: { height: `${Math.max(3, Math.round((d.due / maxF) * 100))}%` } }),
    h('div', { class: 'bar-day' }, i === 0 ? t('today') : (t('weekdays') || [])[new Date(d.day).getDay()] || String(d.day).slice(8)))));

  // недели
  const wk = x.weeks || [];
  const maxW = Math.max(1, ...wk.map((w) => w.answers));
  const weeks = h('div', { class: 'bars' }, wk.map((w) => h('div', { class: 'bar-col', title: `${formatDate(w.week)}: ${w.answers}` },
    h('div', { class: 'bar-val' }, w.answers ? String(w.answers) : ''),
    h('div', { class: 'bar-fill', style: { height: `${Math.max(3, Math.round((w.answers / maxW) * 100))}%` } }),
    h('div', { class: 'bar-day' }, String(w.week).slice(8, 10) + '.' + String(w.week).slice(5, 7)))));

  // точность по видам заданий
  const names = t('exNames') || {};
  const types = (x.by_type || []).filter((r) => r.total >= 3).map((r) => {
    const pct = Math.round((r.correct / r.total) * 100);
    return h('div', { class: 'acc-row' },
      h('div', { class: 'acc-top' }, h('span', {}, names[r.type] || r.type), h('b', { class: pct >= 80 ? 'ok' : pct < 60 ? 'err' : '' }, `${pct}%`)),
      h('div', { class: 'track' }, h('div', { class: 'fill strong', style: { width: `${pct}%` } })),
      h('div', { class: 'tiny muted' }, t('extAnswers', r.total)));
  });

  // трудные слова
  const hard = (x.hard || []).map((w) => h('button', { class: 'dict-row', type: 'button', onClick: () => wordSheet(app, w.id) },
    h('div', { class: 'dict-main' }, h('b', {}, w.uz), h('div', { class: 'small muted' }, w.ru)),
    h('span', { class: 'chip err-chip' }, `✗ ${w.wrong}`), h('span', { class: 'chip ok-chip' }, `✓ ${w.correct}`)));

  // время занятий: 4 части суток
  const hours = x.hours || {};
  const part = (from, to) => Object.entries(hours).filter(([hh]) => Number(hh) >= from && Number(hh) < to).reduce((a, [, n]) => a + n, 0);
  const parts = [[t('dayMorning'), part(5, 12)], [t('dayAfternoon'), part(12, 17)], [t('dayEvening'), part(17, 23)], [t('dayNight'), part(23, 24) + part(0, 5)]];
  const sumH = Math.max(1, parts.reduce((a, [, n]) => a + n, 0));
  const daytime = h('div', { class: 'daytime' }, parts.map(([label, n]) => h('div', {},
    h('b', {}, `${Math.round((n / sumH) * 100)}%`), h('span', { class: 'small muted' }, label))));

  return [
    h('h2', {}, t('extTitle')),
    h('div', { class: 'stats' }, stat(tot.days_active || 0, t('extDays')), stat(tot.minutes || 0, t('extMinutes')), stat(tot.best_streak || 0, t('extBestStreak'))),
    h('h2', {}, t('extForecast')), h('div', { class: 'card' }, forecast),
    wk.length > 1 ? [h('h2', {}, t('extWeeks')), h('div', { class: 'card' }, weeks)] : null,
    types.length ? [h('h2', {}, t('extByType')), h('div', { class: 'card' }, types)] : null,
    hard.length ? [h('h2', {}, t('extHard')), h('p', { class: 'small muted' }, t('extHardHint')), h('div', { class: 'card dict-card' }, hard)] : null,
    Object.keys(hours).length ? [h('h2', {}, t('extWhen')), h('div', { class: 'card' }, daytime)] : null,
  ];
}
