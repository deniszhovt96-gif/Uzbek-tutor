// Мини-помощники для построения интерфейса без фреймворка.
// Текст всегда вставляется как текст (textContent) — защита от внедрения HTML.
import { icon } from './icons.js';

export function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, v);
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    if (Array.isArray(c)) append(el, c);
    else el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

// keepScroll: перерисовать экран, не прокручивая его наверх (например, при выборе тарифа)
export function mount(el, opts = {}) {
  const root = document.getElementById('app');
  const y = window.scrollY;
  if (opts.keepScroll && el.classList) el.classList.add('no-anim');   // без мигания при перерисовке
  root.replaceChildren(el);
  window.scrollTo(0, opts.keepScroll ? y : 0);
}

// Открыть ссылку: t.me — внутри Telegram, остальные — во внешнем браузере
export function openLink(url) {
  const wa = window.Telegram && window.Telegram.WebApp;
  try {
    if (wa && /^https:\/\/t\.me\//.test(url) && wa.openTelegramLink) return wa.openTelegramLink(url);
    if (wa && wa.openLink) return wa.openLink(url);
  } catch { /* старые клиенты */ }
  window.open(url, '_blank', 'noopener');
}

export function haptic(kind) {
  const hf = window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.HapticFeedback;
  if (!hf) return;
  try {
    if (kind === 'success' || kind === 'error' || kind === 'warning') hf.notificationOccurred(kind);
    else hf.impactOccurred('light');
  } catch { /* старые клиенты Telegram */ }
}

export function spinner(text) {
  return h('div', { class: 'center muted' }, h('div', { class: 'spinner' }), text || '');
}

export function audioButton(onClick, label) {
  return h('button', { class: 'audio-btn', type: 'button', 'aria-label': label || 'audio', onClick }, icon('sound'));
}

// Нижняя шторка: закрывается касанием фона. Возвращает функцию закрытия.
export function sheet(...content) {
  const back = h('div', { class: 'sheet-back' });
  const close = () => back.remove();
  back.addEventListener('click', (e) => { if (e.target === back) close(); });
  back.append(h('div', { class: 'sheet' }, h('div', { class: 'sheet-grip' }), ...content));
  document.body.append(back);
  return close;
}

// Кольцо прогресса (0…1) для кружков на карте
export function ring(fraction, size = 64) {
  const NS = 'http://www.w3.org/2000/svg';
  const r = size / 2 - 3;
  const c = 2 * Math.PI * r;
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('class', 'ring');
  svg.setAttribute('viewBox', `0 0 ${size} ${size}`);
  const bg = document.createElementNS(NS, 'circle');
  const fg = document.createElementNS(NS, 'circle');
  for (const el of [bg, fg]) { el.setAttribute('cx', size / 2); el.setAttribute('cy', size / 2); el.setAttribute('r', r); }
  bg.setAttribute('class', 'ring-bg');
  fg.setAttribute('class', 'ring-fg');
  fg.setAttribute('stroke-dasharray', `${(Math.max(0, Math.min(1, fraction)) * c).toFixed(1)} ${c.toFixed(1)}`);
  svg.append(bg);
  if (fraction > 0) svg.append(fg);
  return svg;
}
