// Спряжение глаголов: список по уровням (A1→B2, внутри — по алфавиту), таблицы форм с переводом
// и разговорными вариантами, два упражнения со своими уровнями:
//   • «Напишите форму» — одна клетка (уровень «форма»);
//   • «Заполните таблицу» — корень дан, дописать суффикс и окончание во всех лицах (уровень «таблица»).
// Времена открываются по пройденным темам грамматики; потолок уровня — доля пройденных тем.
import { rpc } from '../api.js';
import { t, getLang } from '../i18n.js';
import { h, mount, spinner, sheet, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { conjugate, decline, acceptedForms, isVerb, PERSONS } from '../uzmorph.js';
import { formTranslation } from '../verbtr.js';
import { displayUz } from '../normalize.js';
import { openTenses, commonRoot, cellOk, reportSheet, flagButton } from '../morph.js';
import { declSheet as declSheetImpl } from './decl.js';

let appRef = null;
export function setConjApp(a) { appRef = a; }

const GROUPS = ['indicative', 'imperative', 'conditional', 'ability', 'nonfinite'];
const CEFRS = ['A1', 'A2', 'B1', 'B2'];
const tenseName = (tn) => (getLang() === 'uz' ? tn.uz : getLang() === 'en' ? tn.en || tn.uz : tn.ru || tn.uz);
const trLang = () => (getLang() === 'en' ? 'en' : 'ru');
const meaning = (v) => (getLang() === 'en' && v.e ? v.e : v.r);

async function loadMorph(ids) {
  if (!ids.length) return {};
  return rpc('get_morph', { p_ids: ids }).catch(() => ({}));
}

// ---------------------------------------------------------------- таблицы спряжения (экран и шторка)
function conjTables(verb, morph, state, redraw) {
  const c = conjugate(verb.uz);
  if (!c) return h('p', { class: 'muted' }, t('conjNotVerb'));
  const seg = (items, current, onPick) => h('div', { class: 'segmented scroll' }, items.map(([value, label]) =>
    h('button', { type: 'button', class: value === current ? 'active' : '', onClick: () => { haptic(); onPick(value); } }, label)));
  const groupBar = seg(GROUPS.map((g) => [g, t(`conjGroup_${g}`)]), state.group, (g) => { state.group = g; redraw(); });
  const polarity = state.group === 'nonfinite' ? null
    : seg([['pos', t('conjPos')], ['neg', t('conjNeg')]], state.neg ? 'neg' : 'pos', (v) => { state.neg = v === 'neg'; redraw(); });

  let cards;
  if (state.group === 'nonfinite') {
    cards = c.nonfinite.map((n) => h('div', { class: 'conj-card' },
      h('div', { class: 'conj-title' }, getLang() === 'uz' ? n.uz : n.ru || n.uz, h('span', { class: 'muted' }, ` ${n.aff}`)),
      h('div', { class: 'conj-form one' }, n.forms.join(' · '))));
  } else {
    cards = c.tenses.filter((tn) => tn.group === state.group).map((tn) => {
      const forms = state.neg ? tn.neg : tn.pos;
      const coll = tn.coll && (state.neg ? tn.coll.neg : tn.coll.pos);
      const rows = forms.map((f, i) => ({ label: PERSONS[i], text: `${f} — ${formTranslation(morph, tn.id, state.neg, i, trLang())}` }));
      return h('div', { class: 'conj-card' },
        flagButton(() => reportSheet({ word: verb, kind: 'conj', item: `${tn.id}${state.neg ? ':neg' : ''}`, title: tenseName(tn), rows })),
        h('div', { class: 'conj-title' }, tenseName(tn)),
        h('div', { class: 'conj-sub muted' }, `${tn.uz} · ${tn.aff}`),
        forms.map((f, i) => {
          const tr = formTranslation(morph, tn.id, state.neg, i, trLang());
          const cv = coll && coll[i];
          return h('div', { class: 'conj-row' },
            h('span', { class: 'conj-p' }, PERSONS[i]),
            h('div', { class: 'conj-cell' },
              h('b', {}, f),
              cv ? h('div', { class: 'conj-coll' }, `${t('colloquialShort')} ${cv}`) : null,
              tr ? h('div', { class: 'conj-tr' }, tr) : null));
        }));
    });
  }
  return h('div', { class: 'conj' }, groupBar, polarity, h('div', { class: 'conj-grid' }, cards),
    h('p', { class: 'tiny muted' }, t('conjNote2')));
}

// Шторка со спряжением — из карточки слова, задания, словаря
export async function conjSheet(verb, app = appRef) {
  const morph = (await loadMorph([verb.id]))[verb.id];
  const state = { group: 'indicative', neg: false };
  const box = h('div', {});
  const redraw = () => box.replaceChildren(conjTables(verb, morph, state, redraw));
  redraw();
  const close = sheet(
    h('div', { class: 'label' }, t('conjTitle')),
    h('h3', {}, verb.uz, h('span', { class: 'muted' }, ` — ${verb.ru}`)),
    app ? h('button', { class: 'btn btn-big', type: 'button', onClick: () => { close(); app.go('conj', { verb }); } }, icon('practice'), t('conjOpenVerb')) : null,
    box);
}

export const declSheet = (noun, app = appRef) => declSheetImpl(noun, app);
export const canConjugate = (word) => word && isVerb(word.uz);
export const canDecline = (word) => word && !isVerb(word.uz) && decline(word.uz) && word.word_class !== 'phrase';

// ---------------------------------------------------------------- список глаголов
const pill = (label, value, cls = '') => h('span', { class: `lvl-pill ${cls} ${value == null ? 'empty' : ''}` }, `${label} ${value == null ? '—' : value}`);

export async function renderConj(app, params = {}) {
  if (params.verb) return renderVerb(app, params.verb, params);
  if (params.train) return startTraining(app, params.train, params.verbs);
  mount(spinner(t('loading')));
  const data = await rpc('get_verbs');
  const verbs = (data.verbs || []).filter((v) => isVerb(v.u));
  const st = data.state || {};
  const open = openTenses(st);
  let q = '';
  const list = h('div', {});
  const draw = () => {
    const ql = q.toLowerCase();
    const rows = q ? verbs.filter((v) => v.u.toLowerCase().includes(ql) || (v.r || '').toLowerCase().includes(ql) || (v.e || '').toLowerCase().includes(ql)) : verbs;
    list.replaceChildren(...CEFRS.map((cefr) => {
      const lv = rows.filter((v) => v.c === cefr);
      if (!lv.length) return null;
      return h('div', {},
        h('div', { class: 'lv-head' }, h('b', {}, cefr), h('span', { class: 'muted small' }, t('nVerbs', lv.length))),
        h('div', { class: 'card dict-card' }, lv.map((v) => h('button', { class: 'dict-row', type: 'button',
          onClick: () => app.go('conj', { verb: { id: v.i, uz: v.u, ru: meaning(v) } }) },
          h('div', { class: 'dict-main' }, h('b', {}, v.u), h('div', { class: 'small muted' }, meaning(v)),
            v.l != null || v.f != null || v.t != null
              ? h('div', { class: 'pill-row' }, pill(t('lvWord'), v.l), pill(t('lvForm'), v.f, 'gold'), pill(t('lvTable'), v.t, 'gold'))
              : null),
          icon('chevron', 'ic chev')))));
    }));
  };
  const search = h('input', { class: 'answer-input dict-search', type: 'search', placeholder: t('dictSearch'),
    onInput: () => { q = search.value.trim(); draw(); } });
  draw();
  const mine = verbs.filter((v) => v.l != null);
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('conjTitle')),
    h('p', { class: 'muted small' }, t('conjSub2')),
    h('div', { class: 'card note' }, icon('grammar'),
      h('div', { class: 'small' }, open.none ? t('conjOpenNone') : t('conjOpenN', open.tenses.length, 16, open.neg),
        h('div', { class: 'tiny muted' }, t('conjCap', st.conj_cap || 1)))),
    h('div', { class: 'two-btns' },
      h('button', { class: 'btn', type: 'button', onClick: () => app.go('conj', { train: 'form', verbs: pickMine(mine, 'f') }) },
        icon('practice'), t('trainForm')),
      h('button', { class: 'btn', type: 'button', onClick: () => app.go('conj', { train: 'table', verbs: pickMine(mine, 't').slice(0, 2) }) },
        icon('conj'), t('trainTable'))),
    search, list));
}

// свои глаголы: сначала те, что пора повторить, потом с наименьшим уровнем
function pickMine(mine, key) {
  const due = (v) => (key === 'f' ? v.fd : v.td);
  return [...mine].sort((a, b) => (due(b) ? 1 : 0) - (due(a) ? 1 : 0) || (a[key] ?? -1) - (b[key] ?? -1) || (b.l || 0) - (a.l || 0))
    .slice(0, 12).map((v) => ({ id: v.i, uz: v.u, ru: meaning(v) }));
}

// ---------------------------------------------------------------- страница глагола
async function renderVerb(app, verb, params) {
  mount(spinner(t('loading')));
  const [morphs, data] = await Promise.all([loadMorph([verb.id]), rpc('get_verbs').catch(() => ({}))]);
  const morph = morphs[verb.id];
  const me = (data.verbs || []).find((v) => v.i === verb.id) || {};
  const state = { group: params.group || 'indicative', neg: false };
  const box = h('div', {});
  const redraw = () => box.replaceChildren(conjTables(verb, morph, state, redraw));
  redraw();
  mount(h('div', { class: 'screen' },
    h('div', { class: 'label' }, t('conjTitle')),
    h('h1', {}, verb.uz), h('p', { class: 'muted' }, verb.ru),
    h('div', { class: 'pill-row' }, pill(t('lvWord'), me.l), pill(t('lvForm'), me.f, 'gold'), pill(t('lvTable'), me.t, 'gold')),
    h('div', { class: 'two-btns' },
      h('button', { class: 'btn', type: 'button', onClick: () => app.go('conj', { train: 'table', verbs: [verb] }) }, icon('conj'), t('trainTableThis')),
      h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => app.go('conj', { train: 'form', verbs: [verb] }) }, icon('practice'), t('trainFormThis'))),
    box));
}

// ---------------------------------------------------------------- тренировки
async function startTraining(app, kind, verbs) {
  mount(spinner(t('loading')));
  const data = await rpc('get_verbs');
  const open = openTenses(data.state || {});
  // без списка — свои глаголы (из рекомендаций): сначала те, что пора повторить
  if (!verbs) {
    const mine = (data.verbs || []).filter((v) => v.l != null && isVerb(v.u));
    verbs = pickMine(mine, kind === 'table' ? 't' : 'f').slice(0, kind === 'table' ? 2 : 12);
  }
  const list = (verbs || []).filter((v) => conjugate(v.uz));
  if (!list.length) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('practice'), h('p', {}, t('conjNoVerbs')),
      h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
    return;
  }
  const morphs = await loadMorph(list.map((v) => v.id));
  if (kind === 'table') return tableTraining(app, list, morphs, open);
  return formTraining(app, list, morphs, open);
}

// уровни по итогам тренировки: по каждому глаголу — доля верных
async function saveResults(kind, results) {
  const out = [];
  for (const [id, r] of Object.entries(results)) {
    const res = await rpc('answer_morph', { p_word: Number(id), p_kind: kind, p_ok: r.ok, p_total: r.total }).catch(() => null);
    if (res && res.ok) out.push({ id: Number(id), uz: r.uz, from: res.prev, to: res.level, cap: res.cap });
  }
  return out;
}

function resultScreen(app, title, ok, total, levels, again) {
  haptic('success');
  mount(h('div', { class: 'screen' },
    h('div', { class: 'card result-hero' }, h('div', { class: 'result-icon ok' }, icon('trophy')),
      h('h1', {}, title), h('div', { class: 'big' }, `${ok}/${total}`),
      levels.length ? h('div', { class: 'small' }, levels.map((l) => h('div', {}, `${l.uz}: ${t('levelChange', l.from, l.to)}`))) : null,
      levels.some((l) => l.to >= l.cap && l.cap < 15) ? h('p', { class: 'tiny muted' }, t('capHint')) : null),
    h('button', { class: 'btn btn-big', onClick: again }, t('again')),
    h('button', { class: 'btn btn-secondary', onClick: () => app.back() }, t('back'))));
}

// --- «Напишите форму»: 10 клеток из открытых времён
function formTraining(app, verbs, morphs, open) {
  const N = 10;
  const tasks = [];
  for (let k = 0; k < N * 4 && tasks.length < N; k++) {
    const v = verbs[k % verbs.length];
    const c = conjugate(v.uz);
    const tenses = c.tenses.filter((tn) => open.tenses.includes(tn.id));
    const tn = tenses[Math.floor(Math.random() * tenses.length)];
    if (!tn) continue;
    const neg = open.neg && Math.random() < 0.35;
    const p = Math.floor(Math.random() * 6);
    const cell = (neg ? tn.neg : tn.pos)[p];
    const coll = tn.coll && (neg ? tn.coll.neg : tn.coll.pos);
    tasks.push({ verb: v, tense: tn, neg, person: p, cell, extra: coll ? [coll[p]] : [] });
  }
  let i = 0;
  let score = 0;
  const results = {};
  const show = async () => {
    if (i >= tasks.length) {
      const levels = await saveResults('form', results);
      return resultScreen(app, t('conjDone'), score, tasks.length, levels, () => formTraining(app, verbs, morphs, open));
    }
    const task = tasks[i];
    let done = false;
    const tr = formTranslation(morphs[task.verb.id], task.tense.id, task.neg, task.person, trLang());
    const input = h('input', { class: 'answer-input', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
      placeholder: t('placeholderUz'), onKeydown: (e) => { if (e.key === 'Enter') check(); } });
    const fb = h('div', {});
    const check = () => {
      if (done) { i++; show(); return; }
      const val = displayUz(input.value.trim());
      if (!val) return;
      done = true;
      const ok = cellOk(val, task.cell, '\u0000', task.extra);
      if (ok) score++;
      const r = results[task.verb.id] || (results[task.verb.id] = { ok: 0, total: 0, uz: task.verb.uz });
      r.total++; if (ok) r.ok++;
      haptic(ok ? 'success' : 'error');
      fb.replaceChildren(h('div', { class: `feedback show ${ok ? 'good' : 'bad'}` },
        h('b', {}, ok ? t('correct') : t('wrong')), ok ? null : h('div', {}, t('rightAnswerIs'), ' ', h('b', {}, task.cell))));
      btn.textContent = t('next');
    };
    const btn = h('button', { class: 'btn btn-big', type: 'button', onClick: check }, t('check'));
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((i / tasks.length) * 100)}%` } })),
        h('span', { class: 'counter' }, `${i + 1}/${tasks.length}`)),
      h('div', { class: 'label' }, t('conjTask')),
      h('div', { class: 'card ex-card' },
        h('div', { class: 'prompt' },
          h('div', { class: 'word-uz' }, task.verb.uz), h('div', { class: 'muted' }, task.verb.ru),
          h('div', { class: 'conj-ask' },
            h('span', { class: 'chip accent' }, tenseName(task.tense)),
            task.neg ? h('span', { class: 'chip err-chip' }, t('conjNeg')) : null,
            h('span', { class: 'chip' }, `${PERSONS[task.person]} · ${t(`pers${task.person}`)}`)),
          tr ? h('div', { class: 'conj-tr center-text' }, `«${tr}»`) : null),
        input,
        h('div', { class: 'helper-row' }, ['oʻ', 'gʻ', 'ʼ'].map((s) =>
          h('button', { class: 'chip-btn', type: 'button', onClick: () => { input.value += s; input.focus(); } }, s))),
        fb, btn)));
    setTimeout(() => input.focus(), 50);
  };
  show();
}

// --- «Заполните таблицу»: корень дан, дописать суффикс и окончание во всех лицах
function tableTraining(app, verbs, morphs, open) {
  const tables = [];
  for (const v of verbs) {
    const c = conjugate(v.uz);
    let tenses = c.tenses.filter((tn) => open.tenses.includes(tn.id));
    // одна тренировка — не больше 8 таблиц: из многих глаголов берём по нескольку времён
    if (verbs.length > 1) tenses = tenses.sort(() => Math.random() - 0.5).slice(0, 3);
    for (const tn of tenses) {
      tables.push({ verb: v, tense: tn, neg: false });
      if (open.neg) tables.push({ verb: v, tense: tn, neg: true });
    }
  }
  const list = tables.slice(0, verbs.length > 1 ? 8 : 40);
  let i = 0;
  let score = 0;
  let total = 0;
  const results = {};
  const show = async () => {
    if (i >= list.length) {
      const levels = await saveResults('table', results);
      return resultScreen(app, t('tableDone'), score, total, levels, () => tableTraining(app, verbs, morphs, open));
    }
    const task = list[i];
    const forms = task.neg ? task.tense.neg : task.tense.pos;
    const coll = task.tense.coll && (task.neg ? task.tense.coll.neg : task.tense.coll.pos);
    const stem = conjugate(task.verb.uz);
    const root = commonRoot(forms, stem.prefix + stem.stem);
    let checked = false;
    const inputs = forms.map(() => h('input', { class: 'tbl-inp', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', placeholder: '…' }));
    inputs.forEach((inp, k) => inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { if (inputs[k + 1]) inputs[k + 1].focus(); else check(); }
    }));
    const fixes = forms.map(() => h('div', { class: 'tbl-fix' }));
    const fb = h('div', {});
    const check = () => {
      if (checked) { i++; show(); return; }
      checked = true;
      let ok = 0;
      inputs.forEach((inp, k) => {
        const good = cellOk(displayUz(inp.value.trim()), forms[k], root, coll ? [coll[k]] : []);
        inp.classList.add(good ? 'ok' : 'bad');
        inp.disabled = true;
        if (good) ok++;
        else fixes[k].textContent = `→ ${forms[k]}`;
      });
      score += ok; total += forms.length;
      const r = results[task.verb.id] || (results[task.verb.id] = { ok: 0, total: 0, uz: task.verb.uz });
      r.ok += ok; r.total += forms.length;
      haptic(ok === forms.length ? 'success' : 'error');
      fb.replaceChildren(h('div', { class: `feedback show ${ok === forms.length ? 'good' : ok >= 4 ? 'good' : 'bad'}` },
        h('b', {}, t('tableScore', ok, forms.length))));
      btn.textContent = t('next');
    };
    const btn = h('button', { class: 'btn btn-big', type: 'button', onClick: check }, t('check'));
    const morph = morphs[task.verb.id];
    const rows = forms.map((f, k) => ({ label: PERSONS[k], text: `${f} — ${formTranslation(morph, task.tense.id, task.neg, k, trLang())}` }));
    let focused = inputs[0];
    inputs.forEach((inp) => inp.addEventListener('focus', () => { focused = inp; }));
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((i / list.length) * 100)}%` } })),
        h('span', { class: 'counter' }, `${i + 1}/${list.length}`)),
      h('div', { class: 'label' }, t('tableTask')),
      h('div', { class: 'card ex-card' },
        flagButton(() => reportSheet({ word: task.verb, kind: 'conj', item: `${task.tense.id}${task.neg ? ':neg' : ''}`, title: tenseName(task.tense), rows })),
        h('div', { class: 'prompt' },
          h('div', { class: 'word-uz' }, task.verb.uz), h('div', { class: 'muted' }, task.verb.ru),
          h('div', { class: 'conj-ask' },
            h('span', { class: 'chip accent' }, tenseName(task.tense)),
            h('span', { class: `chip ${task.neg ? 'err-chip' : ''}` }, task.neg ? t('conjNeg') : t('conjPos')))),
        h('div', { class: 'tbl' }, forms.map((f, k) => h('div', { class: 'tbl-row' },
          h('span', { class: 'conj-p' }, PERSONS[k]),
          h('b', { class: 'tbl-root' }, root),
          inputs[k],
          fixes[k],
          h('div', { class: 'conj-tr tbl-tr' }, formTranslation(morph, task.tense.id, task.neg, k, trLang()))))),
        h('div', { class: 'helper-row' }, ['oʻ', 'gʻ', 'ʼ'].map((s) =>
          h('button', { class: 'chip-btn', type: 'button', onClick: () => { focused.value += s; focused.focus(); } }, s))),
        fb, btn),
      h('p', { class: 'tiny muted' }, t('tableHint'))));
    setTimeout(() => inputs[0].focus(), 50);
  };
  show();
}

export { acceptedForms };
