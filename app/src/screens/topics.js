import { rpc } from '../api.js';
import { t, getLang } from '../i18n.js';
import { h, mount, spinner } from '../ui.js';

export async function renderTopics(app) {
  mount(spinner(t('loading')));
  const topics = await rpc('get_topics');
  const lang = getLang();
  const groups = {};
  for (const tp of topics) (groups[tp.cefr] = groups[tp.cefr] || []).push(tp);

  mount(h('div', { class: 'screen' },
    h('h1', {}, t('topicsTitle')),
    h('p', { class: 'muted' }, t('topicsHint')),
    ['A1', 'A2', 'B1', 'B2'].filter((c) => groups[c]).map((cefr) => [
      h('h2', {}, cefr),
      h('div', { class: 'topic-list' }, groups[cefr].map((tp) => {
        const pct = Math.round((tp.started / tp.total) * 100);
        const name = (lang === 'uz' && tp.name_uz) || (lang === 'en' && tp.name_en) || tp.name;
        return h('button', { class: 'topic', type: 'button', disabled: tp.started >= tp.total,
          onClick: () => app.go('learn', { mode: 'normal', topicId: tp.id }) },
          h('span', { class: 'topic-name' }, name),
          h('span', { class: 'topic-count muted' }, `${tp.started}/${tp.total}`),
          h('span', { class: 'topic-bar' }, h('span', { style: { width: `${pct}%` } })));
      })),
    ])));
}
