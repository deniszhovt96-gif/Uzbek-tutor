// Точка входа: вход через Telegram, три вкладки (Дом, Путь, Настройки), стек экранов, кнопка «Назад» Telegram.
import { login, rpc, tg, ApiError } from './api.js';
import { setLang, t } from './i18n.js';
import { h, mount, spinner, haptic } from './ui.js';
import { icon } from './icons.js';
import { initTheme, applyTheme } from './theme.js';
import { renderHome } from './screens/home.js';
import { renderPath } from './screens/path.js';
import { renderLearn } from './screens/learn.js';
import { renderProgress } from './screens/progress.js';
import { renderSettings } from './screens/settings.js';
import { renderSoon } from './screens/soon.js';
import { renderPractice } from './screens/practice.js';
import { renderGames } from './screens/games.js';
import { renderTest } from './screens/test.js';
import { renderSubscription } from './screens/subscription.js';
import { renderCourse, renderUnit } from './screens/course.js';
import { renderWordCheck } from './screens/wordcheck.js';
import { renderUnitTest } from './screens/unittest.js';
import { renderReview } from './screens/review.js';
import { renderDictionary } from './screens/dictionary.js';
import { renderWordFlags } from './screens/wordflags.js';
import { renderWelcome } from './screens/welcome.js';
import { renderConj, setConjApp } from './screens/conj.js';
import { renderSentences } from './screens/sentences.js';
import { renderDecl } from './screens/decl.js';
import { renderAnalytics } from './screens/analytics.js';
import { renderFormReports } from './screens/formreports.js';

const TABS = ['home', 'path', 'settings'];

export const app = {
  me: null,
  stack: [],
  async refreshMe() {
    this.me = await rpc('get_me');
    setLang(this.me && this.me.ui_lang);
    if (this.me && this.me.settings && this.me.settings.theme) applyTheme(this.me.settings.theme);
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
  // заменить текущий экран (без добавления в историю)
  replace(screen, params = {}) {
    this.leave();
    this.stack[this.stack.length - 1] = { screen, params };
    render();
  },
  tab(name) {
    this.leave();
    this.stack = [{ screen: name, params: {} }];
    render();
  },
  home() { this.tab('home'); },
};
setConjApp(app);
if (window.__TEST__) window.__app = app;   // для автотестов

const SCREENS = {
  home: renderHome,
  path: renderPath,
  settings: renderSettings,
  learn: renderLearn,
  progress: renderProgress,
  soon: renderSoon,
  practice: renderPractice,
  games: renderGames,
  test: renderTest,
  subscription: renderSubscription,
  course: renderCourse,
  unit: renderUnit,
  unittest: renderUnitTest,
  wordcheck: renderWordCheck,
  review: renderReview,
  dictionary: renderDictionary,
  wordflags: renderWordFlags,
  welcome: renderWelcome,
  conj: renderConj,
  sentences: renderSentences,
  decl: renderDecl,
  analytics: renderAnalytics,
  formreports: renderFormReports,
};

// ---------------------------------------------------------------- нижняя навигация
let tabbar = null;
function ensureTabbar() {
  if (tabbar) return tabbar;
  const items = [['home', 'home', 'tabHome'], ['path', 'map', 'tabPath'], ['settings', 'settings', 'tabSettings']];
  tabbar = h('nav', { class: 'tabbar' }, h('div', { class: 'tabbar-inner' }, items.map(([name, ic, label]) =>
    h('button', { class: 'tab', type: 'button', 'data-tab': name, onClick: () => {
      haptic();
      const cur = app.stack[0] && app.stack[0].screen;
      if (cur === name && app.stack.length === 1) { window.scrollTo({ top: 0, behavior: 'smooth' }); return; }
      app.tab(name);
    } }, icon(ic), h('span', { class: 'tab-label' }, t(label))))));
  document.body.append(tabbar);
  return tabbar;
}

function updateTabbar() {
  const bar = ensureTabbar();
  const top = app.stack[app.stack.length - 1];
  const visible = app.stack.length === 1 && TABS.includes(top.screen);
  bar.style.display = visible ? '' : 'none';
  document.getElementById('app').classList.toggle('with-tabs', visible);
  const labels = { home: 'tabHome', path: 'tabPath', settings: 'tabSettings' };
  bar.querySelectorAll('.tab').forEach((b) => {
    b.classList.toggle('active', b.dataset.tab === top.screen);
    b.querySelector('.tab-label').textContent = t(labels[b.dataset.tab]);
  });
}

function render() {
  const { screen, params } = app.stack[app.stack.length - 1];
  const webApp = tg();
  if (webApp && webApp.BackButton) {
    if (app.stack.length > 1) webApp.BackButton.show();
    else webApp.BackButton.hide();
  }
  updateTabbar();
  Promise.resolve(SCREENS[screen](app, params)).then(updateTabbar).catch(showError);
}

function showError(err) {
  console.error(err);
  mount(h('div', { class: 'screen center' },
    h('p', { class: 'err' }, `${t('loginFailed')}: ${err && (err.code || err.message) || err}`),
    h('button', { class: 'btn', onClick: () => start() }, t('retry'))));
}

async function start() {
  initTheme();
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
    app.info = await rpc('get_app_info').catch(() => ({}));
    // реферальная ссылка: код из ссылки на мини-приложение (startapp=ref_…) или запомненный ботом (/start ref_…)
    const startParam = (webApp.initDataUnsafe && webApp.initDataUnsafe.start_param) || null;
    rpc('apply_referral', { p_code: startParam && /^ref_/i.test(startParam) ? startParam : null }).catch(() => null);
    // первый вход — короткое знакомство с приложением
    if (!(app.me && app.me.settings && app.me.settings.onboarded)) app.tab('welcome');
    else app.home();
  } catch (err) {
    showError(err instanceof ApiError ? err : new ApiError(String(err)));
  }
}

start();
