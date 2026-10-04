// Вкладка «Путь»: карта тем от Ташкента (A1) до Хивы (B2), пунктирный маршрут, ворота-тесты между уровнями.
import { rpc } from '../api.js';
import { t, getLang, formatDate } from '../i18n.js';
import { h, mount, spinner, sheet, ring, haptic } from '../ui.js';
import { icon, art, DECOR, CITY_ART } from '../icons.js';
import { allowed, lockedSheet } from './home.js';

const LEVELS = ['A1', 'A2', 'B1', 'B2'];
const PREV = { A2: 'A1', B1: 'A2', B2: 'B1' };
const NS = 'http://www.w3.org/2000/svg';
const STEP = 112;       // расстояние между темами по вертикали
const CITY_H = 108;
const GATE_H = 84;

function topicName(tp) {
  const lang = getLang();
  const name = ((lang === 'uz' && tp.name_uz) || (lang === 'en' && tp.name_en) || tp.name || '')
    .replace(/^(Soʻzlashuv nutqi\. |Spoken: )/, '');
  return name.charAt(0).toUpperCase() + name.slice(1);
}

export async function renderPath(app) {
  mount(spinner(t('loading')));
  const data = await rpc('get_path');
  const levels = Object.fromEntries((data.levels || []).map((l) => [l.cefr, l]));
  const topics = data.topics || [];
  const current = topics.find((tp) => !tp.locked && tp.started < tp.total);

  const wrap = h('div', { class: 'path-wrap' });
  const screen = h('div', { class: 'screen' },
    h('div', { class: 'path-head' },
      h('div', {}, h('h1', {}, t('pathTitle')), h('p', { class: 'muted small' }, t('pathSub'))),
      h('span', { class: 'chip accent' }, icon('map'), t('levelChip', data.unlocked))),
    wrap);
  mount(screen);

  // ---------------------------------------------------------------- раскладка (зависит от ширины экрана)
  let currentY = 0;
  function layout() {
    const W = wrap.clientWidth || 360;
    const cx = W / 2;
    const amp = Math.min(W * 0.27, 120);
    const els = [];
    const points = [];          // точки маршрута
    let doneUntil = 0;          // сколько точек маршрута «пройдено»
    let y = 20;
    let k = 0;                  // сквозной номер темы — для формы извилины
    let decorN = 0;

    for (const cefr of LEVELS) {
      const lv = levels[cefr] || {};
      const lvTopics = topics.filter((tp) => tp.cefr === cefr);
      if (!lvTopics.length) continue;

      // город-уровень
      const cityLocked = lv.state === 'locked';
      els.push(h('div', { class: `city ${cityLocked ? 'locked' : ''}`, style: { top: `${y}px`, height: `${CITY_H}px` } },
        art(CITY_ART[cefr]),
        h('div', {},
          h('div', { class: 'city-name' }, t(`city${cefr}`)),
          h('div', { class: 'muted small' }, `${cefr} · ${t(`levelName${cefr}`)}`),
          h('div', { class: 'tiny muted' }, t('topicWords', lv.started || 0, lv.total || 0)))));
      points.push([cx, y + CITY_H / 2]);
      if (lv.state !== 'locked') doneUntil = points.length;
      y += CITY_H + 70;

      lvTopics.forEach((tp, i) => {
        const x = cx + amp * Math.sin(k * 0.9 + 0.6);
        const isCurrent = current && tp.key === current.key;
        const state = tp.locked ? 'locked' : tp.started >= tp.total ? 'done' : isCurrent ? 'current' : tp.started > 0 ? 'started' : '';
        const node = h('button', { class: `node ${state}`, type: 'button', style: { left: `${x}px`, top: `${y}px` },
          'aria-label': topicName(tp), onClick: () => { haptic(); topicSheet(tp); } },
          state === 'done' || state === 'locked' ? null : ring(tp.started / tp.total, isCurrent ? 76 : 64),
          state === 'done' ? icon('check') : state === 'locked' ? icon('lock') : h('span', { class: 'n' }, String(i + 1)),
          tp.colloquial ? h('span', { class: 'colloq-badge', title: t('colloquial') }, icon('chat')) : null);
        els.push(node);
        if (isCurrent) {
          currentY = y;
          els.push(h('div', { class: 'here', style: { left: `${x}px`, top: `${y - 44}px` } }, t('youAreHere')));
        }
        // подпись — с той стороны, где больше места
        const left = x > cx;
        const half = isCurrent ? 46 : 40;
        const width = Math.max(90, Math.min(140, left ? x - half - 10 : W - x - half - 10));
        els.push(h('div', { class: `node-label ${left ? 'left' : ''}`,
          style: { top: `${y - 18}px`, width: `${width}px`, left: left ? `${x - half - width}px` : `${x + half}px` } },
          h('div', {}, topicName(tp)),
          h('div', { class: 'muted' }, `${tp.started}/${tp.total}`)));
        points.push([x, y]);
        if (tp.started > 0 || isCurrent) doneUntil = points.length;

        // украшение между темами — с противоположной от маршрута стороны
        if (k % 3 === 1 && i < lvTopics.length - 1) {
          const midX = cx + amp * Math.sin((k + 0.5) * 0.9 + 0.6);
          const onLeft = midX > cx;
          const name = DECOR[decorN++ % DECOR.length];
          const d = art(name, 'art decor');
          d.style.top = `${y + STEP / 2 - 31}px`;
          d.style.left = onLeft ? '14px' : `${W - 76}px`;
          els.push(d);
        }
        y += STEP;
        k++;
      });

      // ворота: тест уровня
      y += 10;
      const gateState = lv.state === 'passed' ? 'passed' : lv.state === 'current' ? 'current' : 'locked';
      const sub = gateState === 'passed' ? `${t('gatePassed')}${lv.best_score != null ? ` · ${lv.best_score}/${lv.best_total}` : ''}`
        : gateState === 'locked' ? t('gateLocked')
        : lv.retry_at ? t('gateRetry', formatDate(lv.retry_at)) : t('gateOpen');
      els.push(h('button', { class: `gate ${gateState}`, type: 'button', style: { top: `${y}px`, height: `${GATE_H}px` },
        onClick: () => { haptic(); gateTap(cefr, gateState); } },
        art('gate'),
        h('div', {}, h('b', {}, t('gateTitle', cefr)), h('div', { class: 'small muted' }, sub))));
      points.push([cx, y + GATE_H / 2]);
      if (gateState === 'passed') doneUntil = points.length;
      y += GATE_H + 80;
    }

    // финиш
    const allDone = levels.B2 && levels.B2.state === 'passed';
    els.push(h('div', { class: 'finish', style: { top: `${y - 30}px` } },
      art('suzani'), h('h3', {}, t('finishTitle')), h('p', { class: 'muted small' }, allDone ? t('finishDone') : t('finishText'))));
    points.push([cx, y - 30]);
    y += 140;

    // маршрут: сглаженная кривая через все точки
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('class', 'path-svg');
    svg.setAttribute('width', W);
    svg.setAttribute('height', y);
    svg.setAttribute('viewBox', `0 0 ${W} ${y}`);
    // пройденная и оставшаяся части — разные отрезки одной кривой (без наложения)
    const line = (from, to, cls) => {
      const p = document.createElementNS(NS, 'path');
      p.setAttribute('class', cls);
      p.setAttribute('d', smooth(points, from, to));
      return p;
    };
    const split = Math.max(0, doneUntil - 1);
    if (split > 0) svg.append(line(0, split, 'path-line done'));
    if (split < points.length - 1) svg.append(line(split, points.length - 1, 'path-line'));

    wrap.style.height = `${y}px`;
    wrap.replaceChildren(svg, ...els);
  }

  // ---------------------------------------------------------------- шторки
  function topicSheet(tp) {
    const canChoose = allowed(data, 'topic_choice');
    const close = sheet(
      h('div', { class: 'label' }, `${tp.cefr} · ${t(`city${tp.cefr}`)}`),
      h('h3', {}, topicName(tp)),
      tp.colloquial ? h('p', { class: 'small' }, h('span', { class: 'chip gold' }, t('colloquial')), ' ', t('colloquialTopicHint')) : null,
      h('p', { class: 'muted' }, t('topicWords', tp.started, tp.total), ' · ', t('topicLearned', tp.learned)),
      h('div', { class: 'track' },
        h('div', { class: 'fill', style: { width: `${Math.round((tp.started / tp.total) * 100)}%` } }),
        h('div', { class: 'fill strong', style: { width: `${Math.round((tp.learned / tp.total) * 100)}%` } })),
      tp.locked ? h('p', { class: 'muted' }, t('topicLocked', PREV[tp.cefr] || 'A1'))
        : tp.started >= tp.total ? h('p', { class: 'muted' }, t('topicDone'))
        : h('button', { class: 'btn btn-big', onClick: () => {
            close();
            if (!canChoose) return lockedSheet(app, data.features.topic_choice.min_tier);
            app.go('learn', { mode: 'normal', topicId: tp.id });
          } }, icon('learn'), t('learnTopic')),
      !tp.locked && tp.learned < tp.total
        ? h('button', { class: 'btn btn-secondary', onClick: () => {
            close();
            app.go('wordcheck', { mode: 'topic', topicId: tp.id, topicName: topicName(tp) });
          } }, icon('sparkle'), t('checkTopicBtn'))
        : null,
      !tp.locked && tp.learned < tp.total ? h('p', { class: 'tiny muted' }, t('checkTopicHint')) : null,
      h('button', { class: 'btn btn-ghost topic-words', type: 'button', onClick: () => {
        close();
        app.go('dictionary', { topicId: tp.id, topicName: topicName(tp) });
      } }, icon('dictionary'), t('topicWordsBtn')));
  }

  function gateTap(cefr, state) {
    if (state === 'current') return app.go('test', { cefr });
    const lv = levels[cefr] || {};
    sheet(
      h('div', { class: 'row' }, art('gate'), h('h3', {}, t('gateTitle', cefr))),
      state === 'passed'
        ? h('p', {}, `${t('gatePassed')}: ${lv.best_score}/${lv.best_total}${lv.passed_at ? ` · ${formatDate(lv.passed_at)}` : ''}`)
        : h('p', { class: 'muted' }, t('topicLocked', PREV[cefr] || 'A1')));
  }

  layout();
  const onResize = () => { const sy = window.scrollY; layout(); window.scrollTo(0, sy); };
  window.addEventListener('resize', onResize);
  app.cleanup = () => window.removeEventListener('resize', onResize);
  if (currentY) window.scrollTo(0, Math.max(0, wrap.offsetTop + currentY - window.innerHeight / 2));
}

// Кривая Катмулла — Рома → кубические Безье: плавный маршрут через все точки
// from/to — номера точек: часть кривой с теми же изгибами, что и у всей линии
function smooth(pts, from = 0, to = pts.length - 1) {
  if (to - from < 1) return '';
  let d = `M${pts[from][0].toFixed(1)},${pts[from][1].toFixed(1)}`;
  for (let i = from; i < to; i++) {
    const p0 = pts[i - 1] || pts[i];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[i + 2] || p2;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C${c1[0].toFixed(1)},${c1[1].toFixed(1)} ${c2[0].toFixed(1)},${c2[1].toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
  }
  return d;
}
