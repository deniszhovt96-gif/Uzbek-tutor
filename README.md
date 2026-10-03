# Uzbek Tutor — самоучитель узбекского языка

Telegram Mini App + Telegram Bot. Работает полностью в облаке:

| Часть | Где | Папка |
|---|---|---|
| Приложение (интерфейс) | GitHub Pages | `app/` |
| База данных и логика | Supabase | `supabase/` |
| Аудио | Cloudflare R2 (шаг 3) | — |
| Сборка и выкладка | GitHub Actions | `.github/workflows/` |

Документ с архитектурой и алгоритмом: «Самоучитель узбекского — аудит и архитектура» (claude.ai).

## Структура

```
app/                          приложение (Vite)
  index.html, src/main.js     шаг 1: страница-проверка
supabase/
  config.toml                 настройки Supabase CLI (для GitHub Actions)
  migrations/                 изменения базы — применяются автоматически
  local-tests/                проверки схемы на локальном Postgres (в Supabase не применяются)
.github/workflows/
  deploy-supabase.yml         применяет миграции к Supabase
  deploy-app.yml              собирает и публикует приложение
```

## Разовая настройка (шаг 1)

### 1. Секреты (Settings → Secrets and variables → Actions → вкладка **Secrets**)

| Имя | Значение |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | токен из Supabase: аватар → Account preferences → Access Tokens |
| `SUPABASE_PROJECT_ID` | `jjvtkvritnmwqfpvlxrs` |
| `SUPABASE_DB_PASSWORD` | пароль базы, заданный при создании проекта |

### 2. Переменная (там же → вкладка **Variables** → New repository variable)

| Имя | Значение |
|---|---|
| `SUPABASE_PUBLISHABLE_KEY` | Supabase → Project Settings → API Keys → **Publishable key** (`sb_publishable_…`). Ключ публичный, его можно видеть всем; защиту данных обеспечивает RLS. |

### 3. GitHub Pages

Settings → Pages → Build and deployment → Source: **GitHub Actions**.

### 4. Запуск

Actions → **Deploy Supabase (база данных)** → Run workflow → дождаться зелёной галочки.
Actions → **Deploy App (приложение на GitHub Pages)** → Run workflow → дождаться зелёной галочки.

Дальше всё запускается само при каждом изменении файлов.

## Как проверить шаг 1

1. Supabase → Table Editor: есть таблицы `words`, `examples`, `profiles`, `word_progress`, `plans`, `subscriptions`, `access_codes` и др. В `plans` 8 строк с ценами, в `courses` — 4 курса.
2. Адрес приложения: `https://deniszhovt96-gif.github.io/Uzbek-tutor/` — страница показывает «База данных: Подключено. Тарифов в базе: 8» и таблицу цен.
3. Цены можно поменять прямо в Supabase (Table Editor → `plans`), обновить страницу — изменения видны сразу.

## Безопасность

- Токен Supabase, пароль базы и (позже) токен бота хранятся только в секретах GitHub/Supabase, не в коде.
- Все таблицы под RLS: пользователь видит только свои данные, прямой записи из приложения нет.
- Коды подписок хранятся только в виде хешей.
