-- =============================================================================
-- Шаг 5: алгоритм обучения (утверждённая модель, см. документ «аудит и архитектура»)
--
--   Уровни 0–15. Верный засчитанный ответ: +1 уровень, следующий показ через interval_days.
--   Засчитывается: первая попытка плановой проверки (дата наступила) или шаг заучивания 0→1→2.
--   Ошибка на плановой проверке: 1-я — уровень не меняется, слово в следующем сеансе;
--   2-я подряд — уровень −1 (не ниже 1). Верный ответ обнуляет счётчик ошибок.
--   Правило 3 месяцев: каждые полные 90 дней с level_at — уровень −1 (не ниже 1),
--   считается при обращении, фоновых задач нет.
--   Состав сеанса: R = min(D, S, 10 + ceil((D−10)/2)), N = min(new_max, S − R).
--   Бесплатно: 1 сеанс в день на 15 слов.
-- =============================================================================

-- ---------------------------------------------------------------- время
-- Текущее время. В тестах можно подменить: set app.now = '2026-10-05 10:00+05'.
-- Через API подменить нельзя: PostgREST не выполняет произвольный SET.
create or replace function public.app_now()
returns timestamptz language sql stable as $$
  select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
$$;

create or replace function public.user_today(p_user uuid)
returns date language sql stable security definer set search_path = '' as $$
  select (public.app_now() at time zone coalesce(
            (select p.timezone from public.profiles p where p.id = p_user), 'Asia/Tashkent'))::date
$$;

-- ---------------------------------------------------------------- интервалы и уровни
create or replace function public.interval_days(p_level int)
returns int language sql immutable as $$
  select case p_level
    when 0 then 0 when 1 then 0 when 2 then 1 when 3 then 2 when 4 then 4
    when 5 then 7 when 6 then 12 when 7 then 20 when 8 then 30 when 9 then 40
    when 10 then 50 when 11 then 60 when 12 then 70 when 13 then 80 else 85 end
$$;

-- Действующий уровень с учётом правила 3 месяцев
create or replace function public.effective_level(p_level int, p_level_at timestamptz, p_now timestamptz)
returns int language sql immutable as $$
  select case when p_level is null or p_level_at is null then p_level
              when p_level <= 1 then p_level
              else greatest(1, p_level - floor(extract(epoch from (p_now - p_level_at)) / (90 * 86400))::int)
         end
$$;

-- ---------------------------------------------------------------- нормализация ответов
-- Совпадает с scripts/build_vocab.py (key_uz, _clean_ru) — проверяется тестом.
create or replace function public.key_uz(p text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           replace(
             regexp_replace(
               regexp_replace(lower(normalize(coalesce(p, ''), NFC)), '[‘’ʻʼ`´ʹ]', '''', 'g'),
               '[^a-z'' \-]', ' ', 'g'),
             '-', ' '),
           '\s+', ' ', 'g'), ' ''')
$$;

create or replace function public.key_ru(p text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           replace(
             regexp_replace(
               replace(lower(normalize(regexp_replace(coalesce(p, ''), '\([^)]*\)', ' ', 'g'), NFC)), 'ё', 'е'),
               '[^0-9a-zа-я \-]', ' ', 'g'),
             '-', ' '),
           '\s+', ' ', 'g'))
$$;

-- ---------------------------------------------------------------- сеансы
create table if not exists public.study_sessions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  local_day    date not null,
  mode         text not null check (mode in ('normal','review')),
  tier         text not null,
  word_ids     int[] not null,
  new_ids      int[] not null default '{}',
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  seconds      int not null default 0
);
create index if not exists study_sessions_user_day_idx on public.study_sessions (user_id, local_day);
alter table public.study_sessions enable row level security;
revoke insert, update, delete, truncate on public.study_sessions from anon, authenticated;
grant select on public.study_sessions to authenticated;
drop policy if exists study_sessions_own on public.study_sessions;
create policy study_sessions_own on public.study_sessions for select to authenticated using (user_id = auth.uid());

-- Параметры сеанса по подписке и настройкам пользователя
create or replace function public.session_params(p_user uuid, p_tier text)
returns table (size int, new_max int) language sql stable security definer set search_path = '' as $$
  select
    case when p_tier = 'free' then 15
         else least(60, greatest(10, coalesce((p.settings->>'session_size')::int, 30))) end,
    case when p_tier = 'free' then 10
         else least(30, greatest(0, coalesce((p.settings->>'new_max')::int, 20))) end
  from public.profiles p where p.id = p_user
$$;

-- Карточка слова для сеанса: данные, примеры (вместе с дублями), кандидаты в неверные варианты
create or replace function public.word_card(p_word_id int, p_user uuid, p_now timestamptz)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', w.id, 'uz', w.uz, 'ru', w.ru, 'topic_id', w.topic_id, 'cefr', w.cefr,
    'word_class', w.word_class, 'audio_ok', w.audio_ok,
    'accept_ru', w.accept_ru, 'accept_uz', w.accept_uz,
    'level', coalesce(public.effective_level(wp.level, wp.level_at, p_now), 0),
    'stage', case when wp.word_id is null or wp.level = 0 then 'new'
                  when public.effective_level(wp.level, wp.level_at, p_now) <= 6 then 'learning'
                  else 'review' end,
    'examples', coalesce((
      select jsonb_agg(jsonb_build_object(
               'word_id', e.word_id, 'n', e.n, 'uz', e.uz, 'ru', e.ru,
               'blank_start', e.blank_start, 'blank_len', e.blank_len, 'audio_ok', e.audio_ok)
             order by (e.word_id <> w.id), e.n)
      from public.examples e
      where not e.is_hidden
        and (e.word_id = w.id or e.word_id in (select a.id from public.words a where a.canonical_id = w.id))
    ), '[]'::jsonb),
    'distractors', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'uz', d.uz, 'ru', d.ru))
      from (
        select x.id, x.uz, x.ru from (
          select c.id, c.uz, c.ru,
                 (c.topic_id = w.topic_id) as same_topic,
                 (c.word_class = w.word_class) as same_class
          from public.words c
          where c.is_active and c.canonical_id is null and c.id <> w.id
            and (c.topic_id = w.topic_id or c.cefr = w.cefr)
            and c.uz_key <> w.uz_key
            and not (c.uz_key = any (w.accept_uz))
            and not (c.accept_ru && w.accept_ru)
          order by (c.topic_id = w.topic_id) desc, (c.word_class = w.word_class) desc, random()
          limit 8
        ) x
      ) d
    ), '[]'::jsonb)
  )
  from public.words w
  left join public.word_progress wp on wp.word_id = w.id and wp.user_id = p_user
  where w.id = p_word_id
$$;

create or replace function public.start_session(p_mode text default 'normal', p_topic_id int default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid     uuid := auth.uid();
  v_now     timestamptz := public.app_now();
  v_today   date;
  v_tier    text;
  v_size    int;
  v_new_max int;
  v_due     int;
  v_r       int;
  v_n       int;
  v_review  int[];
  v_new     int[];
  v_sess    public.study_sessions%rowtype;
begin
  if v_uid is null or not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('error', 'not_authenticated');
  end if;
  if p_mode not in ('normal','review') then
    return jsonb_build_object('error', 'bad_mode');
  end if;
  v_today := public.user_today(v_uid);
  v_tier := public.current_tier();

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

    -- повторения по приоритету: грань понижения → заучивание (ниже уровень раньше) → по просрочке
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

    -- новые слова: по порядку изучения (или из выбранной темы)
    select coalesce(array_agg(id order by sort_key), '{}') into v_new
    from (
      select w.id, w.sort_key from public.words w
      where w.is_active and w.canonical_id is null
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

-- ---------------------------------------------------------------- приём ответов
-- p_events: [{"seq":1,"kind":"shown","word_id":5},
--            {"seq":2,"kind":"answer","word_id":5,"ex_type":"uz_ru_choice","target":"ru",
--             "answer":"я","attempt":"first","example":{"word_id":5,"n":1}}]
-- target: 'ru' | 'uz' | 'blank'. Сервер сам проверяет ответ и применяет правила уровней.
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
  v_blank    text;
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

    -- показ карточки нового слова: заводим прогресс (уровень 0)
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

    -- ответ: защита от повторной отправки той же пачки
    insert into public.answer_log (user_id, word_id, session_id, seq, ex_type, answer, is_correct, counted)
    values (v_uid, v_word.id, p_session_id, v_seq, coalesce(ev->>'ex_type', '?'), left(ev->>'answer', 200), false, false)
    on conflict (user_id, session_id, seq) do nothing;
    get diagnostics v_inserted = row_count;
    if v_inserted = 0 then
      v_results := v_results || jsonb_build_object('seq', v_seq, 'duplicate', true);
      continue;
    end if;

    -- проверка ответа на сервере
    v_target := ev->>'target';
    v_answer := coalesce(ev->>'answer', '');
    if v_target = 'ru' then
      v_correct := public.key_ru(v_answer) <> '' and public.key_ru(v_answer) = any (v_word.accept_ru);
    elsif v_target = 'uz' then
      v_correct := public.key_uz(v_answer) <> ''
                   and (public.key_uz(v_answer) = v_word.uz_key or public.key_uz(v_answer) = any (v_word.accept_uz));
    elsif v_target = 'blank' then
      select e.blank_answer into v_blank from public.examples e
       where e.word_id = (ev->'example'->>'word_id')::int and e.n = (ev->'example'->>'n')::int
         and not e.is_hidden and e.blank_answer is not null
         and (e.word_id = v_word.id or e.word_id in (select a.id from public.words a where a.canonical_id = v_word.id));
      v_correct := v_blank is not null and public.key_uz(v_answer) = public.key_uz(v_blank);
    else
      v_correct := false;
    end if;
    v_first := coalesce(ev->>'attempt', 'first') = 'first';

    -- прогресс (если карточку не показывали — заводим)
    insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
    values (v_uid, v_word.id, 0, v_now, v_today, v_now)
    on conflict (user_id, word_id) do nothing;
    select * into v_wp from public.word_progress
     where user_id = v_uid and word_id = v_word.id for update;

    v_eff := public.effective_level(v_wp.level, v_wp.level_at, v_now);
    -- правило 3 месяцев: момент, с которого считается следующий период
    if v_eff < v_wp.level then
      v_level_at := v_wp.level_at + make_interval(days => 90 * (v_wp.level - v_eff));
    else
      v_level_at := v_wp.level_at;
    end if;

    -- засчитывается: шаг заучивания 0→1→2 (любая попытка) или первая попытка плановой проверки
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
      v_due := v_today;                       -- слово вернётся в следующем сеансе
      if v_eff >= 2 then
        v_fail := v_fail + 1;
        if v_fail >= 2 then                   -- вторая ошибка подряд — уровень ниже
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
      'level', v_new, 'due_on', v_due, 'correct_answer',
      case when v_target = 'ru' then v_word.ru when v_target = 'blank' then v_blank else v_word.uz end);
  end loop;

  return jsonb_build_object('ok', true, 'results', v_results);
end
$$;

create or replace function public.finish_session(p_session_id uuid, p_seconds int default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_day date;
begin
  update public.study_sessions
     set finished_at = coalesce(finished_at, public.app_now()),
         seconds = least(greatest(coalesce(p_seconds, 0), 0), 4 * 3600)
   where id = p_session_id and user_id = v_uid
   returning local_day into v_day;
  if v_day is null then
    return jsonb_build_object('error', 'session_not_found');
  end if;
  update public.daily_stats set seconds = seconds + least(greatest(coalesce(p_seconds, 0), 0), 4 * 3600)
   where user_id = v_uid and day = v_day;
  return jsonb_build_object('ok', true);
end
$$;

-- Главный экран: что делать сегодня
create or replace function public.get_home()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_today date;
  v_tier text;
  v_size int; v_new_max int; v_due int; v_r int; v_n int; v_left int;
  v_free_used boolean;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  v_tier := public.current_tier();
  select size, new_max into v_size, v_new_max from public.session_params(v_uid, v_tier);
  select count(*) into v_due from public.word_progress where user_id = v_uid and due_on <= v_today;
  select count(*) into v_left from public.words w
   where w.is_active and w.canonical_id is null
     and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id);
  v_r := least(v_due, v_size, 10 + ceil(greatest(0, v_due - 10) / 2.0)::int);
  v_n := least(v_new_max, v_size - v_r, v_left);
  v_free_used := v_tier = 'free' and exists (
    select 1 from public.study_sessions where user_id = v_uid and local_day = v_today);
  return jsonb_build_object(
    'tier', v_tier,
    'today', v_today,
    'plan_new', v_n,
    'plan_review', v_r,
    'due_total', v_due,
    'daily_limit_reached', v_free_used,
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
      ) select count(*) from s)
  );
end
$$;

-- ---------------------------------------------------------------- права
revoke execute on function public.start_session(text, int) from public, anon;
revoke execute on function public.submit_answers(uuid, jsonb) from public, anon;
revoke execute on function public.finish_session(uuid, int) from public, anon;
revoke execute on function public.get_home() from public, anon;
revoke execute on function public.word_card(int, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.session_params(uuid, text) from public, anon, authenticated;
revoke execute on function public.user_today(uuid) from public, anon, authenticated;
grant execute on function public.start_session(text, int) to authenticated;
grant execute on function public.submit_answers(uuid, jsonb) to authenticated;
grant execute on function public.finish_session(uuid, int) to authenticated;
grant execute on function public.get_home() to authenticated;
