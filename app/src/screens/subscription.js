// Экран «Подписка»: текущий уровень, выбор тарифа и срока, оплата звёздами Telegram, код, история платежей.
import { rpc, tg, createInvoice } from '../api.js';
import { t, tierName, formatDate } from '../i18n.js';
import { h, mount, spinner, haptic } from '../ui.js';
import { icon } from '../icons.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function renderSubscription(app, params = {}) {
  mount(spinner(t('loading')));
  const [me, plans, payments] = await Promise.all([app.refreshMe(), rpc('get_plans'), rpc('get_my_payments')]);
  let tier = params.tier || (me.tier === 'advanced' ? 'advanced' : me.tier === 'basic' ? 'basic' : 'basic');
  let months = params.months || 3;

  const fmt = (n) => Number(n).toLocaleString('ru-RU');
  const status = h('p', { class: 'small' });

  let drawn = false;
  const draw = () => {
    const list = plans.filter((p) => p.tier === tier).sort((a, b) => a.months - b.months);
    const monthly = list.find((p) => p.months === 1);
    let chosen = list.find((p) => p.months === months) || list[0];
    if (chosen) months = chosen.months;

    const tierSeg = h('div', { class: 'segmented' }, ['basic', 'advanced'].map((tr) =>
      h('button', { type: 'button', class: tr === tier ? 'active' : '', onClick: () => { tier = tr; haptic(); draw(); } }, tierName(tr))));

    const features = h('ul', { class: 'feature-list' }, (t(tier === 'basic' ? 'featBasic' : 'featAdvanced') || []).map((f) =>
      h('li', {}, icon('check'), h('span', {}, f))));

    const options = h('div', { class: 'plan-options' }, list.map((p) => {
      const perMonth = Math.round(p.price_stars / p.months);
      const save = monthly && p.months > 1 ? Math.round((1 - p.price_stars / (monthly.price_stars * p.months)) * 100) : 0;
      return h('button', { type: 'button', class: `plan-opt ${p.months === months ? 'active' : ''}`,
        onClick: () => { months = p.months; haptic(); draw(); } },
        h('div', { class: 'plan-m' }, t('months', p.months)),
        h('div', { class: 'plan-price' }, `${fmt(p.price_stars)} ⭐`),
        h('div', { class: 'tiny muted' }, t('perMonth', fmt(perMonth))),
        save > 0 ? h('span', { class: 'plan-save' }, `−${save}%`) : null);
    }));

    const payBtn = h('button', { class: 'btn btn-big', type: 'button', disabled: !chosen || !chosen.price_stars, onClick: () => pay(chosen, payBtn) },
      chosen ? t('payStars', fmt(chosen.price_stars)) : '—');

    const other = chosen ? h('p', { class: 'small muted' }, t('otherPay', fmt(chosen.price_uzs), chosen.price_usd)) : null;

    const keep = drawn;
    drawn = true;
    mount(h('div', { class: 'screen' },
      h('h1', {}, t('subscription')),
      h('div', { class: 'card hero' },
        h('div', { class: 'label' }, t('currentPlan')),
        h('h3', {}, tierName(me.tier)),
        h('p', { class: 'muted small' }, me.tier === 'free' ? t('freeLimits') : t('tierUntil', formatDate(me.tier_ends_at)))),
      h('h2', {}, t(me.tier === 'free' ? 'choosePlan' : 'extendPlan')),
      tierSeg,
      h('div', { class: 'card' }, features),
      options,
      payBtn,
      h('p', { class: 'tiny muted pay-hint' }, t('starsHint')),
      status,
      other,
      h('h2', {}, t('codeLabel')),
      codeBlock(app),
      payments.length ? h('h2', {}, t('myPayments')) : null,
      payments.length ? h('div', { class: 'card' }, payments.map((p) => h('div', { class: 'pay-row' },
        h('div', {}, h('b', {}, `${tierName(p.tier)} · ${t('months', p.months)}`), h('div', { class: 'tiny muted' }, formatDate(p.created_at))),
        h('div', { class: p.status === 'refunded' ? 'muted' : '' }, `${fmt(p.stars)} ⭐`, p.status === 'refunded' ? ` · ${t('refunded')}` : '')))) : null), { keepScroll: keep });
  };

  async function pay(plan, btn) {
    const webApp = tg();
    if (!webApp || !webApp.openInvoice) { status.textContent = t('payNeedsTelegram'); status.className = 'small err'; return; }
    btn.disabled = true;
    status.textContent = t('loading');
    status.className = 'small';
    let link;
    try {
      link = await createInvoice(plan.id);
    } catch (err) {
      btn.disabled = false;
      status.textContent = `${t('payError')} (${err.code || err.message})`;
      status.className = 'small err';
      return;
    }
    status.textContent = '';
    const before = me.tier_ends_at;
    webApp.openInvoice(link, async (result) => {
      btn.disabled = false;
      if (result === 'paid') {
        haptic('success');
        status.textContent = t('payProcessing');
        status.className = 'small ok';
        // бот зачисляет оплату через несколько секунд — ждём изменения подписки
        for (let i = 0; i < 12; i++) {
          await sleep(1500);
          const fresh = await rpc('get_me').catch(() => null);
          if (fresh && (fresh.tier !== me.tier || fresh.tier_ends_at !== before)) break;
        }
        renderSubscription(app, { tier, months });
      } else if (result === 'failed') {
        haptic('error');
        status.textContent = `${t('payError')} ${t('payFailedHint')}`;
        status.className = 'small err';
      }
    });
  }

  draw();
}

function codeBlock(app) {
  const input = h('input', { class: 'answer-input', placeholder: 'XXXX-XXXX-XXXX', autocomplete: 'off', autocapitalize: 'characters' });
  const status = h('p', { class: 'small' });
  const redeem = async () => {
    const code = input.value.trim();
    if (!code) return;
    status.textContent = t('loading');
    status.className = 'small';
    try {
      const r = await rpc('redeem_code', { p_code: code });
      if (r.ok) {
        haptic('success');
        status.textContent = t('codeOk', tierName(r.tier), formatDate(r.ends_at));
        status.className = 'small ok';
        input.value = '';
        setTimeout(() => renderSubscription(app), 1200);
      } else {
        haptic('error');
        status.textContent = (t('codeErrors') || {})[r.error] || r.error;
        status.className = 'small err';
      }
    } catch (err) {
      status.textContent = String(err.message || err);
      status.className = 'small err';
    }
  };
  return h('div', { class: 'card' },
    h('p', { class: 'small muted' }, t('codeHint')),
    input,
    h('button', { class: 'btn btn-secondary', type: 'button', onClick: redeem }, t('activate')),
    status);
}
