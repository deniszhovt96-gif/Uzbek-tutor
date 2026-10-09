// Аналитика для администратора: пользователи, удержание, оплаты, активность, график за 14 дней.
import { rpc } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner } from '../ui.js';
import { icon } from '../icons.js';

export async function renderAnalytics(app) {
  mount(spinner(t('loading')));
  const [a, rf] = await Promise.all([rpc('admin_analytics'), rpc('admin_referrals').catch(() => null)]);
  if (a.error) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('lock'), h('p', {}, t('adminOnly')))));
    return;
  }
  const stat = (value, label) => h('div', { class: 'stat' }, h('b', {}, value == null ? '—' : String(value)), h('span', {}, label));
  const u = a.users || {};
  const r = a.retention || {};
  const m = a.money || {};
  const act = a.activity || {};
  const days = a.days || [];
  const max = Math.max(1, ...days.map((d) => d.users));
  const bars = h('div', { class: 'bars' }, days.map((d, i) => h('div', { class: `bar-col ${d.users ? '' : 'zero'} ${i === days.length - 1 ? 'today' : ''}` },
    h('div', { class: 'bar-val' }, d.users ? String(d.users) : ''),
    h('div', { class: 'bar-fill', style: { height: `${Math.max(3, Math.round((d.users / max) * 100))}%` } }),
    h('div', { class: 'bar-day' }, String(d.day).slice(8, 10)))));
  const tests = act.tests_passed || {};
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('anTitle')),
    h('h2', {}, t('anUsers')),
    h('div', { class: 'stats' }, stat(u.total, t('anTotal')), stat(u.new7, t('anNew7')), stat(u.new30, t('anNew30'))),
    h('div', { class: 'stats' }, stat(u.dau, 'DAU'), stat(u.wau, 'WAU'), stat(u.mau, 'MAU')),
    h('div', { class: 'card' }, h('div', { class: 'label' }, t('anActiveDays')), bars),
    h('h2', {}, t('anRetention')),
    h('div', { class: 'stats' }, stat(r.cohort, t('anCohort')), stat(r.d1 == null ? null : `${r.d1}%`, t('anD1')), stat(r.d7 == null ? null : `${r.d7}%`, t('anD7'))),
    h('p', { class: 'tiny muted' }, t('anRetentionHint')),
    h('h2', {}, t('anMoney')),
    h('div', { class: 'stats' }, stat(m.active_basic, t('tierBasic')), stat(m.active_advanced, t('tierAdvanced')), stat(m.payers_total, t('anPayers'))),
    h('div', { class: 'stats' }, stat(m.payments30, t('anPayments30')), stat(m.stars30, t('anStars30')), stat(u.blocked, t('anBlocked'))),
    rf && !rf.error ? [h('h2', {}, t('anReferrals')),
      h('div', { class: 'stats' }, stat(rf.invited, t('anRefInvited')), stat(rf.paid, t('anRefPaid')), stat(rf.coupons_open, t('anCouponsOpen'))),
      (rf.top || []).length ? h('div', { class: 'card' }, h('div', { class: 'label' }, t('anRefTop')),
        rf.top.map((x) => h('div', { class: 'pay-row' }, h('span', {}, `${x.name || ''}${x.username ? ` @${x.username}` : ''}`), h('b', {}, `${x.invited} / ${x.paid}`)))) : null] : null,
    h('h2', {}, t('anActivity')),
    h('div', { class: 'stats' }, stat(act.sessions7, t('anSessions7')), stat(act.answers7, t('anAnswers7')), stat(act.accuracy7 == null ? null : `${act.accuracy7}%`, t('anAccuracy7'))),
    h('div', { class: 'stats' }, stat(act.topics_read7, t('anTopics7')), stat(act.dialogs_read7, t('anDialogs7')), stat(act.morph7, t('anMorph7'))),
    h('div', { class: 'card' }, h('div', { class: 'label' }, t('anTests')),
      h('div', { class: 'row', style: { gap: '8px', flexWrap: 'wrap' } }, ['A1', 'A2', 'B1', 'B2'].map((c) => h('span', { class: 'chip' }, `${c}: ${tests[c] || 0}`))),
      h('div', { class: 'small muted', style: { marginTop: '8px' } }, `${t('anWordsStarted')}: ${act.words_started || 0}`))));
}
