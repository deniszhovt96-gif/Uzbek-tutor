-- =============================================================================
-- Шаг 11 (часть 2; правила подписок — в 20261005180000_subscription_rules.sql).
--   • Состав сеанса: не меньше половины new_max новых слов, но если новых слов осталось мало — сеанс добирается повторениями.
--   • Повторение: слова с ошибкой (fail_streak > 0) идут первыми — раньше слов более высокого уровня.
--   • Очередь подписок для экрана «Подписка» (действующая и следующие).
--   • Экспресс-проверка темы: все слова темы открытого уровня; верный ответ → уровень 15, следующий показ
--     через 85 дней. Контрольная по пройденному: 20 начатых слов, на уровни не влияет, ошибки → повторение сегодня.
--   • Ссылка на группу приложения.
-- =============================================================================

insert into public.app_config (key, value, note) values
  ('review_quiz_questions',     '20', 'Вопросов в контрольной по пройденному')
on conflict (key) do nothing;

-- группа приложения «Uzbek tutor bot group» (кнопка на «Доме» и в «Настройках»); не перезаписываем, если ссылку уже поменяли
update public.app_config set value = to_jsonb('https://t.me/+luNI8b4qZ1Y4MTA6'::text)
 where key = 'community_url' and coalesce(value #>> '{}', '') = '';

insert into public.feature_access (feature, min_tier, note) values
  ('topic_check',    'free',     'Экспресс-проверка темы (знакомые слова сразу на уровень 15)'),
  ('review_quiz',    'free',     'Контрольная по пройденному')
on conflict (feature) do nothing;

-- Состав сеанса: R повторений и N новых. Новых не меньше половины new_max (если есть что учить).
create or replace function public.session_plan(p_due int, p_size int, p_new_max int, p_left int, p_mode text)
returns table (r int, n int) language sql immutable as $$
  with x as (
    select case when p_mode = 'review' then least(p_due, p_size)
                else least(p_due, p_size - least(ceil(p_new_max / 2.0)::int, p_left, p_size),
                           10 + ceil(greatest(0, p_due - 10) / 2.0)::int) end as r)
  select x.r, case when p_mode = 'review' then 0 else least(p_new_max, p_size - x.r, p_left) end from x
$$;

-- ---------------------------------------------------------------- сеанс
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
  v_left     int;
  v_r        int;
  v_n        int;
  v_limit    int;
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
    -- лимит обучающих сеансов в день; «только повторение» в платных подписках не ограничено
    v_limit := public.sessions_limit(v_tier);
    if v_limit > 0 and (v_tier = 'free' or p_mode = 'normal')
       and (select count(*) from public.study_sessions
             where user_id = v_uid and local_day = v_today and (v_tier = 'free' or mode = 'normal')) >= v_limit then
      return jsonb_build_object('error', 'daily_limit', 'tier', v_tier, 'limit', v_limit);
    end if;

    select size, new_max into v_size, v_new_max from public.session_params(v_uid, v_tier);
    select count(*) into v_due from public.word_progress where user_id = v_uid and due_on <= v_today;
    select count(*) into v_left from public.words w
     where w.is_active and w.canonical_id is null and w.cefr <= v_unlocked
       and (p_topic_id is null or w.topic_id = p_topic_id)
       and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id);
    select r, n into v_r, v_n from public.session_plan(v_due, v_size, v_new_max, v_left, p_mode);

    -- повторения по приоритету: ошибка в прошлый раз → грань понижения → заучивание (ниже уровень раньше) → по просрочке
    select coalesce(array_agg(word_id order by grp, lvl_order, ratio desc, eff), '{}') into v_review
    from (
      select wp.word_id,
             public.effective_level(wp.level, wp.level_at, v_now) as eff,
             case when wp.fail_streak > 0 then 0
                  when wp.level >= 2 and v_now - wp.level_at >= interval '75 days' then 1
                  when public.effective_level(wp.level, wp.level_at, v_now) <= 6 then 2
                  else 3 end as grp,
             case when public.effective_level(wp.level, wp.level_at, v_now) <= 6 or wp.fail_streak > 0
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
  v_limit int; v_used int;
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
  select r, n into v_r, v_n from public.session_plan(v_due, v_size, v_new_max, v_left, 'normal');
  v_limit := public.sessions_limit(v_tier);
  select count(*) into v_used from public.study_sessions
   where user_id = v_uid and local_day = v_today and (v_tier = 'free' or mode = 'normal');
  v_passed_unlocked := exists (select 1 from public.level_test_attempts
                                where user_id = v_uid and cefr = v_unlocked and passed);
  return jsonb_build_object(
    'tier', v_tier,
    'today', v_today,
    'plan_new', v_n,
    'plan_review', v_r,
    'due_total', v_due,
    'sessions_limit', v_limit,
    'sessions_used', v_used,
    'daily_limit_reached', v_limit > 0 and v_used >= v_limit,
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

-- Подписки пользователя: действующая и следующие в очереди (для экрана «Подписка»)
create or replace function public.get_my_subscriptions()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('tier', s.tier, 'starts_at', s.starts_at, 'ends_at', s.ends_at,
                                               'active', s.starts_at <= now()) order by s.starts_at), '[]'::jsonb)
  from public.subscriptions s where s.user_id = auth.uid() and s.ends_at > now()
$$;

-- ---------------------------------------------------------------- экспресс-проверка темы и контрольная
create table if not exists public.word_check_attempts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  mode        text not null check (mode in ('topic','review')),
  topic_id    int,
  questions   jsonb not null,           -- с верными ответами — клиенту не отдаётся
  answers     jsonb not null default '{}'::jsonb,
  total       int not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists word_check_attempts_user_idx on public.word_check_attempts (user_id, started_at desc);
alter table public.word_check_attempts enable row level security;
revoke all on public.word_check_attempts from anon, authenticated;

create or replace function public.word_check_payload(p_attempt uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('attempt_id', a.id, 'mode', a.mode, 'topic_id', a.topic_id, 'total', a.total,
    'answered', (select count(*) from jsonb_object_keys(a.answers)),
    'done', coalesce((select jsonb_agg(k::int) from jsonb_object_keys(a.answers) k), '[]'::jsonb),
    'correct', (select count(*) from jsonb_each(a.answers) x where (x.value->>'c')::boolean),
    'questions', (select jsonb_agg((q - 'answer') || jsonb_build_object('i', i - 1) order by i)
                  from jsonb_array_elements(a.questions) with ordinality as x(q, i)))
  from public.word_check_attempts a where a.id = p_attempt
$$;

-- Экспресс-проверка: все слова темы, ещё не достигшие уровня 15. Ответ вводится с клавиатуры —
-- уровень 15 даётся только за уверенное знание (выбор из вариантов можно угадать).
create or replace function public.start_topic_check(p_topic int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_now  timestamptz := public.app_now();
  v_att  public.word_check_attempts%rowtype;
  v_q    jsonb := '[]'::jsonb;
  r      record;
  v_i    int := 0;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('topic_check') then return jsonb_build_object('error', 'locked_tier'); end if;
  if not exists (select 1 from public.topics where id = p_topic) then return jsonb_build_object('error', 'not_found'); end if;
  if (select cefr from public.topics where id = p_topic) > public.unlocked_cefr(v_uid) then
    return jsonb_build_object('error', 'level_locked');
  end if;
  select * into v_att from public.word_check_attempts
   where user_id = v_uid and mode = 'topic' and topic_id = p_topic and finished_at is null and started_at > v_now - interval '6 hours'
   order by started_at desc limit 1;
  if found then return public.word_check_payload(v_att.id); end if;

  for r in
    select w.* from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
    where w.topic_id = p_topic and w.is_active and w.canonical_id is null
      and coalesce(public.effective_level(wp.level, wp.level_at, v_now), 0) < 15
    order by w.sort_key
  loop
    v_i := v_i + 1;
    v_q := v_q || case when v_i % 2 = 1
      then jsonb_build_object('type', 'ru_uz_input', 'word_id', r.id, 'prompt', r.ru, 'prompt_kind', 'ru', 'input', 'uz', 'answer', r.uz)
      else jsonb_build_object('type', 'uz_ru_input', 'word_id', r.id, 'prompt', r.uz, 'prompt_kind', 'uz', 'input', 'ru',
                              'audio_id', case when r.audio_ok then r.id end, 'answer', r.ru) end;
  end loop;
  if jsonb_array_length(v_q) = 0 then return jsonb_build_object('error', 'all_known'); end if;
  insert into public.word_check_attempts (user_id, mode, topic_id, questions, total, started_at)
  values (v_uid, 'topic', p_topic, public.jsonb_shuffle(v_q), jsonb_array_length(v_q), v_now)
  returning * into v_att;
  return public.word_check_payload(v_att.id);
end
$$;

-- Контрольная по пройденному: начатые слова (уровень 2+), выбор и ввод; уровни не меняются
create or replace function public.start_review_quiz()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_now  timestamptz := public.app_now();
  v_att  public.word_check_attempts%rowtype;
  v_q    jsonb := '[]'::jsonb;
  v_n    int := least(40, greatest(5, public.cfg_int('review_quiz_questions', 20)));
  r      record;
  v_d    jsonb;
  v_i    int := 0;
  v_type text;
  v_pattern text[] := array['uz_ru_choice','ru_uz_input','ru_uz_choice','uz_ru_input'];
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('review_quiz') then return jsonb_build_object('error', 'locked_tier'); end if;
  for r in
    select w.* from public.word_progress wp join public.words w on w.id = wp.word_id
    where wp.user_id = v_uid and wp.level >= 2
    order by random() limit v_n
  loop
    v_type := v_pattern[1 + (v_i % 4)];
    v_i := v_i + 1;
    if v_type like '%choice' then
      v_d := public.pick_distractors(r.id, 3);
      if jsonb_array_length(v_d) < 3 then v_type := replace(v_type, 'choice', 'input'); end if;
    end if;
    v_q := v_q || case v_type
      when 'uz_ru_choice' then jsonb_build_object('type', v_type, 'word_id', r.id, 'prompt', r.uz, 'prompt_kind', 'uz',
        'audio_id', case when r.audio_ok then r.id end,
        'options', public.jsonb_shuffle(jsonb_build_array(r.ru) || (select jsonb_agg(d->'ru') from jsonb_array_elements(v_d) d)), 'answer', r.ru)
      when 'ru_uz_choice' then jsonb_build_object('type', v_type, 'word_id', r.id, 'prompt', r.ru, 'prompt_kind', 'ru',
        'options', public.jsonb_shuffle(jsonb_build_array(r.uz) || (select jsonb_agg(d->'uz') from jsonb_array_elements(v_d) d)), 'answer', r.uz)
      when 'ru_uz_input' then jsonb_build_object('type', v_type, 'word_id', r.id, 'prompt', r.ru, 'prompt_kind', 'ru', 'input', 'uz', 'answer', r.uz)
      else jsonb_build_object('type', 'uz_ru_input', 'word_id', r.id, 'prompt', r.uz, 'prompt_kind', 'uz', 'input', 'ru',
        'audio_id', case when r.audio_ok then r.id end, 'answer', r.ru) end;
  end loop;
  if jsonb_array_length(v_q) < 5 then return jsonb_build_object('error', 'not_enough'); end if;
  insert into public.word_check_attempts (user_id, mode, questions, total, started_at)
  values (v_uid, 'review', v_q, jsonb_array_length(v_q), v_now) returning * into v_att;
  return public.word_check_payload(v_att.id);
end
$$;

-- Ответ: сразу сообщает, верно ли, и верный ответ. Экспресс-проверка: верно → уровень 15.
create or replace function public.answer_word_check(p_attempt uuid, p_index int, p_answer text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_now   timestamptz := public.app_now();
  v_today date;
  v_att   public.word_check_attempts%rowtype;
  q       jsonb;
  w       public.words%rowtype;
  v_a     text := left(coalesce(p_answer, ''), 300);
  v_ok    boolean;
begin
  select * into v_att from public.word_check_attempts where id = p_attempt and user_id = v_uid for update;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if v_att.finished_at is not null then return jsonb_build_object('error', 'finished'); end if;
  if p_index is null or p_index < 0 or p_index >= v_att.total then return jsonb_build_object('error', 'bad_index'); end if;
  q := v_att.questions -> p_index;
  if v_att.answers ? p_index::text then
    return jsonb_build_object('duplicate', true, 'correct', (v_att.answers -> p_index::text ->> 'c')::boolean, 'right', q->>'answer');
  end if;
  select * into w from public.words where id = (q->>'word_id')::int;
  v_ok := case
    when q->>'type' in ('uz_ru_input','uz_ru_choice') then public.key_ru(v_a) <> '' and public.key_ru(v_a) = any (w.accept_ru)
    else public.key_uz(v_a) <> '' and (public.key_uz(v_a) = w.uz_key or public.key_uz(v_a) = any (w.accept_uz)) end;
  update public.word_check_attempts
     set answers = answers || jsonb_build_object(p_index::text, jsonb_build_object('a', v_a, 'c', v_ok))
   where id = p_attempt;
  v_today := public.user_today(v_uid);

  if v_att.mode = 'topic' and v_ok then
    -- знает слово: сразу уровень 15, в конец очереди повторения
    insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at, fail_streak, correct_count, last_correct_at, last_seen_at)
    values (v_uid, w.id, 15, v_now, v_today + public.interval_days(15), v_now, 0, 1, v_now, v_now)
    on conflict (user_id, word_id) do update set
      level = 15, level_at = v_now, due_on = v_today + public.interval_days(15), fail_streak = 0,
      correct_count = public.word_progress.correct_count + 1, last_correct_at = v_now, last_seen_at = v_now;
  elsif not v_ok then
    -- ошибка: начатое слово — в повторение сегодня (уровень не меняется); неначатое придёт как новое
    update public.word_progress set due_on = least(due_on, v_today), wrong_count = wrong_count + 1, last_seen_at = v_now
     where user_id = v_uid and word_id = w.id;
  end if;
  insert into public.daily_stats (user_id, day, correct, wrong)
  values (v_uid, v_today, case when v_ok then 1 else 0 end, case when v_ok then 0 else 1 end)
  on conflict (user_id, day) do update set
    correct = public.daily_stats.correct + excluded.correct, wrong = public.daily_stats.wrong + excluded.wrong;
  return jsonb_build_object('correct', v_ok, 'right', q->>'answer');
end
$$;

create or replace function public.finish_word_check(p_attempt uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_att public.word_check_attempts%rowtype;
begin
  update public.word_check_attempts set finished_at = coalesce(finished_at, now())
   where id = p_attempt and user_id = v_uid returning * into v_att;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  return jsonb_build_object(
    'mode', v_att.mode, 'total', v_att.total,
    'answered', (select count(*) from jsonb_object_keys(v_att.answers)),
    'correct', (select count(*) from jsonb_each(v_att.answers) x where (x.value->>'c')::boolean),
    'mistakes', (select coalesce(jsonb_agg(jsonb_build_object('prompt', q->>'prompt', 'your', v_att.answers -> (i - 1)::text ->> 'a',
                                                               'correct', q->>'answer') order by i), '[]'::jsonb)
                 from jsonb_array_elements(v_att.questions) with ordinality as x(q, i)
                 where v_att.answers ? (i - 1)::text and not (v_att.answers -> (i - 1)::text ->> 'c')::boolean));
end
$$;

-- ---------------------------------------------------------------- права
revoke execute on function public.word_check_payload(uuid) from public, anon, authenticated;
revoke execute on function public.get_my_subscriptions() from public, anon;
revoke execute on function public.start_topic_check(int) from public, anon;
revoke execute on function public.start_review_quiz() from public, anon;
revoke execute on function public.answer_word_check(uuid, int, text) from public, anon;
revoke execute on function public.finish_word_check(uuid) from public, anon;
grant execute on function public.get_my_subscriptions() to authenticated;
grant execute on function public.start_topic_check(int) to authenticated;
grant execute on function public.start_review_quiz() to authenticated;
grant execute on function public.answer_word_check(uuid, int, text) to authenticated;
grant execute on function public.finish_word_check(uuid) to authenticated;
