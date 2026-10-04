# Uzbek Tutor — самоучитель узбекского языка

Telegram Mini App + Telegram Bot. Работает полностью в облаке:

| Часть | Где | Папка |
|---|---|---|
| Приложение (интерфейс) | GitHub Pages | `app/` |
| База данных и логика | Supabase | `supabase/` |
| Аудио | GitHub Pages (репозиторий uzbek-audio) | — |
| Сборка и выкладка | GitHub Actions | `.github/workflows/` |

Документ с архитектурой и алгоритмом: «Самоучитель узбекского — аудит и архитектура» (claude.ai).

## Структура

```
app/                          приложение (Vite, чистый JavaScript)
  src/main.js                 вход через Telegram, навигация
  src/screens/                вкладки «Дом», «Путь», «Настройки»; сеанс, тренировка, игры, тест уровня
  src/screens/games/          игры: пары, верно/неверно, угадай слово, филворд
  src/exercises.js            генерация 15 видов упражнений
  src/exercise-view.js        отображение упражнений (общее для сеанса и тренировки)
  src/theme.js, src/icons.js  темы оформления, собственные иконки и рисунки карты
  src/session.js              очередь сеанса, повторы ошибок, отправка ответов пачками
  src/normalize.js            нормализация ответов (как в базе)
  src/i18n.js                 тексты RU / UZ / EN
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
| `SUPABASE_DB_PASSWORD` | пароль базы (Supabase → Project Settings → Database). Строка подключения собирается в workflow автоматически. |

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

## Шаг 4: вход через Telegram и бот

Функции лежат в `supabase/functions/*/index.ts` и создаются в панели Supabase
(Edge Functions → Deploy a new function → Via Editor), «Verify JWT» = выкл.

Секреты функций (Edge Functions → Secrets):

| Имя | Значение |
|---|---|
| `TELEGRAM_BOT_TOKEN` | токен бота от @BotFather |
| `TELEGRAM_WEBHOOK_SECRET` | любая случайная строка из латинских букв и цифр |
| `APP_URL` | `https://deniszhovt96-gif.github.io/Uzbek-tutor/` |

Webhook бота: открыть в браузере
`https://api.telegram.org/bot<ТОКЕН>/setWebhook?url=https://jjvtkvritnmwqfpvlxrs.supabase.co/functions/v1/telegram-bot&secret_token=<СЕКРЕТ>`

## Шаг 5–6: обучение

- Алгоритм уровней 0–15 работает в базе: `start_session`, `submit_answers`, `finish_session`, `get_home`
  (миграция `20261004150000_learning_engine.sql`), проверки — `supabase/local-tests/test_step5.sql`.
- Ответ проверяется и на телефоне (мгновенная обратная связь), и в базе (окончательно, по тем же правилам).
- Аудио: `https://deniszhovt96-gif.github.io/uzbek-audio/audio/` (адрес в `app/src/config.js`).

## Шаг 7: путь, тесты уровней, тренировка, игры, темы

Миграция `20261004200000_path_tests_games.sql`, проверки — `supabase/local-tests/test_step7.sql`.

Что можно менять без программиста (Supabase → Table Editor):

| Таблица | Что настраивается |
|---|---|
| `app_config` | число вопросов в тесте (30–40), порог сдачи в %, пауза до пересдачи в часах |
| `feature_access` | с какой подписки доступен раздел: `free` / `basic` / `advanced` |
| `plans` | цены подписок |

Тест уровня собирается заново при каждой попытке из слов и примеров уровня; верные ответы
хранятся только в базе (таблица `level_test_attempts` закрыта для чтения из приложения).
Новые слова выдаются только из открытых уровней (A1 открыт всегда, следующий — после сдачи теста).

## Безопасность

- Токен Supabase, пароль базы и (позже) токен бота хранятся только в секретах GitHub/Supabase, не в коде.
- Все таблицы под RLS: пользователь видит только свои данные, прямой записи из приложения нет.
- Коды подписок хранятся только в виде хешей.
