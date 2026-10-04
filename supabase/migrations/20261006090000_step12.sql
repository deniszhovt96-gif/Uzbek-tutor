-- =============================================================================
-- Шаг 12 (решения владельца от 04.10.2026)
--   • Уровни слов перепроверены по каждому слову (data/levels.csv) — темы теперь бывают на нескольких уровнях.
--     На «Пути» тема показывается на каждом своём уровне; совсем маленькие части (меньше path_min_group слов)
--     присоединяются к соседнему уровню той же темы.
--   • Разговорная лексика: слова с register = 'colloquial', литературный вариант и пометка (words.literary, words.note).
--   • Справочник слов: по уровню, теме и алфавиту; слова темы — в листе темы на «Пути».
--   • Пятница — день повторения: новые слова открываются после N повторений за день; N растёт с объёмом изученного.
--   • Пометки «малоиспользуемое» (→ B1) и «не используется» (→ B2) для слов A1/A2 — от пользователей уровня B1+
--     и администраторов; администраторы одобряют или отменяют. Одобренные уровни сохраняются при повторном импорте.
-- =============================================================================

alter table public.words add column if not exists register text not null default 'lit';
alter table public.words add column if not exists literary text;
alter table public.words add column if not exists note text;
alter table public.words add column if not exists en text;

insert into public.app_config (key, value, note) values
  ('path_min_group',     '6',  'Путь: часть темы меньше этого числа слов присоединяется к соседнему уровню'),
  ('review_day',         '5',  'День повторения (ISO: 1 — пн … 7 — вс; 0 — выключено)'),
  ('review_day_base',    '15', 'День повторения: повторений до новых слов — база'),
  ('review_day_per',     '20', 'День повторения: +1 повторение за каждые N начатых слов'),
  ('review_day_max',     '80', 'День повторения: не больше стольких повторений')
on conflict (key) do nothing;

insert into public.feature_access (feature, min_tier, note) values
  ('dictionary', 'free', 'Справочник слов')
on conflict (feature) do nothing;

-- ---------------------------------------------------------------- пометки уровня слов
create table if not exists public.word_level_overrides (
  word_id    int primary key references public.words(id) on delete cascade,
  cefr       text not null check (cefr in ('A1','A2','B1','B2')),
  base_cefr  text not null,                    -- уровень из словаря (обновляется при импорте)
  updated_at timestamptz not null default now(),
  updated_by bigint
);
alter table public.word_level_overrides enable row level security;
revoke all on public.word_level_overrides from anon, authenticated;

create table if not exists public.word_level_proposals (
  id          bigserial primary key,
  word_id     int not null references public.words(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('rare','unused')),
  from_cefr   text not null,
  to_cefr     text not null,
  status      text not null default 'pending' check (status in ('pending','approved','rejected','reverted')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  bigint,
  notified_at timestamptz
);
create unique index if not exists word_level_proposals_one_pending
  on public.word_level_proposals (word_id, user_id) where status = 'pending';
create index if not exists word_level_proposals_status on public.word_level_proposals (status, created_at desc);
alter table public.word_level_proposals enable row level security;
revoke all on public.word_level_proposals from anon, authenticated;

-- Может ли пользователь помечать слова: администратор или открыт уровень B1 и выше
create or replace function public.can_flag_words()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and (public.is_admin() or public.unlocked_cefr(auth.uid()) >= 'B1')
$$;

-- Применить уровень к слову и его полным дублям
create or replace function public.apply_word_level(p_word int, p_cefr text, p_admin bigint)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into public.word_level_overrides (word_id, cefr, base_cefr, updated_by)
  select w.id, p_cefr, coalesce(o.base_cefr, w.cefr), p_admin
    from public.words w left join public.word_level_overrides o on o.word_id = w.id
   where w.id = p_word or w.canonical_id = p_word
  on conflict (word_id) do update set cefr = excluded.cefr, updated_at = now(), updated_by = excluded.updated_by;
  update public.words set cefr = p_cefr where id = p_word or canonical_id = p_word;
end
$$;

create or replace function public.propose_word_level(p_word int, p_kind text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_w   public.words%rowtype;
  v_to  text;
  v_tg  bigint;
  v_adm boolean := public.is_admin();
begin
  if not public.can_flag_words() then return jsonb_build_object('error', 'forbidden'); end if;
  if p_kind not in ('rare','unused') then return jsonb_build_object('error', 'bad_kind'); end if;
  select * into v_w from public.words where id = p_word and is_active;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if v_w.cefr not in ('A1','A2') then return jsonb_build_object('error', 'not_basic'); end if;
  v_to := case p_kind when 'rare' then 'B1' else 'B2' end;
  select tg_id into v_tg from public.profiles where id = v_uid;
  delete from public.word_level_proposals where word_id = p_word and user_id = v_uid and status = 'pending';
  insert into public.word_level_proposals (word_id, user_id, kind, from_cefr, to_cefr, status, decided_at, decided_by)
  values (p_word, v_uid, p_kind, v_w.cefr, v_to,
          case when v_adm then 'approved' else 'pending' end,
          case when v_adm then now() end, case when v_adm then v_tg end);
  if v_adm then
    -- пометка администратора применяется сразу; остальные администраторы получат уведомление и смогут отменить
    perform public.apply_word_level(p_word, v_to, v_tg);
    update public.word_level_proposals set status = 'approved', decided_at = now(), decided_by = v_tg
     where word_id = p_word and status = 'pending';
  end if;
  return jsonb_build_object('ok', true, 'status', case when v_adm then 'approved' else 'pending' end, 'to', v_to);
end
$$;

-- Список для администратора: ожидают решения (по словам) и недавно применённые
create or replace function public.admin_word_proposals()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'pending', coalesce((
      select jsonb_agg(x order by x->>'last' desc) from (
        select jsonb_build_object('word_id', w.id, 'uz', w.uz, 'ru', w.ru, 'cefr', w.cefr,
                 'topic', t.name_ru,
                 'rare', count(*) filter (where p.kind = 'rare'),
                 'unused', count(*) filter (where p.kind = 'unused'),
                 'who', jsonb_agg(distinct coalesce(pr.first_name, '') || coalesce(' @' || pr.username, '')),
                 'last', max(p.created_at)) as x
        from public.word_level_proposals p
        join public.words w on w.id = p.word_id
        join public.topics t on t.id = w.topic_id
        join public.profiles pr on pr.id = p.user_id
        where p.status = 'pending'
        group by w.id, w.uz, w.ru, w.cefr, t.name_ru) s), '[]'::jsonb),
    'applied', coalesce((
      select jsonb_agg(jsonb_build_object('word_id', w.id, 'uz', w.uz, 'ru', w.ru, 'cefr', o.cefr, 'base', o.base_cefr,
                                          'at', o.updated_at) order by o.updated_at desc)
      from public.word_level_overrides o join public.words w on w.id = o.word_id
      where w.canonical_id is null and o.updated_at > now() - interval '60 days'), '[]'::jsonb));
end
$$;

create or replace function public.admin_decide_word(p_word int, p_decision text, p_cefr text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tg bigint := (select tg_id from public.profiles where id = auth.uid());
  v_to text;
  v_o  public.word_level_overrides%rowtype;
begin
  if not public.is_admin() then return jsonb_build_object('error', 'forbidden'); end if;
  if p_decision = 'approve' then
    v_to := coalesce(p_cefr, (select case when count(*) filter (where kind = 'unused') > count(*) filter (where kind = 'rare')
                                          then 'B2' else 'B1' end
                               from public.word_level_proposals where word_id = p_word and status = 'pending'));
    if v_to not in ('A1','A2','B1','B2') then return jsonb_build_object('error', 'bad_cefr'); end if;
    perform public.apply_word_level(p_word, v_to, v_tg);
    update public.word_level_proposals set status = 'approved', decided_at = now(), decided_by = v_tg
     where word_id = p_word and status = 'pending';
    return jsonb_build_object('ok', true, 'cefr', v_to);
  elsif p_decision = 'reject' then
    update public.word_level_proposals set status = 'rejected', decided_at = now(), decided_by = v_tg
     where word_id = p_word and status = 'pending';
    return jsonb_build_object('ok', true);
  elsif p_decision = 'revert' then
    -- отменить применённое изменение: вернуть уровень из словаря
    select * into v_o from public.word_level_overrides where word_id = p_word;
    if not found then return jsonb_build_object('error', 'not_found'); end if;
    update public.words w set cefr = o.base_cefr
      from public.word_level_overrides o
     where o.word_id = w.id and (w.id = p_word or w.canonical_id = p_word);
    delete from public.word_level_overrides
     where word_id in (select id from public.words where id = p_word or canonical_id = p_word);
    update public.word_level_proposals set status = 'reverted', decided_at = now(), decided_by = v_tg
     where word_id = p_word and status = 'approved';
    return jsonb_build_object('ok', true, 'cefr', v_o.base_cefr);
  end if;
  return jsonb_build_object('error', 'bad_decision');
end
$$;

-- Для бота: новые пометки, о которых администраторы ещё не знают (сразу отмечаются как отправленные)
create or replace function public.take_flag_notifications()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v jsonb;
begin
  with n as (
    update public.word_level_proposals set notified_at = now()
     where notified_at is null and created_at > now() - interval '7 days'
    returning *)
  select coalesce(jsonb_agg(jsonb_build_object(
           'uz', w.uz, 'ru', w.ru, 'from', n.from_cefr, 'to', n.to_cefr, 'kind', n.kind, 'status', n.status,
           'name', pr.first_name, 'username', pr.username) order by n.created_at), '[]'::jsonb)
    into v
    from n join public.words w on w.id = n.word_id join public.profiles pr on pr.id = n.user_id;
  return v;
end
$$;

-- ---------------------------------------------------------------- путь: тема на каждом своём уровне
create or replace function public.path_groups()
returns table (topic_id int, cefr text, node_cefr text) language sql stable security definer set search_path = '' as $$
  with cnt as (
    select w.topic_id, w.cefr, count(*) as n from public.words w
     where w.is_active and w.canonical_id is null group by 1, 2),
  big as (select * from cnt where n >= public.cfg_int('path_min_group', 6))
  select c.topic_id, c.cefr,
         case when c.n >= public.cfg_int('path_min_group', 6) then c.cefr
              else coalesce(
                (select min(b.cefr) from big b where b.topic_id = c.topic_id and b.cefr > c.cefr),
                (select max(b.cefr) from big b where b.topic_id = c.topic_id and b.cefr < c.cefr),
                (select c2.cefr from cnt c2 where c2.topic_id = c.topic_id order by c2.n desc, c2.cefr limit 1)) end
  from cnt c
$$;

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
    'can_flag', public.can_flag_words(),
    'topics', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', t.id, 'key', t.id || '-' || c.node_cefr,
               'name', regexp_replace(t.name_ru, '^Разговорная речь\. ', ''),
               'name_uz', t.name_uz, 'name_en', t.name_en, 'cefr', c.node_cefr,
               'colloquial', t.name_ru like 'Разговорная речь.%',
               'total', c.total, 'started', c.started, 'learned', c.learned,
               'locked', c.node_cefr > v_unlocked)
             order by c.node_cefr, t.sort_order), '[]'::jsonb)
      from public.topics t
      join (
        select g.topic_id, g.node_cefr,
               count(*) as total,
               count(wp.word_id) as started,
               count(*) filter (where public.effective_level(wp.level, wp.level_at, v_now) >= 7) as learned
        from public.path_groups() g
        join public.words w on w.topic_id = g.topic_id and w.cefr = g.cefr and w.is_active and w.canonical_id is null
        left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
        group by g.topic_id, g.node_cefr
      ) c on c.topic_id = t.id)
  );
end
$$;

-- ---------------------------------------------------------------- справочник
-- Строка слова для списков: короткие ключи, чтобы список уровня (до ~4000 слов) был лёгким
create or replace function public.dict_rows(p_user uuid, p_cefr text, p_topic int)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'i', w.id, 'u', w.uz, 'r', w.ru, 't', w.topic_id, 'c', w.cefr,
           'l', public.effective_level(wp.level, wp.level_at, public.app_now()),
           'g', case when w.register = 'colloquial' then 1 end,
           'a', case when w.audio_ok then 1 end)
         order by w.sort_key), '[]'::jsonb)
  from public.words w
  left join public.word_progress wp on wp.word_id = w.id and wp.user_id = p_user
  where w.is_active and w.canonical_id is null
    and (p_cefr is null or w.cefr = p_cefr)
    and (p_topic is null or w.topic_id = p_topic)
$$;

create or replace function public.get_dictionary(p_cefr text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_cefr not in ('A1','A2','B1','B2') then return jsonb_build_object('error', 'bad_cefr'); end if;
  return jsonb_build_object(
    'cefr', p_cefr,
    'unlocked', public.unlocked_cefr(v_uid),
    'can_flag', public.can_flag_words(),
    'counts', (select jsonb_object_agg(cefr, n) from (
                 select w.cefr, count(*) n from public.word_progress wp join public.words w on w.id = wp.word_id
                  where wp.user_id = v_uid and w.is_active and w.canonical_id is null group by 1) x),
    'topics', (select jsonb_object_agg(t.id, regexp_replace(t.name_ru, '^Разговорная речь\. ', '💬 '))
                 from public.topics t where exists (select 1 from public.words w where w.topic_id = t.id and w.cefr = p_cefr)),
    'words', public.dict_rows(v_uid, p_cefr, null));
end
$$;

create or replace function public.get_topic_words(p_topic int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  return jsonb_build_object('topic_id', p_topic, 'unlocked', public.unlocked_cefr(v_uid),
                            'can_flag', public.can_flag_words(), 'words', public.dict_rows(v_uid, null, p_topic));
end
$$;

-- Карточка слова в справочнике: примеры, литературный вариант, пометка, моя пометка уровня
create or replace function public.get_word(p_word int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  return (select public.word_card(w.id, v_uid, public.app_now())
                 || jsonb_build_object('register', w.register, 'literary', w.literary, 'note', w.note, 'en', w.en,
                                       'topic', regexp_replace(t.name_ru, '^Разговорная речь\. ', ''),
                                       'can_flag', public.can_flag_words() and w.cefr in ('A1','A2'),
                                       'my_flag', (select p.kind from public.word_level_proposals p
                                                    where p.word_id = w.id and p.user_id = v_uid and p.status = 'pending' limit 1),
                                       'due_on', (select due_on from public.word_progress where user_id = v_uid and word_id = w.id))
          from public.words w join public.topics t on t.id = w.topic_id where w.id = p_word and w.is_active);
end
$$;

-- ---------------------------------------------------------------- день повторения
create or replace function public.review_day_state(p_user uuid, p_today date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_day  int := public.cfg_int('review_day', 5);
  v_need int;
  v_done int;
  v_due  int;
begin
  if v_day = 0 then return jsonb_build_object('active', false, 'tomorrow', false); end if;
  if extract(isodow from p_today)::int <> v_day then
    return jsonb_build_object('active', false, 'tomorrow', extract(isodow from p_today + 1)::int = v_day);
  end if;
  v_need := least(public.cfg_int('review_day_max', 80),
                  public.cfg_int('review_day_base', 15)
                  + (select count(*) from public.word_progress where user_id = p_user)::int
                    / greatest(1, public.cfg_int('review_day_per', 20)));
  select coalesce(reviews, 0) into v_done from public.daily_stats where user_id = p_user and day = p_today;
  v_done := coalesce(v_done, 0);
  select count(*) into v_due from public.word_progress where user_id = p_user and due_on <= p_today;
  return jsonb_build_object('active', true, 'tomorrow', false, 'need', v_need, 'done', v_done, 'due', v_due,
                            'locked', v_done < v_need and v_due > 0);
end
$$;

-- ---------------------------------------------------------------- сеанс: порядок новых слов и день повторения
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
    select coalesce(array_agg(id order by cefr, sort_key), '{}') into v_new
    from (
      select w.id, w.cefr, w.sort_key from public.words w
      where w.is_active and w.canonical_id is null
        and w.cefr <= v_unlocked
        and (p_topic_id is null or w.topic_id = p_topic_id)
        and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id)
      order by w.cefr, w.sort_key
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
  v_rd jsonb;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  v_tier := public.current_tier();
  v_unlocked := public.unlocked_cefr(v_uid);
  v_rd := public.review_day_state(v_uid, v_today);
  select size, new_max into v_size, v_new_max from public.session_params(v_uid, v_tier);
  select count(*) into v_due from public.word_progress wp join public.words w on w.id = wp.word_id and w.is_active
   where wp.user_id = v_uid and wp.due_on <= v_today;
  select count(*) filter (where w.cefr <= v_unlocked), count(*) into v_left, v_left_all
    from public.words w
   where w.is_active and w.canonical_id is null
     and not exists (select 1 from public.word_progress wp where wp.user_id = v_uid and wp.word_id = w.id);
  select r, n into v_r, v_n from public.session_plan(v_due, v_size, v_new_max, v_left,
                                                     case when (v_rd->>'locked')::boolean then 'review' else 'normal' end);
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
    'review_day', v_rd,
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

-- Экспресс-проверка темы: только слова открытых уровней
create or replace function public.start_topic_check(p_topic int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_now  timestamptz := public.app_now();
  v_unl  text;
  v_att  public.word_check_attempts%rowtype;
  v_q    jsonb := '[]'::jsonb;
  r      record;
  v_i    int := 0;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('topic_check') then return jsonb_build_object('error', 'locked_tier'); end if;
  if not exists (select 1 from public.topics where id = p_topic) then return jsonb_build_object('error', 'not_found'); end if;
  v_unl := public.unlocked_cefr(v_uid);
  if not exists (select 1 from public.words where topic_id = p_topic and is_active and cefr <= v_unl) then
    return jsonb_build_object('error', 'level_locked');
  end if;
  select * into v_att from public.word_check_attempts
   where user_id = v_uid and mode = 'topic' and topic_id = p_topic and finished_at is null and started_at > v_now - interval '6 hours'
   order by started_at desc limit 1;
  if found then return public.word_check_payload(v_att.id); end if;

  for r in
    select w.* from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
    where w.topic_id = p_topic and w.is_active and w.canonical_id is null and w.cefr <= v_unl
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

-- ---------------------------------------------------------------- права
revoke execute on function public.apply_word_level(int, text, bigint) from public, anon, authenticated;
revoke execute on function public.take_flag_notifications() from public, anon, authenticated;
revoke execute on function public.path_groups() from public, anon, authenticated;
revoke execute on function public.dict_rows(uuid, text, int) from public, anon, authenticated;
revoke execute on function public.review_day_state(uuid, date) from public, anon, authenticated;
grant execute on function public.take_flag_notifications() to service_role;
revoke execute on function public.can_flag_words() from public, anon;
revoke execute on function public.propose_word_level(int, text) from public, anon;
revoke execute on function public.admin_word_proposals() from public, anon;
revoke execute on function public.admin_decide_word(int, text, text) from public, anon;
revoke execute on function public.get_dictionary(text) from public, anon;
revoke execute on function public.get_topic_words(int) from public, anon;
revoke execute on function public.get_word(int) from public, anon;
grant execute on function public.can_flag_words() to authenticated;
grant execute on function public.propose_word_level(int, text) to authenticated;
grant execute on function public.admin_word_proposals() to authenticated;
grant execute on function public.admin_decide_word(int, text, text) to authenticated;
grant execute on function public.get_dictionary(text) to authenticated;
grant execute on function public.get_topic_words(int) to authenticated;
grant execute on function public.get_word(int) to authenticated;

-- ---------------------------------------------------------------- цены (решение владельца: «Базовая» на месяц = 100 000 сум)
-- Курс ЦБ ≈ 11 860 сум/$ (август 2026) → 100 000 сум ≈ $8,4. Звёзды: при покупке в Telegram ≈ $0,019 за звезду → ~450 ⭐.
-- Скидки: 3 мес. −10%, 6 мес. −15%, 12 мес. −20%. «Продвинутая» — вдвое дороже «Базовой» (как и раньше).
update public.plans p set price_stars = v.stars, price_uzs = v.uzs, price_usd = v.usd
from (values
  ('basic', 1,  450,   100000,  8.49), ('basic', 3, 1200,  270000, 22.99),
  ('basic', 6, 2300,   510000, 42.99), ('basic', 12, 4300, 960000, 80.99),
  ('advanced', 1,  900,  200000, 16.99), ('advanced', 3, 2400,  540000, 45.99),
  ('advanced', 6, 4600, 1020000, 85.99), ('advanced', 12, 8600, 1920000, 161.99)
) as v(tier, months, stars, uzs, usd)
where p.tier = v.tier and p.months = v.months;

-- ---------------------------------------------------------------- карточка слова: разговорная пометка
create or replace function public.word_card(p_word_id integer, p_user uuid, p_now timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', w.id, 'uz', w.uz, 'ru', w.ru, 'topic_id', w.topic_id, 'cefr', w.cefr,
    'word_class', w.word_class, 'audio_ok', w.audio_ok,
    'register', w.register, 'literary', w.literary, 'note', w.note,
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
$function$;
