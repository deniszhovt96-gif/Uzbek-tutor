-- =============================================================================
-- Шаг 7: путь по уровням, тесты между уровнями CEFR, тренировка и игры, темы оформления.
--
--   Тест уровня: 35 вопросов (настраивается в app_config), собирается заново при каждой
--   попытке из слов и примеров уровня → готовых «вариантов» нет, выучить ответы нельзя.
--   Верные ответы хранятся только на сервере. Сдан при ≥ 80 % → открывается следующий уровень.
--   Не сдан → слова с ошибками сразу идут в повторение, новая попытка через 24 часа.
--   Новые слова выдаются только из открытых уровней.
--
--   Доступ к разделам по подпискам — таблица feature_access (можно менять в Table Editor).
-- =============================================================================

-- ---------------------------------------------------------------- настройки приложения
create table if not exists public.app_config (
  key   text primary key,
  value jsonb not null,
  note  text
);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
insert into public.app_config (key, value, note) values
  ('level_test_questions',      '35', 'Вопросов в тесте уровня (30–40)'),
  ('level_test_pass_pct',       '80', 'Порог сдачи теста, %'),
  ('level_test_cooldown_hours', '24', 'Через сколько часов можно пересдать после неудачи'),
  ('level_test_ready_pct',      '80', 'Тест рекомендуется, когда столько % слов уровня на уровне 4+')
on conflict (key) do nothing;

create or replace function public.cfg_int(p_key text, p_default int)
returns int language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::int from public.app_config where key = p_key), p_default)
$$;

-- ---------------------------------------------------------------- доступ к разделам
create table if not exists public.feature_access (
  feature  text primary key,
  min_tier text not null check (min_tier in ('free','basic','advanced')),
  note     text
);
alter table public.feature_access enable row level security;
revoke insert, update, delete, truncate on public.feature_access from anon, authenticated;
grant select on public.feature_access to authenticated;
drop policy if exists feature_access_read on public.feature_access;
create policy feature_access_read on public.feature_access for select to authenticated using (true);
insert into public.feature_access (feature, min_tier, note) values
  ('learn',        'free',     'Учить слова (бесплатно — 1 сеанс в день)'),
  ('topic_choice', 'free',     'Выбор темы на карте пути'),
  ('level_test',   'free',     'Тесты между уровнями'),
  ('practice',     'basic',    'Тренировка (без влияния на уровни)'),
  ('games',        'basic',    'Игры: пары, верно/неверно, угадай слово'),
  ('filword',      'advanced', 'Филворд'),
  ('grammar',      'basic',    'Грамматика'),
  ('history',      'advanced', 'История'),
  ('civics',       'advanced', 'Обществознание'),
  ('culture',      'advanced', 'Культура'),
  ('stats_ext',    'advanced', 'Расширенная статистика')
on conflict (feature) do nothing;

create or replace function public.feature_map()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(feature, jsonb_build_object(
           'allowed', public.tier_rank(public.current_tier()) >= public.tier_rank(min_tier),
           'min_tier', min_tier)), '{}'::jsonb)
  from public.feature_access
$$;

create or replace function public.feature_allowed(p_feature text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select public.tier_rank(public.current_tier()) >= public.tier_rank(min_tier)
                   from public.feature_access where feature = p_feature), false)
$$;

-- ---------------------------------------------------------------- тесты уровней: хранение
create table if not exists public.level_test_attempts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  cefr        text not null check (cefr in ('A1','A2','B1','B2')),
  questions   jsonb not null,                     -- вместе с верными ответами — клиенту не отдаётся
  answers     jsonb not null default '{}'::jsonb, -- {"0": {"a": "...", "c": true}}
  total       int not null,
  score       int,
  passed      boolean,
  started_at  timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists level_test_attempts_user_idx on public.level_test_attempts (user_id, cefr, started_at desc);
alter table public.level_test_attempts enable row level security;
revoke all on public.level_test_attempts from anon, authenticated;

-- Открытый уровень: A1 всегда; следующий — после сдачи теста предыдущего
create or replace function public.unlocked_cefr(p_user uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case (select max(cefr) from public.level_test_attempts where user_id = p_user and passed)
           when 'A1' then 'A2' when 'A2' then 'B1' when 'B1' then 'B2' when 'B2' then 'B2'
           else 'A1' end
$$;

-- Состояние уровней A1–B2 для пути и главного экрана
create or replace function public.level_status(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_now      timestamptz := public.app_now();
  v_unlocked text := public.unlocked_cefr(p_user);
  v_cool     int := public.cfg_int('level_test_cooldown_hours', 24);
  v_ready    int := public.cfg_int('level_test_ready_pct', 80);
begin
  return (
    select jsonb_agg(jsonb_build_object(
      'cefr', l.cefr,
      'total', c.total, 'started', c.started, 'ready', c.ready, 'learned', c.learned,
      'state', case when p.passed_at is not null then 'passed'
                    when l.cefr = v_unlocked then 'current' else 'locked' end,
      'passed_at', p.passed_at,
      'best_score', p.best_score, 'best_total', p.best_total,
      'attempts', p.attempts,
      'retry_at', case when p.passed_at is null and p.last_fail_at > v_now - make_interval(hours => v_cool)
                       then p.last_fail_at + make_interval(hours => v_cool) end,
      'in_progress', p.open_id,
      'recommended', c.total > 0 and c.started = c.total and c.ready * 100 >= c.total * v_ready)
      order by l.cefr)
    from (values ('A1'), ('A2'), ('B1'), ('B2')) as l(cefr)
    cross join lateral (
      select count(*) as total,
             count(wp.word_id) as started,
             count(*) filter (where public.effective_level(wp.level, wp.level_at, v_now) >= 4) as ready,
             count(*) filter (where public.effective_level(wp.level, wp.level_at, v_now) >= 7) as learned
      from public.words w
      left join public.word_progress wp on wp.word_id = w.id and wp.user_id = p_user
      where w.cefr = l.cefr and w.is_active and w.canonical_id is null
    ) c
    cross join lateral (
      select min(a.finished_at) filter (where a.passed) as passed_at,
             max(a.score) filter (where a.finished_at is not null) as best_score,
             max(a.total) as best_total,
             count(*) filter (where a.finished_at is not null) as attempts,
             max(a.finished_at) filter (where a.passed = false) as last_fail_at,
             (array_agg(a.id order by a.started_at desc) filter (
                where a.finished_at is null and a.started_at > v_now - interval '2 hours'))[1] as open_id
      from public.level_test_attempts a
      where a.user_id = p_user and a.cefr = l.cefr
    ) p
  );
end
$$;

-- ---------------------------------------------------------------- подбор неверных вариантов
-- До p_n слов, не совпадающих со словом ни по-узбекски, ни по-русски, и различных между собой
create or replace function public.pick_distractors(p_word_id int, p_n int default 3)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  w       public.words%rowtype;
  r       record;
  v_out   jsonb := '[]'::jsonb;
  v_uz    text[];
  v_ru    text[];
begin
  select * into w from public.words where id = p_word_id;
  v_uz := array[w.uz_key] || w.accept_uz;
  v_ru := array[public.key_ru(w.ru)] || w.accept_ru;
  for r in
    select c.uz, c.ru, c.uz_key, public.key_ru(c.ru) as rk
    from public.words c
    where c.is_active and c.canonical_id is null and c.id <> w.id
      and (c.topic_id = w.topic_id or c.cefr = w.cefr)
      and not (c.accept_ru && w.accept_ru)
    order by (c.topic_id = w.topic_id and c.word_class = w.word_class) desc,
             (c.word_class = w.word_class) desc, random()
    limit 30
  loop
    continue when r.uz_key = any (v_uz) or r.rk = any (v_ru);
    v_out := v_out || jsonb_build_object('uz', r.uz, 'ru', r.ru);
    v_uz := v_uz || r.uz_key;
    v_ru := v_ru || r.rk;
    exit when jsonb_array_length(v_out) >= p_n;
  end loop;
  return v_out;
end
$$;

create or replace function public.jsonb_shuffle(p jsonb)
returns jsonb language sql volatile as $$
  select coalesce(jsonb_agg(x order by random()), '[]'::jsonb) from jsonb_array_elements(p) x
$$;

-- ---------------------------------------------------------------- тест уровня: вопросы для клиента
-- Без верных ответов
create or replace function public.level_test_payload(p_attempt uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'attempt_id', a.id, 'cefr', a.cefr, 'total', a.total,
    'pass_pct', public.cfg_int('level_test_pass_pct', 80),
    'answered', (select count(*) from jsonb_object_keys(a.answers)),
    'answers', (select coalesce(jsonb_object_agg(k, v->'a'), '{}'::jsonb) from jsonb_each(a.answers) as e(k, v)),
    'questions', (select jsonb_agg((q - 'answer') || jsonb_build_object('i', i - 1) order by i)
                  from jsonb_array_elements(a.questions) with ordinality as x(q, i)))
  from public.level_test_attempts a
  where a.id = p_attempt
$$;

-- ---------------------------------------------------------------- тест уровня: начало
create or replace function public.start_level_test(p_cefr text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid      uuid := auth.uid();
  v_now      timestamptz := public.app_now();
  v_unlocked text;
  v_att      public.level_test_attempts%rowtype;
  v_last     timestamptz;
  v_cool     int := public.cfg_int('level_test_cooldown_hours', 24);
  v_n        int := least(40, greatest(30, public.cfg_int('level_test_questions', 35)));
  v_n_sent   int;
  v_n_word   int;
  v_q        jsonb := '[]'::jsonb;
  v_pattern  text[] := array['uz_ru_choice','ru_uz_choice','audio_choice','ru_uz_input',
                             'uz_ru_choice','ru_uz_choice','uz_ru_input'];
  v_type     text;
  v_i        int := 0;
  v_used     int[] := '{}';
  r          record;
  e          record;
  v_d        jsonb;
  v_opts     jsonb;
  v_answer   text;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('level_test') then return jsonb_build_object('error', 'locked_tier'); end if;
  if p_cefr is null or p_cefr not in ('A1','A2','B1','B2') then return jsonb_build_object('error', 'bad_level'); end if;
  if exists (select 1 from public.level_test_attempts where user_id = v_uid and cefr = p_cefr and passed) then
    return jsonb_build_object('error', 'already_passed');
  end if;
  v_unlocked := public.unlocked_cefr(v_uid);
  if p_cefr > v_unlocked then return jsonb_build_object('error', 'level_locked'); end if;

  -- незавершённая попытка (до 2 часов) — продолжаем
  select * into v_att from public.level_test_attempts
   where user_id = v_uid and cefr = p_cefr and finished_at is null and started_at > v_now - interval '2 hours'
   order by started_at desc limit 1;
  if found then return public.level_test_payload(v_att.id); end if;

  -- брошенные попытки закрываем как несданные
  update public.level_test_attempts a
     set finished_at = a.started_at + interval '2 hours', passed = false,
         score = (select count(*) from jsonb_each(a.answers) x where (x.value->>'c')::boolean)
   where a.user_id = v_uid and a.finished_at is null;

  -- пауза после неудачной попытки
  select max(finished_at) into v_last from public.level_test_attempts
   where user_id = v_uid and cefr = p_cefr and passed = false;
  if v_last is not null and v_last > v_now - make_interval(hours => v_cool) then
    return jsonb_build_object('error', 'cooldown', 'retry_at', v_last + make_interval(hours => v_cool));
  end if;

  v_n_sent := round(v_n * 0.3);
  v_n_word := v_n - v_n_sent;

  -- 1) вопросы по словам: сначала начатые слова (чаще — с ошибками), затем остальные слова уровня
  for r in
    select w.* from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
    where w.cefr = p_cefr and w.is_active and w.canonical_id is null
    order by (wp.word_id is null), -ln(1 - random()) / (1 + coalesce(wp.wrong_count, 0))
    limit v_n_word
  loop
    v_type := v_pattern[1 + (v_i % array_length(v_pattern, 1))];
    v_i := v_i + 1;
    if v_type = 'audio_choice' and not r.audio_ok then v_type := 'uz_ru_choice'; end if;
    v_d := public.pick_distractors(r.id, 3);
    if v_type like '%choice' and jsonb_array_length(v_d) < 3 then
      v_type := case when v_type = 'uz_ru_choice' then 'uz_ru_input' else 'ru_uz_input' end;
    end if;
    v_used := v_used || r.id;
    v_q := v_q || case v_type
      when 'uz_ru_choice' then jsonb_build_object(
        'type', v_type, 'word_id', r.id, 'prompt', r.uz, 'prompt_kind', 'uz',
        'audio_id', case when r.audio_ok then r.id end,
        'options', public.jsonb_shuffle(jsonb_build_array(r.ru) || (select jsonb_agg(d->'ru') from jsonb_array_elements(v_d) d)),
        'answer', r.ru)
      when 'ru_uz_choice' then jsonb_build_object(
        'type', v_type, 'word_id', r.id, 'prompt', r.ru, 'prompt_kind', 'ru',
        'options', public.jsonb_shuffle(jsonb_build_array(r.uz) || (select jsonb_agg(d->'uz') from jsonb_array_elements(v_d) d)),
        'answer', r.uz)
      when 'audio_choice' then jsonb_build_object(
        'type', v_type, 'word_id', r.id, 'prompt', null, 'prompt_kind', 'audio', 'audio_id', r.id,
        'options', public.jsonb_shuffle(jsonb_build_array(r.uz) || (select jsonb_agg(d->'uz') from jsonb_array_elements(v_d) d)),
        'answer', r.uz)
      when 'ru_uz_input' then jsonb_build_object(
        'type', v_type, 'word_id', r.id, 'prompt', r.ru, 'prompt_kind', 'ru', 'input', 'uz', 'answer', r.uz)
      else jsonb_build_object(
        'type', 'uz_ru_input', 'word_id', r.id, 'prompt', r.uz, 'prompt_kind', 'uz', 'input', 'ru',
        'audio_id', case when r.audio_ok then r.id end, 'answer', r.ru)
    end;
  end loop;

  -- 2) вопросы по предложениям: «вставь слово» и «переведи предложение»
  v_i := 0;
  for r in
    select w.* from public.words w
    where w.cefr = p_cefr and w.is_active and w.canonical_id is null and not (w.id = any (v_used))
      and exists (select 1 from public.examples x where x.word_id = w.id and not x.is_hidden)
    order by random()
    limit v_n_sent
  loop
    v_i := v_i + 1;
    v_type := case when v_i % 2 = 1 then 'fill_choice' else 'sentence_choice' end;
    e := null;
    if v_type = 'fill_choice' then
      select x.* into e from public.examples x
       where x.word_id = r.id and not x.is_hidden and x.blank_answer is not null
         and public.key_uz(x.blank_answer) = r.uz_key
       order by random() limit 1;
      v_d := public.pick_distractors(r.id, 3);
      if e.word_id is null or jsonb_array_length(v_d) < 3 then v_type := 'sentence_choice'; end if;
    end if;
    if v_type = 'fill_choice' then
      v_answer := e.blank_answer;
      v_opts := jsonb_build_array(v_answer) || (
        select jsonb_agg(case when e.blank_start = 0 then upper(left(d->>'uz', 1)) || substr(d->>'uz', 2)
                              else d->>'uz' end)
        from jsonb_array_elements(v_d) d);
      v_q := v_q || jsonb_build_object(
        'type', 'fill_choice', 'word_id', r.id,
        'sentence', jsonb_build_object(
          'before', substr(e.uz, 1, e.blank_start),
          'after', substr(e.uz, e.blank_start + e.blank_len + 1),
          'ru', e.ru),
        'options', public.jsonb_shuffle(v_opts), 'answer', v_answer);
    else
      select x.* into e from public.examples x
       where x.word_id = r.id and not x.is_hidden order by random() limit 1;
      select jsonb_agg(s.ru) into v_opts from (
        select distinct on (public.key_ru(x.ru)) x.ru
        from public.examples x join public.words w2 on w2.id = x.word_id
        where w2.cefr = p_cefr and x.word_id <> r.id and not x.is_hidden
          and public.key_ru(x.ru) <> public.key_ru(e.ru)
          and x.word_id in (select w3.id from public.words w3 where w3.cefr = p_cefr and w3.is_active
                            order by random() limit 12)
        order by public.key_ru(x.ru), random()
        limit 3) s;
      continue when v_opts is null or jsonb_array_length(v_opts) < 3;
      v_q := v_q || jsonb_build_object(
        'type', 'sentence_choice', 'word_id', r.id, 'prompt', e.uz, 'prompt_kind', 'uz_sentence',
        'audio_example', case when e.audio_ok then jsonb_build_object('word_id', e.word_id, 'n', e.n) end,
        'options', public.jsonb_shuffle(jsonb_build_array(e.ru) || v_opts), 'answer', e.ru);
    end if;
  end loop;

  if jsonb_array_length(v_q) = 0 then return jsonb_build_object('error', 'no_material'); end if;

  insert into public.level_test_attempts (user_id, cefr, questions, total, started_at)
  values (v_uid, p_cefr, public.jsonb_shuffle(v_q), jsonb_array_length(v_q), v_now)
  returning * into v_att;
  return public.level_test_payload(v_att.id);
end
$$;

-- ---------------------------------------------------------------- тест уровня: ответ на вопрос
-- Результат вопроса не сообщается до конца теста. Ответ на вопрос принимается один раз.
create or replace function public.answer_level_test(p_attempt uuid, p_index int, p_answer text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_att public.level_test_attempts%rowtype;
  q     jsonb;
  w     public.words%rowtype;
  v_ok  boolean;
  v_a   text := left(coalesce(p_answer, ''), 300);
begin
  select * into v_att from public.level_test_attempts where id = p_attempt and user_id = v_uid for update;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if v_att.finished_at is not null then return jsonb_build_object('error', 'finished'); end if;
  if v_att.started_at < public.app_now() - interval '2 hours' then return jsonb_build_object('error', 'expired'); end if;
  if p_index is null or p_index < 0 or p_index >= v_att.total then return jsonb_build_object('error', 'bad_index'); end if;
  if v_att.answers ? p_index::text then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  q := v_att.questions -> p_index;
  select * into w from public.words where id = (q->>'word_id')::int;
  v_ok := case q->>'type'
    when 'uz_ru_choice'    then public.key_ru(v_a) <> '' and public.key_ru(v_a) = public.key_ru(q->>'answer')
    when 'sentence_choice' then public.key_ru(v_a) <> '' and public.key_ru(v_a) = public.key_ru(q->>'answer')
    when 'uz_ru_input'     then public.key_ru(v_a) <> '' and public.key_ru(v_a) = any (w.accept_ru)
    when 'ru_uz_input'     then public.key_uz(v_a) <> '' and (public.key_uz(v_a) = w.uz_key or public.key_uz(v_a) = any (w.accept_uz))
    else public.key_uz(v_a) <> '' and public.key_uz(v_a) = public.key_uz(q->>'answer')
  end;
  update public.level_test_attempts
     set answers = answers || jsonb_build_object(p_index::text, jsonb_build_object('a', v_a, 'c', v_ok))
   where id = p_attempt;
  return jsonb_build_object('ok', true, 'answered', (select count(*) from jsonb_object_keys(v_att.answers)) + 1);
end
$$;

-- ---------------------------------------------------------------- тест уровня: итог
create or replace function public.finish_level_test(p_attempt uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_now   timestamptz := public.app_now();
  v_att   public.level_test_attempts%rowtype;
  v_score int;
  v_need  int;
  v_pass  boolean;
  v_today date;
  v_cool  int := public.cfg_int('level_test_cooldown_hours', 24);
begin
  select * into v_att from public.level_test_attempts where id = p_attempt and user_id = v_uid for update;
  if not found then return jsonb_build_object('error', 'not_found'); end if;

  if v_att.finished_at is null then
    v_score := (select count(*) from jsonb_each(v_att.answers) x where (x.value->>'c')::boolean);
    v_need := ceil(v_att.total * public.cfg_int('level_test_pass_pct', 80) / 100.0);
    v_pass := v_score >= v_need;
    update public.level_test_attempts set score = v_score, passed = v_pass, finished_at = v_now
     where id = p_attempt returning * into v_att;
    -- слова с ошибками — в повторение уже сегодня (уровни не меняются)
    v_today := public.user_today(v_uid);
    update public.word_progress wp set due_on = v_today
     where wp.user_id = v_uid and wp.due_on > v_today
       and wp.word_id in (
         select (q->>'word_id')::int
         from jsonb_array_elements(v_att.questions) with ordinality as x(q, i)
         where not coalesce((v_att.answers -> (i - 1)::text ->> 'c')::boolean, false));
  end if;

  v_need := ceil(v_att.total * public.cfg_int('level_test_pass_pct', 80) / 100.0);
  return jsonb_build_object(
    'cefr', v_att.cefr, 'score', v_att.score, 'total', v_att.total, 'need', v_need, 'passed', v_att.passed,
    'next_cefr', case when v_att.passed then case v_att.cefr when 'A1' then 'A2' when 'A2' then 'B1' when 'B1' then 'B2' end end,
    'course_done', v_att.passed and v_att.cefr = 'B2',
    'retry_at', case when not v_att.passed then v_att.finished_at + make_interval(hours => v_cool) end,
    'mistakes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'type', q->>'type',
               'prompt', case when q ? 'sentence'
                              then (q->'sentence'->>'before') || '___' || (q->'sentence'->>'after')
                              else q->>'prompt' end,
               'hint', q->'sentence'->>'ru',
               'audio_id', q->'audio_id',
               'your', v_att.answers -> (i - 1)::text ->> 'a',
               'correct', q->>'answer') order by i), '[]'::jsonb)
      from jsonb_array_elements(v_att.questions) with ordinality as x(q, i)
      where not coalesce((v_att.answers -> (i - 1)::text ->> 'c')::boolean, false))
  );
end
$$;

-- ---------------------------------------------------------------- тренировка и игры
-- Слова, которые пользователь уже начал (уровень ≥ 1), в случайном порядке. На уровни не влияет.
create or replace function public.start_practice(p_feature text default 'practice', p_count int default 20)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_ids int[];
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_feature not in ('practice','games','filword') then return jsonb_build_object('error', 'bad_feature'); end if;
  if not public.feature_allowed(p_feature) then
    return jsonb_build_object('error', 'locked_tier',
      'need', (select min_tier from public.feature_access where feature = p_feature));
  end if;
  select coalesce(array_agg(word_id), '{}') into v_ids from (
    select wp.word_id from public.word_progress wp
    where wp.user_id = v_uid and wp.level >= 1
    order by random()
    limit least(greatest(coalesce(p_count, 20), 4), 60)) t;
  return jsonb_build_object(
    'started', (select count(*) from public.word_progress where user_id = v_uid and level >= 1),
    'items', coalesce((select jsonb_agg(public.word_card(x, v_uid, v_now)) from unnest(v_ids) x), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------- сеанс: новые слова только из открытых уровней
create or replace function public.start_session(p_mode text default 'normal', p_topic_id int default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid      uuid := auth.uid();
  v_now      timestamptz := public.app_now();
  v_today    date;
  v_tier     text;
  v_size     int;
  v_new_max  int;
  v_due      int;
  v_r        int;
  v_n        int;
  v_review   int[];
  v_new      int[];
  v_unlocked text;
  v_sess     public.study_sessions%rowtype;
begin
  if v_uid is null or not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('error', 'not_authenticated');
  end if;
  if p_mode not in ('normal','review') then
    return jsonb_build_object('error', 'bad_mode');
  end if;
  v_today := public.user_today(v_uid);
  v_tier := public.current_tier();
  v_unlocked := public.unlocked_cefr(v_uid);

  if p_topic_id is not null then
    if not public.feature_allowed('topic_choice') then
      return jsonb_build_object('error', 'locked_tier');
    end if;
    if (select cefr from public.topics where id = p_topic_id) > v_unlocked then
      return jsonb_build_object('error', 'level_locked');
    end if;
  end if;

  -- незавершённый сеанс за последние 3 часа — продолжаем его (перезагрузка приложения)
  select * into v_sess from public.study_sessions
   where user_id = v_uid and finished_at is null and local_day = v_today
     and started_at > v_now - interval '3 hours' and mode = p_mode
   order by started_at desc limit 1;

  if not found then
    if v_tier = 'free' and exists (select 1 from public.study_sessions
                                    where user_id = v_uid and local_day = v_today) then
      return jsonb_build_object('error', 'daily_limit', 'tier', v_tier);
    end if;

    select size, new_max into v_size, v_new_max from public.session_params(v_uid, v_tier);

    select count(*) into v_due from public.word_progress
     where user_id = v_uid and due_on <= v_today;

    if p_mode = 'review' then
      v_r := least(v_due, v_size);
      v_n := 0;
    else
      v_r := least(v_due, v_size, 10 + ceil(greatest(0, v_due - 10) / 2.0)::int);
      v_n := least(v_new_max, v_size - v_r);
    end if;

    select coalesce(array_agg(word_id order by grp, lvl_order, ratio desc, eff), '{}') into v_review
    from (
      select wp.word_id,
             public.effective_level(wp.level, wp.level_at, v_now) as eff,
             case when wp.level >= 2 and v_now - wp.level_at >= interval '75 days' then 0
                  when public.effective_level(wp.level, wp.level_at, v_now) <= 6 then 1
                  else 2 end as grp,
             case when public.effective_level(wp.level, wp.level_at, v_now) <= 6
                  then public.effective_level(wp.level, wp.level_at, v_now) else 0 end as lvl_order,
             (v_today - coalesce(wp.last_correct_at, wp.first_seen_at)::date)::numeric
               / greatest(public.interval_days(public.effective_level(wp.level, wp.level_at, v_now)), 1) as ratio
      from public.word_progress wp
      where wp.user_id = v_uid and wp.due_on <= v_today
      order by 3, 4, 5 desc, 2
      limit v_r
    ) t;

    select coalesce(array_agg(id order by sort_key), '{}') into v_new
    from (
      select w.id, w.sort_key from public.words w
      where w.is_active and w.canonical_id is null
        and w.cefr <= v_unlocked
        and (p_topic_id is null or w.topic_id = p_topic_id)
        and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id)
      order by w.sort_key
      limit v_n
    ) t;

    insert into public.study_sessions (user_id, local_day, mode, tier, word_ids, new_ids, started_at)
    values (v_uid, v_today, p_mode, v_tier, v_review || v_new, v_new, v_now)
    returning * into v_sess;

    insert into public.daily_stats (user_id, day, sessions) values (v_uid, v_today, 1)
    on conflict (user_id, day) do update set sessions = public.daily_stats.sessions + 1;
  end if;

  return jsonb_build_object(
    'session_id', v_sess.id,
    'tier', v_tier,
    'local_day', v_sess.local_day,
    'review_count', cardinality(v_sess.word_ids) - cardinality(v_sess.new_ids),
    'new_count', cardinality(v_sess.new_ids),
    'items', coalesce((select jsonb_agg(public.word_card(x.id, v_uid, v_now) order by x.ord)
                       from unnest(v_sess.word_ids) with ordinality as x(id, ord)), '[]'::jsonb)
  );
end
$$;

-- ---------------------------------------------------------------- приём ответов: новые виды заданий
-- target: 'ru' | 'uz' | 'blank' | 'token' (слово с окончанием) | 'sentence_ru' | 'sentence_uz'
create or replace function public.submit_answers(p_session_id uuid, p_events jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid      uuid := auth.uid();
  v_now      timestamptz := public.app_now();
  v_today    date;
  v_sess     public.study_sessions%rowtype;
  ev         jsonb;
  v_word     public.words%rowtype;
  v_wp       public.word_progress%rowtype;
  v_ex       public.examples%rowtype;
  v_seq      int;
  v_kind     text;
  v_target   text;
  v_answer   text;
  v_first    boolean;
  v_correct  boolean;
  v_counted  boolean;
  v_eff      int;
  v_new      int;
  v_level_at timestamptz;
  v_due      date;
  v_fail     int;
  v_right    text;
  v_results  jsonb := '[]'::jsonb;
  v_inserted int;
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;
  select * into v_sess from public.study_sessions where id = p_session_id and user_id = v_uid;
  if not found then
    return jsonb_build_object('error', 'session_not_found');
  end if;
  if v_sess.started_at < v_now - interval '24 hours' then
    return jsonb_build_object('error', 'session_expired');
  end if;
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 100 then
    return jsonb_build_object('error', 'bad_events');
  end if;
  v_today := public.user_today(v_uid);

  for ev in select * from jsonb_array_elements(p_events) loop
    v_seq  := (ev->>'seq')::int;
    v_kind := ev->>'kind';
    if v_seq is null or v_kind not in ('shown','answer') then continue; end if;
    if not ((ev->>'word_id')::int = any (v_sess.word_ids)) then
      v_results := v_results || jsonb_build_object('seq', v_seq, 'error', 'word_not_in_session');
      continue;
    end if;
    select * into v_word from public.words where id = (ev->>'word_id')::int;

    if v_kind = 'shown' then
      insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
      values (v_uid, v_word.id, 0, v_now, v_today, v_now)
      on conflict (user_id, word_id) do nothing;
      get diagnostics v_inserted = row_count;
      if v_inserted > 0 then
        insert into public.daily_stats (user_id, day, new_words) values (v_uid, v_today, 1)
        on conflict (user_id, day) do update set new_words = public.daily_stats.new_words + 1;
      end if;
      v_results := v_results || jsonb_build_object('seq', v_seq, 'ok', true);
      continue;
    end if;

    insert into public.answer_log (user_id, word_id, session_id, seq, ex_type, answer, is_correct, counted)
    values (v_uid, v_word.id, p_session_id, v_seq, coalesce(ev->>'ex_type', '?'), left(ev->>'answer', 200), false, false)
    on conflict (user_id, session_id, seq) do nothing;
    get diagnostics v_inserted = row_count;
    if v_inserted = 0 then
      v_results := v_results || jsonb_build_object('seq', v_seq, 'duplicate', true);
      continue;
    end if;

    v_target := ev->>'target';
    v_answer := coalesce(ev->>'answer', '');
    v_right := null;
    v_ex := null;
    if v_target in ('blank','token','sentence_ru','sentence_uz') then
      select e.* into v_ex from public.examples e
       where e.word_id = (ev->'example'->>'word_id')::int and e.n = (ev->'example'->>'n')::int
         and not e.is_hidden
         and (e.word_id = v_word.id or e.word_id in (select a.id from public.words a where a.canonical_id = v_word.id));
    end if;

    if v_target = 'ru' then
      v_correct := public.key_ru(v_answer) <> '' and public.key_ru(v_answer) = any (v_word.accept_ru);
      v_right := v_word.ru;
    elsif v_target = 'uz' then
      v_correct := public.key_uz(v_answer) <> ''
                   and (public.key_uz(v_answer) = v_word.uz_key or public.key_uz(v_answer) = any (v_word.accept_uz));
      v_right := v_word.uz;
    elsif v_target = 'blank' then
      v_right := v_ex.blank_answer;
      v_correct := v_right is not null and public.key_uz(v_answer) = public.key_uz(v_right);
    elsif v_target = 'token' then
      -- слово целиком вместе с окончанием, начиная с места пропуска
      if v_ex.blank_start is not null then
        v_right := substring(substr(v_ex.uz, v_ex.blank_start + 1) from '^[A-Za-zʻʼ'']+');
      end if;
      v_correct := v_right is not null and public.key_uz(v_answer) = public.key_uz(v_right);
    elsif v_target = 'sentence_ru' then
      v_right := v_ex.ru;
      v_correct := v_right is not null and public.key_ru(v_answer) <> '' and public.key_ru(v_answer) = public.key_ru(v_right);
    elsif v_target = 'sentence_uz' then
      v_right := v_ex.uz;
      v_correct := v_right is not null and public.key_uz(v_answer) <> '' and public.key_uz(v_answer) = public.key_uz(v_right);
    else
      v_correct := false;
    end if;
    v_first := coalesce(ev->>'attempt', 'first') = 'first';

    insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
    values (v_uid, v_word.id, 0, v_now, v_today, v_now)
    on conflict (user_id, word_id) do nothing;
    select * into v_wp from public.word_progress
     where user_id = v_uid and word_id = v_word.id for update;

    v_eff := public.effective_level(v_wp.level, v_wp.level_at, v_now);
    if v_eff < v_wp.level then
      v_level_at := v_wp.level_at + make_interval(days => 90 * (v_wp.level - v_eff));
    else
      v_level_at := v_wp.level_at;
    end if;

    v_counted := (v_eff <= 1) or (v_first and v_wp.due_on <= v_today);
    v_new  := v_eff;
    v_fail := v_wp.fail_streak;
    v_due  := v_wp.due_on;

    if v_counted and v_correct then
      v_new := least(15, v_eff + 1);
      v_level_at := v_now;
      v_fail := 0;
      v_due := v_today + public.interval_days(v_new);
    elsif v_counted and not v_correct then
      v_due := v_today;
      if v_eff >= 2 then
        v_fail := v_fail + 1;
        if v_fail >= 2 then
          v_new := greatest(1, v_eff - 1);
          v_level_at := v_now;
          v_fail := 0;
        end if;
      end if;
    end if;

    update public.word_progress set
      level = v_new,
      level_at = v_level_at,
      due_on = v_due,
      fail_streak = v_fail,
      correct_count = correct_count + case when v_counted and v_correct then 1 else 0 end,
      wrong_count   = wrong_count   + case when not v_correct then 1 else 0 end,
      last_correct_at = case when v_counted and v_correct then v_now else last_correct_at end,
      last_seen_at = v_now
    where user_id = v_uid and word_id = v_word.id;

    update public.answer_log set is_correct = v_correct, counted = v_counted,
           level_before = v_eff, level_after = v_new
     where user_id = v_uid and session_id = p_session_id and seq = v_seq;

    insert into public.daily_stats (user_id, day, correct, wrong, reviews)
    values (v_uid, v_today, case when v_correct then 1 else 0 end, case when v_correct then 0 else 1 end,
            case when v_counted and v_eff >= 2 then 1 else 0 end)
    on conflict (user_id, day) do update set
      correct = public.daily_stats.correct + excluded.correct,
      wrong   = public.daily_stats.wrong + excluded.wrong,
      reviews = public.daily_stats.reviews + excluded.reviews;

    v_results := v_results || jsonb_build_object(
      'seq', v_seq, 'correct', v_correct, 'counted', v_counted,
      'level', v_new, 'due_on', v_due, 'correct_answer', v_right);
  end loop;

  return jsonb_build_object('ok', true, 'results', v_results);
end
$$;

-- ---------------------------------------------------------------- главный экран
create or replace function public.get_home()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_today date;
  v_tier text;
  v_unlocked text;
  v_size int; v_new_max int; v_due int; v_r int; v_n int; v_left int; v_left_all int;
  v_free_used boolean;
  v_passed_unlocked boolean;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  v_tier := public.current_tier();
  v_unlocked := public.unlocked_cefr(v_uid);
  select size, new_max into v_size, v_new_max from public.session_params(v_uid, v_tier);
  select count(*) into v_due from public.word_progress where user_id = v_uid and due_on <= v_today;
  select count(*) filter (where w.cefr <= v_unlocked), count(*) into v_left, v_left_all
    from public.words w
   where w.is_active and w.canonical_id is null
     and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id);
  v_r := least(v_due, v_size, 10 + ceil(greatest(0, v_due - 10) / 2.0)::int);
  v_n := least(v_new_max, v_size - v_r, v_left);
  v_free_used := v_tier = 'free' and exists (
    select 1 from public.study_sessions where user_id = v_uid and local_day = v_today);
  v_passed_unlocked := exists (select 1 from public.level_test_attempts
                                where user_id = v_uid and cefr = v_unlocked and passed);
  return jsonb_build_object(
    'tier', v_tier,
    'today', v_today,
    'plan_new', v_n,
    'plan_review', v_r,
    'due_total', v_due,
    'daily_limit_reached', v_free_used,
    'unlocked', v_unlocked,
    'need_test', v_left = 0 and v_left_all > 0 and not v_passed_unlocked,
    'words_started', (select count(*) from public.word_progress where user_id = v_uid),
    'words_basic', (select count(*) from public.word_progress
                     where user_id = v_uid and public.effective_level(level, level_at, v_now) >= 7),
    'words_left', v_left,
    'today_stats', (select to_jsonb(d) - 'user_id' from public.daily_stats d where d.user_id = v_uid and d.day = v_today),
    'streak', (
      with recursive s(day) as (
        select v_today where exists (select 1 from public.daily_stats where user_id = v_uid and day = v_today and (correct + wrong) > 0)
        union all
        select s.day - 1 from s
        where exists (select 1 from public.daily_stats where user_id = v_uid and day = s.day - 1 and (correct + wrong) > 0)
      ) select count(*) from s),
    'levels', public.level_status(v_uid),
    'features', public.feature_map(),
    'test_questions', least(40, greatest(30, public.cfg_int('level_test_questions', 35))),
    'test_pass_pct', public.cfg_int('level_test_pass_pct', 80)
  );
end
$$;

-- ---------------------------------------------------------------- карта пути
create or replace function public.get_path()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_unlocked text;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_unlocked := public.unlocked_cefr(v_uid);
  return jsonb_build_object(
    'unlocked', v_unlocked,
    'levels', public.level_status(v_uid),
    'features', public.feature_map(),
    'topics', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', t.id, 'name', t.name_ru, 'name_uz', t.name_uz, 'name_en', t.name_en, 'cefr', t.cefr,
               'total', c.total, 'started', c.started, 'learned', c.learned,
               'locked', t.cefr > v_unlocked)
             order by t.sort_order), '[]'::jsonb)
      from public.topics t
      cross join lateral (
        select count(*) as total,
               count(wp.word_id) as started,
               count(*) filter (where public.effective_level(wp.level, wp.level_at, v_now) >= 7) as learned
        from public.words w
        left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
        where w.topic_id = t.id and w.is_active and w.canonical_id is null
      ) c
      where c.total > 0)
  );
end
$$;

-- ---------------------------------------------------------------- настройки: тема оформления
create or replace function public.update_settings(p_ui_lang text default null, p_settings jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_clean jsonb := '{}'::jsonb;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_ui_lang is not null and p_ui_lang not in ('ru','uz','en') then
    return jsonb_build_object('error', 'bad_lang');
  end if;
  if p_settings is not null then
    if p_settings ? 'session_size' then
      v_clean := v_clean || jsonb_build_object('session_size', least(60, greatest(10, (p_settings->>'session_size')::int)));
    end if;
    if p_settings ? 'new_max' then
      v_clean := v_clean || jsonb_build_object('new_max', least(30, greatest(0, (p_settings->>'new_max')::int)));
    end if;
    if p_settings ? 'audio_exercises' then
      v_clean := v_clean || jsonb_build_object('audio_exercises', (p_settings->>'audio_exercises')::boolean);
    end if;
    if p_settings ? 'intensity' and p_settings->>'intensity' in ('light','medium','intense') then
      v_clean := v_clean || jsonb_build_object('intensity', p_settings->>'intensity');
    end if;
    if p_settings ? 'theme' and p_settings->>'theme' in ('telegram','light','dark','gray','sand','midnight') then
      v_clean := v_clean || jsonb_build_object('theme', p_settings->>'theme');
    end if;
  end if;
  update public.profiles
     set ui_lang = coalesce(p_ui_lang, ui_lang),
         settings = settings || v_clean
   where id = v_uid;
  return public.get_me();
end
$$;

-- ---------------------------------------------------------------- права
revoke execute on function public.cfg_int(text, int) from public, anon, authenticated;
revoke execute on function public.feature_map() from public, anon;
revoke execute on function public.feature_allowed(text) from public, anon;
revoke execute on function public.unlocked_cefr(uuid) from public, anon, authenticated;
revoke execute on function public.level_status(uuid) from public, anon, authenticated;
revoke execute on function public.pick_distractors(int, int) from public, anon, authenticated;
revoke execute on function public.level_test_payload(uuid) from public, anon, authenticated;
revoke execute on function public.start_level_test(text) from public, anon;
revoke execute on function public.answer_level_test(uuid, int, text) from public, anon;
revoke execute on function public.finish_level_test(uuid) from public, anon;
revoke execute on function public.start_practice(text, int) from public, anon;
revoke execute on function public.get_path() from public, anon;
grant execute on function public.feature_map() to authenticated;
grant execute on function public.feature_allowed(text) to authenticated;
grant execute on function public.start_level_test(text) to authenticated;
grant execute on function public.answer_level_test(uuid, int, text) to authenticated;
grant execute on function public.finish_level_test(uuid) to authenticated;
grant execute on function public.start_practice(text, int) to authenticated;
grant execute on function public.get_path() to authenticated;
