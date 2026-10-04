// Администратор: пометки уровня слов от пользователей B1+ — одобрить (→ B1 / B2), отклонить, отменить применённое.
import { rpc } from '../api.js';
import { t, formatDate } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { wordSheet } from './dictionary.js';

export async function renderWordFlags(app) {
  mount(spinner(t('loading')));
  const d = await rpc('admin_word_proposals');
  if (d.error) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('lock'), h('p', {}, d.error))));
    return;
  }
  const act = async (el, word, decision, cefr) => {
    haptic();
    el.classList.add('busy');
    const r = await rpc('admin_decide_word', { p_word: word, p_decision: decision, p_cefr: cefr || null });
    if (r && r.ok) {
      haptic('success');
      el.replaceChildren(h('p', { class: 'small ok' },
        decision === 'reject' ? t('flagRejected') : decision === 'revert' ? t('flagReverted', r.cefr) : t('flagApplied', r.cefr)));
    } else {
      el.classList.remove('busy');
    }
  };

  const pending = (d.pending || []).map((p) => {
    const el = h('div', { class: 'card review-q' },
      h('div', { class: 'row' },
        h('button', { class: 'link-btn', type: 'button', onClick: () => wordSheet(app, p.word_id) }, h('b', {}, p.uz), ` — ${p.ru}`),
        h('span', { class: 'spacer' }), h('span', { class: 'chip' }, p.cefr)),
      h('p', { class: 'small muted' }, p.topic),
      h('p', { class: 'small' }, t('flagVotes', p.rare, p.unused), h('br'), h('span', { class: 'muted' }, (p.who || []).join(', '))),
      h('div', { class: 'review-btns' },
        h('button', { class: 'btn btn-small btn-ok', type: 'button', onClick: () => act(el, p.word_id, 'approve', 'B1') }, icon('check'), t('flagToB1')),
        h('button', { class: 'btn btn-small btn-ok', type: 'button', onClick: () => act(el, p.word_id, 'approve', 'B2') }, icon('check'), t('flagToB2')),
        h('button', { class: 'btn btn-small btn-no', type: 'button', onClick: () => act(el, p.word_id, 'reject') }, icon('close'), t('reject'))));
    return el;
  });

  const applied = (d.applied || []).map((p) => {
    const el = h('div', { class: 'pay-row' },
      h('div', {}, h('b', {}, p.uz), ` — ${p.ru}`, h('div', { class: 'tiny muted' }, `${p.base} → ${p.cefr} · ${formatDate(p.at)}`)),
      h('button', { class: 'btn btn-small btn-secondary', type: 'button', onClick: () => act(el, p.word_id, 'revert') }, t('flagRevert')));
    return el;
  });

  mount(h('div', { class: 'screen' },
    h('h1', {}, t('flagsTitle')),
    h('p', { class: 'muted small' }, t('flagsSub')),
    h('h2', {}, `${t('flagsPending')} (${pending.length})`),
    pending.length ? pending : h('div', { class: 'card empty' }, icon('check'), h('p', {}, t('flagsNone'))),
    applied.length ? [h('h2', {}, t('flagsApplied')), h('div', { class: 'card' }, applied)] : null));
}
