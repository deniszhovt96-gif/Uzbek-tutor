// Вкладка «Дом»: профиль, план на сегодня, разделы, активность, прогресс по уровням.
import { rpc, tg } from '../api.js';
import { t, tierName, formatDate } from '../i18n.js';
import { h, mount, spinner, sheet, haptic } from '../ui.js';
import { icon } from '../icons.js';

export function lockedSheet(app, minTier) {
  const close = sheet(
    h('div', { class: 'row' }, h('span', { class: 'tile-icon' }, icon('lock')), h('h3', {}, t('lockedTier', tierName(minTier)))),
    h('button', { class: 'btn btn-big', onClick: () => { close(); app.go('subscription'); } }, t('toSubscription')));
}

export function allowed(home, feature) {
  const f = home && home.features && home.features[feature];
  return !f || f.allowed;
}

export async function renderHome(app) {
  mount(spinner(t('loading')));
  const [me, home, stats] = await Promise.all([app.refreshMe(), rpc('get_home'), rpc('get_stats', { p_days: 14 })]);
  app.homeData = home;

  // ---------------------------------------------------------------- профиль
  const user = tg() && tg().initDataUnsafe && tg().initDataUnsafe.user;
  const name = me.first_name || (user && user.first_name) || '';
  const avatar = h('div', { class: 'avatar' }, (name[0] || '?').toUpperCase());
  if (user && user.photo_url) {
    const img = h('img', { src: user.photo_url, alt: '' });
    img.onerror = () => img.remove();
    avatar.replaceChildren(img);
  }
  const tierChip = h('span', { class: `chip tier-${me.tier}` },
    me.tier === 'free' ? tierName('free') : `${tierName(me.tier)}${me.tier_ends_at ? ` · ${t('tierUntil', formatDate(me.tier_ends_at))}` : ''}`);
  const profile = h('header', { class: 'profile' }, avatar,
    h('div', {},
      h('div', { class: 'profile-name' }, t('hello', name)),
      h('div', { class: 'profile-chips' },
        h('span', { class: 'chip accent' }, icon('map'), t('levelChip', home.unlocked)),
        home.streak > 0 ? h('span', { class: 'chip gold' }, icon('flame'), t('streakChip', home.streak)) : null,
        tierChip)));

  // ---------------------------------------------------------------- план на сегодня
  const num = (value, label) => h('div', { class: 'plan-num' }, h('b', {}, String(value)), h('span', {}, label));
  let plan;
  if (home.daily_limit_reached) {
    plan = h('div', { class: 'card hero' },
      h('div', { class: 'label' }, t('planTitle')),
      h('p', {}, t('dailyLimit')),
      h('button', { class: 'btn', onClick: () => app.go('subscription') }, t('toSubscription')));
  } else {
    const hasPlan = home.plan_new + home.plan_review > 0;
    plan = h('div', { class: 'card hero' },
      h('div', { class: 'label' }, t('planTitle')),
      home.need_test && home.plan_review === 0
        ? h('div', {}, h('h3', {}, t('needTestTitle', home.unlocked)), h('p', { class: 'muted small' }, t('needTestText', home.unlocked)))
        : hasPlan
          ? h('div', { class: 'plan-nums' }, num(home.plan_new, t('planNew')), num(home.plan_review, t('planReview')))
          : h('p', {}, t('todayNothing')),
      hasPlan || !home.need_test
        ? h('button', { class: 'btn btn-big', onClick: () => app.go('learn', { mode: 'normal' }) },
            home.words_started > 0 ? t('continueLearning') : t('startLearning'))
        : null,
      home.need_test
        ? h('button', { class: `btn ${hasPlan ? 'btn-secondary' : 'btn-big'}`, onClick: () => app.go('test', { cefr: home.unlocked }) },
            icon('test'), t('toTest'))
        : null,
      home.due_total > 0 && me.tier !== 'free' && home.plan_new > 0
        ? h('button', { class: 'btn btn-secondary', onClick: () => app.go('learn', { mode: 'review' }) }, t('reviewOnly', home.due_total))
        : null);
  }

  // ---------------------------------------------------------------- разделы
  const tile = (ic, label, onClick, opts = {}) =>
    h('button', { class: `tile ${opts.cls || ''}`, type: 'button', onClick: () => { haptic(); onClick(); } },
      h('span', { class: 'tile-icon' }, icon(ic)), h('span', {}, label),
      opts.badge ? h('span', { class: 'badge' }, opts.badge) : null);
  const gated = (feature, fn) => () => {
    if (allowed(home, feature)) return fn();
    return lockedSheet(app, home.features[feature].min_tier);
  };
  const lockBadge = (feature) => (allowed(home, feature) ? null : icon('lock'));
  const soon = (key, feature) => () => app.go('soon', { title: t(key), need: home.features[feature] && home.features[feature].min_tier });
  const testLevel = (home.levels || []).find((l) => l.state === 'current');

  const tiles = h('div', { class: 'tiles' },
    tile('learn', t('secLearn'), () => app.go('learn', { mode: 'normal' })),
    tile('review', t('secReview'), () => app.go('learn', { mode: me.tier === 'free' ? 'normal' : 'review' })),
    tile('practice', t('secPractice'), gated('practice', () => app.go('practice')), { badge: lockBadge('practice') }),
    tile('games', t('secGames'), gated('games', () => app.go('games')), { badge: lockBadge('games') }),
    tile('filword', t('secWordsearch'), gated('filword', () => app.go('games', { game: 'filword' })), { badge: lockBadge('filword'), cls: 'gold' }),
    tile('test', t('secTest'), () => (testLevel ? app.go('test', { cefr: testLevel.cefr }) : app.tab('path')),
      { badge: testLevel ? testLevel.cefr : null, cls: 'gold' }),
    tile('grammar', t('secGrammar'), () => app.go('course', { course: 'grammar' })),
    tile('history', t('secHistory'), () => app.go('course', { course: 'history' })),
    tile('civics', t('secCivics'), () => app.go('course', { course: 'civics' })),
    tile('culture', t('secCulture'), soon('secCulture', 'culture'), { badge: t('soon'), cls: 'dim' }),
    tile('progress', t('secProgress'), () => app.go('progress')),
    tile('settings', t('secSettings'), () => app.tab('settings')));

  // ---------------------------------------------------------------- активность
  const today = home.today_stats || {};
  const answersToday = (today.correct || 0) + (today.wrong || 0);
  const accuracy = answersToday ? Math.round((today.correct / answersToday) * 100) : 0;
  const stat = (value, label) => h('div', { class: 'stat' }, h('b', {}, String(value)), h('span', {}, label));
  const days = stats.days || [];
  const maxAnswers = Math.max(1, ...days.map((d) => d.correct + d.wrong));
  const bars = h('div', { class: 'bars' }, days.map((d, i) => {
    const n = d.correct + d.wrong;
    return h('div', { class: `bar-col ${n ? '' : 'zero'} ${i === days.length - 1 ? 'today' : ''}`, title: `${d.day}: ${n}` },
      h('div', { class: 'bar-val' }, n ? String(n) : ''),
      h('div', { class: 'bar-fill', style: { height: `${Math.max(3, Math.round((n / maxAnswers) * 100))}%` } }),
      h('div', { class: 'bar-day' }, String(d.day).slice(8, 10)));
  }));

  // ---------------------------------------------------------------- прогресс по уровням
  const cefrRows = h('div', { class: 'cefr-rows' }, (home.levels || []).map((l) => {
    const pct = (n) => `${l.total ? Math.round((n / l.total) * 100) : 0}%`;
    return h('div', { class: `cefr-row ${l.state}` },
      h('div', { class: 'cefr-badge' }, l.state === 'passed' ? icon('check') : l.state === 'locked' ? icon('lock') : l.cefr),
      h('div', {},
        h('div', { class: 'cefr-top' },
          h('span', {}, h('b', {}, `${l.cefr} · ${t(`city${l.cefr}`)}`)),
          h('span', { class: 'muted' }, t('cefrCount', l.started, l.total))),
        h('div', { class: 'track' },
          h('div', { class: 'fill', style: { width: pct(l.started) } }),
          h('div', { class: 'fill strong', style: { width: pct(l.learned) } }))));
  }));

  mount(h('div', { class: 'screen' },
    profile,
    plan,
    h('h2', {}, t('sections')),
    tiles,
    h('h2', {}, t('activityTitle')),
    h('div', { class: 'stats' },
      stat(answersToday, t('todayAnswers')),
      stat(`${accuracy}%`, t('todayAccuracy')),
      stat(Math.round((today.seconds || 0) / 60), t('todayMinutes'))),
    h('div', { class: 'card' }, bars),
    h('h2', {}, t('progressCefr')),
    h('div', { class: 'stats' },
      stat(home.words_started, t('statStarted')),
      stat(home.words_basic, t('statBasic')),
      stat(home.streak, t('statStreak'))),
    h('div', { class: 'card' }, cefrRows,
      h('div', { class: 'legend' },
        h('span', {}, h('i', { class: 'dot', style: { background: 'var(--accent-soft)' } }), t('legendStarted')),
        h('span', {}, h('i', { class: 'dot', style: { background: 'var(--accent)' } }), t('legendLearned'))),
      h('button', { class: 'link-row', type: 'button', onClick: () => app.go('progress') },
        icon('progress'), h('span', { class: 'spacer' }, t('moreStats')), icon('chevron')))));
}
