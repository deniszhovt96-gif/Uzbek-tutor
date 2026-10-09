// «Как образуется форма»: таблицы для тем грамматики — по каждому лицу и числу
// корень + суффикс + окончание = форма, на двух глаголах (основа на согласный и на гласный).
// Формы берутся из uzmorph.js, поэтому таблицы всегда совпадают с упражнениями.
import { t, getLang } from './i18n.js';
import { h } from './ui.js';
import { conjugate, decline, acceptedForms, PERSONS, CASES } from './uzmorph.js';

// тема грамматики (№) → какие таблицы показать
const TOPIC_TABLES = {
  3: [['pres_fut', false]], 5: [['past_def', false]], 6: [['past_indef', false]],
  7: [['pres_cont', false], ['pres_moqda', false]], 8: [['pres_fut', true], ['past_def', true]],
  16: [['imper', false], ['imper', true]], 21: [['fut_pres', false]], 22: [['fut_intent', false]],
  23: [['cond', false]], 24: [['wish', false], ['unreal', false]],
  25: [['past_cont', false], ['past_habit', false], ['past_perf', false]], 26: [['can', false]],
  9: 'cases', 10: 'poss', 11: 'plural', 27: 'overview',
};
const EX = ['bormoq', 'oʻqimoq'];           // основа на согласный / на гласный
const PERS_RU = ['я', 'ты', 'он, она', 'мы', 'вы', 'они'];
const PERS_EN = ['I', 'you', 'he, she', 'we', 'you (pl.)', 'they'];
// личные окончания по временам (men, sen, u, biz, siz, ular)
const E_PRES = ['man', 'san', 'di', 'miz', 'siz', 'di'];
const E_PROG = ['man', 'san', 'ti', 'miz', 'siz', 'ti'];
const E_PRED = ['man', 'san', '', 'miz', 'siz', ''];
const E_POSS = ['m', 'ng', '', 'k', 'ngiz', ''];
const TENSE_END = { pres_fut: E_PRES, past_narr: E_PRES, pres_cont: E_PROG, pres_moqda: E_PRED, past_indef: E_PRED,
  fut_pres: E_PRED, fut_intent: E_PRED, past_def: E_POSS, cond: E_POSS, wish: E_POSS, can: E_PRES };

// bor + a + man: разбор формы на корень, суффикс времени и личное окончание
function split(form, stem, tenseId, i) {
  const f = acceptedForms(form)[0];
  if (!f.startsWith(stem)) return { root: '', suf: f, end: '' };
  let rest = f.slice(stem.length);
  let aux = '';
  const sp = rest.indexOf(' ');
  if (tenseId === 'can') {                       // bor + a ol + aman
    const k = rest.lastIndexOf('ol');
    return { root: stem, suf: rest.slice(0, k + 2), end: rest.slice(k + 2) };
  }
  if (tenseId === 'imper') return { root: stem, suf: '', end: rest };
  if (sp >= 0) { aux = rest.slice(sp); rest = rest.slice(0, sp); }   // вспомогательное слово (edi, boʻlardi, emas)
  const endings = TENSE_END[tenseId];
  const e = endings ? endings[i] : '';
  if (e && rest.endsWith(e) && rest.length > e.length) return { root: stem, suf: rest.slice(0, -e.length), end: e + aux };
  return { root: stem, suf: rest, end: aux };
}

const piece = (txt, cls) => (txt ? h('span', { class: cls }, txt.trim()) : null);
const plus = () => h('span', { class: 'gf-plus' }, '+');
function formula(p) {
  const parts = [piece(p.root, 'gf-root'), piece(p.suf, 'gf-suf'), piece(p.end, 'gf-end')].filter(Boolean);
  return parts.flatMap((x, i) => (i ? [plus(), x] : [x]));
}

function tenseTable(tenseId, neg) {
  const vs = EX.map((v) => conjugate(v));
  const tn = vs.map((c) => c.tenses.find((x) => x.id === tenseId));
  const name = getLang() === 'uz' ? tn[0].uz : getLang() === 'en' ? tn[0].en : tn[0].ru;
  const pers = getLang() === 'en' ? PERS_EN : PERS_RU;
  return h('div', { class: 'gf-card' },
    h('div', { class: 'gf-title' }, `${name}${neg ? ` · ${t('conjNeg').toLowerCase()}` : ''}`),
    h('div', { class: 'gf-sub muted' }, `${tn[0].uz} · ${tn[0].aff}`),
    h('div', { class: 'gf-legend' }, h('span', { class: 'gf-root' }, t('gfRoot')), plus(), h('span', { class: 'gf-suf' }, t('gfSuf')), plus(),
      h('span', { class: 'gf-end' }, t('gfEnd'))),
    h('table', { class: 'gf-table' },
      h('thead', {}, h('tr', {}, h('th', {}, t('gfPerson')), ...EX.map((v) => h('th', {}, v)))),
      h('tbody', {}, PERSONS.map((p, i) => h('tr', {},
        h('td', { class: 'gf-p' }, h('b', {}, p), h('div', { class: 'tiny muted' }, pers[i])),
        ...tn.map((x, k) => {
          const cell = (neg ? x.neg : x.pos)[i];
          const stem = vs[k].prefix + vs[k].stem;
          return h('td', {}, h('div', { class: 'gf-formula' }, formula(split(cell, stem, tenseId, i))), h('div', { class: 'gf-result' }, cell));
        }))))));
}

function casesTable(kind) {
  const words = ['kitob', 'bola', 'yurak'];
  const ds = words.map((w) => decline(w));
  const col = kind === 'plural' ? 'pl' : 'sg';
  const hint = { nom: '—', gen: '-ning', acc: '-ni', dat: '-ga / -ka / -qa', loc: '-da', abl: '-dan' };
  return h('div', { class: 'gf-card' },
    h('div', { class: 'gf-title' }, kind === 'plural' ? t('gfPluralTitle') : t('gfCasesTitle')),
    h('div', { class: 'gf-legend' }, h('span', { class: 'gf-root' }, t('gfWord')), plus(),
      kind === 'plural' ? [h('span', { class: 'gf-suf' }, '-lar'), plus()] : null, h('span', { class: 'gf-end' }, t('gfCaseEnd'))),
    h('table', { class: 'gf-table' },
      h('thead', {}, h('tr', {}, h('th', {}, t('gfCase')), h('th', {}, t('gfEnding')), ...words.map((w) => h('th', {}, w)))),
      h('tbody', {}, CASES.map((cs, i) => h('tr', {},
        h('td', { class: 'gf-p' }, h('b', {}, cs.uz.split(' ')[0]), h('div', { class: 'tiny muted' }, cs.q)),
        h('td', {}, h('span', { class: 'gf-end' }, kind === 'plural' ? `-lar${hint[cs.id] === '—' ? '' : hint[cs.id].replace(' / -ka / -qa', '')}` : hint[cs.id])),
        ...ds.map((d, k) => {
          const f = d.columns.find((c) => c.id === col).forms[i];
          return h('td', {}, h('div', { class: 'gf-formula' }, formula({ root: words[k], suf: kind === 'plural' ? 'lar' : '', end: f.slice(words[k].length + (kind === 'plural' ? 3 : 0)) })),
            h('div', { class: 'gf-result' }, f));
        }))))));
}

function possTable() {
  const words = ['kitob', 'bola', 'oʻgʻil'];
  const ds = words.map((w) => decline(w));
  const pers = getLang() === 'en' ? ['my', 'your', 'his/her', 'our', 'your (pl.)', 'their'] : ['мой', 'твой', 'его, её', 'наш', 'ваш', 'их'];
  const ends = ['-(i)m', '-(i)ng', '-(s)i', '-(i)miz', '-(i)ngiz', '-(s)i'];
  return h('div', { class: 'gf-card' },
    h('div', { class: 'gf-title' }, t('gfPossTitle')),
    h('div', { class: 'gf-legend' }, h('span', { class: 'gf-root' }, t('gfWord')), plus(), h('span', { class: 'gf-end' }, t('gfPossEnd'))),
    h('table', { class: 'gf-table' },
      h('thead', {}, h('tr', {}, h('th', {}, t('gfPerson')), h('th', {}, t('gfEnding')), ...words.map((w) => h('th', {}, w)))),
      h('tbody', {}, PERSONS.map((p, i) => h('tr', {},
        h('td', { class: 'gf-p' }, h('b', {}, p), h('div', { class: 'tiny muted' }, pers[i])),
        h('td', {}, h('span', { class: 'gf-end' }, ends[i])),
        ...ds.map((d) => h('td', {}, h('div', { class: 'gf-result' }, d.columns.find((c) => c.id === `poss${i}`).forms[0]))))))),
    h('p', { class: 'tiny muted' }, t('gfPossNote')));
}

function overviewTable() {
  const c = conjugate('bormoq');
  return h('div', { class: 'gf-card' },
    h('div', { class: 'gf-title' }, t('gfOverview')),
    h('table', { class: 'gf-table' },
      h('thead', {}, h('tr', {}, h('th', {}, t('gfTense')), h('th', {}, t('gfSuffix')), h('th', {}, 'men'), h('th', {}, 'u'))),
      h('tbody', {}, c.tenses.map((tn) => h('tr', {},
        h('td', { class: 'gf-p' }, h('b', {}, getLang() === 'uz' ? tn.uz : getLang() === 'en' ? tn.en : tn.ru)),
        h('td', {}, h('span', { class: 'gf-suf' }, tn.aff)),
        h('td', {}, h('div', { class: 'gf-result' }, tn.pos[0])),
        h('td', {}, h('div', { class: 'gf-result' }, acceptedForms(tn.pos[2])[0])))))));
}

// Блок для страницы темы грамматики (или null, если у темы нет таблиц)
export function grammarFormsBlock(unit) {
  if (!unit || unit.course_id !== 'grammar') return null;
  const spec = TOPIC_TABLES[unit.n];
  if (!spec) return null;
  let tables;
  if (spec === 'cases' || spec === 'plural') tables = [casesTable(spec)];
  else if (spec === 'poss') tables = [possTable()];
  else if (spec === 'overview') tables = [overviewTable()];
  else tables = spec.map(([id, neg]) => tenseTable(id, neg));
  return h('div', {}, h('h2', {}, t('gfTitle')), h('p', { class: 'small muted' }, t('gfHint')), tables);
}
