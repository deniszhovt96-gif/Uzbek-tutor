-- =============================================================================
-- Uzbek Tutor — начальная схема базы (шаг 1 MVP)
--
-- Принципы:
--   * Учебный контент (слова, примеры, курсы) хранится ровно один раз.
--   * Ссылки на аудио НЕ хранятся: адрес вычисляется из ID слова
--     (word_{id}.mp3, word_{id}_ex{n}.mp3).
--   * Все таблицы под RLS. Пользователь видит только свои строки.
--     Прямой записи из приложения нет — только через функции базы.
--   * Курсы (грамматика/история/обществознание/культура) закрыты для прямого
--     чтения: выдаются функциями с учётом уровня подписки (шаг 5).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- 1. Учебный контент: словарь
-- -----------------------------------------------------------------------------

create table public.topics (
  id          smallint primary key,
  source_no   smallint,                      -- «Тема №» из исходной таблицы (может быть неточным)
  name_ru     text not null,
  name_uz     text,
  name_en     text,
  cefr        text not null check (cefr in ('A1','A2','B1','B2')),
  sort_order  int  not null
);

create table public.words (
  id            int primary key,             -- = ID из исходной таблицы
  topic_id      smallint not null references public.topics(id),
  cefr          text not null check (cefr in ('A1','A2','B1','B2')),
  uz            text not null,               -- отображаемая форма (апострофы приведены к oʻ gʻ ʼ)
  ru            text not null,               -- перевод как в источнике, с пояснениями в скобках
  uz_key        text not null,               -- нормализованная форма для сравнения
  accept_ru     text[] not null default '{}',-- все принимаемые русские ответы (нормализованные)
  accept_uz     text[] not null default '{}',-- все принимаемые узбекские ответы (нормализованные)
  word_class    text not null default 'other' check (word_class in ('verb','phrase','other')),
  canonical_id  int references public.words(id),  -- не NULL = полный дубль другой карточки
  audio_ok      boolean not null default true,
  is_active     boolean not null default true,
  sort_key      int not null                 -- порядок изучения: CEFR → тема → ID
);
create index words_learn_order_idx on public.words (sort_key) where canonical_id is null and is_active;
create index words_topic_idx       on public.words (topic_id);
create index words_uz_key_idx      on public.words (uz_key);

create table public.examples (
  word_id       int not null references public.words(id) on delete cascade,
  n             smallint not null check (n between 1 and 5),
  uz            text not null,
  ru            text not null,
  blank_start   smallint,                    -- позиция пропуска для «вставь слово» (NULL = не годится)
  blank_len     smallint,
  blank_answer  text,
  audio_ok      boolean not null default true,
  primary key (word_id, n)
);

-- -----------------------------------------------------------------------------
-- 2. Учебный контент: курсы (грамматика, история, обществознание, культура)
-- -----------------------------------------------------------------------------

create table public.courses (
  id          text primary key check (id in ('grammar','history','civics','culture')),
  title_ru    text not null,
  title_uz    text,
  title_en    text,
  min_tier    text not null default 'free' check (min_tier in ('free','basic','advanced')),
  sort_order  int not null
);

create table public.course_sections (
  id          serial primary key,
  course_id   text not null references public.courses(id) on delete cascade,
  title_ru    text not null,
  title_uz    text,
  title_en    text,
  sort_order  int not null
);

create table public.course_units (
  id           serial primary key,
  course_id    text not null references public.courses(id) on delete cascade,
  section_id   int references public.course_sections(id) on delete set null,
  source_no    int,
  title_ru     text not null,
  title_uz     text,
  title_en     text,
  express_ru   text, express_uz text, express_en text,
  detailed_ru  text, detailed_uz text, detailed_en text,
  source       text,
  verified_at  date,                         -- дата последней сверки (обществознание)
  sort_order   int not null
);

create table public.unit_tasks (
  id            serial primary key,
  unit_id       int not null references public.course_units(id) on delete cascade,
  n             smallint not null,
  kind          text not null check (kind in ('open','choice','order','match','truefalse')),
  prompt_ru     text, prompt_uz text, prompt_en text,
  options       jsonb,
  answer        jsonb,
  source_quote  text,                        -- фраза источника, на которой основан вопрос
  origin        text not null check (origin in ('source','generated')),
  status        text not null default 'draft' check (status in ('draft','approved','rejected')),
  unique (unit_id, n)
);

create table public.timeline_events (
  id          serial primary key,
  course_id   text not null references public.courses(id) on delete cascade,
  unit_id     int references public.course_units(id) on delete set null,
  date_label  text not null,
  sort_year   int,
  text_ru     text not null,
  text_uz     text,
  text_en     text,
  sort_order  int not null
);

create table public.reference_items (
  id          serial primary key,
  course_id   text not null references public.courses(id) on delete cascade,
  title_ru    text not null,
  title_uz    text,
  title_en    text,
  value       text not null,
  sort_order  int not null
);

create table public.unit_example_links (
  unit_id  int not null references public.course_units(id) on delete cascade,
  word_id  int not null,
  n        smallint not null,
  primary key (unit_id, word_id, n),
  foreign key (word_id, n) references public.examples(word_id, n) on delete cascade
);

-- -----------------------------------------------------------------------------
-- 3. Пользователи и прогресс
-- -----------------------------------------------------------------------------

create table public.profiles (
  id             uuid primary key default gen_random_uuid(),  -- = sub в токене (auth.uid())
  tg_id          bigint unique,              -- NULL допустим (будущее мобильное приложение)
  username       text,
  first_name     text,
  last_name      text,
  language_code  text,
  ui_lang        text not null default 'ru' check (ui_lang in ('ru','uz','en')),
  timezone       text not null default 'Asia/Tashkent',
  settings       jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now(),
  last_seen_at   timestamptz not null default now()
);

create table public.word_progress (
  user_id          uuid not null references public.profiles(id) on delete cascade,
  word_id          int  not null references public.words(id),
  level            smallint not null default 0 check (level between 0 and 15),
  level_at         timestamptz not null default now(),  -- от этого момента считаются 90 дней
  due_on           date not null,                       -- дата следующей проверки (по часовому поясу пользователя)
  fail_streak      smallint not null default 0,         -- ошибок подряд на плановых проверках
  correct_count    int not null default 0,
  wrong_count      int not null default 0,
  first_seen_at    timestamptz not null default now(),
  last_correct_at  timestamptz,
  last_seen_at     timestamptz,
  primary key (user_id, word_id)
);
create index word_progress_due_idx on public.word_progress (user_id, due_on);

create table public.answer_log (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  word_id       int not null,
  session_id    uuid not null,
  seq           int not null,
  at            timestamptz not null default now(),
  ex_type       text not null,
  answer        text,
  is_correct    boolean not null,
  counted       boolean not null,            -- повлиял ли ответ на уровень
  level_before  smallint,
  level_after   smallint,
  unique (user_id, session_id, seq)          -- защита от двойной отправки
);
create index answer_log_at_idx on public.answer_log (at);

create table public.daily_stats (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  day        date not null,
  sessions   int not null default 0,
  new_words  int not null default 0,
  reviews    int not null default 0,
  correct    int not null default 0,
  wrong      int not null default 0,
  seconds    int not null default 0,
  primary key (user_id, day)
);

create table public.course_progress (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  unit_id     int  not null references public.course_units(id) on delete cascade,
  status      text not null default 'opened' check (status in ('opened','read','tested')),
  best_score  smallint,
  updated_at  timestamptz not null default now(),
  primary key (user_id, unit_id)
);

-- -----------------------------------------------------------------------------
-- 4. Подписки, цены, коды доступа, администраторы
-- -----------------------------------------------------------------------------

create table public.plans (
  id           serial primary key,
  tier         text not null check (tier in ('basic','advanced')),
  months       smallint not null check (months in (1,3,6,12)),
  price_stars  int,
  price_uzs    int,
  price_usd    numeric(10,2),
  is_active    boolean not null default true,
  unique (tier, months)
);

create table public.subscriptions (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  tier        text not null check (tier in ('basic','advanced')),
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  source      text not null check (source in ('code','stars','manual')),
  source_ref  text,                          -- id кода / платежа / комментарий
  created_at  timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index subscriptions_user_idx on public.subscriptions (user_id, ends_at);

create table public.access_codes (
  id             bigint generated always as identity primary key,
  code_hash      text not null unique,       -- sha256 нормализованного кода; сам код не хранится
  tier           text not null check (tier in ('basic','advanced')),
  months         smallint not null check (months in (1,3,6,12)),
  max_uses       int not null default 1 check (max_uses >= 1),
  used_count     int not null default 0,
  redeem_before  timestamptz,                -- NULL = без ограничения
  note           text,
  is_active      boolean not null default true,
  created_by     bigint,                     -- tg_id администратора
  created_at     timestamptz not null default now()
);

create table public.code_redemptions (
  code_id          bigint not null references public.access_codes(id),
  user_id          uuid not null references public.profiles(id) on delete cascade,
  subscription_id  bigint references public.subscriptions(id),
  redeemed_at      timestamptz not null default now(),
  primary key (code_id, user_id)
);

create table public.code_attempts (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  at       timestamptz not null default now(),
  success  boolean not null default false
);
create index code_attempts_user_idx on public.code_attempts (user_id, at);

create table public.admins (
  tg_id     bigint primary key,
  note      text,
  added_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 5. Функции подписок и кодов
-- -----------------------------------------------------------------------------

create or replace function public.tier_rank(p_tier text)
returns int language sql immutable as $$
  select case p_tier when 'advanced' then 2 when 'basic' then 1 else 0 end
$$;

-- Действующий уровень подписки текущего пользователя: 'free' | 'basic' | 'advanced'
create or replace function public.current_tier()
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.tier from public.subscriptions s
      where s.user_id = auth.uid() and s.starts_at <= now() and s.ends_at > now()
      order by public.tier_rank(s.tier) desc limit 1),
    'free')
$$;

-- Код: только A–Z и 0–9, верхний регистр (пробелы, дефисы, регистр не важны)
create or replace function public.normalize_code(p_code text)
returns text language sql immutable as $$
  select regexp_replace(upper(coalesce(p_code, '')), '[^A-Z0-9]', '', 'g')
$$;

create or replace function public.hash_code(p_code text)
returns text language sql immutable set search_path = '' as $$
  select encode(extensions.digest(public.normalize_code(p_code), 'sha256'), 'hex')
$$;

-- Активация кода пользователем. Ответ: {"ok":true,"tier":..,"ends_at":..}
-- или {"ok":false,"error":"<код ошибки>"}.
create or replace function public.redeem_code(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid       uuid := auth.uid();
  v_code      public.access_codes%rowtype;
  v_start     timestamptz;
  v_end       timestamptz;
  v_sub_id    bigint;
  v_attempts  int;
begin
  if v_uid is null or not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  -- не больше 5 неудачных попыток за час
  select count(*) into v_attempts from public.code_attempts
   where user_id = v_uid and not success and at > now() - interval '1 hour';
  if v_attempts >= 5 then
    return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
  end if;

  select * into v_code from public.access_codes
   where code_hash = public.hash_code(p_code)
   for update;

  if not found or not v_code.is_active then
    insert into public.code_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;
  if v_code.redeem_before is not null and v_code.redeem_before < now() then
    insert into public.code_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('ok', false, 'error', 'code_expired');
  end if;
  if exists (select 1 from public.code_redemptions where code_id = v_code.id and user_id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'already_redeemed');
  end if;
  if v_code.used_count >= v_code.max_uses then
    insert into public.code_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('ok', false, 'error', 'code_used_up');
  end if;

  -- код того же уровня продлевает подписку с даты её окончания
  select greatest(now(), coalesce(max(ends_at), now())) into v_start
    from public.subscriptions
   where user_id = v_uid and tier = v_code.tier and ends_at > now();
  v_end := v_start + make_interval(months => v_code.months);

  insert into public.subscriptions (user_id, tier, starts_at, ends_at, source, source_ref)
  values (v_uid, v_code.tier, v_start, v_end, 'code', v_code.id::text)
  returning id into v_sub_id;

  insert into public.code_redemptions (code_id, user_id, subscription_id)
  values (v_code.id, v_uid, v_sub_id);

  update public.access_codes set used_count = used_count + 1 where id = v_code.id;
  insert into public.code_attempts (user_id, success) values (v_uid, true);

  return jsonb_build_object('ok', true, 'tier', v_code.tier, 'starts_at', v_start, 'ends_at', v_end);
end
$$;

-- Генерация кодов (вызывает только сервер — бот администратора).
-- Возвращает коды в открытом виде ОДИН раз; в базе остаются только хеши.
-- Алфавит без похожих символов: нет 0, O, 1, I.
create or replace function public.admin_create_codes(
  p_tier text, p_months int, p_count int,
  p_max_uses int default 1, p_redeem_before timestamptz default null,
  p_note text default null, p_created_by bigint default null)
returns setof text language plpgsql security definer set search_path = '' as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 32 символа
  v_bytes    bytea;
  v_raw      text;
  v_code     text;
  i          int;
  j          int;
begin
  if p_tier not in ('basic','advanced') then raise exception 'bad tier %', p_tier; end if;
  if p_months not in (1,3,6,12) then raise exception 'bad months %', p_months; end if;
  if p_count < 1 or p_count > 500 then raise exception 'count must be 1..500'; end if;

  for i in 1..p_count loop
    loop
      v_bytes := extensions.gen_random_bytes(12);
      v_raw := '';
      for j in 0..11 loop
        -- 256 делится на 32 без остатка → равномерное распределение
        v_raw := v_raw || substr(v_alphabet, (get_byte(v_bytes, j) % 32) + 1, 1);
      end loop;
      exit when not exists (select 1 from public.access_codes where code_hash = public.hash_code(v_raw));
    end loop;
    v_code := substr(v_raw,1,4) || '-' || substr(v_raw,5,4) || '-' || substr(v_raw,9,4);
    insert into public.access_codes (code_hash, tier, months, max_uses, redeem_before, note, created_by)
    values (public.hash_code(v_raw), p_tier, p_months, greatest(p_max_uses, 1), p_redeem_before, p_note, p_created_by);
    return next v_code;
  end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- 6. Права и RLS
-- -----------------------------------------------------------------------------

-- Включаем RLS на всех таблицах
alter table public.topics             enable row level security;
alter table public.words              enable row level security;
alter table public.examples           enable row level security;
alter table public.courses            enable row level security;
alter table public.course_sections    enable row level security;
alter table public.course_units       enable row level security;
alter table public.unit_tasks         enable row level security;
alter table public.timeline_events    enable row level security;
alter table public.reference_items    enable row level security;
alter table public.unit_example_links enable row level security;
alter table public.profiles           enable row level security;
alter table public.word_progress      enable row level security;
alter table public.answer_log         enable row level security;
alter table public.daily_stats        enable row level security;
alter table public.course_progress    enable row level security;
alter table public.plans              enable row level security;
alter table public.subscriptions      enable row level security;
alter table public.access_codes       enable row level security;
alter table public.code_redemptions   enable row level security;
alter table public.code_attempts      enable row level security;
alter table public.admins             enable row level security;

-- Приложение никогда не пишет в таблицы напрямую — только через функции базы
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;

-- Словарь: читают авторизованные пользователи
grant select on public.topics, public.words, public.examples to authenticated;
create policy topics_read   on public.topics   for select to authenticated using (true);
create policy words_read    on public.words    for select to authenticated using (true);
create policy examples_read on public.examples for select to authenticated using (true);

-- Цены: видны всем (нужны и до входа)
grant select on public.plans to anon, authenticated;
create policy plans_read on public.plans for select to anon, authenticated using (is_active);

-- Свои данные пользователя: только чтение своих строк
grant select on public.profiles, public.word_progress, public.answer_log,
               public.daily_stats, public.course_progress, public.subscriptions to authenticated;
create policy profiles_own        on public.profiles        for select to authenticated using (id = auth.uid());
create policy word_progress_own   on public.word_progress   for select to authenticated using (user_id = auth.uid());
create policy answer_log_own      on public.answer_log      for select to authenticated using (user_id = auth.uid());
create policy daily_stats_own     on public.daily_stats     for select to authenticated using (user_id = auth.uid());
create policy course_progress_own on public.course_progress for select to authenticated using (user_id = auth.uid());
create policy subscriptions_own   on public.subscriptions   for select to authenticated using (user_id = auth.uid());

-- Курсы, коды, попытки, администраторы: без политик = недоступны напрямую
-- (курсы будут выдаваться функциями с учётом подписки на шаге 5)

-- Функции: по умолчанию в Postgres их может вызвать любой — закрываем лишнее
revoke execute on function public.redeem_code(text) from public, anon;
grant  execute on function public.redeem_code(text) to authenticated;
revoke execute on function public.current_tier() from public, anon;
grant  execute on function public.current_tier() to authenticated;
revoke execute on function public.admin_create_codes(text,int,int,int,timestamptz,text,bigint) from public, anon, authenticated;
grant  execute on function public.admin_create_codes(text,int,int,int,timestamptz,text,bigint) to service_role;

-- -----------------------------------------------------------------------------
-- 7. Начальные данные
-- -----------------------------------------------------------------------------

insert into public.courses (id, title_ru, title_uz, title_en, min_tier, sort_order) values
  ('grammar', 'Грамматика',       'Grammatika',     'Grammar',       'free',     1),
  ('history', 'История',          'Tarix',          'History',       'advanced', 2),
  ('civics',  'Обществознание',   'Jamiyatshunoslik','Civics',       'advanced', 3),
  ('culture', 'Культура',         'Madaniyat',      'Culture',       'advanced', 4);

-- Цены — ПРЕДЛОЖЕНИЕ, меняются прямо в таблице plans (Table Editor в Supabase)
insert into public.plans (tier, months, price_stars, price_uzs, price_usd) values
  ('basic',     1,  150,  35000,  2.99),
  ('basic',     3,  400,  95000,  7.99),
  ('basic',     6,  700, 170000, 13.99),
  ('basic',    12, 1200, 290000, 23.99),
  ('advanced',  1,  300,  70000,  5.99),
  ('advanced',  3,  800, 190000, 15.99),
  ('advanced',  6, 1400, 340000, 27.99),
  ('advanced', 12, 2400, 580000, 47.99);

-- Администратор из старой версии (лист admins). Проверьте, что это ваш Telegram ID.
insert into public.admins (tg_id, note) values (182665947, 'Denis');
