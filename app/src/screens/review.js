// Проверка вопросов администратором: черновики → одобрить / отклонить. Пользователи видят только одобренные.
import { rpc } from '../api.js';
import { t } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { icon } from '../icons.js';

const COURSE = { grammar: 'secGrammar', history: 'secHistory', civics: 'secCivics', culture: 'secCulture' };

export async function renderReview(app, { unit } = {}) {
  mount(spinner(t('loading')));
  if (!unit) {
    const s = await rpc('admin_review_summary');
    if (s.error) throw new Error(s.error);
    let lastCourse = null;
    const rows = [];
    for (const u of s.units) {
      if (u.course_id !== lastCourse) { rows.push(h('h2', {}, t(COURSE[u.course_id]))); lastCourse = u.course_id; }
      rows.push(h('button', { class: 'unit-card', type: 'button', onClick: () => app.go('review', { unit: u.id }) },
        h('span', { class: 'unit-n' }, u.draft ? String(u.draft) : icon('check')),
        h('span', { class: 'unit-body' }, h('span', { class: 'unit-title' }, `${u.n}. ${u.title_ru}`),
          h('span', { class: 'tiny muted' }, t('reviewCounts', u.draft, u.approved, u.rejected))),
        icon('chevron', 'ic chev')));
    }
    mount(h('div', { class: 'screen' },
      h('h1', {}, t('reviewTitle')),
      h('p', { class: 'muted small' }, t('reviewHint')),
      h('div', { class: 'stats' },
        h('div', { class: 'stat' }, h('b', {}, String(s.draft)), h('span', {}, t('reviewDraft'))),
        h('div', { class: 'stat' }, h('b', {}, String(s.approved)), h('span', {}, t('reviewApproved'))),
        h('div', { class: 'stat' }, h('b', {}, String(s.rejected)), h('span', {}, t('reviewRejected')))),
      h('div', { class: 'unit-list' }, rows)));
    return;
  }

  const d = await rpc('admin_unit_questions', { p_unit: unit });
  if (d.error) throw new Error(d.error);
  const set = async (id, status, el) => {
    haptic(status === 'approved' ? 'success' : undefined);
    await rpc('admin_set_question', { p_task: id, p_status: status });
    el.dataset.status = status;
    el.querySelector('.q-status').textContent = t(`status_${status}`);
  };
  const cards = d.questions.map((q) => {
    const el = h('div', { class: 'card review-q', 'data-status': q.status },
      h('div', { class: 'row' }, h('b', {}, `${q.k}.`), h('span', { class: 'spacer' }), h('span', { class: 'chip q-status' }, t(`status_${q.status}`))),
      h('p', {}, h('b', {}, q.prompt_ru)),
      h('ol', { class: 'q-opts' }, q.options.ru.map((o, k) => h('li', { class: k === 0 ? 'ok' : '' }, o, k === 0 ? ' ✓' : ''))),
      h('div', { class: 'quote small' }, icon('learn'), h('span', {}, `«${q.quote_ru}»`)),
      h('details', {}, h('summary', { class: 'small muted' }, 'UZ / EN'),
        h('p', { class: 'small' }, h('b', {}, q.prompt_uz), h('br'), q.options.uz.join(' · ')),
        h('p', { class: 'small' }, h('b', {}, q.prompt_en), h('br'), q.options.en.join(' · '))),
      h('div', { class: 'review-btns' },
        h('button', { class: 'btn btn-small btn-ok', type: 'button', onClick: () => set(q.id, 'approved', el) }, icon('check'), t('approve')),
        h('button', { class: 'btn btn-small btn-no', type: 'button', onClick: () => set(q.id, 'rejected', el) }, icon('close'), t('reject'))));
    return el;
  });
  mount(h('div', { class: 'screen' },
    h('div', { class: 'label' }, t(COURSE[d.unit.course_id])),
    h('h1', {}, `${d.unit.n}. ${d.unit.title_ru}`),
    h('button', { class: 'btn btn-secondary', type: 'button', onClick: async () => {
      await rpc('admin_set_question', { p_task: null, p_status: 'approved', p_unit: unit });
      haptic('success');
      app.replace('review', { unit });
    } }, icon('check'), t('approveAllDrafts')),
    ...cards));
}
