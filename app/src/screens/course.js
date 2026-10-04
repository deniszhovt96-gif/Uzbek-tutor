// Курсы «Грамматика», «История», «Обществознание»: список тем, тема (кратко / подробно / примеры / задания),
// хронология, справочник контактов, базовая лексика.
import { rpc } from '../api.js';
import { t, getLang, tierName } from '../i18n.js';
import { h, mount, spinner, haptic, audioButton } from '../ui.js';
import { icon } from '../icons.js';
import { play, exampleAudio } from '../audio.js';
import { topicImage } from '../images.js';

// Поле на нужном языке с запасным русским: pick(obj, 'title') → title_uz | title_ru
export function pick(obj, base, lang = getLang()) {
  if (!obj) return '';
  return obj[`${base}_${lang}`] || obj[`${base}_ru`] || obj[base] || '';
}

const COURSE_ICON = { grammar: 'grammar', history: 'history', civics: 'civics', culture: 'culture' };
const EXTRA_TAB = { grammar: ['vocab', 'courseVocab'], history: ['timeline', 'courseTimeline'], civics: ['contacts', 'courseContacts'] };

// ---------------------------------------------------------------- курс
export async function renderCourse(app, { course, tab = 'units' }) {
  mount(spinner(t('loading')));
  const data = await rpc('get_course', { p_course: course });
  if (data.error) throw new Error(data.error);
  const units = data.units || [];
  const read = units.filter((u) => u.read).length;
  const sections = Object.fromEntries((data.sections || []).map((s) => [s.id, s]));
  const extra = EXTRA_TAB[course];

  const tabs = h('div', { class: 'segmented' },
    [['units', 'courseTopics'], ...(extra ? [extra] : [])].map(([key, label]) =>
      h('button', { type: 'button', class: key === tab ? 'active' : '', onClick: () => key !== tab && app.replace('course', { course, tab: key }) }, t(label))));

  let body;
  if (tab === 'units') {
    body = h('div', { class: 'unit-list' }, units.map((u) => {
      const meta = course === 'history' ? (pick(u, 'period') || u.period) : pick(sections[u.section_id], 'title');
      return h('button', { class: `unit-card ${u.locked ? 'locked' : ''} ${u.read ? 'read' : ''}`, type: 'button',
        onClick: () => { haptic(); app.go('unit', { id: u.id }); } },
        h('span', { class: 'unit-n' }, u.read ? icon('check') : u.locked ? icon('lock') : String(u.n)),
        h('span', { class: 'unit-body' },
          meta ? h('span', { class: 'unit-meta' }, meta) : null,
          h('span', { class: 'unit-title' }, pick(u, 'title')),
          h('span', { class: 'unit-express' }, pick(u, 'express')),
          u.tasks_done ? h('span', { class: 'tiny muted' }, t('tasksDone', u.tasks_done, u.tasks_total)) : null,
          u.tested ? h('span', { class: 'chip gold', style: { alignSelf: 'flex-start' } }, icon('trophy'), t('unitTestBadge', u.best_score)) : null),
        icon('chevron', 'ic chev'));
    }));
  } else if (tab === 'timeline') {
    body = h('div', { class: 'timeline' }, (data.timeline || []).map((e) =>
      h('div', { class: 'tl-item' },
        h('span', { class: 'tl-dot' }),
        h('div', {}, h('div', { class: 'tl-date' }, e.date), h('div', {}, pick(e, 'text'))))));
  } else if (tab === 'contacts') {
    body = h('div', {},
      h('div', { class: 'card note' }, icon('civics'), h('span', {}, t('civicsDisclaimer'))),
      h('div', { class: 'card' }, (data.reference || []).filter((r) => r.kind === 'contact').map((r) => {
        const v = r.value;
        const href = /^\d+$/.test(v) ? `tel:${v}` : `https://${v}`;
        return h('div', { class: 'contact-row' },
          h('span', {}, pick(r, 'title')),
          h('a', { class: 'contact-val', href, target: '_blank', rel: 'noopener' }, v));
      })));
  } else if (tab === 'vocab') {
    body = h('div', { class: 'card' }, (data.reference || []).filter((r) => r.kind === 'vocab').map((r) =>
      h('div', { class: 'vocab-row' },
        h('div', { class: 'row' }, h('b', {}, r.value), r.extra && r.extra.transcription ? h('span', { class: 'muted small' }, `[${r.extra.transcription}]`) : null,
          h('span', { class: 'spacer' }), h('span', { class: 'small' }, getLang() === 'en' ? r.title_en : r.title_ru)),
        r.extra && r.extra.example ? h('div', { class: 'small muted' }, r.extra.example) : null)));
  }

  const preview = !data.allowed
    ? h('div', { class: 'card note gold' }, icon('lock'),
        h('div', {}, h('div', {}, t('previewNote', data.preview, tierName(data.min_tier))),
          h('button', { class: 'btn btn-small', type: 'button', onClick: () => app.go('subscription', { tier: data.min_tier }) }, t('toSubscription'))))
    : null;

  mount(h('div', { class: 'screen' },
    h('div', { class: 'course-head' },
      h('span', { class: 'tile-icon' }, icon(COURSE_ICON[course] || 'learn')),
      h('div', {}, h('h1', {}, pick(data, 'title')), h('div', { class: 'muted small' }, t('readCount', read, units.length)))),
    h('div', { class: 'track', style: { margin: '6px 0 14px' } },
      h('div', { class: 'fill strong', style: { width: `${units.length ? Math.round((read / units.length) * 100) : 0}%` } })),
    preview,
    tabs,
    h('div', { style: { height: '12px' } }),
    body));
}

// ---------------------------------------------------------------- тема
export async function renderUnit(app, { id, lang }) {
  mount(spinner(t('loading')));
  const [u, testInfo, img] = await Promise.all([
    rpc('get_unit', { p_unit: id }),
    rpc('unit_test_info', { p_unit: id }).catch(() => null),
    topicImage(null, null)]);
  if (u.error === 'locked_tier') {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('lock'),
      h('p', {}, t('lockedTier', tierName(u.need))),
      h('button', { class: 'btn', onClick: () => app.go('subscription', { tier: u.need }) }, t('toSubscription')),
      h('button', { class: 'btn btn-secondary', onClick: () => app.back() }, t('back')))));
    return;
  }
  if (u.error) throw new Error(u.error);
  const L = lang || getLang();
  const audioEnabled = !(app.me.settings && app.me.settings.audio_exercises === false);
  let done = new Set(u.tasks_done || []);
  let isRead = u.read;

  // язык текста темы можно переключить прямо здесь: читать по-узбекски — тоже практика
  const langSeg = h('div', { class: 'segmented small-seg' }, [['ru', 'RU'], ['uz', 'UZ'], ['en', 'EN']].map(([v, label]) =>
    h('button', { type: 'button', class: v === L ? 'active' : '', onClick: () => v !== L && app.replace('unit', { id, lang: v }) }, label)));

  const paragraphs = (text) => String(text || '').split(/\n+/).filter(Boolean).map((p) => h('p', {}, p));
  const detailed = h('div', { class: 'detailed collapsed' }, paragraphs(pick(u, 'detailed', L)));
  const expandBtn = h('button', { class: 'btn btn-ghost btn-small', type: 'button', onClick: () => {
    detailed.classList.remove('collapsed');
    expandBtn.remove();
  } }, t('readMore'));

  // примеры из словаря (грамматика)
  const exBox = h('div', { class: 'card' });
  let exOffset = 0;
  const highlight = (text, match) => {
    if (!match) return [text];
    const i = text.toLowerCase().indexOf(match.toLowerCase());
    if (i < 0) return [text];
    return [text.slice(0, i), h('mark', {}, text.slice(i, i + match.length)), text.slice(i + match.length)];
  };
  const addExamples = (list) => {
    for (const e of list) {
      exBox.append(h('div', { class: 'example' },
        h('div', { class: 'ex-uz' }, h('span', {}, ...highlight(e.uz, e.match)),
          e.audio_ok && audioEnabled ? audioButton(() => play(exampleAudio(e.word_id, e.n))) : null),
        h('div', { class: 'ex-ru muted small' }, e.ru)));
    }
    exOffset += list.length;
  };
  addExamples(u.examples || []);
  const moreBtn = h('button', { class: 'btn btn-secondary btn-small', type: 'button', onClick: async () => {
    moreBtn.disabled = true;
    const more = await rpc('unit_examples', { p_unit: id, p_limit: 8, p_offset: exOffset });
    addExamples(more);
    moreBtn.disabled = false;
    if (more.length < 8) moreBtn.remove();
  } }, t('moreExamples'));

  // задания для самопроверки
  const taskEls = (u.tasks || []).map((task) => {
    const el = h('button', { class: `task ${done.has(task.n) ? 'done' : ''}`, type: 'button', onClick: async () => {
      const now = !done.has(task.n);
      haptic(now ? 'success' : undefined);
      el.classList.toggle('done', now);
      const r = await rpc('mark_unit', { p_unit: id, p_task: task.n, p_done: now }).catch(() => null);
      if (r && r.tasks_done) done = new Set(r.tasks_done);
    } },
      h('span', { class: 'task-check' }, icon('check')),
      h('span', {}, h('b', {}, `${task.n}. `), pick(task, 'prompt', L)));
    return el;
  });

  const readBtn = h('button', { class: `btn ${isRead ? 'btn-secondary' : 'btn-big'}`, type: 'button', onClick: async () => {
    isRead = !isRead;
    haptic(isRead ? 'success' : undefined);
    readBtn.className = `btn ${isRead ? 'btn-secondary' : 'btn-big'}`;
    readBtn.replaceChildren(icon('check'), isRead ? t('markedRead') : t('markRead'));
    await rpc('mark_unit', { p_unit: id, p_read: isRead }).catch(() => null);
  } }, icon('check'), isRead ? t('markedRead') : t('markRead'));

  const image = await topicImage(u.course_id, u.n);
  const figure = image ? h('figure', { class: 'topic-img' },
    h('img', { src: image.src, alt: pick(image, 'caption', L), loading: 'lazy', onError: (e) => e.target.closest('figure').remove() }),
    h('figcaption', {}, pick(image, 'caption', L), ' · ',
      h('a', { href: image.page, target: '_blank', rel: 'noopener' }, `${image.author ? `${image.author}, ` : ''}${image.license}`))) : null;

  const testBlock = testInfo && testInfo.available ? h('div', { class: 'card test-card' },
    h('div', { class: 'row' }, h('span', { class: 'tile-icon gold' }, icon('trophy')),
      h('div', {}, h('b', {}, t('unitTest')), h('div', { class: 'small muted' },
        testInfo.passed ? t('unitTestBest', testInfo.best_score, testInfo.total) : t('unitTestHint', testInfo.total)))),
    h('button', { class: 'btn', type: 'button', onClick: () => app.go('unittest', { id, title: pick(u, 'title', L) }) },
      testInfo.best_score != null ? t('unitTestAgain') : t('unitTestStart'))) : null;

  const meta = u.course_id === 'history' ? (pick(u, 'period', L) || u.period) : pick(u.section, 'title', L);
  mount(h('div', { class: 'screen' },
    h('div', { class: 'row', style: { justifyContent: 'space-between' } },
      meta ? h('span', { class: 'chip accent' }, meta) : h('span', {}), langSeg),
    h('h1', { style: { marginTop: '12px' } }, pick(u, 'title', L)),
    figure,
    u.course_id === 'civics' ? h('div', { class: 'card note' }, icon('civics'), h('span', { class: 'small' }, t('civicsDisclaimer'))) : null,
    h('div', { class: 'card express' }, h('div', { class: 'label' }, t('unitExpress')), paragraphs(pick(u, 'express', L))),
    h('h2', {}, t('unitDetailed')),
    h('div', { class: 'card' }, detailed, expandBtn),
    u.has_examples && (u.examples || []).length ? [h('h2', {}, t('unitExamples')), exBox, (u.examples || []).length >= 8 ? moreBtn : null] : null,
    taskEls.length ? [h('h2', {}, t('unitTasks')), h('p', { class: 'small muted' }, t('tasksHint')), h('div', { class: 'task-list' }, taskEls)] : null,
    u.source ? h('p', { class: 'tiny muted', style: { marginTop: '18px' } }, `${t('unitSource')}: ${u.source}`) : null,
    readBtn,
    testBlock,
    h('div', { class: 'unit-nav' },
      u.prev_id ? h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => app.replace('unit', { id: u.prev_id, lang }) }, t('prevUnit')) : h('span', {}),
      u.next_id ? h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => app.replace('unit', { id: u.next_id, lang }) }, t('nextUnit')) : h('span', {}))));
}
