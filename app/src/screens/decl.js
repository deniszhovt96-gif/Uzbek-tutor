// Склонение существительных: список по уровням, таблица падежей (ед., мн., притяжательные) с подсказками
// перевода и упражнение «допишите окончания» со своим уровнем (decl). Столбцы открываются по темам
// грамматики: падежи (9), множественное число (11), притяжательные аффиксы (10).
import { rpc } from '../api.js';
import { t, getLang } from '../i18n.js';
import { h, mount, spinner, sheet, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { decline, CASES } from '../uzmorph.js';
import { CASE_MEANING, POSS_MEANING } from '../verbtr.js';
import { displayUz } from '../normalize.js';
import { openColumns, commonRoot, cellOk, reportSheet, flagButton, stableRedraw } from '../morph.js';

const CEFRS = ['A1', 'A2', 'B1', 'B2'];
const CASE_SHORT = ['Bosh', 'Qaratqich', 'Tushum', 'Joʻnalish', 'Oʻrin-payt', 'Chiqish'];
const COL_LABEL = { sg: () => t('declSg'), pl: () => t('declPl'), poss0: () => 'mening', poss1: () => 'sening', poss2: () => 'uning',
  poss3: () => 'bizning', poss4: () => 'sizning', poss5: () => 'ularning' };
const meaning = (v) => (getLang() === 'en' && v.e ? v.e : v.r);

// Подсказка перевода для строки (падежа) столбца
const POSS_RU = { m: ['мой', 'твой', 'его / её', 'наш', 'ваш', 'их'], f: ['моя', 'твоя', 'его / её', 'наша', 'ваша', 'их'],
  n: ['моё', 'твоё', 'его / её', 'наше', 'ваше', 'их'] };
export function caseHint(morph, enWord, colId, caseIdx) {
  const L = getLang() === 'en' ? 'en' : 'ru';
  const cs = CASES[caseIdx].id;
  if (L === 'en') {
    const w = enWord ? String(enWord).split(/[,;(]/)[0].trim() : '';
    if (!w) return CASE_MEANING.en[cs];
    const base = colId === 'sg' ? `the ${w}` : colId === 'pl' ? `the ${w}s` : `${POSS_MEANING.en[Number(colId.slice(4))]} ${w}`;
    return { nom: base, gen: `of ${base}`, acc: `${base} (object)`, dat: `to ${base}`, loc: `in / at ${base}`, abl: `from ${base}` }[cs];
  }
  const r = morph && morph.ru;
  if (!r) return CASE_MEANING.ru[cs];
  if (colId === 'sg' || colId === 'pl') {
    const f = colId === 'sg' ? r.sg : r.pl;     // им, род, вин, дат, пр
    return { nom: f[0], gen: `${f[1]} (чей? чего?)`, acc: f[2], dat: `к ${f[3]} / куда?`, loc: `в ${f[4]} / у…`, abl: `из ${f[1]} / от…` }[cs];
  }
  const pi = Number(colId.slice(4));
  const pron = (POSS_RU[r.g] || POSS_RU.m)[pi];
  return caseIdx === 0 ? `${pron} ${r.sg[0]}` : `${CASE_MEANING.ru[cs].split(':')[1].trim()} (${pron} ${r.sg[0]})`;
}

function declTable(noun, morph, col) {
  const d = decline(noun.uz);
  const c = d.columns.find((x) => x.id === col);
  const rows = CASES.map((cs, i) => ({ label: cs.uz, text: `${c.forms[i]} — ${caseHint(morph, noun.en, col, i)}` }));
  return h('div', { class: 'conj-card decl-card' },
    flagButton(() => reportSheet({ word: noun, kind: 'decl', item: col, title: COL_LABEL[col](), rows })),
    CASES.map((cs, i) => h('div', { class: 'conj-row' },
      h('span', { class: 'conj-p' }, h('span', {}, cs.uz), h('span', { class: 'tiny muted' }, ` ${cs.q}`)),
      h('div', { class: 'conj-cell right' }, h('b', {}, c.forms[i]), h('div', { class: 'conj-tr' }, caseHint(morph, noun.en, col, i))))),
    h('p', { class: 'tiny muted' }, t('declNote')));
}

function colSeg(cols, cur, onPick) {
  return h('div', { class: 'segmented scroll' }, cols.map((id) => h('button', { type: 'button', class: id === cur ? 'active' : '',
    onClick: () => { haptic(); onPick(id); } }, COL_LABEL[id]())));
}

// Шторка со склонением (из карточки слова и словаря)
export async function declSheet(noun, app) {
  const d = decline(noun.uz);
  if (!d) return;
  const morph = (await rpc('get_morph', { p_ids: [noun.id] }).catch(() => ({})))[noun.id];
  let col = 'sg';
  const box = h('div', {});
  const draw = stableRedraw(box, () => h('div', {}, colSeg(d.columns.map((x) => x.id), col, (c) => { if (c === col) return; col = c; draw(); }), declTable(noun, morph, col)));
  draw();
  const close = sheet(h('div', { class: 'label' }, t('declTitle')), h('h3', {}, noun.uz, h('span', { class: 'muted' }, ` — ${noun.ru}`)),
    app ? h('button', { class: 'btn btn-big', type: 'button', onClick: () => { close(); app.go('decl', { noun }); } }, icon('practice'), t('declOpenNoun')) : null,
    box);
}

// ---------------------------------------------------------------- экран «Склонение»
export async function renderDecl(app, params = {}) {
  if (params.noun) return renderNoun(app, params.noun);
  if (params.train) return declTraining(app, params.train);
  mount(spinner(t('loading')));
  const data = await rpc('get_nouns');
  const nouns = (data.nouns || []).filter((n) => decline(n.u));
  const open = openColumns(data.state || {});
  let q = '';
  const list = h('div', {});
  const pill = (label, value, cls = '') => h('span', { class: `lvl-pill ${cls} ${value == null ? 'empty' : ''}` }, `${label} ${value == null ? '—' : value}`);
  const draw = () => {
    const ql = q.toLowerCase();
    const rows = q ? nouns.filter((v) => v.u.toLowerCase().includes(ql) || (v.r || '').toLowerCase().includes(ql) || (v.e || '').toLowerCase().includes(ql)) : nouns;
    list.replaceChildren(...CEFRS.map((cefr) => {
      const lv = rows.filter((v) => v.c === cefr).slice(0, q ? 200 : 400);
      if (!lv.length) return null;
      return h('div', {},
        h('div', { class: 'lv-head' }, h('b', {}, cefr), h('span', { class: 'muted small' }, t('nNouns', rows.filter((v) => v.c === cefr).length))),
        h('div', { class: 'card dict-card' }, lv.map((v) => h('button', { class: 'dict-row', type: 'button',
          onClick: () => app.go('decl', { noun: { id: v.i, uz: v.u, ru: meaning(v), en: v.e } }) },
          h('div', { class: 'dict-main' }, h('b', {}, v.u), h('div', { class: 'small muted' }, meaning(v)),
            v.l != null || v.d != null ? h('div', { class: 'pill-row' }, pill(t('lvWord'), v.l), pill(t('lvDecl'), v.d, 'gold')) : null),
          icon('chevron', 'ic chev')))));
    }));
  };
  const search = h('input', { class: 'answer-input dict-search', type: 'search', placeholder: t('dictSearch'),
    onInput: () => { q = search.value.trim(); draw(); } });
  draw();
  const mine = nouns.filter((v) => v.l != null)
    .sort((a, b) => (b.dd ? 1 : 0) - (a.dd ? 1 : 0) || (a.d ?? -1) - (b.d ?? -1))
    .slice(0, 3).map((v) => ({ id: v.i, uz: v.u, ru: meaning(v), en: v.e }));
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('declTitle')),
    h('p', { class: 'muted small' }, t('declSub')),
    h('div', { class: 'card note' }, icon('grammar'),
      h('div', { class: 'small' }, open.none ? t('declOpenNone') : t('declOpenCols', open.cols.length > 2, open.cols.includes('pl')),
        h('div', { class: 'tiny muted' }, t('declCap', (data.state && data.state.decl_cap) || 1)))),
    h('button', { class: 'btn btn-big', type: 'button', onClick: () => app.go('decl', { train: mine }) }, icon('practice'), t('trainDecl')),
    search, list));
}

async function renderNoun(app, noun) {
  mount(spinner(t('loading')));
  const [morphs, data] = await Promise.all([rpc('get_morph', { p_ids: [noun.id] }).catch(() => ({})), rpc('get_nouns').catch(() => ({}))]);
  const morph = morphs[noun.id];
  const me = (data.nouns || []).find((v) => v.i === noun.id) || {};
  const d = decline(noun.uz);
  let col = 'sg';
  const box = h('div', {});
  const draw = stableRedraw(box, () => h('div', {}, colSeg(d.columns.map((x) => x.id), col, (c) => { if (c === col) return; col = c; draw(); }), declTable(noun, morph, col)));
  draw();
  mount(h('div', { class: 'screen' },
    h('div', { class: 'label' }, t('declTitle')),
    h('h1', {}, noun.uz), h('p', { class: 'muted' }, noun.ru),
    h('div', { class: 'pill-row' },
      h('span', { class: `lvl-pill ${me.l == null ? 'empty' : ''}` }, `${t('lvWord')} ${me.l ?? '—'}`),
      h('span', { class: `lvl-pill gold ${me.d == null ? 'empty' : ''}` }, `${t('lvDecl')} ${me.d ?? '—'}`)),
    h('button', { class: 'btn btn-big', type: 'button', onClick: () => app.go('decl', { train: [noun] }) }, icon('practice'), t('trainDeclThis')),
    box));
}

// ---------------------------------------------------------------- упражнение: допишите окончания
async function declTraining(app, nouns) {
  mount(spinner(t('loading')));
  const data = await rpc('get_nouns');
  const open = openColumns(data.state || {});
  const list0 = (nouns || []).filter((n) => decline(n.uz));
  if (!list0.length) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('practice'), h('p', {}, t('declNoNouns')),
      h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
    return;
  }
  const morphs = await rpc('get_morph', { p_ids: list0.map((n) => n.id) }).catch(() => ({}));
  const tables = [];
  for (const n of list0) {
    let cols = open.cols;
    if (cols.length > 3) cols = ['sg', ...cols.filter((c) => c !== 'sg').sort(() => Math.random() - 0.5).slice(0, list0.length > 1 ? 1 : 3)];
    for (const c of cols) tables.push({ noun: n, col: c });
  }
  let i = 0;
  let score = 0;
  let total = 0;
  const results = {};
  const show = async () => {
    if (i >= tables.length) {
      const levels = [];
      for (const [id, r] of Object.entries(results)) {
        const res = await rpc('answer_morph', { p_word: Number(id), p_kind: 'decl', p_ok: r.ok, p_total: r.total }).catch(() => null);
        if (res && res.ok) levels.push(`${r.uz}: ${t('levelChange', res.prev, res.level)}`);
      }
      haptic('success');
      mount(h('div', { class: 'screen' },
        h('div', { class: 'card result-hero' }, h('div', { class: 'result-icon ok' }, icon('trophy')),
          h('h1', {}, t('tableDone')), h('div', { class: 'big' }, `${score}/${total}`),
          h('div', { class: 'small' }, levels.map((l) => h('div', {}, l)))),
        h('button', { class: 'btn btn-big', onClick: () => declTraining(app, nouns) }, t('again')),
        h('button', { class: 'btn btn-secondary', onClick: () => app.back() }, t('back'))));
      return;
    }
    const task = tables[i];
    const d = decline(task.noun.uz);
    const c = d.columns.find((x) => x.id === task.col);
    const root = commonRoot(c.forms, task.noun.uz);
    const morph = morphs[task.noun.id];
    let checked = false;
    // именительный падеж показан готовым — спрашиваем остальные 5
    const inputs = c.forms.map((f, k) => (k === 0 ? null : h('input', { class: 'tbl-inp', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', placeholder: '…' })));
    const ins = inputs.filter(Boolean);
    ins.forEach((inp, k) => inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') { if (ins[k + 1]) ins[k + 1].focus(); else check(); } }));
    let focused = ins[0];
    ins.forEach((inp) => inp.addEventListener('focus', () => { focused = inp; }));
    const fixes = c.forms.map(() => h('div', { class: 'tbl-fix' }));
    const fb = h('div', {});
    const check = () => {
      if (checked) { i++; show(); return; }
      checked = true;
      let ok = 0;
      inputs.forEach((inp, k) => {
        if (!inp) return;
        const good = cellOk(displayUz(inp.value.trim()), c.forms[k], root);
        inp.classList.add(good ? 'ok' : 'bad'); inp.disabled = true;
        if (good) ok++; else fixes[k].textContent = `→ ${c.forms[k]}`;
      });
      score += ok; total += 5;
      const r = results[task.noun.id] || (results[task.noun.id] = { ok: 0, total: 0, uz: task.noun.uz });
      r.ok += ok; r.total += 5;
      haptic(ok === 5 ? 'success' : 'error');
      fb.replaceChildren(h('div', { class: `feedback show ${ok >= 4 ? 'good' : 'bad'}` }, h('b', {}, t('tableScore', ok, 5))));
      btn.textContent = t('next');
    };
    const btn = h('button', { class: 'btn btn-big', type: 'button', onClick: check }, t('check'));
    const rows = CASES.map((cs, k) => ({ label: cs.uz, text: `${c.forms[k]} — ${caseHint(morph, task.noun.en, task.col, k)}` }));
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((i / tables.length) * 100)}%` } })),
        h('span', { class: 'counter' }, `${i + 1}/${tables.length}`)),
      h('div', { class: 'label' }, t('declTask')),
      h('div', { class: 'card ex-card' },
        flagButton(() => reportSheet({ word: task.noun, kind: 'decl', item: task.col, title: COL_LABEL[task.col](), rows })),
        h('div', { class: 'prompt' },
          h('div', { class: 'word-uz' }, task.noun.uz), h('div', { class: 'muted' }, task.noun.ru),
          h('div', { class: 'conj-ask' }, h('span', { class: 'chip accent' }, COL_LABEL[task.col]()))),
        h('div', { class: 'tbl decl-tbl' }, c.forms.map((f, k) => h('div', { class: 'tbl-row' },
          h('span', { class: 'conj-p decl-p' }, CASE_SHORT[k]),
          k === 0 ? h('b', { class: 'tbl-root' }, f) : h('b', { class: 'tbl-root' }, root),
          inputs[k] || h('span', {}),
          fixes[k],
          h('div', { class: 'conj-tr tbl-tr' }, caseHint(morph, task.noun.en, task.col, k))))),
        h('div', { class: 'helper-row' }, ['oʻ', 'gʻ', 'ʼ'].map((s) =>
          h('button', { class: 'chip-btn', type: 'button', onClick: () => { focused.value += s; focused.focus(); } }, s))),
        fb, btn),
      h('p', { class: 'tiny muted' }, t('tableHint'))));
    setTimeout(() => ins[0].focus(), 50);
  };
  show();
}
