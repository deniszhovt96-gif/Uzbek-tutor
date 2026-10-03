import { rpc } from '../api.js';
import { t, tierName, formatDate } from '../i18n.js';
import { h, mount, spinner } from '../ui.js';

export async function renderHome(app) {
  mount(spinner(t('loading')));
  const [me, home] = await Promise.all([app.refreshMe(), rpc('get_home')]);

  const hasPlan = home.plan_new + home.plan_review > 0;
  const started = home.words_started > 0;
  const tierLine = me.tier === 'free'
    ? tierName('free')
    : `${tierName(me.tier)} ${me.tier_ends_at ? t('tierUntil', formatDate(me.tier_ends_at)) : ''}`;

  let main;
  if (home.daily_limit_reached) {
    main = h('div', { class: 'card hero' },
      h('p', {}, t('dailyLimit')),
      h('button', { class: 'btn', onClick: () => app.go('settings') }, t('toSubscription')));
  } else {
    main = h('div', { class: 'card hero' },
      h('div', { class: 'plan' }, hasPlan ? t('todayPlan', home.plan_new, home.plan_review) : t('todayNothing')),
      h('button', { class: 'btn btn-big', onClick: () => app.go('learn', { mode: 'normal' }) },
        started ? t('continueLearning') : t('startLearning')),
      home.due_total > 0 && me.tier !== 'free'
        ? h('button', { class: 'btn btn-secondary', onClick: () => app.go('learn', { mode: 'review' }) }, t('reviewOnly', home.due_total))
        : null,
      me.tier !== 'free'
        ? h('button', { class: 'btn btn-link', onClick: () => app.go('topics') }, t('chooseTopic'))
        : null);
  }

  const stat = (value, label) => h('div', { class: 'stat' }, h('b', {}, String(value)), h('span', {}, label));
  const tile = (icon, label, onClick, badge) =>
    h('button', { class: 'tile', type: 'button', onClick }, h('span', { class: 'tile-icon' }, icon), h('span', {}, label),
      badge ? h('span', { class: 'badge' }, badge) : null);
  const soon = (key, need) => () => app.go('soon', { title: t(key), need });

  mount(h('div', { class: 'screen' },
    h('header', { class: 'top' },
      h('div', {}, h('h1', {}, t('hello', me.first_name || '')), h('span', { class: `chip tier-${me.tier}` }, tierLine))),
    main,
    h('div', { class: 'stats' },
      stat(home.words_started, t('statStarted')),
      stat(home.words_basic, t('statBasic')),
      stat(home.streak, t('statStreak'))),
    h('h2', {}, t('sections')),
    h('div', { class: 'tiles' },
      tile('📚', t('secLearn'), () => app.go('learn', { mode: 'normal' })),
      tile('🔁', t('secReview'), () => (me.tier === 'free' ? app.go('learn', { mode: 'normal' }) : app.go('learn', { mode: 'review' }))),
      tile('📐', t('secGrammar'), soon('secGrammar', null), t('soon')),
      tile('🏛', t('secHistory'), soon('secHistory', 'advanced'), t('soon')),
      tile('⚖️', t('secCivics'), soon('secCivics', 'advanced'), t('soon')),
      tile('🎭', t('secCulture'), soon('secCulture', 'advanced'), t('soon')),
      tile('🔤', t('secWordsearch'), soon('secWordsearch', 'advanced'), t('soon')),
      tile('📈', t('secProgress'), () => app.go('progress')),
      tile('⚙️', t('secSettings'), () => app.go('settings')))));
}
