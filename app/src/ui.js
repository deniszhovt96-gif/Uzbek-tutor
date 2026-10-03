// Мини-помощники для построения интерфейса без фреймворка.
// Текст всегда вставляется как текст (textContent) — защита от внедрения HTML.

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

export function mount(el) {
  const root = document.getElementById('app');
  root.replaceChildren(el);
  window.scrollTo(0, 0);
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
  return h('button', { class: 'audio-btn', type: 'button', 'aria-label': label || 'audio', onClick }, '🔊');
}
