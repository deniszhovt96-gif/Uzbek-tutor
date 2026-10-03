import { t } from '../i18n.js';
import { h, mount } from '../ui.js';

export function renderSoon(app, { title, need }) {
  mount(h('div', { class: 'screen' },
    h('h1', {}, title),
    h('div', { class: 'card' },
      h('p', {}, t('soonText')),
      need === 'advanced' ? h('p', { class: 'muted' }, t('needAdvanced')) : null,
      h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
}
