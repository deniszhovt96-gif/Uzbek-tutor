// Edge Function: telegram-bot
// Webhook бота @uzbek_tutor_bot.
//   /start             — приветствие и кнопка «Открыть приложение»
//   /help              — список команд
//   /gencode T M N [U] — (только админ) N кодов подписки T (basic|advanced) на M месяцев (1,3,6,12),
//                        U — сколько раз можно активировать каждый код (по умолчанию 1)
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
    help: "Команды:\n/start — открыть приложение\n/help — помощь",
    adminHelp: "\n\nАдминистратор:\n/gencode basic|advanced 1|3|6|12 количество [активаций]\nНапример: /gencode basic 1 5",
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
    help: "Buyruqlar:\n/start — ilovani ochish\n/help — yordam",
    adminHelp: "\n\nAdministrator:\n/gencode basic|advanced 1|3|6|12 soni [faollashtirish]",
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
    help: "Commands:\n/start — open the app\n/help — help",
    adminHelp: "\n\nAdmin:\n/gencode basic|advanced 1|3|6|12 count [uses]",
    notAdmin: "This command is for administrators only.",
    badArgs: "Format: /gencode basic|advanced 1|3|6|12 count [uses]",
    codes: (tier: string, months: number, n: number, uses: number) =>
      `Codes created: ${n}\nPlan: ${tier}, ${months} mo.\nUses per code: ${uses}\n\nCodes are shown only once — save them:`,
    error: "Command failed. Please try again later.",
  },
} as const;

function langOf(code?: string): Lang {
  if (!code) return "ru";
  if (code.startsWith("uz")) return "uz";
  if (code.startsWith("ru")) return "ru";
  return "en";
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

async function tgCall(token: string, method: string, payload: unknown): Promise<void> {
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) console.error(`telegram ${method} failed`, res.status, await res.text());
}

export function parseGencode(text: string):
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
  if (req.method !== "POST") return ok();

  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  const appUrl = Deno.env.get("APP_URL");
  if (!token || !secret || !appUrl) {
    console.error("telegram-bot: secrets are not configured");
    return ok();
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
  const msg = update?.message;
  const text: string = msg?.text ?? "";
  if (!msg || !text.startsWith("/") || msg.chat?.type !== "private") return ok();

  const from = msg.from ?? {};
  const lang = langOf(from.language_code);
  const t = TEXT[lang];
  const chatId = msg.chat.id;
  const command = text.split(/\s+/)[0].split("@")[0].toLowerCase();

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const isAdmin = async () => {
    const { data } = await db.from("admins").select("tg_id").eq("tg_id", from.id).maybeSingle();
    return Boolean(data);
  };

  try {
    if (command === "/start") {
      await tgCall(token, "sendMessage", {
        chat_id: chatId,
        text: t.start(from.first_name || ""),
        reply_markup: { inline_keyboard: [[{ text: t.open, web_app: { url: appUrl } }]] },
      });
    } else if (command === "/help") {
      await tgCall(token, "sendMessage", { chat_id: chatId, text: t.help + ((await isAdmin()) ? t.adminHelp : "") });
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
