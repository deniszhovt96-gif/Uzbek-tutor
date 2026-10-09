// Пометки «Нужно исправить» к формам спряжения и склонения: администратор отмечает «исправлено» или «отклонено».
// Сами формы строятся правилами (uzmorph.js), переводы — из data/verb_forms.csv и data/noun_forms.csv:
// исправление вносится в эти файлы / правила, а здесь пометка закрывается.
import { rpc } from '../api.js';
import { t, formatDate } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { icon } from '../icons.js';

export async function renderFormReports(app, params = {}) {
  const status = params.status || 'new';
  mount(spinner(t('loading')));
  const data = await rpc('admin_form_reports', { p_status: status });
  if (data.error) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('lock'), h('p', {}, t('adminOnly')))));
    return;
  }
  const items = data.items || [];
  const seg = h('div', { class: 'segmented' }, [['new', t('frNew')], ['fixed', t('frFixed')], ['rejected', t('frRejected')]].map(([v, l]) =>
    h('button', { type: 'button', class: v === status ? 'active' : '', onClick: () => v !== status && app.replace('formreports', { status: v }) }, l)));
  const card = (r) => {
    const el = h('div', { class: 'card fr-card' },
      h('div', { class: 'row', style: { justifyContent: 'space-between' } },
        h('b', {}, `${r.uz} — ${r.ru}`), h('span', { class: 'chip' }, r.kind === 'conj' ? t('conjBtn') : t('declBtn'))),
      h('div', { class: 'small muted' }, `${r.item || ''}${r.person != null ? ` · ${t('frRow')} ${r.person + 1}` : ` · ${t('repWhole')}`}`),
      r.form ? h('div', { class: 'small fr-form' }, r.form) : null,
      h('div', { class: 'fr-comment' }, `«${r.comment}»`),
      h('div', { class: 'tiny muted' }, `${r.name || ''}${r.username ? ` @${r.username}` : ''} · ${formatDate(r.created_at)}`),
      status === 'new' ? h('div', { class: 'flag-btns' },
        h('button', { class: 'btn btn-small', type: 'button', onClick: () => decide(r.id, 'fixed', el) }, icon('check'), t('frMarkFixed')),
        h('button', { class: 'btn btn-small btn-secondary', type: 'button', onClick: () => decide(r.id, 'rejected', el) }, t('frMarkRejected'))) : null);
    return el;
  };
  const decide = async (id, st, el) => {
    const res = await rpc('admin_resolve_form_report', { p_id: id, p_status: st }).catch(() => null);
    if (res && res.ok) { haptic('success'); el.remove(); }
  };
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('frTitle')),
    h('p', { class: 'muted small' }, t('frSub')),
    seg,
    h('div', { style: { height: '12px' } }),
    items.length ? items.map(card) : h('div', { class: 'card empty' }, icon('check'), h('p', {}, t('frNone')))));
}
