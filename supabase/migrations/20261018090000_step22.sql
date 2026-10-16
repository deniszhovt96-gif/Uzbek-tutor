-- =============================================================================
-- Шаг 22: хранение данных, безопасность, «Повторение» без новых слов
--   • maintenance_daily(): раз в сутки чистит и ужимает данные пользователей (вызывается workflow «Напоминания»);
--   • доступ к таблицам словаря только через функции приложения; функции — по белому списку;
--   • ограничение частоты для функций, отдающих много контента (словарь, слово, темы, глаголы, существительные);
--   • «Повторение»: только уже просмотренные слова, без новых.
-- =============================================================================

-- ---------------------------------------------------------------- сроки хранения (можно менять в app_config)
insert into public.app_config (key, value, note) values
  ('keep_answer_log_days', '35', 'журнал ответов: статистика смотрит последние 30 дней'),
  ('keep_sessions_days', '60', 'сеансы занятий (списки слов сеанса)'),
  ('keep_test_details_days', '30', 'вопросы и ответы тестов (итог теста хранится всегда)'),
  ('keep_word_checks_days', '30', 'экспресс-проверки и контрольные'),
  ('keep_code_attempts_days', '7', 'попытки ввода кодов (защита от перебора — 1 час)'),
  ('keep_reminder_log_days', '14', 'журнал отправленных напоминаний'),
  ('keep_form_reports_days', '90', 'разобранные пометки форм'),
  ('keep_rate_hits_days', '2', 'счётчики частоты запросов'),
  ('rate_dict_per_hour', '40', 'словарь уровня: вызовов в час на пользователя'),
  ('rate_word_per_hour', '400', 'карточка слова: вызовов в час'),
  ('rate_topic_per_hour', '80', 'слова темы: вызовов в час'),
  ('rate_morph_list_per_hour', '40', 'списки глаголов и существительных: вызовов в час')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- ежедневная чистка
create or replace function public.maintenance_daily(p_force boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_last date := (select (value #>> '{}')::date from public.app_config where key = 'maintenance_last');
  v_today date := (now() at time zone 'Asia/Tashkent')::date;
  n1 int; n2 int; n3 int; n4 int; n5 int; n6 int; n7 int; n8 int; n9 int; n10 int;
begin
  if not p_force and v_last = v_today then return jsonb_build_object('skipped', true, 'last', v_last); end if;
  delete from public.answer_log where at < now() - make_interval(days => public.cfg_int('keep_answer_log_days', 35));
  get diagnostics n1 = row_count;
  delete from public.study_sessions where started_at < now() - make_interval(days => public.cfg_int('keep_sessions_days', 60));
  get diagnostics n2 = row_count;
  -- тесты: итог (балл, сдан/нет) остаётся, вопросы и ответы удаляются
  update public.level_test_attempts set questions = '[]', answers = '{}'
   where finished_at < now() - make_interval(days => public.cfg_int('keep_test_details_days', 30)) and questions <> '[]'::jsonb;
  get diagnostics n3 = row_count;
  update public.unit_test_attempts set questions = '[]', answers = '{}'
   where finished_at < now() - make_interval(days => public.cfg_int('keep_test_details_days', 30)) and questions <> '[]'::jsonb;
  get diagnostics n4 = row_count;
  delete from public.word_check_attempts where started_at < now() - make_interval(days => public.cfg_int('keep_word_checks_days', 30));
  get diagnostics n5 = row_count;
  delete from public.code_attempts where at < now() - make_interval(days => public.cfg_int('keep_code_attempts_days', 7));
  get diagnostics n6 = row_count;
  delete from public.reminder_log where day < v_today - public.cfg_int('keep_reminder_log_days', 14);
  get diagnostics n7 = row_count;
  delete from public.form_reports where status <> 'new' and coalesce(decided_at, created_at) < now() - make_interval(days => public.cfg_int('keep_form_reports_days', 90));
  get diagnostics n8 = row_count;
  delete from public.pending_referrals where created_at < now() - interval '7 days';
  get diagnostics n9 = row_count;
  delete from public.rate_hits where bucket < now() - make_interval(days => public.cfg_int('keep_rate_hits_days', 2));
  get diagnostics n10 = row_count;
  insert into public.app_config (key, value, note) values ('maintenance_last', to_jsonb(v_today::text), 'последняя ежедневная чистка')
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('answer_log', n1, 'sessions', n2, 'level_tests', n3, 'unit_tests', n4, 'word_checks', n5,
                            'code_attempts', n6, 'reminder_log', n7, 'form_reports', n8, 'pending_referrals', n9, 'rate_hits', n10);
end
$$;

-- журнал ответов: статистика ищет по пользователю и дате
create index if not exists answer_log_user_at_idx on public.answer_log (user_id, at);

-- ---------------------------------------------------------------- ограничение частоты
create table if not exists public.rate_hits (
  user_id uuid not null references public.profiles(id) on delete cascade,
  key     text not null,
  bucket  timestamptz not null,
  n       int not null default 0,
  primary key (user_id, key, bucket)
);
alter table public.rate_hits enable row level security;

-- Счётчик вызовов в час; сверх лимита — ошибка rate_limited. Без профиля (вход не через Telegram) — no_profile.
create or replace function public.rate_hit(p_key text, p_max int)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then return; end if;
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'no_profile' using errcode = 'P0001';
  end if;
  insert into public.rate_hits (user_id, key, bucket, n) values (v_uid, p_key, date_trunc('hour', now()), 1)
  on conflict (user_id, key, bucket) do update set n = public.rate_hits.n + 1
  returning n into v_n;
  if v_n > p_max then raise exception 'rate_limited' using errcode = 'P0001'; end if;
end
$$;

-- get_dictionary: ограничение частоты
create or replace function public.get_dictionary(p_cefr text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  perform public.rate_hit('dict', public.cfg_int('rate_dict_per_hour', 40));
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_cefr not in ('A1','A2','B1','B2') then return jsonb_build_object('error', 'bad_cefr'); end if;
  return jsonb_build_object(
    'cefr', p_cefr,
    'unlocked', public.unlocked_cefr(v_uid),
    'can_flag', public.can_flag_words(),
    'counts', (select jsonb_object_agg(cefr, n) from (
                 select w.cefr, count(*) n from public.word_progress wp join public.words w on w.id = wp.word_id
                  where wp.user_id = v_uid and w.is_active and w.canonical_id is null group by 1) x),
    'topics', (select jsonb_object_agg(t.id, jsonb_build_array(
                   regexp_replace(t.name_ru, '^Разговорная речь\. ', '💬 '),
                   regexp_replace(coalesce(t.name_uz, t.name_ru), '^Soʻzlashuv nutqi\. ', '💬 '),
                   regexp_replace(coalesce(t.name_en, t.name_ru), '^Spoken: ', '💬 ')))
                 from public.topics t where exists (select 1 from public.words w where w.topic_id = t.id and w.cefr = p_cefr)),
    'words', public.dict_rows(v_uid, p_cefr, null));
end
$$;

-- get_word: ограничение частоты
create or replace function public.get_word(p_word int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  perform public.rate_hit('word', public.cfg_int('rate_word_per_hour', 400));
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  return (select public.word_card(w.id, v_uid, public.app_now())
                 || jsonb_build_object('register', w.register, 'literary', w.literary, 'note', w.note, 'en', w.en,
                                       'topic', regexp_replace(t.name_ru, '^Разговорная речь\. ', ''),
                                       'topic_uz', regexp_replace(t.name_uz, '^Soʻzlashuv nutqi\. ', ''),
                                       'topic_en', regexp_replace(t.name_en, '^Spoken: ', ''),
                                       'can_flag', public.can_flag_words() and w.cefr in ('A1','A2'),
                                       'my_flag', (select p.kind from public.word_level_proposals p
                                                    where p.word_id = w.id and p.user_id = v_uid and p.status = 'pending' limit 1),
                                       'due_on', (select due_on from public.word_progress where user_id = v_uid and word_id = w.id))
          from public.words w join public.topics t on t.id = w.topic_id where w.id = p_word and w.is_active);
end
$$;

-- get_topic_words: ограничение частоты
create or replace function public.get_topic_words(p_topic int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  perform public.rate_hit('topic', public.cfg_int('rate_topic_per_hour', 80));
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  return jsonb_build_object('topic_id', p_topic, 'unlocked', public.unlocked_cefr(v_uid),
                            'can_flag', public.can_flag_words(), 'words', public.dict_rows(v_uid, null, p_topic));
end
$$;

-- get_verbs: ограничение частоты
create or replace function public.get_verbs()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_today date;
begin
  perform public.rate_hit('verbs', public.cfg_int('rate_morph_list_per_hour', 40));
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  return jsonb_build_object('state', public.morph_state(v_uid), 'verbs', (
    select coalesce(jsonb_agg(jsonb_build_object('i', w.id, 'u', w.uz, 'r', w.ru, 'e', w.en, 'c', w.cefr,
             'l', public.effective_level(wp.level, wp.level_at, v_now),
             'f', vf.level, 'fd', vf.due_on <= v_today, 't', vt.level, 'td', vt.due_on <= v_today,
             'm', w.morph is not null)
             order by w.cefr, w.uz_key), '[]'::jsonb)
    from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
    left join public.verb_progress vf on vf.word_id = w.id and vf.user_id = v_uid and vf.kind = 'form'
    left join public.verb_progress vt on vt.word_id = w.id and vt.user_id = v_uid and vt.kind = 'table'
    where w.is_active and w.canonical_id is null and w.word_class = 'verb' and w.uz ~ '(moq|mak)$'));
end
$$;

-- get_nouns: ограничение частоты
create or replace function public.get_nouns()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_today date;
begin
  perform public.rate_hit('nouns', public.cfg_int('rate_morph_list_per_hour', 40));
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  return jsonb_build_object('state', public.morph_state(v_uid), 'nouns', (
    select coalesce(jsonb_agg(jsonb_build_object('i', w.id, 'u', w.uz, 'r', w.ru, 'e', w.en, 'c', w.cefr,
             'l', public.effective_level(wp.level, wp.level_at, v_now),
             'd', vd.level, 'dd', vd.due_on <= v_today)
             order by w.cefr, w.uz_key), '[]'::jsonb)
    from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
    left join public.verb_progress vd on vd.word_id = w.id and vd.user_id = v_uid and vd.kind = 'decl'
    where w.is_active and w.canonical_id is null and w.pos = 'n' and w.uz !~ ' ' and w.uz ~ '^[a-zʻʼ]+$'));
end
$$;

-- ---------------------------------------------------------------- «Повторение» без новых слов
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
  v_rd       jsonb;
  v_sess     public.study_sessions%rowtype;
  v_colloq   boolean := coalesce(((select settings from public.profiles where id = auth.uid())->>'colloquial_first')::boolean, false);
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
  v_rd := public.review_day_state(v_uid, v_today);

  if p_topic_id is not null then
    if not public.feature_allowed('topic_choice') then
      return jsonb_build_object('error', 'locked_tier');
    end if;
    if not exists (select 1 from public.words where topic_id = p_topic_id and is_active and cefr <= v_unlocked) then
      return jsonb_build_object('error', 'level_locked');
    end if;
  end if;

  select * into v_sess from public.study_sessions
   where user_id = v_uid and finished_at is null and local_day = v_today
     and started_at > v_now - interval '3 hours' and mode = p_mode and cardinality(word_ids) > 0
   order by started_at desc limit 1;

  if not found then
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
    -- день повторения: пока не сделано нужное число повторений, сеанс состоит только из повторений
    if (v_rd->>'locked')::boolean then
      select r, n into v_r, v_n from public.session_plan(v_due, v_size, v_new_max, v_left, 'review');
    else
      select r, n into v_r, v_n from public.session_plan(v_due, v_size, v_new_max, v_left, p_mode);
      -- «Повторение»: только уже просмотренные слова; если к повторению на сегодня мало,
      -- добираем самыми слабыми из уже изученных (их ответы не меняют уровень — см. submit_answers)
      if p_mode = 'review' then
        v_r := least(v_size, (select count(*) from public.word_progress wp join public.words w on w.id = wp.word_id and w.is_active
                               where wp.user_id = v_uid));
      end if;
    end if;

    select coalesce(array_agg(word_id order by not_due, grp, lvl_order, ratio desc, eff), '{}') into v_review
    from (
      select wp.word_id, (wp.due_on > v_today) as not_due,
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
      join public.words w on w.id = wp.word_id and w.is_active
      where wp.user_id = v_uid and (wp.due_on <= v_today or p_mode = 'review')
      order by 2, 4, 5, 6 desc, 3
      limit v_r
    ) t;

    -- новые слова: сначала нижний уровень, внутри — порядок словаря (уровень мог измениться после пометок)
    -- слова из пройденных тем курсов (word_queue) — в первую очередь, независимо от уровня
    delete from public.word_queue q where q.user_id = v_uid
       and exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = q.word_id);
    select coalesce(array_agg(id order by q_first, q_at, c_first, cefr, sort_key), '{}') into v_new
    from (
      select w.id, w.cefr, w.sort_key, (q.word_id is null) as q_first, q.added_at as q_at,
             case when v_colloq and w.register = 'colloquial' then 0 else 1 end as c_first from public.words w
      left join public.word_queue q on q.user_id = v_uid and q.word_id = w.id and p_topic_id is null
      where w.is_active and w.canonical_id is null
        and (w.cefr <= v_unlocked or q.word_id is not null
             -- «сначала разговорная речь»: разговорные слова — и на уровень выше открытого
             or (v_colloq and w.register = 'colloquial'
                 and w.cefr <= case v_unlocked when 'A1' then 'A2' when 'A2' then 'B1' else 'B2' end))
        and (p_topic_id is null or w.topic_id = p_topic_id)
        and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id)
      order by (q.word_id is null), q.added_at,
               case when v_colloq and w.register = 'colloquial' then 0 else 1 end, w.cefr, w.sort_key
      limit v_n
    ) t;

    -- пустой сеанс не создаём: он не должен расходовать дневной лимит
    if cardinality(v_review) + cardinality(v_new) = 0 then
      return jsonb_build_object('items', '[]'::jsonb, 'tier', v_tier, 'mode', p_mode);
    end if;
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
    'review_day', v_rd,
    'review_count', cardinality(v_sess.word_ids) - cardinality(v_sess.new_ids),
    'new_count', cardinality(v_sess.new_ids),
    'items', coalesce((select jsonb_agg(public.word_card(x.id, v_uid, v_now) order by x.ord)
                       from unnest(v_sess.word_ids) with ordinality as x(id, ord)), '[]'::jsonb)
  );
end
$$;

-- ---------------------------------------------------------------- права: таблицы
-- Словарь, примеры и темы приложение получает только через функции; прямое чтение таблиц закрыто.
drop policy if exists words_read on public.words;
drop policy if exists examples_read on public.examples;
drop policy if exists topics_read on public.topics;
drop policy if exists feature_access_read on public.feature_access;
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
-- остаются: свои строки пользователя (по RLS) и публичные цены
grant select on public.plans to anon, authenticated;
grant select on public.profiles, public.word_progress, public.subscriptions, public.payments, public.daily_stats,
                public.study_sessions, public.answer_log, public.course_progress to authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- ---------------------------------------------------------------- права: функции по белому списку
-- Пользователь приложения может вызывать только функции, которые вызывает само приложение;
-- служебные (оплата, напоминания, коды, чистка) — только сервер (service_role).
do $$
declare
  r record;
  v_allow text[] := array['admin_analytics', 'admin_decide_word', 'admin_form_reports', 'admin_referrals', 'admin_resolve_form_report', 'admin_review_summary', 'admin_set_question', 'admin_unit_questions', 'admin_word_proposals', 'answer_level_test', 'answer_morph', 'answer_sentence', 'answer_word_check', 'apply_referral', 'finish_level_test', 'finish_session', 'finish_unit_test', 'finish_word_check', 'get_app_info', 'get_course', 'get_dictionary', 'get_group_codes', 'get_home', 'get_marathon', 'get_me', 'get_morph', 'get_morph_state', 'get_my_payments', 'get_my_subscriptions', 'get_next_step', 'get_nouns', 'get_path', 'get_path_courses', 'get_plans', 'get_referral_info', 'get_sentence_levels', 'get_share_image', 'get_stats', 'get_stats_ext', 'get_topic_words', 'get_unit', 'get_verbs', 'get_week', 'get_word', 'marathon_answer', 'marathon_batch', 'mark_unit', 'propose_word_level', 'redeem_code', 'report_form', 'start_level_test', 'start_marathon', 'start_mistakes', 'start_practice', 'start_review_quiz', 'start_sentences', 'start_session', 'start_topic_check', 'start_unit_test', 'submit_answers', 'unit_examples', 'unit_test_info', 'update_settings', 'effective_level', 'app_now', 'current_tier', 'get_courses'];
begin
  for r in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
    if r.proname = any (v_allow) then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
-- ссылка на сообщество и версия — без входа
grant execute on function public.get_app_info() to anon;
