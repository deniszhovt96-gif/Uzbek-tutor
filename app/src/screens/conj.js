// Спряжение и склонение: таблицы форм (как в справочниках спряжения) и тренировка.
// Формы строит uzmorph.js по правилам литературного языка — для любого глагола словаря.
import { rpc } from '../api.js';
import { t, getLang } from '../i18n.js';
import { h, mount, spinner, sheet, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { conjugate, decline, acceptedForms, isVerb, PERSONS, CASES } from '../uzmorph.js';
import { keyUz, displayUz } from '../normalize.js';

// ссылка на приложение для кнопок в шторках (шторки открываются из заданий, где app не передаётся)
let appRef = null;
export function setConjApp(a) { appRef = a; }

const GROUPS = ['indicative', 'imperative', 'conditional', 'ability', 'nonfinite'];
const tenseName = (tn) => (getLang() === 'uz' ? tn.uz : getLang() === 'en' ? tn.en || tn.uz : tn.ru || tn.uz);

// ---------------------------------------------------------------- таблицы спряжения (в экран или в шторку)
function conjTables(verb, state, redraw) {
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
    cards = c.tenses.filter((tn) => tn.group === state.group).map((tn) => h('div', { class: 'conj-card' },
      h('div', { class: 'conj-title' }, tenseName(tn)),
      h('div', { class: 'conj-sub muted' }, `${tn.uz} · ${tn.aff}`),
      (state.neg ? tn.neg : tn.pos).map((f, i) => h('div', { class: 'conj-row' },
        h('span', { class: 'conj-p' }, PERSONS[i]), h('b', {}, f)))));
  }
  return h('div', { class: 'conj' }, groupBar, polarity, h('div', { class: 'conj-grid' }, cards),
    h('p', { class: 'tiny muted' }, t('conjNote')));
}

// Шторка со спряжением — из карточки слова, задания, словаря
export function conjSheet(verb, app = appRef) {
  const state = { group: 'indicative', neg: false };
  const box = h('div', {});
  const redraw = () => box.replaceChildren(conjTables(verb, state, redraw));
  redraw();
  const close = sheet(
    h('div', { class: 'label' }, t('conjTitle')),
    h('h3', {}, verb.uz, h('span', { class: 'muted' }, ` — ${verb.ru}`)),
    box,
    app ? h('button', { class: 'btn btn-big', type: 'button', onClick: () => { close(); app.go('conj', { verb }); } }, icon('practice'), t('conjTrainThis')) : null);
}

// Шторка со склонением существительного
export function declSheet(noun, app = appRef) {
  const d = decline(noun.uz);
  if (!d) return;
  let col = 'sg';
  const box = h('div', {});
  const labels = { sg: t('declSg'), pl: t('declPl'), poss0: 'mening', poss1: 'sening', poss2: 'uning', poss3: 'bizning', poss4: 'sizning', poss5: 'ularning' };
  const draw = () => {
    const c = d.columns.find((x) => x.id === col);
    box.replaceChildren(
      h('div', { class: 'segmented scroll' }, d.columns.map((x) => h('button', { type: 'button', class: x.id === col ? 'active' : '',
        onClick: () => { col = x.id; haptic(); draw(); } }, labels[x.id]))),
      h('div', { class: 'conj-card decl-card' }, CASES.map((cs, i) => h('div', { class: 'conj-row' },
        h('span', { class: 'conj-p' }, h('span', {}, cs.uz), h('span', { class: 'tiny muted' }, ` ${cs.q}`)), h('b', {}, c.forms[i])))),
      h('p', { class: 'tiny muted' }, t('declNote')));
  };
  draw();
  sheet(h('div', { class: 'label' }, t('declTitle')), h('h3', {}, noun.uz, h('span', { class: 'muted' }, ` — ${noun.ru}`)), box);
}

export const canConjugate = (word) => word && isVerb(word.uz);
export const canDecline = (word) => word && !isVerb(word.uz) && decline(word.uz) && word.word_class !== 'phrase';

// ---------------------------------------------------------------- экран «Спряжение»: список глаголов → таблицы → тренировка
export async function renderConj(app, params = {}) {
  if (params.verb) return renderVerb(app, params.verb, params);
  mount(spinner(t('loading')));
  const data = await rpc('get_verbs');
  const verbs = (data.verbs || []).filter((v) => isVerb(v.u));
  let q = '';
  const list = h('div', { class: 'card dict-card' });
  const draw = () => {
    // точное совпадение — первым, затем начинающиеся с запроса, затем остальные
    const rank = (v) => { const u = v.u.toLowerCase(); const r = v.r.toLowerCase();
      return u === q || r === q ? 0 : u.startsWith(q) || r.startsWith(q) ? 1 : 2; };
    const rows = (q ? verbs.filter((v) => v.u.toLowerCase().includes(q) || v.r.toLowerCase().includes(q))
      .sort((a, b) => rank(a) - rank(b)) : verbs).slice(0, 200);
    list.replaceChildren(...rows.map((v) => h('button', { class: 'dict-row', type: 'button', onClick: () => app.go('conj', { verb: { id: v.i, uz: v.u, ru: v.r } }) },
      h('div', { class: 'dict-main' }, h('b', {}, v.u), h('div', { class: 'small muted' }, v.r)),
      v.l != null ? h('span', { class: 'lvl-pill' }, String(v.l)) : null)));
  };
  const search = h('input', { class: 'answer-input dict-search', type: 'search', placeholder: t('dictSearch'),
    onInput: () => { q = search.value.trim().toLowerCase(); draw(); } });
  draw();
  mount(h('div', { class: 'screen' },
    h('h1', {}, t('conjTitle')),
    h('p', { class: 'muted small' }, t('conjSub', verbs.length)),
    h('button', { class: 'btn btn-big', type: 'button', onClick: () => startTraining(app, verbs.filter((v) => v.l != null).slice(0, 80)) },
      icon('practice'), t('conjTrainMine')),
    search, list));
}

function renderVerb(app, verb, params) {
  const state = { group: params.group || 'indicative', neg: false };
  const box = h('div', {});
  const redraw = () => box.replaceChildren(conjTables(verb, state, redraw));
  redraw();
  mount(h('div', { class: 'screen' },
    h('div', { class: 'label' }, t('conjTitle')),
    h('h1', {}, verb.uz), h('p', { class: 'muted' }, verb.ru),
    h('button', { class: 'btn btn-big', type: 'button', onClick: () => startTraining(app, [{ i: verb.id, u: verb.uz, r: verb.ru }], state.group) },
      icon('practice'), t('conjTrainThis')),
    box));
}

// ---------------------------------------------------------------- тренировка: 10 форм
function startTraining(app, verbs, group) {
  const pool = verbs.length ? verbs : [];
  if (!pool.length) {
    mount(h('div', { class: 'screen' }, h('div', { class: 'card empty' }, icon('practice'), h('p', {}, t('conjNoVerbs')),
      h('button', { class: 'btn', onClick: () => app.back() }, t('back')))));
    return;
  }
  const N = 10;
  const tasks = [];
  for (let k = 0; k < N * 3 && tasks.length < N; k++) {
    const v = pool[Math.floor(Math.random() * pool.length)];
    const c = conjugate(v.u);
    if (!c) continue;
    const tenses = c.tenses.filter((tn) => !group || group === 'nonfinite' || tn.group === group);
    const tn = tenses[Math.floor(Math.random() * tenses.length)];
    const neg = Math.random() < 0.3;
    const p = Math.floor(Math.random() * 6);
    const cell = (neg ? tn.neg : tn.pos)[p];
    tasks.push({ verb: v, tense: tn, neg, person: p, cell, accept: acceptedForms(cell) });
  }
  let i = 0;
  let score = 0;
  const show = () => {
    if (i >= tasks.length) {
      haptic('success');
      mount(h('div', { class: 'screen' },
        h('div', { class: 'card result-hero' }, h('div', { class: 'result-icon ok' }, icon('trophy')),
          h('h1', {}, t('conjDone')), h('div', { class: 'big' }, `${score}/${tasks.length}`)),
        h('button', { class: 'btn btn-big', onClick: () => startTraining(app, verbs, group) }, t('again')),
        h('button', { class: 'btn btn-secondary', onClick: () => app.back() }, t('back'))));
      return;
    }
    const task = tasks[i];
    let done = false;
    const input = h('input', { class: 'answer-input', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
      placeholder: t('placeholderUz'), onKeydown: (e) => { if (e.key === 'Enter') check(); } });
    const fb = h('div', {});
    const check = () => {
      if (done) { i++; show(); return; }
      const val = displayUz(input.value.trim());
      if (!val) return;
      done = true;
      const ok = task.accept.some((a) => keyUz(a) === keyUz(val));
      if (ok) score++;
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
          h('div', { class: 'word-uz' }, task.verb.u), h('div', { class: 'muted' }, task.verb.r),
          h('div', { class: 'conj-ask' },
            h('span', { class: 'chip accent' }, tenseName(task.tense)),
            task.neg ? h('span', { class: 'chip err-chip' }, t('conjNeg')) : null,
            h('span', { class: 'chip' }, PERSONS[task.person]))),
        input,
        h('div', { class: 'helper-row' }, ['oʻ', 'gʻ', 'ʼ'].map((s) =>
          h('button', { class: 'chip-btn', type: 'button', onClick: () => { input.value += s; input.focus(); } }, s))),
        fb, btn)));
    setTimeout(() => input.focus(), 50);
  };
  show();
}
