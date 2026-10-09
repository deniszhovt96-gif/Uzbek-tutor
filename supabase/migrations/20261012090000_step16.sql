-- =============================================================================
-- Шаг 16
--   • Спряжение и склонение: переводы форм (words.morph), отдельные уровни глагола/существительного
--     (форма, таблица, склонение), открытие времён и падежей по темам грамматики, потолок уровня.
--   • Пометки «Нужно исправить» для форм — администраторам.
--   • Диалоги (курс dialogs), уровни у тем курсов, слова пройденных тем — в ближайшую очередь заучивания.
--   • Рекомендуемый порядок занятий, цель недели, недельное сообщение бота.
--   • Предложения по уровням, бонусные короткие фразы; игра «Мои ошибки».
--   • Групповая подписка на 3 человек (−15%), аналитика для администратора.
-- =============================================================================

-- ---------------------------------------------------------------- словарь: часть речи и формы перевода
alter table public.words add column if not exists pos text;
alter table public.words add column if not exists morph jsonb;

-- ---------------------------------------------------------------- курсы: диалоги, уровни тем
alter table public.courses drop constraint if exists courses_id_check;
alter table public.courses add constraint courses_id_check
  check (id in ('grammar','history','civics','culture','dialogs'));
insert into public.courses (id, title_ru, title_uz, title_en, min_tier, sort_order)
values ('dialogs', 'Диалоги', 'Dialoglar', 'Dialogues', 'free', 5)
on conflict (id) do update set title_ru = excluded.title_ru, title_uz = excluded.title_uz, title_en = excluded.title_en;

alter table public.course_units add column if not exists cefr text not null default 'A1'
  check (cefr in ('A1','A2','B1','B2'));
alter table public.course_units add column if not exists extra jsonb;

insert into public.feature_access (feature, min_tier, note) values
  ('dialogs', 'free', 'Диалоги по ситуациям'),
  ('mistakes', 'free', 'Игра «Мои ошибки»'),
  ('analytics', 'free', 'Аналитика (только администраторы)')
on conflict (feature) do nothing;

create or replace function public.course_feature(p_course text)
returns text language sql immutable as $$
  select case p_course when 'grammar' then 'grammar' when 'history' then 'history'
                       when 'civics' then 'civics' when 'dialogs' then 'dialogs' else 'culture' end
$$;

-- ---------------------------------------------------------------- слова тем курсов → очередь заучивания
-- unit_terms заполняет импорт курсов (узбекские слова темы: термины в скобках, лексика диалогов),
-- unit_words — те из них, что есть в словаре (пересчитывается после импорта курсов и словаря).
create table if not exists public.unit_terms (
  unit_id  int  not null references public.course_units(id) on delete cascade,
  term_key text not null,
  primary key (unit_id, term_key)
);
create table if not exists public.unit_words (
  unit_id int not null references public.course_units(id) on delete cascade,
  word_id int not null,
  primary key (unit_id, word_id)
);
alter table public.unit_terms enable row level security;
alter table public.unit_words enable row level security;
revoke all on public.unit_terms, public.unit_words from anon, authenticated;

create or replace function public.refresh_unit_words()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare v int;
begin
  delete from public.unit_words;
  insert into public.unit_words (unit_id, word_id)
  select distinct t.unit_id, coalesce(w.canonical_id, w.id)
    from public.unit_terms t
    join public.words w on w.uz_key = t.term_key and w.is_active
  on conflict do nothing;
  get diagnostics v = row_count;
  return v;
end
$$;

create table if not exists public.word_queue (
  user_id  uuid not null references public.profiles(id) on delete cascade,
  word_id  int  not null,
  unit_id  int,
  added_at timestamptz not null default now(),
  primary key (user_id, word_id)
);
alter table public.word_queue enable row level security;
revoke all on public.word_queue from anon, authenticated;

-- тема прочитана или тест сдан → её слова встают в ближайшую очередь новых слов
create or replace function public.queue_unit_words()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.read_at is not null or new.status = 'tested')
     and (tg_op = 'INSERT' or (old.read_at is null and old.status <> 'tested')) then
    insert into public.word_queue (user_id, word_id, unit_id)
    select new.user_id, uw.word_id, new.unit_id
      from public.unit_words uw
     where uw.unit_id = new.unit_id
       and not exists (select 1 from public.word_progress wp where wp.user_id = new.user_id and wp.word_id = uw.word_id)
    on conflict do nothing;
  end if;
  return new;
end
$$;
drop trigger if exists course_progress_queue on public.course_progress;
create trigger course_progress_queue after insert or update on public.course_progress
  for each row execute function public.queue_unit_words();

-- ---------------------------------------------------------------- спряжение и склонение: уровни
-- kind: form — «напишите форму» (одна клетка), table — вся таблица времени, decl — таблица склонения
create table if not exists public.verb_progress (
  user_id  uuid not null references public.profiles(id) on delete cascade,
  word_id  int  not null,
  kind     text not null check (kind in ('form','table','decl')),
  level    smallint not null default 0,
  due_on   date not null default current_date,
  correct  int not null default 0,
  wrong    int not null default 0,
  last_at  timestamptz,
  primary key (user_id, word_id, kind)
);
alter table public.verb_progress enable row level security;
revoke all on public.verb_progress from anon, authenticated;

-- Темы грамматики, которые вводят формы: спряжение — 13 тем, склонение — 3 темы.
-- Пройдена = прочитана или сдан тест. Потолок уровня = 15 × доля пройденных тем (минимум 1).
create or replace function public.morph_state(p_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with passed as (
    select u.source_no from public.course_progress cp
      join public.course_units u on u.id = cp.unit_id and u.course_id = 'grammar'
     where cp.user_id = p_user and (cp.read_at is not null or cp.status = 'tested'))
  select jsonb_build_object(
    'grammar', coalesce((select jsonb_agg(source_no order by source_no) from passed), '[]'::jsonb),
    'conj_cap', (select case when count(*) = 13 then 15 else greatest(1, floor(15.0 * count(*) / 13))::int end
                   from passed where source_no in (3,5,6,7,8,16,21,22,23,24,25,26,27)),
    'decl_cap', (select case when count(*) = 3 then 15 else greatest(1, floor(15.0 * count(*) / 3))::int end
                   from passed where source_no in (9,10,11)))
$$;

create or replace function public.answer_morph(p_word int, p_kind text, p_ok int, p_total int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_cap   int;
  v_st    jsonb;
  v_cur   public.verb_progress%rowtype;
  v_level int;
  v_ratio numeric;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_kind not in ('form','table','decl') or p_total is null or p_total < 1 or p_ok < 0 or p_ok > p_total then
    return jsonb_build_object('error', 'bad_args');
  end if;
  if not exists (select 1 from public.words where id = p_word) then return jsonb_build_object('error', 'not_found'); end if;
  v_today := public.user_today(v_uid);
  v_st := public.morph_state(v_uid);
  v_cap := case when p_kind = 'decl' then (v_st->>'decl_cap')::int else (v_st->>'conj_cap')::int end;
  select * into v_cur from public.verb_progress where user_id = v_uid and word_id = p_word and kind = p_kind for update;
  v_ratio := p_ok::numeric / p_total;
  v_level := coalesce(v_cur.level, 0);
  v_level := case when v_ratio >= 0.8 then least(v_cap, v_level + 1)
                  when v_ratio >= 0.5 then least(v_cap, v_level)
                  else greatest(0, v_level - 1) end;
  insert into public.verb_progress (user_id, word_id, kind, level, due_on, correct, wrong, last_at)
  values (v_uid, p_word, p_kind, v_level, v_today + public.interval_days(v_level), p_ok, p_total - p_ok, now())
  on conflict (user_id, word_id, kind) do update set
    level = excluded.level, due_on = excluded.due_on, last_at = now(),
    correct = public.verb_progress.correct + excluded.correct,
    wrong = public.verb_progress.wrong + excluded.wrong;
  insert into public.daily_stats (user_id, day, correct, wrong) values (v_uid, v_today, p_ok, p_total - p_ok)
  on conflict (user_id, day) do update set
    correct = public.daily_stats.correct + excluded.correct, wrong = public.daily_stats.wrong + excluded.wrong;
  return jsonb_build_object('ok', true, 'level', v_level, 'prev', coalesce(v_cur.level, 0), 'cap', v_cap);
end
$$;

-- Список глаголов: по уровню (A1→B2), внутри — по алфавиту; три уровня владения
create or replace function public.get_verbs()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_today date;
begin
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

-- Список существительных для склонения
create or replace function public.get_nouns()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_today date;
begin
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

-- Формы перевода для выбранных слов
-- p_ids — JSON-массив id (не больше 60)
create or replace function public.get_morph(p_ids jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(w.id::text, w.morph), '{}'::jsonb)
    from public.words w
   where w.id in (select x::int from jsonb_array_elements_text(case when jsonb_typeof(p_ids) = 'array' then p_ids else '[]' end) with ordinality a(x, k) where k <= 60)
     and w.morph is not null and auth.uid() is not null
$$;

-- ---------------------------------------------------------------- «Нужно исправить»: формы и переводы
create table if not exists public.form_reports (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  word_id     int  not null,
  kind        text not null check (kind in ('conj','decl')),
  item        text,                 -- время / столбец склонения
  person      smallint,             -- строка (лицо / падеж), null — вся таблица
  form        text,                 -- форма и перевод, как их видел пользователь
  comment     text not null,
  status      text not null default 'new' check (status in ('new','fixed','rejected')),
  created_at  timestamptz not null default now(),
  notified_at timestamptz,
  decided_at  timestamptz,
  decided_by  bigint
);
alter table public.form_reports enable row level security;
revoke all on public.form_reports from anon, authenticated;

create or replace function public.report_form(p_word int, p_kind text, p_item text, p_person int, p_form text, p_comment text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_kind not in ('conj','decl') or coalesce(btrim(p_comment), '') = '' then return jsonb_build_object('error', 'bad_args'); end if;
  if not exists (select 1 from public.words where id = p_word) then return jsonb_build_object('error', 'not_found'); end if;
  if (select count(*) from public.form_reports where user_id = v_uid and created_at > now() - interval '1 day') >= 30 then
    return jsonb_build_object('error', 'too_many');
  end if;
  insert into public.form_reports (user_id, word_id, kind, item, person, form, comment)
  values (v_uid, p_word, p_kind, left(p_item, 40), p_person, left(p_form, 300), left(btrim(p_comment), 500));
  return jsonb_build_object('ok', true);
end
$$;

create or replace function public.admin_form_reports(p_status text default 'new')
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_admin() then jsonb_build_object('error', 'forbidden') else jsonb_build_object('items', (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', r.id, 'word_id', r.word_id, 'uz', w.uz, 'ru', w.ru, 'kind', r.kind, 'item', r.item, 'person', r.person,
             'form', r.form, 'comment', r.comment, 'status', r.status, 'created_at', r.created_at,
             'name', p.first_name, 'username', p.username) order by r.created_at desc), '[]'::jsonb)
      from public.form_reports r join public.words w on w.id = r.word_id join public.profiles p on p.id = r.user_id
     where r.status = coalesce(p_status, r.status)
     limit 200)) end
$$;

create or replace function public.admin_resolve_form_report(p_id bigint, p_status text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.is_admin() then return jsonb_build_object('error', 'forbidden'); end if;
  if p_status not in ('new','fixed','rejected') then return jsonb_build_object('error', 'bad_status'); end if;
  update public.form_reports set status = p_status, decided_at = now(),
         decided_by = (select tg_id from public.profiles where id = auth.uid())
   where id = p_id;
  return jsonb_build_object('ok', found);
end
$$;

create or replace function public.take_form_notifications()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v jsonb;
begin
  with n as (
    update public.form_reports set notified_at = now()
     where notified_at is null and created_at > now() - interval '7 days'
    returning *)
  select coalesce(jsonb_agg(jsonb_build_object(
           'uz', w.uz, 'ru', w.ru, 'kind', n.kind, 'item', n.item, 'person', n.person, 'form', n.form,
           'comment', n.comment, 'name', pr.first_name, 'username', pr.username) order by n.created_at), '[]'::jsonb)
    into v
    from n join public.words w on w.id = n.word_id join public.profiles pr on pr.id = n.user_id;
  return v;
end
$$;

-- ---------------------------------------------------------------- игра «Мои ошибки»
create or replace function public.start_mistakes()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('mistakes') then
    return jsonb_build_object('error', 'locked_tier', 'need', (select min_tier from public.feature_access where feature = 'mistakes'));
  end if;
  return jsonb_build_object('items', (
    select coalesce(jsonb_agg(public.word_card(x.word_id, v_uid, v_now)), '[]'::jsonb)
      from (select wp.word_id from public.word_progress wp
              join public.words w on w.id = wp.word_id and w.is_active
             where wp.user_id = v_uid and wp.wrong_count > 0
             order by wp.wrong_count::numeric / (wp.wrong_count + wp.correct_count) desc, wp.wrong_count desc,
                      wp.last_seen_at desc nulls last
             limit 20) x));
end
$$;
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
     and started_at > v_now - interval '3 hours' and mode = p_mode
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
    end if;

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
      join public.words w on w.id = wp.word_id and w.is_active
      where wp.user_id = v_uid and wp.due_on <= v_today
      order by 3, 4, 5 desc, 2
      limit v_r
    ) t;

    -- новые слова: сначала нижний уровень, внутри — порядок словаря (уровень мог измениться после пометок)
    -- слова из пройденных тем курсов (word_queue) — в первую очередь, независимо от уровня
    delete from public.word_queue q where q.user_id = v_uid
       and exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = q.word_id);
    select coalesce(array_agg(id order by q_first, q_at, cefr, sort_key), '{}') into v_new
    from (
      select w.id, w.cefr, w.sort_key, (q.word_id is null) as q_first, q.added_at as q_at from public.words w
      left join public.word_queue q on q.user_id = v_uid and q.word_id = w.id and p_topic_id is null
      where w.is_active and w.canonical_id is null
        and (w.cefr <= v_unlocked or q.word_id is not null)
        and (p_topic_id is null or w.topic_id = p_topic_id)
        and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id)
      order by (q.word_id is null), q.added_at, w.cefr, w.sort_key
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
    'review_day', v_rd,
    'review_count', cardinality(v_sess.word_ids) - cardinality(v_sess.new_ids),
    'new_count', cardinality(v_sess.new_ids),
    'items', coalesce((select jsonb_agg(public.word_card(x.id, v_uid, v_now) order by x.ord)
                       from unnest(v_sess.word_ids) with ordinality as x(id, ord)), '[]'::jsonb)
  );
end
$$;

-- ---------------------------------------------------------------- предложения по уровням, бонусные короткие фразы
-- long  — примеры из 4+ слов, когда знакома большая часть слов (как в шаге 15), по уровню слова;
-- bonus — короткие примеры (до 3 слов) своего уровня: необязательная лексика, учится как слова.
drop function if exists public.start_sentences();
create or replace function public.start_sentences(p_cefr text default null, p_kind text default 'long')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_now   timestamptz := public.app_now();
  v_today date;
  v_lvl   int := public.cfg_int('example_ready_level', 4);
  v_n     int := least(30, greatest(5, public.cfg_int('sentences_per_set', 12)));
  v_items jsonb;
  v_ready int;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('sentences') then return jsonb_build_object('error', 'locked_tier'); end if;
  if p_kind not in ('long','bonus') then return jsonb_build_object('error', 'bad_kind'); end if;
  v_today := public.user_today(v_uid);

  if p_kind = 'long' then
    with mine as (
      select wp.word_id from public.word_progress wp
      join public.words w on w.id = wp.word_id and w.is_active and (p_cefr is null or w.cefr = p_cefr)
      where wp.user_id = v_uid and public.effective_level(wp.level, wp.level_at, v_now) >= v_lvl),
    cand as (
      select e.*, sp.level as s_level, sp.due_on as s_due
      from public.examples e
      join mine m on m.word_id = e.word_id
      left join public.sentence_progress sp on sp.user_id = v_uid and sp.word_id = e.word_id and sp.n = e.n
      where not e.is_hidden and e.n_words >= 4 and cardinality(e.word_ids) > 0
        and (sp.due_on is null or sp.due_on <= v_today)
        and public.example_ready(v_uid, -1, e.word_ids, e.n_words, v_now)),
    pick as (select * from cand order by (s_due is null), s_due, random() limit v_n)
    select coalesce(jsonb_agg(jsonb_build_object(
             'word_id', p.word_id, 'n', p.n, 'uz', p.uz, 'ru', p.ru, 'audio_ok', p.audio_ok,
             'blank_start', p.blank_start, 'blank_len', p.blank_len, 'nw', p.n_words, 'level', coalesce(p.s_level, 0),
             'word', jsonb_build_object('id', w.id, 'uz', w.uz, 'ru', w.ru))), '[]'::jsonb),
           (select count(*) from cand)
      into v_items, v_ready
      from pick p join public.words w on w.id = p.word_id;
  else
    with cand as (
      select e.*, w.sort_key, sp.level as s_level, sp.due_on as s_due
      from public.examples e
      join public.words w on w.id = e.word_id and w.is_active and w.canonical_id is null
                         and w.cefr = coalesce(p_cefr, public.unlocked_cefr(v_uid))
      left join public.sentence_progress sp on sp.user_id = v_uid and sp.word_id = e.word_id and sp.n = e.n
      where not e.is_hidden and e.n_words between 2 and 3
        and (sp.due_on is null or sp.due_on <= v_today)),
    pick as (select * from cand order by (s_due is null), s_due, sort_key, n limit v_n)
    select coalesce(jsonb_agg(jsonb_build_object(
             'word_id', p.word_id, 'n', p.n, 'uz', p.uz, 'ru', p.ru, 'audio_ok', p.audio_ok,
             'blank_start', p.blank_start, 'blank_len', p.blank_len, 'nw', p.n_words, 'level', coalesce(p.s_level, 0),
             'word', jsonb_build_object('id', w.id, 'uz', w.uz, 'ru', w.ru))), '[]'::jsonb),
           (select count(*) from cand)
      into v_items, v_ready
      from pick p join public.words w on w.id = p.word_id;
  end if;

  return jsonb_build_object(
    'items', v_items, 'ready', v_ready, 'kind', p_kind, 'cefr', p_cefr,
    'pool', (select coalesce(jsonb_agg(ru), '[]'::jsonb) from (
               select e.ru from public.examples e join public.words w on w.id = e.word_id
               where w.cefr = coalesce(p_cefr, w.cefr) and w.cefr <= public.unlocked_cefr(v_uid)
                 and (case when p_kind = 'long' then e.n_words between 4 and 9 else e.n_words between 2 and 3 end)
                 and not e.is_hidden
               order by random() limit 60) x));
end
$$;

-- Сводка по уровням для экрана «Предложения»
create or replace function public.get_sentence_levels()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_now   timestamptz := public.app_now();
  v_today date;
  v_lvl   int := public.cfg_int('example_ready_level', 4);
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  return jsonb_build_object('unlocked', public.unlocked_cefr(v_uid), 'levels', (
    select jsonb_agg(jsonb_build_object(
      'cefr', c.cefr,
      'long_ready', (select count(*) from public.examples e
                       join public.word_progress wp on wp.word_id = e.word_id and wp.user_id = v_uid
                       join public.words w on w.id = e.word_id and w.cefr = c.cefr and w.is_active
                       left join public.sentence_progress sp on sp.user_id = v_uid and sp.word_id = e.word_id and sp.n = e.n
                      where not e.is_hidden and e.n_words >= 4 and cardinality(e.word_ids) > 0
                        and public.effective_level(wp.level, wp.level_at, v_now) >= v_lvl
                        and (sp.due_on is null or sp.due_on <= v_today)
                        and public.example_ready(v_uid, -1, e.word_ids, e.n_words, v_now)),
      'long_learned', (select count(*) from public.sentence_progress sp join public.examples e on e.word_id = sp.word_id and e.n = sp.n
                         join public.words w on w.id = e.word_id and w.cefr = c.cefr
                        where sp.user_id = v_uid and e.n_words >= 4 and sp.level >= 3),
      'bonus_total', (select count(*) from public.examples e join public.words w on w.id = e.word_id
                        and w.cefr = c.cefr and w.is_active and w.canonical_id is null
                       where not e.is_hidden and e.n_words between 2 and 3),
      'bonus_started', (select count(*) from public.sentence_progress sp join public.examples e on e.word_id = sp.word_id and e.n = sp.n
                          join public.words w on w.id = e.word_id and w.cefr = c.cefr
                         where sp.user_id = v_uid and e.n_words between 2 and 3),
      'bonus_due', (select count(*) from public.sentence_progress sp join public.examples e on e.word_id = sp.word_id and e.n = sp.n
                      join public.words w on w.id = e.word_id and w.cefr = c.cefr
                     where sp.user_id = v_uid and e.n_words between 2 and 3 and sp.due_on <= v_today))
      order by c.cefr)
    from (values ('A1'), ('A2'), ('B1'), ('B2')) c(cefr)));
end
$$;

-- ---------------------------------------------------------------- цель недели
create or replace function public.get_week()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_mon   date;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  v_mon := v_today - (extract(isodow from v_today)::int - 1);
  return jsonb_build_object(
    'goal', coalesce(((select settings from public.profiles where id = v_uid)->>'week_goal')::int, 5),
    'today_done', exists (select 1 from public.daily_stats where user_id = v_uid and day = v_today and correct + wrong > 0),
    'days', (select coalesce(jsonb_agg(extract(isodow from day)::int order by day), '[]'::jsonb)
               from public.daily_stats where user_id = v_uid and day between v_mon and v_today and correct + wrong > 0));
end
$$;

-- ---------------------------------------------------------------- недельное сообщение: общая статистика + пожелание
-- По понедельникам в 9:00 по времени пользователя (настройка «weekly», по умолчанию включено).
create or replace function public.weekly_stats()
returns jsonb language sql stable security definer set search_path = '' as $$
  with wk as (
    select user_id, count(*) filter (where correct + wrong > 0) as days, sum(correct + wrong) as answers,
           sum(correct) as correct
      from public.daily_stats
     where day between current_date - 7 and current_date - 1
     group by user_id having sum(correct + wrong) > 0),
  crs as (
    select distinct cp.user_id from public.course_progress cp
     where cp.read_at >= now() - interval '7 days')
  select case when (select count(*) from wk) = 0 then null else jsonb_build_object(
    'users', (select count(*) from wk),
    'days5', (select round(100.0 * count(*) filter (where days >= 5) / count(*)) from wk),
    'days3', (select round(100.0 * count(*) filter (where days >= 3) / count(*)) from wk),
    'ans100', (select round(100.0 * count(*) filter (where answers >= 100) / count(*)) from wk),
    'course', (select round(100.0 * count(*) filter (where wk.user_id in (select user_id from crs)) / count(*)) from wk),
    'acc', (select round(100.0 * sum(correct) / nullif(sum(answers), 0)) from wk)) end
$$;

create or replace function public.weekly_text(p_lang text, p_st jsonb, p_week int)
returns text language plpgsql immutable as $$
declare
  v_wish  text[];
  v_tip   text[];
  v_head  text;
  v_stats text := '';
begin
  if p_lang = 'uz' then
    v_head := 'Yangi haftangiz xayrli boʻlsin! 🌱';
    v_wish := array['Yangi hafta yangi soʻzlar va yangi suhbatlar olib kelsin!',
                    'Sizga yengil va qiziqarli hafta tilaymiz!',
                    'Har kuni kichik qadam — katta natija. Omad!',
                    'Bu hafta ham oʻzbek tilida bir qadam oldinga!'];
    v_tip := array['Vaqt kam boʻlsa ham, kuniga 5 daqiqa takrorlash soʻzlarni xotirada saqlaydi.',
                   'Seriyani uzmang: bitta qisqa mashgʻulot ham hisoblanadi.',
                   'Soʻzlardan keyin bitta grammatika mavzusi yoki dialogni oʻqing — tartibni ilovadagi tavsiyalar koʻrsatadi.',
                   'Juma — takrorlash kuni. Oʻrganganlaringizni mustahkamlang.'];
    if p_st is not null then
      v_stats := E'\n\nOʻtgan hafta oʻquvchilar:\n'
        || '• ' || (p_st->>'days5') || '% — 5 kun va undan koʻp shugʻullandi;' || E'\n'
        || '• ' || (p_st->>'days3') || '% — kamida 3 kun;' || E'\n'
        || '• ' || (p_st->>'ans100') || '% — 100 dan ortiq topshiriq bajardi;' || E'\n'
        || '• ' || (p_st->>'course') || '% — grammatika, madaniyat yoki tarix mavzusini oʻqidi;' || E'\n'
        || '• javoblarning oʻrtacha aniqligi — ' || (p_st->>'acc') || '%.';
    end if;
  elsif p_lang = 'en' then
    v_head := 'Happy new week! 🌱';
    v_wish := array['May this week bring you new words and new conversations!',
                    'Wishing you an easy and interesting week!',
                    'A small step every day adds up. Good luck!',
                    'One more step forward in Uzbek this week!'];
    v_tip := array['Even 5 minutes of review a day keeps words in memory when time is short.',
                   'Keep your streak: one short session counts.',
                   'After a word session, read one grammar topic or a dialogue — see the recommendations in the app.',
                   'Friday is review day — consolidate what you have learned.'];
    if p_st is not null then
      v_stats := E'\n\nLast week our learners:\n'
        || '• ' || (p_st->>'days5') || '% studied 5 days or more;' || E'\n'
        || '• ' || (p_st->>'days3') || '% studied at least 3 days;' || E'\n'
        || '• ' || (p_st->>'ans100') || '% did more than 100 exercises;' || E'\n'
        || '• ' || (p_st->>'course') || '% read a grammar, culture or history topic;' || E'\n'
        || '• average answer accuracy: ' || (p_st->>'acc') || '%.';
    end if;
  else
    v_head := 'С новой неделей! 🌱';
    v_wish := array['Пусть эта неделя принесёт новые слова и новые разговоры!',
                    'Желаем лёгкой и интересной недели!',
                    'Маленький шаг каждый день — большой результат. Удачи!',
                    'Ещё на шаг ближе к свободному узбекскому!'];
    v_tip := array['Даже если времени мало, 5 минут повторения в день не дают словам забыться.',
                   'Не прерывайте серию: одно короткое занятие тоже считается.',
                   'После слов прочитайте одну тему грамматики или диалог — порядок подскажут рекомендации в приложении.',
                   'Пятница — день повторения. Закрепите изученное.'];
    if p_st is not null then
      v_stats := E'\n\nКак занимались ученики на прошлой неделе:\n'
        || '• ' || (p_st->>'days5') || '% занимались 5 дней и больше;' || E'\n'
        || '• ' || (p_st->>'days3') || '% — хотя бы 3 дня;' || E'\n'
        || '• ' || (p_st->>'ans100') || '% выполнили больше 100 заданий;' || E'\n'
        || '• ' || (p_st->>'course') || '% прочитали тему грамматики, культуры или истории;' || E'\n'
        || '• средняя точность ответов — ' || (p_st->>'acc') || '%.';
    end if;
  end if;
  return v_head || v_stats || E'\n\n' || v_wish[1 + p_week % 4] || E'\n' || v_tip[1 + (p_week + 1) % 4];
end
$$;
create or replace function public.reminders_take(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_out jsonb := '[]'::jsonb;
  r record;
  v_local timestamptz;
  v_today date;
  v_hour int;
  v_due int;
  v_end timestamptz;
  v_rd int := public.cfg_int('review_day', 5);
  v_wst jsonb;
  v_wst_done boolean := false;
begin
  delete from public.cron_tokens where created_at < now() - interval '15 minutes';
  delete from public.cron_tokens where token = p_token;
  if not found then return jsonb_build_object('error', 'bad_token'); end if;

  for r in
    select p.id, p.tg_id, p.ui_lang, p.first_name, coalesce(p.timezone, 'Asia/Tashkent') tz,
           coalesce((p.settings->>'remind')::boolean, true) remind,
           coalesce((p.settings->>'remind_hour')::int, 19) remind_hour, p.created_at,
           coalesce((p.settings->>'weekly')::boolean, true) weekly
      from public.profiles p
     where p.tg_id is not null and not p.bot_blocked
  loop
    v_local := now() at time zone r.tz;
    v_today := v_local::date;
    v_hour := extract(hour from v_local)::int;
    -- понедельник, 9:00 — недельное сообщение (тем, кто занимался за последние 30 дней или недавно пришёл)
    if extract(isodow from v_today)::int = 1 and v_hour = 9 and r.weekly
       and (exists (select 1 from public.daily_stats d where d.user_id = r.id and d.day > v_today - 30)
            or r.created_at > now() - interval '30 days')
       and not exists (select 1 from public.reminder_log l where l.user_id = r.id and l.kind = 'weekly' and l.day = v_today) then
      if not v_wst_done then v_wst := public.weekly_stats(); v_wst_done := true; end if;
      insert into public.reminder_log (user_id, kind, day) values (r.id, 'weekly', v_today);
      v_out := v_out || jsonb_build_object('tg_id', r.tg_id, 'lang', r.ui_lang, 'name', r.first_name, 'kind', 'weekly',
        'text', public.weekly_text(r.ui_lang, v_wst, extract(week from v_today)::int));
    end if;
    if v_hour <> r.remind_hour then continue; end if;

    -- конец подписки через 3 дня или раньше (и нет следующей) — один раз на подписку
    select max(s.ends_at) into v_end from public.subscriptions s where s.user_id = r.id and s.ends_at > now();
    if v_end is not null and v_end < now() + interval '3 days'
       and not exists (select 1 from public.reminder_log l where l.user_id = r.id and l.kind = 'sub_end' and l.day = v_end::date) then
      insert into public.reminder_log (user_id, kind, day) values (r.id, 'sub_end', v_end::date);
      v_out := v_out || jsonb_build_object('tg_id', r.tg_id, 'lang', r.ui_lang, 'name', r.first_name, 'kind', 'sub_end',
        'ends_at', v_end, 'tier', (select s.tier from public.subscriptions s where s.user_id = r.id and s.ends_at = v_end limit 1));
    end if;

    if not r.remind then continue; end if;
    -- сегодня уже занимались — не беспокоим
    if exists (select 1 from public.daily_stats d where d.user_id = r.id and d.day = v_today and d.correct + d.wrong > 0) then continue; end if;
    -- давно не заходили (30+ дней) — не надоедаем
    if not exists (select 1 from public.daily_stats d where d.user_id = r.id and d.day > v_today - 30)
       and r.created_at < now() - interval '30 days' then continue; end if;
    if exists (select 1 from public.reminder_log l where l.user_id = r.id and l.kind = 'daily' and l.day = v_today) then continue; end if;
    insert into public.reminder_log (user_id, kind, day) values (r.id, 'daily', v_today);
    select count(*) into v_due from public.word_progress wp join public.words w on w.id = wp.word_id and w.is_active
     where wp.user_id = r.id and wp.due_on <= v_today;
    v_out := v_out || jsonb_build_object('tg_id', r.tg_id, 'lang', r.ui_lang, 'name', r.first_name, 'kind', 'daily',
      'due', v_due,
      'started', (select count(*) from public.word_progress where user_id = r.id),
      'review_day_tomorrow', v_rd > 0 and extract(isodow from v_today + 1)::int = v_rd,
      'review_day_today', v_rd > 0 and extract(isodow from v_today)::int = v_rd);
  end loop;
  return jsonb_build_object('ok', true, 'items', v_out);
end
$$;

-- ---------------------------------------------------------------- групповая подписка: 3 человека, −15%
-- Покупатель получает подписку себе и 2 кода для друзей (одноразовые, активировать в течение года).
alter table public.plans add column if not exists seats smallint not null default 1;
alter table public.plans drop constraint if exists plans_seats_check;
alter table public.plans add constraint plans_seats_check check (seats in (1, 3));
alter table public.plans drop constraint if exists plans_tier_months_key;
alter table public.plans drop constraint if exists plans_tier_months_seats_key;
alter table public.plans add constraint plans_tier_months_seats_key unique (tier, months, seats);

insert into public.plans (tier, months, seats, price_stars, price_uzs, price_usd, is_active)
select p.tier, p.months, 3,
       (round(p.price_stars * 3 * 0.85 / 10.0) * 10)::int,
       (round(p.price_uzs * 3 * 0.85 / 1000.0) * 1000)::int,
       round(p.price_usd * 3 * 0.85, 2), true
  from public.plans p where p.seats = 1
on conflict (tier, months, seats) do nothing;

create table if not exists public.group_codes (
  id        bigint generated always as identity primary key,
  owner_id  uuid not null references public.profiles(id) on delete cascade,
  code      text not null,
  tier      text not null,
  months    smallint not null,
  charge_id text,
  created_at timestamptz not null default now()
);
alter table public.group_codes enable row level security;
revoke all on public.group_codes from anon, authenticated;

create or replace function public.get_plans()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'tier', tier, 'months', months, 'seats', seats,
           'price_stars', price_stars, 'price_uzs', price_uzs, 'price_usd', price_usd)
         order by seats, tier desc, months), '[]'::jsonb)
  from public.plans where is_active
$$;

create or replace function public.stars_invoice_data(p_user uuid, p_plan_id integer)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when p.id is null or not p.is_active or coalesce(p.price_stars, 0) <= 0 or pr.id is null
              then jsonb_build_object('error', 'bad_plan')
              else jsonb_build_object('plan_id', p.id, 'tier', p.tier, 'months', p.months, 'seats', p.seats,
                                      'stars', p.price_stars, 'tg_id', pr.tg_id, 'ui_lang', pr.ui_lang) end
  from (select 1) one
  left join public.plans p on p.id = p_plan_id
  left join public.profiles pr on pr.id = p_user
$$;

create or replace function public.stars_grant_payment(p_payload text, p_tg_id bigint, p_amount integer, p_charge_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_check jsonb;
  v_plan  public.plans%rowtype;
  v_user  uuid;
  v_start timestamptz;
  v_end   timestamptz;
  v_sub   bigint;
  v_pay   public.payments%rowtype;
  v_parts text[] := string_to_array(coalesce(p_payload, ''), ':');
  v_codes jsonb := '[]'::jsonb;
  v_code  text;
begin
  if p_charge_id is null or p_charge_id = '' then return jsonb_build_object('ok', false, 'error', 'no_charge_id'); end if;
  select * into v_pay from public.payments where charge_id = p_charge_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'tier', v_pay.tier,
      'ends_at', (select ends_at from public.subscriptions where id = v_pay.subscription_id));
  end if;

  if array_length(v_parts, 1) <> 3 or v_parts[1] <> 'p' then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;
  select * into v_plan from public.plans where id = v_parts[2]::int;
  select id into v_user from public.profiles where id = v_parts[3]::uuid and tg_id = p_tg_id;
  if v_plan.id is null or v_user is null then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;

  v_check := public.grant_subscription(v_user, v_plan.tier, v_plan.months, 'stars', p_charge_id);
  v_sub := (v_check->>'sub_id')::bigint;
  v_start := (v_check->>'starts_at')::timestamptz;
  v_end := (v_check->>'ends_at')::timestamptz;
  insert into public.payments (user_id, plan_id, tier, months, stars, charge_id, subscription_id)
  values (v_user, v_plan.id, v_plan.tier, v_plan.months, p_amount, p_charge_id, v_sub);

  -- групповая подписка: коды для друзей
  if v_plan.seats > 1 then
    for v_code in select * from public.admin_create_codes(v_plan.tier, v_plan.months, v_plan.seats - 1, 1,
                                                          now() + interval '1 year', 'group ' || p_charge_id, null) loop
      insert into public.group_codes (owner_id, code, tier, months, charge_id) values (v_user, v_code, v_plan.tier, v_plan.months, p_charge_id);
      v_codes := v_codes || to_jsonb(v_code);
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'tier', v_plan.tier, 'months', v_plan.months, 'seats', v_plan.seats,
                            'starts_at', v_start, 'ends_at', v_end, 'codes', v_codes);
end
$$;

-- Коды групповой подписки владельца и их статус
create or replace function public.get_group_codes()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', g.code, 'tier', g.tier, 'months', g.months,
           'used', coalesce(a.used_count, 0) >= coalesce(a.max_uses, 1), 'created_at', g.created_at)
           order by g.created_at desc, g.id), '[]'::jsonb)
  from public.group_codes g
  left join public.access_codes a on a.code_hash = public.hash_code(replace(g.code, '-', ''))
  where g.owner_id = auth.uid()
$$;

-- ---------------------------------------------------------------- аналитика для администратора
create or replace function public.admin_analytics()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := (now() at time zone 'Asia/Tashkent')::date;
begin
  if not public.is_admin() then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'users', jsonb_build_object(
      'total', (select count(*) from public.profiles),
      'new7', (select count(*) from public.profiles where created_at > now() - interval '7 days'),
      'new30', (select count(*) from public.profiles where created_at > now() - interval '30 days'),
      'dau', (select count(distinct user_id) from public.daily_stats where day = v_today and correct + wrong > 0),
      'wau', (select count(distinct user_id) from public.daily_stats where day > v_today - 7 and correct + wrong > 0),
      'mau', (select count(distinct user_id) from public.daily_stats where day > v_today - 30 and correct + wrong > 0),
      'blocked', (select count(*) from public.profiles where bot_blocked)),
    -- удержание: из пришедших 8–60 дней назад — сколько занимались на 1-й и 7-й день
    'retention', (select jsonb_build_object(
        'cohort', count(*),
        'd1', round(100.0 * count(*) filter (where exists (select 1 from public.daily_stats d where d.user_id = p.id
                and d.day = (p.created_at at time zone 'Asia/Tashkent')::date + 1 and d.correct + d.wrong > 0)) / nullif(count(*), 0)),
        'd7', round(100.0 * count(*) filter (where exists (select 1 from public.daily_stats d where d.user_id = p.id
                and d.day between (p.created_at at time zone 'Asia/Tashkent')::date + 7 and (p.created_at at time zone 'Asia/Tashkent')::date + 8
                and d.correct + d.wrong > 0)) / nullif(count(*), 0)))
      from public.profiles p where p.created_at between now() - interval '60 days' and now() - interval '8 days'),
    'money', jsonb_build_object(
      'active_basic', (select count(distinct user_id) from public.subscriptions where tier = 'basic' and starts_at <= now() and ends_at > now()),
      'active_advanced', (select count(distinct user_id) from public.subscriptions where tier = 'advanced' and starts_at <= now() and ends_at > now()),
      'payments30', (select count(*) from public.payments where created_at > now() - interval '30 days'),
      'stars30', (select coalesce(sum(stars), 0) from public.payments where created_at > now() - interval '30 days'),
      'payers_total', (select count(distinct user_id) from public.payments)),
    'activity', jsonb_build_object(
      'sessions7', (select count(*) from public.study_sessions where local_day > v_today - 7),
      'answers7', (select coalesce(sum(correct + wrong), 0) from public.daily_stats where day > v_today - 7),
      'accuracy7', (select round(100.0 * sum(correct) / nullif(sum(correct + wrong), 0)) from public.daily_stats where day > v_today - 7),
      'words_started', (select count(*) from public.word_progress),
      'topics_read7', (select count(*) from public.course_progress cp join public.course_units u on u.id = cp.unit_id
                        where cp.read_at > now() - interval '7 days' and u.course_id <> 'dialogs'),
      'dialogs_read7', (select count(*) from public.course_progress cp join public.course_units u on u.id = cp.unit_id
                         where cp.read_at > now() - interval '7 days' and u.course_id = 'dialogs'),
      'morph7', (select count(*) from public.verb_progress where last_at > now() - interval '7 days'),
      'tests_passed', (select coalesce(jsonb_object_agg(cefr, n), '{}'::jsonb) from
                         (select cefr, count(distinct user_id) n from public.level_test_attempts where passed group by cefr) t)),
    'days', (select coalesce(jsonb_agg(jsonb_build_object('day', d, 'users', u, 'new', n) order by d), '[]'::jsonb) from (
               select g.d::date d,
                      (select count(distinct user_id) from public.daily_stats s where s.day = g.d::date and s.correct + s.wrong > 0) u,
                      (select count(*) from public.profiles p where (p.created_at at time zone 'Asia/Tashkent')::date = g.d::date) n
                 from generate_series(v_today - 13, v_today, interval '1 day') g(d)) x));
end
$$;

-- ---------------------------------------------------------------- рекомендуемый порядок занятий на день
-- 1) сессия слов → 2) тема курса (грамматика → культура → обществознание → история, по очереди)
-- → 3) диалог → 4) закрепление (таблицы спряжения/склонения, предложения или контрольная)
create or replace function public.get_next_step()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid      uuid := auth.uid();
  v_today    date;
  v_tz       text;
  v_unlocked text;
  v_words    boolean;
  v_course   boolean;
  v_dialog   boolean;
  v_cons     boolean;
  v_last     text;
  v_order    text[] := array['grammar','culture','civics','history'];
  v_start    int;
  v_c        text;
  v_unit     record;
  v_next     jsonb;
  k          int;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  v_tz := coalesce((select timezone from public.profiles where id = v_uid), 'Asia/Tashkent');
  v_unlocked := public.unlocked_cefr(v_uid);

  v_words := exists (select 1 from public.study_sessions where user_id = v_uid and local_day = v_today and finished_at is not null);
  v_course := exists (select 1 from public.course_progress cp join public.course_units u on u.id = cp.unit_id
                       where cp.user_id = v_uid and u.course_id <> 'dialogs' and (cp.read_at at time zone v_tz)::date = v_today);
  v_dialog := exists (select 1 from public.course_progress cp join public.course_units u on u.id = cp.unit_id
                       where cp.user_id = v_uid and u.course_id = 'dialogs' and (cp.read_at at time zone v_tz)::date = v_today);
  v_cons := exists (select 1 from public.verb_progress where user_id = v_uid and (last_at at time zone v_tz)::date = v_today)
         or exists (select 1 from public.sentence_progress where user_id = v_uid and (last_at at time zone v_tz)::date = v_today)
         or exists (select 1 from public.word_check_attempts where user_id = v_uid and (started_at at time zone v_tz)::date = v_today);

  if not v_words then
    v_next := jsonb_build_object('kind', 'words');
  elsif not v_course then
    -- курс, следующий за последним изученным
    select u.course_id into v_last from public.course_progress cp join public.course_units u on u.id = cp.unit_id
     where cp.user_id = v_uid and u.course_id <> 'dialogs' and cp.read_at is not null
     order by cp.read_at desc limit 1;
    v_start := coalesce(array_position(v_order, v_last), 0);
    for k in 1..4 loop
      v_c := v_order[(v_start + k - 1) % 4 + 1];
      select u.id, u.course_id, u.title_ru, u.title_uz, u.title_en, u.cefr into v_unit
        from public.course_units u
        left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = v_uid
       where u.course_id = v_c and u.cefr <= v_unlocked and cp.read_at is null and public.unit_allowed(u)
       order by u.cefr, u.sort_order limit 1;
      if found then
        v_next := jsonb_build_object('kind', 'course', 'course', v_unit.course_id, 'unit_id', v_unit.id, 'cefr', v_unit.cefr,
                                     'title_ru', v_unit.title_ru, 'title_uz', v_unit.title_uz, 'title_en', v_unit.title_en);
        exit;
      end if;
    end loop;
  end if;
  if v_next is null and v_words and not v_dialog then
    select u.id, u.title_ru, u.title_uz, u.title_en, u.cefr into v_unit
      from public.course_units u
      left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = v_uid
     where u.course_id = 'dialogs' and u.cefr <= v_unlocked and cp.read_at is null and public.unit_allowed(u)
     order by u.cefr, u.sort_order limit 1;
    if found then
      v_next := jsonb_build_object('kind', 'dialog', 'course', 'dialogs', 'unit_id', v_unit.id, 'cefr', v_unit.cefr,
                                   'title_ru', v_unit.title_ru, 'title_uz', v_unit.title_uz, 'title_en', v_unit.title_en);
    end if;
  end if;
  if v_next is null and v_words and not v_cons then
    v_next := jsonb_build_object('kind', 'consolidate', 'what',
      case when exists (select 1 from public.verb_progress where user_id = v_uid and due_on <= v_today) then 'conj'
           when exists (select 1 from public.sentence_progress where user_id = v_uid and due_on <= v_today) then 'sentences'
           when (select count(*) from public.word_progress where user_id = v_uid) >= 20 then 'quiz'
           else 'conj' end);
  end if;
  return jsonb_build_object(
    'next', coalesce(v_next, jsonb_build_object('kind', 'done')),
    'steps', jsonb_build_object('words', v_words, 'course', v_course, 'dialog', v_dialog, 'consolidate', v_cons));
end
$$;
create or replace function public.get_course(p_course text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not exists (select 1 from public.courses where id = p_course) then return jsonb_build_object('error', 'not_found'); end if;
  return (
    select jsonb_build_object(
      'id', c.id, 'title_ru', c.title_ru, 'title_uz', c.title_uz, 'title_en', c.title_en,
      'allowed', public.feature_allowed(public.course_feature(c.id)),
      'min_tier', (select fa.min_tier from public.feature_access fa where fa.feature = public.course_feature(c.id)),
      'preview', public.cfg_int('course_preview_units', 2),
      'sections', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', s.id, 'title_ru', s.title_ru, 'title_uz', s.title_uz, 'title_en', s.title_en) order by s.sort_order), '[]'::jsonb)
                   from public.course_sections s where s.course_id = c.id),
      'units', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', u.id, 'n', u.source_no, 'section_id', u.section_id, 'cefr', u.cefr,
                  'title_ru', u.title_ru, 'title_uz', u.title_uz, 'title_en', u.title_en,
                  'period', u.period, 'period_uz', u.period_uz, 'period_en', u.period_en,
                  'express_ru', u.express_ru, 'express_uz', u.express_uz, 'express_en', u.express_en,
                  'locked', not public.unit_allowed(u),
                  'read', cp.read_at is not null,
                  'tested', coalesce(cp.status = 'tested', false),
                  'best_score', cp.best_score,
                  'tasks_done', coalesce(cardinality(cp.tasks_done), 0),
                  'tasks_total', (select count(*) from public.unit_tasks t where t.unit_id = u.id and t.status = 'approved' and t.kind = 'open'))
                order by u.cefr, u.sort_order), '[]'::jsonb)
                from public.course_units u
                left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = v_uid
                where u.course_id = c.id),
      'timeline', (select coalesce(jsonb_agg(jsonb_build_object(
                     'date', e.date_label, 'text_ru', e.text_ru, 'text_uz', e.text_uz, 'text_en', e.text_en, 'unit_id', e.unit_id)
                     order by e.sort_order), '[]'::jsonb)
                   from public.timeline_events e where e.course_id = c.id),
      'reference', (select coalesce(jsonb_agg(jsonb_build_object(
                      'kind', r.kind, 'title_ru', r.title_ru, 'title_uz', r.title_uz, 'title_en', r.title_en,
                      'value', r.value, 'extra', r.extra) order by r.kind, r.sort_order), '[]'::jsonb)
                    from public.reference_items r where r.course_id = c.id))
    from public.courses c where c.id = p_course);
end
$$;

create or replace function public.get_unit(p_unit int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_unit public.course_units%rowtype;
  v_prog public.course_progress%rowtype;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  select * into v_unit from public.course_units where id = p_unit;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if not public.unit_allowed(v_unit) then
    return jsonb_build_object('error', 'locked_tier',
      'need', (select fa.min_tier from public.feature_access fa where fa.feature = public.course_feature(v_unit.course_id)));
  end if;
  insert into public.course_progress (user_id, unit_id, status) values (v_uid, p_unit, 'opened')
  on conflict (user_id, unit_id) do update set updated_at = now()
  returning * into v_prog;
  return jsonb_build_object(
    'id', v_unit.id, 'course_id', v_unit.course_id, 'n', v_unit.source_no, 'cefr', v_unit.cefr, 'extra', v_unit.extra,
    'words', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'uz', w.uz, 'ru', w.ru, 'en', w.en) order by w.sort_key), '[]'::jsonb)
              from public.unit_words uw join public.words w on w.id = uw.word_id where uw.unit_id = v_unit.id),
    'title_ru', v_unit.title_ru, 'title_uz', v_unit.title_uz, 'title_en', v_unit.title_en,
    'period', v_unit.period, 'period_uz', v_unit.period_uz, 'period_en', v_unit.period_en,
    'section', (select jsonb_build_object('title_ru', s.title_ru, 'title_uz', s.title_uz, 'title_en', s.title_en)
                from public.course_sections s where s.id = v_unit.section_id),
    'express_ru', v_unit.express_ru, 'express_uz', v_unit.express_uz, 'express_en', v_unit.express_en,
    'detailed_ru', v_unit.detailed_ru, 'detailed_uz', v_unit.detailed_uz, 'detailed_en', v_unit.detailed_en,
    'source', v_unit.source,
    'tasks', (select coalesce(jsonb_agg(jsonb_build_object(
                'n', t.n, 'kind', t.kind, 'prompt_ru', t.prompt_ru, 'prompt_uz', t.prompt_uz, 'prompt_en', t.prompt_en)
                order by t.n), '[]'::jsonb)
              from public.unit_tasks t where t.unit_id = v_unit.id and t.status = 'approved' and t.kind = 'open'),
    'has_examples', v_unit.example_pattern is not null,
    'examples', public.unit_examples(v_unit.id, 8, 0),
    'read', v_prog.read_at is not null,
    'tasks_done', to_jsonb(v_prog.tasks_done),
    'prev_id', (select u.id from public.course_units u where u.course_id = v_unit.course_id and u.sort_order < v_unit.sort_order order by u.sort_order desc limit 1),
    'next_id', (select u.id from public.course_units u where u.course_id = v_unit.course_id and u.sort_order > v_unit.sort_order order by u.sort_order limit 1)
  );
end
$$;
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
      if p_settings->>'intensity' <> 'light' and public.current_tier() <> 'advanced' then
        return jsonb_build_object('error', 'locked_tier', 'need', 'advanced');
      end if;
      v_clean := v_clean || jsonb_build_object('intensity', p_settings->>'intensity');
    end if;
    if p_settings ? 'theme' and p_settings->>'theme' in ('telegram','light','dark','gray','sand','midnight') then
      v_clean := v_clean || jsonb_build_object('theme', p_settings->>'theme');
    end if;
    if p_settings ? 'remind' then
      v_clean := v_clean || jsonb_build_object('remind', (p_settings->>'remind')::boolean);
    end if;
    if p_settings ? 'remind_hour' then
      v_clean := v_clean || jsonb_build_object('remind_hour', least(23, greatest(6, (p_settings->>'remind_hour')::int)));
    end if;
    if p_settings ? 'onboarded' then
      v_clean := v_clean || jsonb_build_object('onboarded', (p_settings->>'onboarded')::boolean);
    end if;
    if p_settings ? 'week_goal' then
      v_clean := v_clean || jsonb_build_object('week_goal', least(7, greatest(1, (p_settings->>'week_goal')::int)));
    end if;
    if p_settings ? 'weekly' then
      v_clean := v_clean || jsonb_build_object('weekly', (p_settings->>'weekly')::boolean);
    end if;
    if p_settings ? 'feedback_asked' then
      v_clean := v_clean || jsonb_build_object('feedback_asked', (p_settings->>'feedback_asked')::boolean);
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
revoke execute on function public.refresh_unit_words() from public, anon, authenticated;
revoke execute on function public.queue_unit_words() from public, anon, authenticated;
revoke execute on function public.morph_state(uuid) from public, anon, authenticated;
revoke execute on function public.take_form_notifications() from public, anon, authenticated;
revoke execute on function public.weekly_stats() from public, anon, authenticated;
revoke execute on function public.weekly_text(text, jsonb, int) from public, anon, authenticated;
grant execute on function public.take_form_notifications() to service_role;
grant execute on function public.refresh_unit_words() to service_role;

revoke execute on function public.answer_morph(int, text, int, int) from public, anon;
revoke execute on function public.get_verbs() from public, anon;
revoke execute on function public.get_nouns() from public, anon;
revoke execute on function public.get_morph(jsonb) from public, anon;
revoke execute on function public.report_form(int, text, text, int, text, text) from public, anon;
revoke execute on function public.admin_form_reports(text) from public, anon;
revoke execute on function public.admin_resolve_form_report(bigint, text) from public, anon;
revoke execute on function public.start_mistakes() from public, anon;
revoke execute on function public.start_sentences(text, text) from public, anon;
revoke execute on function public.get_sentence_levels() from public, anon;
revoke execute on function public.get_week() from public, anon;
revoke execute on function public.get_group_codes() from public, anon;
revoke execute on function public.admin_analytics() from public, anon;
revoke execute on function public.get_next_step() from public, anon;
grant execute on function public.answer_morph(int, text, int, int) to authenticated;
grant execute on function public.get_verbs() to authenticated;
grant execute on function public.get_nouns() to authenticated;
grant execute on function public.get_morph(jsonb) to authenticated;
grant execute on function public.report_form(int, text, text, int, text, text) to authenticated;
grant execute on function public.admin_form_reports(text) to authenticated;
grant execute on function public.admin_resolve_form_report(bigint, text) to authenticated;
grant execute on function public.start_mistakes() to authenticated;
grant execute on function public.start_sentences(text, text) to authenticated;
grant execute on function public.get_sentence_levels() to authenticated;
grant execute on function public.get_week() to authenticated;
grant execute on function public.get_group_codes() to authenticated;
grant execute on function public.admin_analytics() to authenticated;
grant execute on function public.get_next_step() to authenticated;

-- слова тем — по уже загруженным данным (после импорта курсов и словаря пересчитываются снова)
select public.refresh_unit_words();
