// Точка входа: вход через Telegram, навигация между экранами, кнопка «Назад» Telegram.
import { login, rpc, tg, ApiError } from './api.js';
import { setLang, t } from './i18n.js';
import { h, mount, spinner } from './ui.js';
import { renderHome } from './screens/home.js';
import { renderLearn } from './screens/learn.js';
import { renderProgress } from './screens/progress.js';
import { renderSettings } from './screens/settings.js';
import { renderTopics } from './screens/topics.js';
import { renderSoon } from './screens/soon.js';

export const app = {
  me: null,
  stack: [],
  async refreshMe() {
    this.me = await rpc('get_me');
    setLang(this.me && this.me.ui_lang);
    return this.me;
  },
  leave() {
    if (this.cleanup) { try { this.cleanup(); } catch (e) { console.warn(e); } this.cleanup = null; }
  },
  go(screen, params = {}) {
    this.leave();
    this.stack.push({ screen, params });
    render();
  },
  back() {
    this.leave();
    if (this.stack.length > 1) this.stack.pop();
    render();
  },
  home() {
    this.leave();
    this.stack = [{ screen: 'home', params: {} }];
    render();
  },
};

const SCREENS = {
  home: renderHome,
  learn: renderLearn,
  progress: renderProgress,
  settings: renderSettings,
  topics: renderTopics,
  soon: renderSoon,
};

function render() {
  const { screen, params } = app.stack[app.stack.length - 1];
  const webApp = tg();
  if (webApp && webApp.BackButton) {
    if (app.stack.length > 1) webApp.BackButton.show();
    else webApp.BackButton.hide();
  }
  Promise.resolve(SCREENS[screen](app, params)).catch(showError);
}

function showError(err) {
  console.error(err);
  mount(h('div', { class: 'screen center' },
    h('p', { class: 'err' }, `${t('loginFailed')}: ${err && (err.code || err.message) || err}`),
    h('button', { class: 'btn', onClick: () => start() }, t('retry'))));
}

async function start() {
  const webApp = tg();
  if (!webApp) {
    mount(h('div', { class: 'screen center' }, h('h1', {}, t('appName')), h('p', { class: 'muted' }, t('loginNeeded'))));
    return;
  }
  webApp.ready();
  webApp.expand();
  if (webApp.BackButton) webApp.BackButton.onClick(() => app.back());
  setLang((webApp.initDataUnsafe && webApp.initDataUnsafe.user && webApp.initDataUnsafe.user.language_code || 'ru').slice(0, 2));
  mount(spinner(t('loading')));
  try {
    await login();
    await app.refreshMe();
    app.home();
  } catch (err) {
    showError(err instanceof ApiError ? err : new ApiError(String(err)));
  }
}

start();
