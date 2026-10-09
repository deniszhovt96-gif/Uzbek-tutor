// Экран «Подписка»: текущий уровень, выбор тарифа и срока, оплата звёздами Telegram, код, история платежей.
import { rpc, tg, createInvoice } from '../api.js';
import { t, tierName, formatDate } from '../i18n.js';
import { h, mount, spinner, haptic, sheet, openLink } from '../ui.js';
import { icon } from '../icons.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function renderSubscription(app, params = {}) {
  mount(spinner(t('loading')));
  const [me, plans, payments, queue, groupCodes, ref] = await Promise.all([app.refreshMe(), rpc('get_plans'), rpc('get_my_payments'),
    rpc('get_my_subscriptions').catch(() => []), rpc('get_group_codes').catch(() => []), rpc('get_referral_info').catch(() => null)]);
  const couponsAvail = (ref && ref.coupons) || 0;
  let useCoupons = params.useCoupons != null ? params.useCoupons : null;   // null — по умолчанию: максимум допустимых
  // после текущей подписки: другой уровень продолжится на оставшийся срок
  const next = (queue || []).filter((q) => q.tier !== me.tier);
  let tier = params.tier || (me.tier === 'advanced' ? 'advanced' : me.tier === 'basic' ? 'basic' : 'basic');
  let months = params.months || 3;
  let seats = params.seats || 1;            // 1 — для себя, 3 — группа из трёх человек (−15%)

  const fmt = (n) => Number(n).toLocaleString('ru-RU');
  const status = h('p', { class: 'small' });

  let drawn = false;
  const draw = () => {
    const list = plans.filter((p) => p.tier === tier && (p.seats || 1) === seats).sort((a, b) => a.months - b.months);
    const monthly = plans.find((p) => p.tier === tier && (p.seats || 1) === 1 && p.months === 1);
    let chosen = list.find((p) => p.months === months) || list[0];
    if (chosen) months = chosen.months;

    const tierSeg = h('div', { class: 'segmented' }, ['basic', 'advanced'].map((tr) =>
      h('button', { type: 'button', class: tr === tier ? 'active' : '', onClick: () => { tier = tr; haptic(); draw(); } }, tierName(tr))));

    const seatSeg = h('div', { class: 'segmented' }, [[1, t('forMe')], [3, t('forGroup')]].map(([v, l]) =>
      h('button', { type: 'button', class: v === seats ? 'active' : '', onClick: () => { seats = v; haptic(); draw(); } }, l)));

    const features = h('ul', { class: 'feature-list' }, (t(tier === 'basic' ? 'featBasic' : 'featAdvanced') || []).map((f) =>
      h('li', {}, icon('check'), h('span', {}, f))));

    const options = h('div', { class: 'plan-options' }, list.map((p) => {
      const perMonth = Math.round(p.price_stars / p.months / (p.seats || 1));
      const save = monthly && (p.months > 1 || (p.seats || 1) > 1)
        ? Math.round((1 - p.price_stars / (monthly.price_stars * p.months * (p.seats || 1))) * 100) : 0;
      return h('button', { type: 'button', class: `plan-opt ${p.months === months ? 'active' : ''}`,
        onClick: () => { months = p.months; haptic(); draw(); } },
        h('div', { class: 'plan-m' }, t('months', p.months)),
        h('div', { class: 'plan-price' }, `${fmt(p.price_stars)} ⭐`),
        h('div', { class: 'tiny muted' }, seats > 1 ? t('perPersonMonth', fmt(perMonth)) : t('perMonth', fmt(perMonth))),
        save > 0 ? h('span', { class: 'plan-save' }, `−${save}%`) : null);
    }));

    // купоны: обычная подписка — 1, групповая — до 3 (каждый −5% на долю одного участника)
    const maxCoupons = chosen ? Math.min(couponsAvail, chosen.seats || 1) : 0;
    const nCoupons = useCoupons == null ? maxCoupons : Math.min(useCoupons, maxCoupons);
    const finalStars = chosen ? Math.max(1, chosen.price_stars - Math.round((chosen.price_stars / (chosen.seats || 1)) * 0.05 * nCoupons)) : 0;
    const couponBox = maxCoupons > 0 ? h('div', { class: 'card coupon-card' },
      h('div', { class: 'row', style: { justifyContent: 'space-between' } },
        h('b', {}, t('couponsUse')), h('span', { class: 'chip gold' }, t('couponsHave', couponsAvail))),
      h('div', { class: 'segmented' }, Array.from({ length: maxCoupons + 1 }, (_, k) => k).map((k) =>
        h('button', { type: 'button', class: k === nCoupons ? 'active' : '', onClick: () => { useCoupons = k; haptic(); draw(); } },
          k === 0 ? t('couponsNone') : `${k} × −5%`))),
      nCoupons > 0 ? h('p', { class: 'small muted' }, t('couponsSaving', fmt(chosen.price_stars - finalStars))) : null) : null;

    const payBtn = h('button', { class: 'btn btn-big', type: 'button', disabled: !chosen || !chosen.price_stars, onClick: () => pay(chosen, payBtn, nCoupons) },
      chosen ? (nCoupons > 0 ? t('payStarsCoupon', fmt(finalStars), fmt(chosen.price_stars)) : t('payStars', fmt(chosen.price_stars))) : '—');

    const other = chosen ? h('p', { class: 'small muted' }, t('otherPay', fmt(chosen.price_uzs), chosen.price_usd)) : null;

    const keep = drawn;
    drawn = true;
    mount(h('div', { class: 'screen' },
      h('h1', {}, t('subscription')),
      h('div', { class: 'card hero' },
        h('div', { class: 'label' }, t('currentPlan')),
        h('h3', {}, tierName(me.tier)),
        h('p', { class: 'muted small' }, me.tier === 'free' ? t('freeLimits') : t('tierUntil', formatDate(me.tier_ends_at))),
        next.map((q) => h('p', { class: 'small queue-note' }, icon('clock'), t('nextPlan', tierName(q.tier), formatDate(q.ends_at))))),
      h('h2', {}, t(me.tier === 'free' ? 'choosePlan' : 'extendPlan')),
      tierSeg,
      seatSeg,
      seats > 1 ? h('p', { class: 'small muted' }, t('groupHint')) : null,
      h('div', { class: 'card' }, features),
      options,
      couponBox,
      payBtn,
      h('p', { class: 'tiny muted pay-hint' }, t('starsHint')),
      status,
      other,
      (groupCodes || []).length ? [h('h2', {}, t('groupCodesTitle')), h('div', { class: 'card' },
        h('p', { class: 'small muted' }, t('groupCodesHint')),
        groupCodes.map((c) => h('div', { class: 'pay-row' },
          h('div', {}, h('b', { class: 'code-text' }, c.code), h('div', { class: 'tiny muted' }, `${tierName(c.tier)} · ${t('months', c.months)}`)),
          c.used ? h('span', { class: 'chip' }, t('codeUsed'))
            : h('button', { class: 'btn btn-small btn-secondary', type: 'button', onClick: () => copyCode(c.code) }, t('copy')))))] : null,
      ref && ref.code ? referralBlock(ref) : null,
      h('h2', {}, t('codeLabel')),
      codeBlock(app),
      payments.length ? h('h2', {}, t('myPayments')) : null,
      payments.length ? h('div', { class: 'card' }, payments.map((p) => h('div', { class: 'pay-row' },
        h('div', {}, h('b', {}, `${tierName(p.tier)} · ${t('months', p.months)}`), h('div', { class: 'tiny muted' }, formatDate(p.created_at))),
        h('div', { class: p.status === 'refunded' ? 'muted' : '' }, `${fmt(p.stars)} ⭐`, p.status === 'refunded' ? ` · ${t('refunded')}` : '')))) : null), { keepScroll: keep });
  };

  async function pay(plan, btn, coupons = 0) {
    const webApp = tg();
    if (!webApp || !webApp.openInvoice) { status.textContent = t('payNeedsTelegram'); status.className = 'small err'; return; }
    btn.disabled = true;
    status.textContent = t('loading');
    status.className = 'small';
    let link;
    try {
      link = await createInvoice(plan.id, false, coupons);
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
        renderSubscription(app, { tier, months, seats, useCoupons });
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

function copyCode(code) {
  try { navigator.clipboard.writeText(code); haptic('success'); } catch { /* нет доступа к буферу */ }
}

// Пригласить друга: личная ссылка, счётчики и условия
const BOT = 'uzbek_tutor_bot';
function referralBlock(ref) {
  const link = `https://t.me/${BOT}?start=ref_${ref.code}`;
  const share = () => openLink(`https://t.me/share/url?url=${encodeURIComponent(link)}&text=${encodeURIComponent(t('refShareText'))}`);
  return [
    h('h2', {}, t('refTitle')),
    h('div', { class: 'card ref-card' },
      h('p', { class: 'small' }, t('refLead')),
      h('div', { class: 'ref-link' }, h('span', { class: 'code-text' }, link)),
      h('div', { class: 'two-btns' },
        h('button', { class: 'btn', type: 'button', onClick: share }, icon('users'), t('refShare')),
        h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => copyCode(link) }, t('copy'))),
      h('div', { class: 'stats' },
        h('div', { class: 'stat' }, h('b', {}, String(ref.invited || 0)), h('span', {}, t('refInvited'))),
        h('div', { class: 'stat' }, h('b', {}, String(ref.paid || 0)), h('span', {}, t('refPaid'))),
        h('div', { class: 'stat' }, h('b', {}, String(ref.coupons || 0)), h('span', {}, t('refCoupons')))),
      ref.welcome ? h('p', { class: 'small ok' }, t('refWelcomeHave')) : null,
      h('button', { class: 'link-btn small', type: 'button', onClick: () => sheet(
        h('h3', {}, t('refRulesTitle')),
        h('ul', { class: 'feature-list' }, t('refRules').map((r) => h('li', {}, icon('check'), h('span', {}, r))))) }, t('refRulesBtn'))),
  ];
}
