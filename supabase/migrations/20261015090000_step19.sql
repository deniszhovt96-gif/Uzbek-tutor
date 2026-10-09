-- =============================================================================
-- Шаг 19
--   • «Сначала разговорная речь» (настройка colloquial_first): новые слова уровня — сначала разговорные;
--     в спряжении разговорные варианты показываются первыми.
--   • Состояние открытых времён для экранов спряжения (get_morph_state).
--   • Темы курсов на карте «Путь» (get_path_courses) — рядом с темами слов своего уровня.
-- =============================================================================

create or replace function public.get_morph_state()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then jsonb_build_object('error', 'not_authenticated')
              else public.morph_state(auth.uid()) end
$$;

-- Темы курсов для карты: по уровню, внутри — порядок курса; «Путь» раскладывает их между темами слов
create or replace function public.get_path_courses()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'course', u.course_id, 'cefr', u.cefr, 'n', u.source_no,
           'title_ru', u.title_ru, 'title_uz', u.title_uz, 'title_en', u.title_en,
           'read', cp.read_at is not null, 'locked', not public.unit_allowed(u))
         order by u.cefr, array_position(array['grammar','culture','civics','history'], u.course_id), u.sort_order), '[]'::jsonb)
    from public.course_units u
    left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = auth.uid()
   where u.course_id in ('grammar','culture','civics','history') and auth.uid() is not null
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
    if p_settings ? 'colloquial_first' then
      v_clean := v_clean || jsonb_build_object('colloquial_first', (p_settings->>'colloquial_first')::boolean);
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

revoke execute on function public.get_morph_state() from public, anon;
revoke execute on function public.get_path_courses() from public, anon;
grant execute on function public.get_morph_state() to authenticated;
grant execute on function public.get_path_courses() to authenticated;

-- ---------------------------------------------------------------- «Поделиться»: картинка + реферальная ссылка
-- Картинка выбирается администратором: app_config share_image = имя набора (файлы app/public/share/<имя>-<язык>.jpg).
insert into public.app_config (key, value, note) values
  ('share_image', '"promo"', 'Картинка для «Поделиться»: app/public/share/<значение>-ru.jpg / -en.jpg')
on conflict (key) do nothing;

create or replace function public.ref_share_data(p_user uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  return (select jsonb_build_object('code', public.ensure_ref_code(p.id), 'tg_id', p.tg_id, 'lang', p.ui_lang,
            'image', coalesce((select value #>> '{}' from public.app_config where key = 'share_image'), 'promo'))
          from public.profiles p where p.id = p_user);
end
$$;
revoke execute on function public.ref_share_data(uuid) from public, anon, authenticated;
grant execute on function public.ref_share_data(uuid) to service_role;

create or replace function public.get_share_image()
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select value #>> '{}' from public.app_config where key = 'share_image'), 'promo')
$$;
revoke execute on function public.get_share_image() from public, anon;
grant execute on function public.get_share_image() to authenticated;
