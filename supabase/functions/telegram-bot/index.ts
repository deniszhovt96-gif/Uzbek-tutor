// Edge Function: telegram-bot
// Webhook бота @uzbek_tutor_bot.
//   /start             — приветствие и кнопка «Открыть приложение»
//   /help              — список команд
//   /gencode T M N [U] — (только админ) N кодов подписки T (basic|advanced) на M месяцев (1,3,6,12),
//                        U — сколько раз можно активировать каждый код (по умолчанию 1)
//   /paysupport        — помощь с оплатой (обязательна для оплаты звёздами)
//   /terms             — условия подписки
//   /refund ID         — (только админ) вернуть звёзды по платежу (ID из уведомления об оплате)
//   /grant U T M       — (только админ) выдать подписку T (basic|advanced) на M месяцев пользователю U
//                        (Telegram ID или @username). Старшая подписка действует первой, младшая — после неё.
//   /id                — пользователь узнаёт свой Telegram ID (чтобы сообщить администратору)
//
// Оплата звёздами:
//   POST …/telegram-bot/invoice  (из приложения, с токеном пользователя) → ссылка на счёт
//   POST …/telegram-bot/flags    (из приложения после пометки слова) → уведомление администраторам о новых пометках
//   POST …/telegram-bot/cron     (раз в час из GitHub Actions, заголовок X-Cron-Token — одноразовый пропуск из базы)
//                                 → напоминания: ежедневное в выбранный час, день повторения, конец подписки
//   pre_checkout_query → проверка тарифа и цены; successful_payment → продление подписки
//
// Секреты функции: TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, APP_URL.
// Настройка функции: «Verify JWT» = ВЫКЛ (запросы приходят от Telegram).
// Подлинность запроса проверяется заголовком X-Telegram-Bot-Api-Secret-Token.

import { createClient } from "npm:@supabase/supabase-js@2";

type Lang = "ru" | "uz" | "en";

const TEXT = {
  ru: {
    start: (name: string) =>
      `Ассалому алайкум, ${name}! 👋\n\nЭто самоучитель узбекского языка: 8 700+ слов с озвучкой, примеры, грамматика, история и обществознание Узбекистана.\n\nНажмите кнопку ниже, чтобы начать.`,
    open: "Открыть приложение",
    help: "Команды:\n/start — открыть приложение\n/paysupport — помощь с оплатой\n/terms — условия подписки\n/id — мой Telegram ID\n/help — помощь",
    adminHelp: "\n\nАдминистратор:\n/gencode basic|advanced 1|3|6|12 количество [активаций]\nНапример: /gencode basic 1 5\n/refund ID_платежа — вернуть звёзды\n/grant ID|@username basic|advanced месяцев — выдать подписку\nНапример: /grant 123456789 advanced 1",
    tierName: (tier: string) => (tier === "basic" ? "Базовая" : "Продвинутая"),
    invoiceTitle: (tier: string, months: number) => `Подписка «${tier === "basic" ? "Базовая" : "Продвинутая"}» · ${months} мес.`,
    invoiceDesc: (tier: string, months: number) =>
      tier === "basic"
        ? `Безлимитное изучение слов, тренировка, игры и грамматика на ${months} мес.`
        : `Всё из «Базовой» + история, обществознание, культура, филворд и расширенная статистика на ${months} мес.`,
    paid: (tier: string, until: string) => `Оплата получена ✅\nПодписка «${tier === "basic" ? "Базовая" : "Продвинутая"}» действует до ${until}.`,
    payFailed: "Оплата получена, но подписку не удалось продлить автоматически. Мы уже разбираемся — напишите /paysupport.",
    paySupport: (admin: string) =>
      `Помощь с оплатой.\n\nЕсли звёзды списались, а подписка не появилась, или нужна отмена — напишите администратору: ${admin}.\nУкажите дату оплаты. Возврат звёзд возможен, если подпиской ещё не пользовались.`,
    terms:
      "Условия подписки\n\n• Подписка оплачивается звёздами Telegram на 1, 3, 6 или 12 месяцев и не продлевается автоматически.\n• Новая оплата того же уровня продлевает подписку с даты её окончания. Если действуют обе подписки, сначала работает «Продвинутая», а «Базовая» продолжается после неё на оставшийся срок.\n• «Базовая»: лёгкая программа, до 2 сеансов с новыми словами в день (повторение без ограничений), тренировка, игры, грамматика. «Продвинутая»: любая интенсивность и сеансы без ограничений, дополнительно история, обществознание, культура, филворд, расширенная статистика.\n• Пригласите друга по своей ссылке (Настройки → Подписка): он получит купон −5% на первую оплату, а вы — купон −5%, когда он оформит подписку. Купоны личные, не сгорают; купон снижает цену тарифа (уже со скидкой за срок) ещё на 5%; на обычную подписку — 1 купон, на групповую — до 3 (каждый −5% на долю одного участника).\n• Вопросы и возвраты — /paysupport.",
    refundUsage: "Формат: /refund ID_платежа",
    refundDone: (stars: number) => `Возврат выполнен: ${stars} ⭐. Подписка по этому платежу отменена.`,
    refundFail: (e: string) => `Возврат не выполнен: ${e}`,
    notAdmin: "Команда доступна только администратору.",
    badArgs: "Формат: /gencode basic|advanced 1|3|6|12 количество [активаций]\nНапример: /gencode advanced 3 10",
    codes: (tier: string, months: number, n: number, uses: number) =>
      `Создано кодов: ${n}\nПодписка: ${tier === "basic" ? "Базовая" : "Продвинутая"}, ${months} мес.\nАктиваций на код: ${uses}\n\nКоды показаны один раз — сохраните их:`,
    error: "Не удалось выполнить команду. Попробуйте позже.",
  },
  uz: {
    start: (name: string) =>
      `Assalomu alaykum, ${name}! 👋\n\nBu oʻzbek tilini oʻrganish ilovasi: 8 700+ soʻz ovozli, misollar, grammatika, tarix va jamiyatshunoslik.\n\nBoshlash uchun quyidagi tugmani bosing.`,
    open: "Ilovani ochish",
    help: "Buyruqlar:\n/start — ilovani ochish\n/paysupport — toʻlov boʻyicha yordam\n/terms — obuna shartlari\n/id — mening Telegram ID\n/help — yordam",
    adminHelp: "\n\nAdministrator:\n/gencode basic|advanced 1|3|6|12 soni [faollashtirish]\n/refund ID — yulduzlarni qaytarish\n/grant ID|@username basic|advanced oy — obuna berish",
    tierName: (tier: string) => (tier === "basic" ? "Asosiy" : "Kengaytirilgan"),
    invoiceTitle: (tier: string, months: number) => `«${tier === "basic" ? "Asosiy" : "Kengaytirilgan"}» obuna · ${months} oy`,
    invoiceDesc: (tier: string, months: number) =>
      tier === "basic"
        ? `${months} oyga cheksiz soʻz oʻrganish, mashq, oʻyinlar va grammatika.`
        : `${months} oyga «Asosiy»dagi hammasi + tarix, jamiyatshunoslik, madaniyat, filvord va kengaytirilgan statistika.`,
    paid: (tier: string, until: string) => `Toʻlov qabul qilindi ✅\n«${tier === "basic" ? "Asosiy" : "Kengaytirilgan"}» obuna ${until} gacha amal qiladi.`,
    payFailed: "Toʻlov qabul qilindi, lekin obunani avtomatik uzaytirib boʻlmadi. /paysupport ga yozing.",
    paySupport: (admin: string) =>
      `Toʻlov boʻyicha yordam.\n\nYulduzlar yechilgan, lekin obuna paydo boʻlmagan boʻlsa yoki bekor qilish kerak boʻlsa — administratorga yozing: ${admin}.\nToʻlov sanasini koʻrsating.`,
    terms:
      "Obuna shartlari\n\n• Obuna Telegram yulduzlari bilan 1, 3, 6 yoki 12 oyga toʻlanadi va avtomatik uzaytirilmaydi.\n• Xuddi shu darajadagi yangi toʻlov obunani tugash sanasidan uzaytiradi.\n• Doʻstingizni havolangiz orqali taklif qiling (Sozlamalar → Obuna): u birinchi toʻlovga −5% kupon oladi, siz esa u obuna boʻlganda −5% kupon olasiz. Kuponlar shaxsiy, muddatsiz; kupon tarif narxini (muddat chegirmasi bilan) yana 5% kamaytiradi; oddiy obunaga 1 ta, guruh obunasiga 3 tagacha (har biri bitta ishtirokchi ulushiga −5%).\n• Savollar va qaytarish — /paysupport.",
    refundUsage: "Format: /refund ID",
    refundDone: (stars: number) => `Qaytarildi: ${stars} ⭐.`,
    refundFail: (e: string) => `Qaytarib boʻlmadi: ${e}`,
    notAdmin: "Bu buyruq faqat administrator uchun.",
    badArgs: "Format: /gencode basic|advanced 1|3|6|12 soni [faollashtirish]",
    codes: (tier: string, months: number, n: number, uses: number) =>
      `Yaratilgan kodlar: ${n}\nObuna: ${tier === "basic" ? "Asosiy" : "Kengaytirilgan"}, ${months} oy\nHar bir kod: ${uses} marta\n\nKodlar faqat bir marta koʻrsatiladi:`,
    error: "Buyruqni bajarib boʻlmadi. Keyinroq urinib koʻring.",
  },
  en: {
    start: (name: string) =>
      `Assalomu alaykum, ${name}! 👋\n\nThis is an Uzbek self-study app: 8,700+ words with audio, examples, grammar, history and civics of Uzbekistan.\n\nTap the button below to start.`,
    open: "Open the app",
    help: "Commands:\n/start — open the app\n/paysupport — payment help\n/terms — subscription terms\n/id — my Telegram ID\n/help — help",
    adminHelp: "\n\nAdmin:\n/gencode basic|advanced 1|3|6|12 count [uses]\n/refund ID — refund stars\n/grant ID|@username basic|advanced months — grant a subscription",
    tierName: (tier: string) => (tier === "basic" ? "Basic" : "Advanced"),
    invoiceTitle: (tier: string, months: number) => `${tier === "basic" ? "Basic" : "Advanced"} plan · ${months} mo.`,
    invoiceDesc: (tier: string, months: number) =>
      tier === "basic"
        ? `Unlimited word learning, practice, games and grammar for ${months} mo.`
        : `Everything in Basic + history, civics, culture, word search and extended stats for ${months} mo.`,
    paid: (tier: string, until: string) => `Payment received ✅\nYour ${tier === "basic" ? "Basic" : "Advanced"} plan is active until ${until}.`,
    payFailed: "Payment received, but the subscription could not be extended automatically. Please write /paysupport.",
    paySupport: (admin: string) =>
      `Payment help.\n\nIf stars were charged but the subscription did not appear, or you need a refund, contact the administrator: ${admin}.\nPlease include the payment date.`,
    terms:
      "Subscription terms\n\n• Plans are paid with Telegram Stars for 1, 3, 6 or 12 months and do not renew automatically.\n• A new payment of the same plan extends it from its end date.\n• Invite a friend with your link (Settings → Subscription): they get a −5% coupon for their first payment, and you get a −5% coupon when they subscribe. Coupons are personal and never expire; a coupon takes another 5% off the plan price (already including the term discount); 1 coupon per regular plan, up to 3 per group plan (each −5% off one member’s share).\n• Questions and refunds — /paysupport.",
    refundUsage: "Format: /refund ID",
    refundDone: (stars: number) => `Refunded: ${stars} ⭐.`,
    refundFail: (e: string) => `Refund failed: ${e}`,
    notAdmin: "This command is for administrators only.",
    badArgs: "Format: /gencode basic|advanced 1|3|6|12 count [uses]",
    codes: (tier: string, months: number, n: number, uses: number) =>
      `Codes created: ${n}\nPlan: ${tier}, ${months} mo.\nUses per code: ${uses}\n\nCodes are shown only once — save them:`,
    error: "Command failed. Please try again later.",
  },
} as const;

// Групповая подписка (3 человека, −15%): пояснение в счёте и коды для друзей после оплаты
const GROUP_NOTE: Record<Lang, string> = {
  ru: "Групповая: вам подписка и 2 кода для друзей.",
  uz: "Guruh: sizga obuna va doʻstlar uchun 2 ta kod.",
  en: "Group: your plan plus 2 codes for friends.",
};
// Реферальная программа: купоны −5%
const COUPON_NOTE: Record<Lang, (n: number) => string> = {
  ru: (n) => `Применено купонов: ${n}.`,
  uz: (n) => `Qoʻllangan kuponlar: ${n}.`,
  en: (n) => `Coupons applied: ${n}.`,
};
const REF_TEXT = {
  ru: {
    welcome: "🎁 Вы пришли по приглашению друга — вам купон −5% на первую оплату подписки. Он появится в приложении: Настройки → Подписка.",
    earned: (n: number) => `🎉 Ваш друг оформил подписку по вашей ссылке — вам начислен купон −5%. Доступно купонов: ${n}.\nПрименить: приложение → Настройки → Подписка.`,
  },
  uz: {
    welcome: "🎁 Siz doʻstingiz taklifi bilan keldingiz — birinchi obuna toʻloviga −5% kupon. U ilovada: Sozlamalar → Obuna.",
    earned: (n: number) => `🎉 Doʻstingiz havolangiz orqali obuna boʻldi — sizga −5% kupon berildi. Mavjud kuponlar: ${n}.\nQoʻllash: ilova → Sozlamalar → Obuna.`,
  },
  en: {
    welcome: "🎁 You joined through a friend’s invite — you get a −5% coupon for your first subscription payment. Find it in the app: Settings → Subscription.",
    earned: (n: number) => `🎉 Your friend subscribed through your link — you’ve earned a −5% coupon. Coupons available: ${n}.\nUse it: app → Settings → Subscription.`,
  },
} as Record<Lang, { welcome: string; earned: (n: number) => string }>;

const GROUP_CODES: Record<Lang, string> = {
  ru: "Коды для друзей (активировать в приложении: Подписка → Код подписки; также видны там же):",
  uz: "Doʻstlar uchun kodlar (ilovada faollashtiriladi: Obuna → Obuna kodi; ular u yerda ham koʻrinadi):",
  en: "Codes for friends (activate in the app: Subscription → Subscription code; also listed there):",
};

function langOf(code?: string): Lang {
  if (!code) return "ru";
  if (code.startsWith("uz")) return "uz";
  if (code.startsWith("ru")) return "ru";
  return "en";
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

async function tgApi(token: string, method: string, payload: unknown): Promise<any> {
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.ok) console.error(`telegram ${method} failed`, res.status, JSON.stringify(data));
  return data;
}

async function tgCall(token: string, method: string, payload: unknown): Promise<void> {
  await tgApi(token, method, payload);
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" } });
}

function formatDate(iso: string, lang: Lang): string {
  try {
    return new Date(iso).toLocaleDateString(lang === "en" ? "en-GB" : lang === "uz" ? "uz-Latn-UZ" : "ru-RU", { timeZone: "Asia/Tashkent" });
  } catch {
    return iso.slice(0, 10);
  }
}

function dbClient() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// ---------------------------------------------------------------- счёт из приложения
// POST …/telegram-bot/invoice, заголовок Authorization: Bearer <токен пользователя>, тело {"plan_id": 3}
async function createInvoice(req: Request, token: string): Promise<Response> {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "not_authenticated" }, 401);
  const db = dbClient();
  const { data: auth, error: authErr } = await db.auth.getUser(jwt);
  if (authErr || !auth?.user) return json({ error: "not_authenticated" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { /* пусто */ }
  const planId = Number(body.plan_id);
  if (!Number.isInteger(planId)) return json({ error: "bad_plan" }, 400);
  const coupons = Math.max(0, Math.min(3, Number(body.coupons) || 0));
  const { data: plan, error } = await db.rpc("stars_invoice_data", { p_user: auth.user.id, p_plan_id: planId, p_coupons: coupons });
  if (error) { console.error(error); return json({ error: "db_error" }, 500); }
  if (plan.error) return json({ error: plan.error }, 400);
  const lang: Lang = plan.ui_lang === "uz" || plan.ui_lang === "en" ? plan.ui_lang : "ru";
  const t = TEXT[lang];
  const group = Number(plan.seats) > 1;
  const title = (t.invoiceTitle(plan.tier, plan.months) + (group ? " ×3" : "")).slice(0, 32);
  const couponNote = plan.coupons > 0 ? COUPON_NOTE[lang](plan.coupons) + " " : "";
  const res = await tgApi(token, "createInvoiceLink", {
    title,
    description: (couponNote + (group ? GROUP_NOTE[lang] + " " : "") + t.invoiceDesc(plan.tier, plan.months)).slice(0, 255),
    payload: plan.coupons > 0 ? `p:${plan.plan_id}:${auth.user.id}:${plan.coupons}` : `p:${plan.plan_id}:${auth.user.id}`,
    currency: "XTR",
    prices: [{ label: title, amount: plan.stars }],
  });
  if (!res.ok) return json({ error: "telegram_error" }, 502);
  return json({ link: res.result });
}

// ---------------------------------------------------------------- «Поделиться»: картинка + реферальная ссылка
// POST …/telegram-bot/share (токен пользователя). Готовит сообщение с картинкой и кнопкой-ссылкой
// (savePreparedInlineMessage); приложение открывает выбор чата через WebApp.shareMessage(id).
const SHARE_TEXT: Record<Lang, { caption: (link: string) => string; button: string }> = {
  ru: { caption: (l) => `Учу узбекский в Telegram — присоединяйся! 🇺🇿\nПо моей ссылке — скидка 5% на подписку:\n${l}`, button: "Учить узбекский" },
  uz: { caption: (l) => `Telegramda oʻzbek tilini oʻrganyapman — qoʻshil! 🇺🇿\nMening havolam orqali obunaga 5% chegirma:\n${l}`, button: "Oʻrganishni boshlash" },
  en: { caption: (l) => `I’m learning Uzbek in Telegram — join me! 🇺🇿\nMy link gives you 5% off a subscription:\n${l}`, button: "Learn Uzbek" },
};
export function shareImageUrl(appUrl: string, image: string, lang: Lang): string {
  const base = appUrl.endsWith("/") ? appUrl : appUrl + "/";
  return `${base}share/${image}-${lang === "en" ? "en" : "ru"}.jpg`;
}
async function prepareShare(req: Request, token: string, appUrl: string): Promise<Response> {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "not_authenticated" }, 401);
  const db = dbClient();
  const { data: auth, error: authErr } = await db.auth.getUser(jwt);
  if (authErr || !auth?.user) return json({ error: "not_authenticated" }, 401);
  const { data: sd, error } = await db.rpc("ref_share_data", { p_user: auth.user.id });
  if (error || !sd?.code) return json({ error: "db_error" }, 500);
  const lang: Lang = sd.lang === "uz" || sd.lang === "en" ? sd.lang : "ru";
  const me = await tgApi(token, "getMe", {});
  const link = `https://t.me/${me?.result?.username || "uzbek_tutor_bot"}?start=ref_${sd.code}`;
  const photo = shareImageUrl(appUrl, String(sd.image || "promo"), lang);
  const res = await tgApi(token, "savePreparedInlineMessage", {
    user_id: sd.tg_id,
    result: {
      type: "photo", id: `share_${sd.code}`.slice(0, 64), photo_url: photo, thumbnail_url: photo,
      caption: SHARE_TEXT[lang].caption(link),
      reply_markup: { inline_keyboard: [[{ text: SHARE_TEXT[lang].button, url: link }]] },
    },
    allow_user_chats: true, allow_group_chats: true, allow_channel_chats: true,
  });
  if (!res?.ok) return json({ error: "telegram_error", link, photo }, 502);
  return json({ id: res.result.id, link, photo });
}

// ---------------------------------------------------------------- оплата: обновления от Telegram
async function onPreCheckout(token: string, q: any): Promise<void> {
  const db = dbClient();
  const lang = langOf(q.from?.language_code);
  const { data, error } = await db.rpc("stars_check_plan", {
    p_payload: q.invoice_payload, p_tg_id: q.from?.id, p_amount: q.total_amount,
  });
  const ok = !error && q.currency === "XTR" && data?.ok === true;
  if (!ok) console.error("pre_checkout rejected", error, JSON.stringify(data));
  const reason = lang === "uz" ? "Tarif oʻzgardi. Ilovani qayta oching va yana urinib koʻring."
    : lang === "en" ? "The plan has changed. Reopen the app and try again."
    : "Тариф изменился. Откройте приложение заново и повторите оплату.";
  await tgCall(token, "answerPreCheckoutQuery", ok
    ? { pre_checkout_query_id: q.id, ok: true }
    : { pre_checkout_query_id: q.id, ok: false, error_message: reason });
}

async function onPaid(token: string, msg: any): Promise<void> {
  const db = dbClient();
  const sp = msg.successful_payment;
  const lang = langOf(msg.from?.language_code);
  const t = TEXT[lang];
  const { data, error } = await db.rpc("stars_grant_payment", {
    p_payload: sp.invoice_payload, p_tg_id: msg.from?.id, p_amount: sp.total_amount, p_charge_id: sp.telegram_payment_charge_id,
  });
  if (error || !data?.ok) {
    console.error("stars_grant_payment failed", error, JSON.stringify(data), sp.telegram_payment_charge_id);
    await tgCall(token, "sendMessage", { chat_id: msg.chat.id, text: t.payFailed });
    await notifyAdmins(db, token, `⚠️ Оплата ${sp.total_amount} ⭐ не зачислена автоматически.\nПользователь: ${msg.from?.id}\nID: ${sp.telegram_payment_charge_id}`);
    return;
  }
  if (data.duplicate) return;
  const codes: string[] = Array.isArray(data.codes) ? data.codes : [];
  await tgCall(token, "sendMessage", { chat_id: msg.chat.id, text: t.paid(data.tier, formatDate(data.ends_at, lang))
    + (codes.length ? `\n\n${GROUP_CODES[lang]}\n${codes.join("\n")}` : "") });
  // автору реферальной ссылки — сообщение о купоне
  if (data.referrer?.tg_id) {
    const rl: Lang = data.referrer.lang === "uz" || data.referrer.lang === "en" ? data.referrer.lang : "ru";
    await tgCall(token, "sendMessage", { chat_id: data.referrer.tg_id, text: REF_TEXT[rl].earned(Number(data.referrer.coupons) || 1) });
  }
  await notifyAdmins(db, token, await adminCard(db, sp.telegram_payment_charge_id, "💫 <b>Новая оплата</b>", true), true);
}

// Возврат прошёл не через /refund (например, через поддержку Telegram) — всё равно отменяем подписку
async function onRefunded(token: string, msg: any): Promise<void> {
  const db = dbClient();
  const rp = msg.refunded_payment;
  const { data, error } = await db.rpc("stars_refund_payment", { p_charge_id: rp.telegram_payment_charge_id });
  if (error || !data?.ok) {
    console.error("stars_refund_payment failed", error, JSON.stringify(data), rp.telegram_payment_charge_id);
    await notifyAdmins(db, token, `⚠️ Возврат ${rp.total_amount} ⭐ не найден в базе.\nПользователь: ${msg.from?.id}\nID: ${rp.telegram_payment_charge_id}`);
    return;
  }
  if (data.duplicate) return;   // возврат уже обработан командой /refund
  await notifyAdmins(db, token, await adminCard(db, rp.telegram_payment_charge_id, `↩️ <b>Возврат ${rp.total_amount} ⭐</b> (не через /refund) — подписка по платежу отменена`, false), true);
}

async function notifyAdmins(db: any, token: string, text: string, html = false): Promise<void> {
  const { data } = await db.from("admins").select("tg_id");
  for (const a of data ?? []) {
    await tgCall(token, "sendMessage", html ? { chat_id: a.tg_id, text, parse_mode: "HTML" } : { chat_id: a.tg_id, text });
  }
}

// ---------------------------------------------------------------- пометки уровня слов → администраторам
// POST …/telegram-bot/flags, заголовок Authorization: Bearer <токен пользователя>. Собирает все ещё не отправленные
// пометки (от любых пользователей) одним сообщением — повторные вызовы ничего не дублируют.
async function notifyFlags(req: Request, token: string): Promise<Response> {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "not_authenticated" }, 401);
  const db = dbClient();
  const { data: auth, error: authErr } = await db.auth.getUser(jwt);
  if (authErr || !auth?.user) return json({ error: "not_authenticated" }, 401);
  const { data, error } = await db.rpc("take_flag_notifications", {});
  if (error) throw error;
  const items = (data ?? []) as any[];
  // пометки форм спряжения/склонения («Нужно исправить»)
  const { data: fdata } = await db.rpc("take_form_notifications", {});
  const forms = (fdata ?? []) as any[];
  if (forms.length) {
    const flines = forms.slice(0, 20).map((f) => {
      const who = `${escapeHtml(f.name ?? "")}${f.username ? ` @${escapeHtml(f.username)}` : ""}`;
      const where = `${f.kind === "conj" ? "спряжение" : "склонение"}${f.item ? `, ${escapeHtml(f.item)}` : ""}${f.person != null ? `, строка ${f.person + 1}` : ""}`;
      return `• <b>${escapeHtml(f.uz)}</b> (${where}): ${escapeHtml(f.comment ?? "")}${f.form ? `\n  <i>${escapeHtml(String(f.form).slice(0, 160))}</i>` : ""} — ${who}`;
    });
    if (forms.length > 20) flines.push(`…и ещё ${forms.length - 20}`);
    await notifyAdmins(db, token, `⚑ <b>Нужно исправить форму</b>\n${flines.join("\n")}\n\nПриложение → Настройки → «Пометки форм».`, true);
  }
  if (!items.length) return json({ ok: true, sent: forms.length });
  const kind = (k: string) => (k === "rare" ? "малоиспользуемое" : "не используется");
  const lines = items.slice(0, 30).map((f) => {
    const who = `${escapeHtml(f.name ?? "")}${f.username ? ` @${escapeHtml(f.username)}` : ""}`;
    const done = f.status === "approved" ? " — <i>применено администратором</i>" : "";
    return `• <b>${escapeHtml(f.uz)}</b> — ${escapeHtml(f.ru)}: ${kind(f.kind)}, ${f.from} → ${f.to} (${who})${done}`;
  });
  if (items.length > 30) lines.push(`…и ещё ${items.length - 30}`);
  await notifyAdmins(db, token,
    `🏷 <b>Пометки уровня слов</b>\n${lines.join("\n")}\n\nРешение: приложение → Настройки → «Пометки слов».`, true);
  return json({ ok: true, sent: items.length });
}

// ---------------------------------------------------------------- напоминания
function plural(n: number, one: string, few: string, many: string): string {
  const a = n % 10, b = n % 100;
  return a === 1 && b !== 11 ? one : a >= 2 && a <= 4 && (b < 12 || b > 14) ? few : many;
}
const REMIND = {
  ru: {
    hi: (name: string) => `Привет${name ? `, ${name}` : ""}! 👋`,
    due: (n: number) => `Сегодня ждут повторения ${n} ${plural(n, "слово", "слова", "слов")}. 10 минут — и они останутся в памяти.`,
    fresh: "Самое время выучить новые слова — сеанс займёт около 10 минут.",
    first: "Начните первый урок узбекского — это около 10 минут.",
    rdToday: "Сегодня пятница — день повторения: сначала повторяем изученное, потом откроются новые слова.",
    rdTomorrow: "Завтра пятница — день повторения.",
    off: "Изменить время или отключить напоминания: Настройки в приложении.",
    subEnd: (tier: string, date: string) => `Подписка «${tier}» заканчивается ${date}. Продлить можно в приложении: Настройки → Подписка.`,
    open: "Открыть приложение",
    tiers: { basic: "Базовая", advanced: "Продвинутая" } as Record<string, string>,
  },
  uz: {
    hi: (name: string) => `Salom${name ? `, ${name}` : ""}! 👋`,
    due: (n: number) => `Bugun ${n} ta soʻz takrorlashni kutmoqda. 10 daqiqa — va ular xotirada qoladi.`,
    fresh: "Yangi soʻzlarni oʻrganish vaqti — mashgʻulot taxminan 10 daqiqa.",
    first: "Oʻzbek tilidan birinchi darsni boshlang — taxminan 10 daqiqa.",
    rdToday: "Bugun juma — takrorlash kuni: avval oʻrganilganlarni takrorlaymiz, keyin yangi soʻzlar ochiladi.",
    rdTomorrow: "Ertaga juma — takrorlash kuni.",
    off: "Vaqtni oʻzgartirish yoki eslatmalarni oʻchirish: ilovadagi Sozlamalar.",
    subEnd: (tier: string, date: string) => `«${tier}» obunasi ${date} da tugaydi. Uzaytirish: ilovada Sozlamalar → Obuna.`,
    open: "Ilovani ochish",
    tiers: { basic: "Asosiy", advanced: "Kengaytirilgan" } as Record<string, string>,
  },
  en: {
    hi: (name: string) => `Hi${name ? `, ${name}` : ""}! 👋`,
    due: (n: number) => `${n} ${n === 1 ? "word is" : "words are"} waiting for review today. 10 minutes — and they stay in your memory.`,
    fresh: "Time to learn some new words — a session takes about 10 minutes.",
    first: "Start your first Uzbek lesson — about 10 minutes.",
    rdToday: "Today is Friday, review day: first we review, then new words unlock.",
    rdTomorrow: "Tomorrow is Friday, review day.",
    off: "Change the time or turn reminders off: Settings in the app.",
    subEnd: (tier: string, date: string) => `Your ${tier} plan ends on ${date}. You can renew it in the app: Settings → Subscription.`,
    open: "Open the app",
    tiers: { basic: "Basic", advanced: "Advanced" } as Record<string, string>,
  },
};

async function runReminders(req: Request, token: string, appUrl: string): Promise<Response> {
  const cronToken = req.headers.get("X-Cron-Token") || "";
  if (!cronToken) return json({ error: "forbidden" }, 403);
  const db = dbClient();
  const { data, error } = await db.rpc("reminders_take", { p_token: cronToken });
  if (error) throw error;
  if (!data?.ok) return json({ error: data?.error ?? "forbidden" }, 403);
  let sent = 0, blocked = 0;
  for (const r of (data.items ?? []) as any[]) {
    const L = REMIND[(r.lang === "uz" || r.lang === "en") ? r.lang : "ru" as "ru" | "uz" | "en"];
    let text: string;
    if (typeof r.text === "string" && r.text) {
      text = r.text;                                  // готовый текст из базы (недельное сообщение)
    } else if (r.kind === "sub_end") {
      const date = new Date(r.ends_at).toLocaleDateString(r.lang === "en" ? "en-GB" : "ru-RU");
      text = L.subEnd(L.tiers[r.tier] ?? r.tier, date);
    } else {
      const lines = [L.hi(r.name ?? "")];
      if (r.review_day_today) lines.push(L.rdToday);
      lines.push(r.due > 0 ? L.due(r.due) : r.started > 0 ? L.fresh : L.first);
      if (r.review_day_tomorrow) lines.push(L.rdTomorrow);
      lines.push("", L.off);
      text = lines.join("\n");
    }
    const res = await tgApi(token, "sendMessage", {
      chat_id: r.tg_id, text, reply_markup: { inline_keyboard: [[{ text: L.open, web_app: { url: appUrl } }]] },
    });
    if (res?.ok) sent++;
    else if (res?.error_code === 403) {           // пользователь заблокировал бота
      blocked++;
      await db.rpc("set_bot_blocked", { p_tg_id: r.tg_id, p_blocked: true });
    }
    await new Promise((ok) => setTimeout(ok, 40));   // не больше ~25 сообщений в секунду
  }
  return json({ ok: true, sent, blocked });
}

const TIER_RU: Record<string, string> = { free: "Бесплатная", basic: "Базовая", advanced: "Продвинутая" };

// Карточка платежа для администратора (HTML): кто, что, до какой даты; ID и команда возврата копируются нажатием
async function adminCard(db: any, chargeId: string, title: string, withRefund: boolean): Promise<string> {
  const id = escapeHtml(chargeId);
  const { data: info } = await db.rpc("admin_payment_info", { p_charge_id: chargeId });
  const lines = [title];
  if (info) {
    const who = [info.name, info.username ? `@${info.username}` : ""].filter(Boolean).join(" ") || "—";
    lines.push(`${escapeHtml(who)} · <a href="tg://user?id=${info.tg_id}">профиль</a>`);
    lines.push(`${TIER_RU[info.tier] ?? info.tier}, ${info.months} мес., ${info.stars} ⭐`);
    lines.push(info.tier_ends_at
      ? `Подписка «${TIER_RU[info.tier]}» действует до ${formatDate(info.tier_ends_at, "ru")}`
      : `Подписки «${TIER_RU[info.tier]}» сейчас нет`);
    lines.push(`Текущий уровень: ${TIER_RU[info.current_tier] ?? info.current_tier}`);
  }
  lines.push(`ID: <code>${id}</code>`);
  if (withRefund) lines.push(`Возврат: <code>/refund ${id}</code>`);
  return lines.join("\n");
}

export const GRANT_USAGE = "Формат: /grant ID|@username basic|advanced месяцев\nНапример: /grant 123456789 advanced 1\nСвой ID пользователь узнаёт командой /id.";

export function parseGrant(text: string): { tgId: number | null; username: string | null; tier: string; months: number } | null {
  const [, who, tier, m] = text.trim().split(/\s+/);
  if (!who || !tier || !m) return null;
  const months = Number(m);
  if (!["basic", "advanced"].includes(tier.toLowerCase()) || ![1, 3, 6, 12].includes(months)) return null;
  if (/^\d{3,15}$/.test(who)) return { tgId: Number(who), username: null, tier: tier.toLowerCase(), months };
  const u = who.replace(/^@/, "");
  if (!/^[A-Za-z0-9_]{4,32}$/.test(u)) return null;
  return { tgId: null, username: u, tier: tier.toLowerCase(), months };
}

function parseGencode(text: string):
  | { tier: "basic" | "advanced"; months: number; count: number; uses: number }
  | null {
  const parts = text.trim().split(/\s+/);
  if (parts.length < 4 || parts.length > 5) return null;
  const [, tier, monthsS, countS, usesS] = parts;
  const months = Number(monthsS), count = Number(countS), uses = usesS ? Number(usesS) : 1;
  if (tier !== "basic" && tier !== "advanced") return null;
  if (![1, 3, 6, 12].includes(months)) return null;
  if (!Number.isInteger(count) || count < 1 || count > 50) return null;
  if (!Number.isInteger(uses) || uses < 1 || uses > 1000) return null;
  return { tier, months, count, uses };
}

async function handler(req: Request): Promise<Response> {
  const ok = () => new Response("ok");
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return ok();

  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  const appUrl = Deno.env.get("APP_URL");
  if (!token || !secret || !appUrl) {
    console.error("telegram-bot: secrets are not configured");
    return ok();
  }
  if (new URL(req.url).pathname.endsWith("/cron")) {
    try {
      return await runReminders(req, token, appUrl);
    } catch (e) {
      console.error("cron error", e);
      return json({ error: "server_error" }, 500);
    }
  }
  if (new URL(req.url).pathname.endsWith("/flags")) {
    try {
      return await notifyFlags(req, token);
    } catch (e) {
      console.error("flags error", e);
      return json({ error: "server_error" }, 500);
    }
  }
  if (new URL(req.url).pathname.endsWith("/share")) {
    try { return await prepareShare(req, token, appUrl); } catch (e) { console.error("share error", e); return json({ error: "server_error" }, 500); }
  }
  if (new URL(req.url).pathname.endsWith("/invoice")) {
    try {
      return await createInvoice(req, token);
    } catch (e) {
      console.error("invoice error", e);
      return json({ error: "server_error" }, 500);
    }
  }
  if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  let update: any;
  try {
    update = await req.json();
  } catch {
    return ok();
  }
  try {
    if (update?.pre_checkout_query) {
      await onPreCheckout(token, update.pre_checkout_query);
      return ok();
    }
    if (update?.message?.successful_payment) {
      await onPaid(token, update.message);
      return ok();
    }
    if (update?.message?.refunded_payment) {
      await onRefunded(token, update.message);
      return ok();
    }
  } catch (e) {
    console.error("payment update error", e);
    return ok();
  }
  const msg = update?.message;
  const text: string = msg?.text ?? "";
  if (!msg || !text.startsWith("/") || msg.chat?.type !== "private") return ok();

  const from = msg.from ?? {};
  const lang = langOf(from.language_code);
  const t = TEXT[lang];
  const chatId = msg.chat.id;
  const command = text.split(/\s+/)[0].split("@")[0].toLowerCase();

  const db = dbClient();
  const isAdmin = async () => {
    const { data } = await db.from("admins").select("tg_id").eq("tg_id", from.id).maybeSingle();
    return Boolean(data);
  };

  try {
    if (command === "/start") {
      await db.rpc("set_bot_blocked", { p_tg_id: from.id, p_blocked: false });
      // реферальная ссылка: t.me/<бот>?start=ref_КОД
      const arg = text.split(/\s+/)[1] || "";
      let refNote = "";
      if (/^ref_[A-Za-z0-9]{4,12}$/.test(arg)) {
        const { data: rr } = await db.rpc("ref_remember", { p_tg_id: from.id, p_code: arg.slice(4) });
        if (rr?.ok) refNote = "\n\n" + REF_TEXT[lang].welcome;
      }
      await tgCall(token, "sendMessage", {
        chat_id: chatId,
        text: t.start(from.first_name || "") + refNote,
        reply_markup: { inline_keyboard: [[{ text: t.open, web_app: { url: appUrl } }]] },
      });
    } else if (command === "/help") {
      await tgCall(token, "sendMessage", { chat_id: chatId, text: t.help + ((await isAdmin()) ? t.adminHelp : "") });
    } else if (command === "/paysupport") {
      const { data } = await db.from("admins").select("tg_id").limit(1);
      const adminId = data?.[0]?.tg_id;
      const link = adminId ? `<a href="tg://user?id=${adminId}">${lang === "en" ? "administrator" : lang === "uz" ? "administrator" : "администратор"}</a>` : "—";
      await tgCall(token, "sendMessage", { chat_id: chatId, parse_mode: "HTML", text: escapeHtml(t.paySupport("{ADMIN}")).replace("{ADMIN}", link) });
    } else if (command === "/terms") {
      await tgCall(token, "sendMessage", { chat_id: chatId, text: t.terms });
    } else if (command === "/refund") {
      if (!(await isAdmin())) {
        await tgCall(token, "sendMessage", { chat_id: chatId, text: t.notAdmin });
        return ok();
      }
      const chargeId = text.trim().split(/\s+/)[1];
      if (!chargeId) {
        await tgCall(token, "sendMessage", { chat_id: chatId, text: t.refundUsage });
        return ok();
      }
      const { data: pay } = await db.from("payments").select("stars,status,user_id").eq("charge_id", chargeId).maybeSingle();
      if (!pay) {
        await tgCall(token, "sendMessage", { chat_id: chatId, text: t.refundFail("not_found") });
        return ok();
      }
      const { data: prof } = await db.from("profiles").select("tg_id").eq("id", pay.user_id).maybeSingle();
      if (pay.status !== "refunded") {
        const r = await tgApi(token, "refundStarPayment", { user_id: prof?.tg_id, telegram_payment_charge_id: chargeId });
        if (!r.ok) {
          await tgCall(token, "sendMessage", { chat_id: chatId, text: t.refundFail(r.description || "telegram_error") });
          return ok();
        }
      }
      const { data: rr, error: re } = await db.rpc("stars_refund_payment", { p_charge_id: chargeId });
      if (re || !rr?.ok) throw re ?? new Error(JSON.stringify(rr));
      await tgCall(token, "sendMessage", {
        chat_id: chatId, parse_mode: "HTML",
        text: await adminCard(db, chargeId, `↩️ <b>Возврат выполнен: ${pay.stars} ⭐</b> — подписка по этому платежу отменена`, false),
      });
    } else if (command === "/id") {
      await tgCall(token, "sendMessage", { chat_id: chatId, parse_mode: "HTML",
        text: `${lang === "en" ? "Your Telegram ID" : lang === "uz" ? "Sizning Telegram ID" : "Ваш Telegram ID"}: <code>${from.id}</code>` });
    } else if (command === "/grant") {
      if (!(await isAdmin())) {
        await tgCall(token, "sendMessage", { chat_id: chatId, text: t.notAdmin });
        return ok();
      }
      const args = parseGrant(text);
      if (!args) {
        await tgCall(token, "sendMessage", { chat_id: chatId, text: GRANT_USAGE });
        return ok();
      }
      let tgId = args.tgId;
      if (!tgId && args.username) {
        const { data: u } = await db.from("profiles").select("tg_id").ilike("username", args.username.replace(/_/g, "\\_")).limit(2);
        if (!u || u.length !== 1) {
          await tgCall(token, "sendMessage", { chat_id: chatId, text: `Пользователь @${args.username} не найден (он должен хотя бы раз открыть приложение). Можно указать Telegram ID — пользователь узнает его командой /id.` });
          return ok();
        }
        tgId = Number(u[0].tg_id);
      }
      const { data: g, error: ge } = await db.rpc("admin_grant", { p_tg_id: tgId, p_tier: args.tier, p_months: args.months, p_admin: from.id });
      if (ge) throw ge;
      if (!g?.ok) {
        const why: Record<string, string> = { no_user: "пользователь не найден — он должен хотя бы раз открыть приложение", bad_args: "неверные параметры", forbidden: "нет прав" };
        await tgCall(token, "sendMessage", { chat_id: chatId, text: `Подписка не выдана: ${why[g?.error] ?? g?.error}.\n\n${GRANT_USAGE}` });
        return ok();
      }
      const tierRu = args.tier === "basic" ? "Базовая" : "Продвинутая";
      const d = (iso: string) => new Date(iso).toLocaleDateString("ru-RU");
      const who = `${escapeHtml(g.name ?? "")}${g.username ? ` (@${escapeHtml(g.username)})` : ""}, ID <code>${tgId}</code>`;
      await tgCall(token, "sendMessage", { chat_id: chatId, parse_mode: "HTML",
        text: `✅ Выдана подписка «${tierRu}» на ${args.months} мес.\n${who}\nПериод: ${d(g.starts_at)} — ${d(g.ends_at)}` });
      await tgApi(token, "sendMessage", { chat_id: tgId,
        text: `🎁 Вам выдана подписка «${tierRu}» на ${args.months} мес. — до ${d(g.ends_at)}.\nОткройте приложение, чтобы продолжить.`,
        reply_markup: { inline_keyboard: [[{ text: t.open, web_app: { url: appUrl } }]] } }).catch(() => {});
    } else if (command === "/gencode") {
      if (!(await isAdmin())) {
        await tgCall(token, "sendMessage", { chat_id: chatId, text: t.notAdmin });
        return ok();
      }
      const args = parseGencode(text);
      if (!args) {
        await tgCall(token, "sendMessage", { chat_id: chatId, text: t.badArgs });
        return ok();
      }
      const { data, error } = await db.rpc("admin_create_codes", {
        p_tier: args.tier,
        p_months: args.months,
        p_count: args.count,
        p_max_uses: args.uses,
        p_note: `bot ${new Date().toISOString().slice(0, 10)}`,
        p_created_by: from.id,
      });
      if (error) throw error;
      const codes = (data as string[]).map((c) => `<code>${escapeHtml(c)}</code>`).join("\n");
      await tgCall(token, "sendMessage", {
        chat_id: chatId,
        parse_mode: "HTML",
        text: `${escapeHtml(t.codes(args.tier, args.months, args.count, args.uses))}\n\n${codes}`,
      });
    }
  } catch (e) {
    console.error("telegram-bot error", e);
    await tgCall(token, "sendMessage", { chat_id: chatId, text: t.error });
  }
  return ok();
}

if (typeof Deno !== "undefined" && typeof Deno.serve === "function") {
  Deno.serve(handler);
}
