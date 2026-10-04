// Темы оформления. Выбор хранится в профиле (settings.theme) и в памяти телефона — чтобы не мигало при запуске.
const KEY = 'ut_theme';

// Цвет фона каждой темы — для шапки Telegram
export const THEMES = {
  telegram: null,
  light: '#f5f6f8',
  dark: '#0f1115',
  gray: '#e6e7ea',
  sand: '#f3ede2',
  midnight: '#0b1424',
};

function webApp() {
  return window.Telegram && window.Telegram.WebApp;
}

export function currentTheme() {
  return document.documentElement.dataset.theme || 'telegram';
}

export function applyTheme(name) {
  const theme = Object.prototype.hasOwnProperty.call(THEMES, name) ? name : 'telegram';
  const root = document.documentElement;
  root.dataset.theme = theme;
  const wa = webApp();
  root.dataset.scheme = theme === 'telegram' ? (wa && wa.colorScheme) || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    : theme === 'dark' || theme === 'midnight' ? 'dark' : 'light';
  try { localStorage.setItem(KEY, theme); } catch { /* приватный режим */ }
  if (wa) {
    try {
      const color = THEMES[theme];
      if (color) {
        wa.setHeaderColor && wa.setHeaderColor(color);
        wa.setBackgroundColor && wa.setBackgroundColor(color);
        wa.setBottomBarColor && wa.setBottomBarColor(color);
      } else {
        wa.setHeaderColor && wa.setHeaderColor('secondary_bg_color');
        wa.setBackgroundColor && wa.setBackgroundColor('secondary_bg_color');
      }
    } catch { /* старые клиенты Telegram */ }
  }
}

export function initTheme() {
  let saved = null;
  try { saved = localStorage.getItem(KEY); } catch { /* нет доступа */ }
  applyTheme(saved || 'telegram');
  const wa = webApp();
  if (wa && wa.onEvent) wa.onEvent('themeChanged', () => currentTheme() === 'telegram' && applyTheme('telegram'));
}
