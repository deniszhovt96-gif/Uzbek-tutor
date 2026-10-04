// Справочник слов: по уровням, темам и алфавиту; слова одной темы (из «Пути»); карточка слова с примерами.
// Пользователи уровня B1+ и администраторы могут пометить слово A1/A2 как малоиспользуемое (→ B1) или
// неиспользуемое (→ B2); пометки пользователей проверяют администраторы.
import { rpc, notifyFlags } from '../api.js';
import { t, formatDate, getLang } from '../i18n.js';
import { h, mount, spinner, sheet, haptic, audioButton } from '../ui.js';
import { icon } from '../icons.js';
import { play, wordAudio, exampleAudio } from '../audio.js';
import { tilesOf } from '../exercises.js';

const LEVELS = ['A1', 'A2', 'B1', 'B2'];
// Порядок узбекского алфавита (латиница)
const ALPHABET = ['a', 'b', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'x', 'y', 'z',
  'oʻ', 'gʻ', 'sh', 'ch', 'ng'];
const PAGE = 300;

function firstLetter(uz) {
  const tile = tilesOf(String(uz).toLowerCase()).find((x) => !x.space && /[a-z]/.test(x.ch));
  if (!tile) return '#';
  const ch = tile.ch.replace('ʼ', '');
  return ALPHABET.includes(ch) ? ch : ch[0];
}
const letterRank = (l) => { const i = ALPHABET.indexOf(l); return i < 0 ? 99 : i; };

// Уровень знания слова 0–15 → короткая подпись
function stageOf(l) {
  if (l == null) return null;
  if (l <= 1) return 'new';
  if (l <= 6) return 'learning';
  return 'known';
}

function wordRow(w, onOpen) {
  const st = stageOf(w.l);
  return h('button', { class: `dict-row ${st || 'none'}`, type: 'button', onClick: () => onOpen(w.i) },
    h('div', { class: 'dict-main' },
      h('b', {}, w.u), w.g ? h('span', { class: 'chip tiny-chip gold' }, t('colloquialShort')) : null,
      h('div', { class: 'small muted' }, w.r)),
    st ? h('span', { class: `lvl-pill ${st}`, title: `${w.l}/15` }, String(w.l)) : null);
}

export async function renderDictionary(app, params = {}) {
  mount(spinner(t('loading')));
  const topicMode = params.topicId != null;
  let cefr = params.cefr;
  let filter = params.filter || (topicMode ? 'all' : 'started');
  let group = params.group || 'topic';
  let query = '';
  let limit = PAGE;
  let data;
  if (topicMode) {
    data = await rpc('get_topic_words', { p_topic: params.topicId });
  } else {
    if (!cefr) cefr = (app.homeData && app.homeData.unlocked) || 'A1';
    data = await rpc('get_dictionary', { p_cefr: cefr });
  }
  const words = data.words || [];
  const topics = data.topics || {};

  const list = h('div', { class: 'dict-list' });
  const search = h('input', { class: 'answer-input dict-search', type: 'search', placeholder: t('dictSearch'),
    onInput: () => { query = search.value.trim().toLowerCase(); draw(); } });

  const seg = (items, current, onPick) => h('div', { class: 'segmented' }, items.map(([value, label]) =>
    h('button', { type: 'button', class: value === current ? 'active' : '', onClick: () => value !== current && onPick(value) }, label)));

  const open = (id) => wordSheet(app, id, () => renderDictionary(app, { ...params, cefr, filter, group }));

  function draw() {
    let rows = words;
    if (filter === 'started') rows = rows.filter((w) => w.l != null);
    if (query) rows = rows.filter((w) => w.u.toLowerCase().includes(query) || w.r.toLowerCase().includes(query));
    const groups = new Map();
    const keyOf = topicMode ? (w) => w.c : group === 'abc' ? (w) => firstLetter(w.u) : (w) => w.t;
    for (const w of rows) {
      const k = keyOf(w);
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(w);
    }
    let keys = [...groups.keys()];
    if (topicMode) keys.sort();
    if (group === 'abc' && !topicMode) {
      keys.sort((a, b) => letterRank(a) - letterRank(b));
      for (const k of keys) groups.get(k).sort((a, b) => a.u.localeCompare(b.u, 'uz'));
    }
    let shown = 0;
    const out = [];
    let more = 0;
    for (const k of keys) {
      const g = groups.get(k);
      if (shown >= limit) { more += g.length; continue; }
      const tn = topics[k];
      const tname = Array.isArray(tn) ? tn[{ ru: 0, uz: 1, en: 2 }[getLang()] || 0] || tn[0] : tn || '';
      const title = topicMode ? `${k} · ${t(`city${k}`)}` : group === 'abc' ? k.toUpperCase() : tname;
      out.push(h('div', { class: 'dict-group' }, h('div', { class: 'label' }, title, h('span', { class: 'muted' }, ` · ${g.length}`)),
        h('div', { class: 'card dict-card' }, g.map((w) => wordRow(w, open)))));
      shown += g.length;
    }
    if (!rows.length) {
      out.push(h('div', { class: 'card empty' }, icon('learn'),
        h('p', {}, filter === 'started' && !query ? t('dictEmptyStarted') : t('dictNothing'))));
    }
    if (more) {
      out.push(h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => { limit += PAGE; draw(); } },
        t('dictMore', more)));
    }
    list.replaceChildren(...out);
  }

  const startedCount = words.filter((w) => w.l != null).length;
  mount(h('div', { class: 'screen' },
    h('h1', {}, topicMode ? params.topicName || t('dictTitle') : t('dictTitle')),
    topicMode
      ? h('p', { class: 'muted small' }, t('dictTopicSub', words.length, startedCount))
      : h('p', { class: 'muted small' }, t('dictSub')),
    topicMode ? null : seg(LEVELS.map((l) => [l, `${l}${data.counts && data.counts[l] ? ` · ${data.counts[l]}` : ''}`]), cefr,
      (v) => renderDictionary(app, { ...params, cefr: v, filter, group })),
    h('div', { class: 'dict-controls' },
      seg([['started', t('dictStarted')], ['all', t('dictAll')]], filter, (v) => { filter = v; rerenderControls(); draw(); }),
      topicMode ? null : seg([['topic', t('dictByTopic')], ['abc', t('dictByAbc')]], group, (v) => { group = v; rerenderControls(); draw(); })),
    search,
    list));

  // переключатели перерисовываются без перезагрузки списка слов
  function rerenderControls() {
    const box = document.querySelector('.dict-controls');
    if (!box) return;
    box.replaceChildren(...[
      seg([['started', t('dictStarted')], ['all', t('dictAll')]], filter, (v) => { filter = v; rerenderControls(); draw(); }),
      topicMode ? null : seg([['topic', t('dictByTopic')], ['abc', t('dictByAbc')]], group, (v) => { group = v; rerenderControls(); draw(); })].filter(Boolean));
  }
  draw();
}

// ---------------------------------------------------------------- карточка слова
export async function wordSheet(app, id, onChanged) {
  const w = await rpc('get_word', { p_word: id });
  if (!w || w.error) return;
  const audioOn = !(app.me && app.me.settings && app.me.settings.audio_exercises === false);
  const st = w.level > 0 ? w.level : null;
  const flagBox = h('div', {});

  const drawFlags = (myFlag) => {
    if (!w.can_flag) return flagBox.replaceChildren();
    const btn = (kind, label) => h('button', { type: 'button', class: `btn btn-small ${myFlag === kind ? '' : 'btn-secondary'}`,
      onClick: async () => {
        haptic();
        const r = await rpc('propose_word_level', { p_word: w.id, p_kind: kind });
        if (r && r.ok) {
          notifyFlags();
          haptic('success');
          flagBox.replaceChildren(h('p', { class: 'small ok' }, r.status === 'approved' ? t('flagApplied', r.to) : t('flagSent')));
          if (r.status === 'approved' && onChanged) onChanged();
        } else {
          flagBox.replaceChildren(h('p', { class: 'small warn' }, (t('flagErrors') || {})[r && r.error] || String(r && r.error)));
        }
      } }, label);
    flagBox.replaceChildren(...[
      h('div', { class: 'label' }, t('flagTitle')),
      h('p', { class: 'tiny muted' }, t('flagHint', w.cefr)),
      h('div', { class: 'flag-btns' }, btn('rare', t('flagRare')), btn('unused', t('flagUnused'))),
      myFlag ? h('p', { class: 'tiny muted' }, t('flagPending')) : null].filter(Boolean));
  };
  drawFlags(w.my_flag);

  const examples = (w.examples || []).map((ex) => h('div', { class: 'example' },
    h('div', { class: 'ex-uz' }, h('span', {}, ex.uz), ex.audio_ok && audioOn ? audioButton(() => play(exampleAudio(ex.word_id, ex.n))) : null),
    h('div', { class: 'ex-ru muted' }, ex.ru)));

  sheet(
    h('div', { class: 'label' }, `${w.cefr} · ${(getLang() === 'uz' && w.topic_uz) || (getLang() === 'en' && w.topic_en) || w.topic || ''}`),
    h('div', { class: 'word-uz' }, w.uz, w.audio_ok && audioOn ? audioButton(() => play(wordAudio(w.id))) : null),
    h('div', { class: 'word-ru' }, w.ru),
    w.en ? h('div', { class: 'small muted', style: { textAlign: 'center' } }, w.en) : null,
    w.register === 'colloquial'
      ? h('div', { class: 'colloq-note' }, h('span', { class: 'chip gold' }, t('colloquial')),
          w.literary && w.literary !== w.uz ? h('span', { class: 'small' }, ` ${t('literaryForm')}: `, h('b', {}, w.literary)) : null,
          w.note ? h('div', { class: 'tiny muted' }, w.note) : null)
      : null,
    st ? h('p', { class: 'small', style: { textAlign: 'center' } },
      t('dictLevel', st), w.due_on ? ` · ${t('dictNext', formatDate(w.due_on))}` : '')
      : h('p', { class: 'small muted', style: { textAlign: 'center' } }, t('dictNotStarted')),
    examples.length ? h('div', { class: 'examples' }, h('div', { class: 'label' }, t('examples')), examples) : null,
    flagBox);
}
