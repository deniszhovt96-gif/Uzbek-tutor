// Диалог по ситуации: чтение (реплики, перевод по нажатию), заметка, слова диалога и упражнения:
// «следующая реплика», «пропущенное слово», «перевод реплики», «порядок реплик».
// Завершённые упражнения отмечают диалог пройденным — его слова встают в ближайшую очередь заучивания.
import { rpc } from '../api.js';
import { t, getLang } from '../i18n.js';
import { h, mount, haptic } from '../ui.js';
import { icon } from '../icons.js';
import { keyUz } from '../normalize.js';
import { pick, unitWords } from './course.js';

const shuffle = (a) => { const b = [...a]; for (let i = b.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [b[i], b[j]] = [b[j], b[i]]; } return b; };
const tr = (line) => (getLang() === 'en' ? line.en || line.ru : line.ru);

export function renderDialog(app, u) {
  const ex = u.extra || {};
  const lines = ex.lines || [];
  const speakers = ex.speakers || {};
  let showTr = false;
  const lineEls = lines.map((ln) => {
    const trEl = h('div', { class: 'dlg-tr' }, tr(ln));
    const el = h('button', { class: `dlg-line ${ln.who === 'A' ? 'a' : 'b'}`, type: 'button', onClick: () => el.classList.toggle('open') },
      h('div', { class: 'dlg-who' }, speakers[ln.who] || ln.who),
      h('div', { class: 'dlg-uz' }, ln.uz), trEl);
    return el;
  });
  const box = h('div', { class: 'dlg' }, lineEls);
  const trBtn = h('button', { class: 'btn btn-secondary btn-small', type: 'button', onClick: () => {
    showTr = !showTr; box.classList.toggle('all-open', showTr);
    trBtn.textContent = showTr ? t('dlgHideTr') : t('dlgShowTr');
  } }, t('dlgShowTr'));

  mount(h('div', { class: 'screen' },
    h('div', { class: 'row', style: { gap: '6px' } }, h('span', { class: 'chip' }, u.cefr || ''), u.section ? h('span', { class: 'chip accent' }, pick(u.section, 'title')) : null,
      u.read ? h('span', { class: 'chip gold' }, icon('check'), t('dlgDone')) : null),
    h('h1', { style: { marginTop: '12px' } }, pick(u, 'title')),
    h('div', { class: 'card express' }, h('p', {}, pick(u, 'express'))),
    h('div', { class: 'row', style: { justifyContent: 'space-between' } }, h('h2', {}, t('dlgRead')), trBtn),
    h('p', { class: 'tiny muted' }, t('dlgTapHint')),
    box,
    pick(u, 'detailed') ? h('div', { class: 'card note' }, icon('sparkle'), h('div', { class: 'small' }, pick(u, 'detailed'))) : null,
    unitWords(u),
    h('button', { class: 'btn btn-big', type: 'button', onClick: () => runExercises(app, u) }, icon('practice'), t('dlgPractice')),
    h('div', { class: 'unit-nav' },
      u.prev_id ? h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => app.replace('unit', { id: u.prev_id }) }, t('prevUnit')) : h('span', {}),
      u.next_id ? h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => app.replace('unit', { id: u.next_id }) }, t('nextUnit')) : h('span', {}))));
}

// ---------------------------------------------------------------- упражнения
function buildTasks(u) {
  const ex = u.extra || {};
  const lines = ex.lines || [];
  const vocab = (ex.vocab || []).map((v) => v.toLowerCase());
  const tasks = [];
  // 1) следующая реплика (2 задания)
  const idx = shuffle(lines.slice(0, -1).map((_, i) => i)).slice(0, 2);
  for (const i of idx) {
    const right = lines[i + 1];
    const wrong = shuffle(lines.filter((l, k) => k !== i + 1 && k !== i)).slice(0, 2);
    tasks.push({ kind: 'next', prompt: lines[i], answer: right.uz, options: shuffle([right.uz, ...wrong.map((w) => w.uz)]) });
  }
  // 2) пропущенное слово (2 задания): слово из лексики диалога или самое длинное слово реплики
  const used = new Set();
  for (const ln of shuffle(lines)) {
    if (tasks.filter((x) => x.kind === 'gap').length >= 2) break;
    const words = ln.uz.split(/\s+/);
    let k = words.findIndex((w) => vocab.some((v) => keyUz(w).startsWith(keyUz(v).slice(0, Math.max(3, keyUz(v).length - 3)))));
    if (k < 0) k = words.reduce((best, w, j) => (keyUz(w).length > keyUz(words[best]).length ? j : best), 0);
    const clean = words[k].replace(/[.,!?;:«»"]/g, '');
    if (clean.length < 3 || used.has(keyUz(clean))) continue;
    used.add(keyUz(clean));
    const pool = shuffle(lines.flatMap((l) => l.uz.split(/\s+/)).map((w) => w.replace(/[.,!?;:«»"]/g, ''))
      .filter((w) => w.length >= 3 && keyUz(w) !== keyUz(clean)));
    const distract = [...new Set(pool.map((w) => w))].slice(0, 3);
    const masked = words.map((w, j) => (j === k ? w.replace(clean, '_____') : w)).join(' ');
    tasks.push({ kind: 'gap', prompt: { ...ln, uz: masked }, answer: clean, options: shuffle([clean, ...distract]) });
  }
  // 3) перевод реплики (2 задания)
  for (const ln of shuffle(lines).slice(0, 2)) {
    const wrong = shuffle(lines.filter((l) => l !== ln)).slice(0, 2);
    tasks.push({ kind: 'translate', prompt: ln, answer: ln.uz, options: shuffle([ln.uz, ...wrong.map((w) => w.uz)]) });
  }
  // 4) порядок реплик (1 задание): 4 подряд идущие реплики
  if (lines.length >= 4) {
    const s = Math.floor(Math.random() * (lines.length - 3));
    tasks.push({ kind: 'order', seq: lines.slice(s, s + 4) });
  }
  return shuffle(tasks.filter((x) => x.kind !== 'order')).concat(tasks.filter((x) => x.kind === 'order'));
}

function runExercises(app, u) {
  const speakers = (u.extra && u.extra.speakers) || {};
  const tasks = buildTasks(u);
  let i = 0;
  let ok = 0;
  const show = () => {
    if (i >= tasks.length) return finish();
    const task = tasks[i];
    const fb = h('div', {});
    let answered = false;
    const next = h('button', { class: 'btn btn-big', type: 'button', style: { display: 'none' }, onClick: () => { i++; show(); } }, t('next'));
    const done = (good, right) => {
      answered = true;
      if (good) ok++;
      haptic(good ? 'success' : 'error');
      fb.replaceChildren(h('div', { class: `feedback show ${good ? 'good' : 'bad'}` }, h('b', {}, good ? t('correct') : t('wrong')),
        good || !right ? null : h('div', {}, t('rightAnswerIs'), ' ', h('b', {}, right))));
      next.style.display = '';
    };
    let body;
    const optBtns = (opts, answer) => h('div', { class: 'options' }, opts.map((o) => {
      const b = h('button', { class: 'option', type: 'button', onClick: () => {
        if (answered) return;
        const good = o === answer;
        b.classList.add(good ? 'right' : 'wrong');
        if (!good) [...b.parentNode.children].forEach((x) => { if (x.textContent === answer) x.classList.add('right'); });
        done(good, null);
      } }, o);
      return b;
    }));
    if (task.kind === 'next') {
      body = [h('div', { class: 'label' }, t('dlgNextQ')),
        h('div', { class: 'dlg-line a open' }, h('div', { class: 'dlg-who' }, speakers[task.prompt.who] || ''), h('div', { class: 'dlg-uz' }, task.prompt.uz),
          h('div', { class: 'dlg-tr' }, tr(task.prompt))),
        optBtns(task.options, task.answer)];
    } else if (task.kind === 'gap') {
      body = [h('div', { class: 'label' }, t('dlgGapQ')),
        h('div', { class: 'dlg-line a open' }, h('div', { class: 'dlg-uz' }, task.prompt.uz), h('div', { class: 'dlg-tr' }, tr(task.prompt))),
        optBtns(task.options, task.answer)];
    } else if (task.kind === 'translate') {
      body = [h('div', { class: 'label' }, t('dlgTrQ')),
        h('div', { class: 'card prompt-card' }, h('b', {}, tr(task.prompt))),
        optBtns(task.options, task.answer)];
    } else {
      // порядок: нажимайте реплики по порядку
      const picked = [];
      const order = shuffle(task.seq.map((_, k) => k));
      const area = h('div', { class: 'dlg' });
      const btns = order.map((k) => {
        const b = h('button', { class: 'option', type: 'button', onClick: () => {
          if (answered || picked.includes(k)) return;
          picked.push(k); b.disabled = true;
          area.append(h('div', { class: 'dlg-line a open' }, h('div', { class: 'dlg-uz' }, task.seq[k].uz)));
          if (picked.length === task.seq.length) {
            const good = picked.every((x, j) => x === j);
            done(good, good ? null : task.seq.map((l) => l.uz).join(' → '));
          }
        } }, task.seq[k].uz);
        return b;
      });
      body = [h('div', { class: 'label' }, t('dlgOrderQ')), area, h('div', { class: 'options' }, btns)];
    }
    mount(h('div', { class: 'screen session' },
      h('div', { class: 'session-top' },
        h('div', { class: 'progress' }, h('div', { class: 'bar', style: { width: `${Math.round((i / tasks.length) * 100)}%` } })),
        h('span', { class: 'counter' }, `${i + 1}/${tasks.length}`)),
      h('div', { class: 'card ex-card' }, body, fb, next)));
  };
  const finish = async () => {
    const passed = ok >= Math.ceil(tasks.length * 0.6);
    if (passed) await rpc('mark_unit', { p_unit: u.id, p_read: true }).catch(() => null);
    haptic('success');
    mount(h('div', { class: 'screen' },
      h('div', { class: 'card result-hero' }, h('div', { class: `result-icon ${passed ? 'ok' : ''}` }, icon(passed ? 'trophy' : 'dialog')),
        h('h1', {}, passed ? t('dlgPassed') : t('dlgTryAgain')), h('div', { class: 'big' }, `${ok}/${tasks.length}`),
        passed && (u.words || []).length ? h('p', { class: 'muted small' }, t('dlgWordsQueued', u.words.length)) : null),
      h('button', { class: 'btn btn-big', onClick: () => runExercises(app, u) }, t('again')),
      passed ? h('button', { class: 'btn', onClick: () => app.home() }, t('toHome')) : null,
      h('button', { class: 'btn btn-secondary', onClick: () => app.replace('unit', { id: u.id }) }, t('dlgBack'))));
  };
  show();
}
