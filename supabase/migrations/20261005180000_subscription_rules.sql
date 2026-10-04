-- =============================================================================
-- Шаг 11: правила подписок и сеансов (решения владельца, 04.10.2026).
--
--   • Две подписки сразу: сначала действует старшая («Продвинутая»), затем младшая — на свой оставшийся срок.
--     Все выдачи (звёзды, коды, администратор) идут через grant_subscription.
--   • Администратор выдаёт подписку командой бота /grant (admin_grant).
--   • «Базовая» — только лёгкая интенсивность (30 слов, до 20 новых), до 2 сеансов с новыми словами в день;
--     средняя и интенсивная — только «Продвинутая»; сеансы «Продвинутой» без ограничений.
--     Лимиты — app_config: sessions_per_day_free / _basic / _advanced (0 = без ограничений).
--   • В сеансе не меньше половины new_max новых слов (10 из 20, 13 из 25, 15 из 30), остальное — повторения.
--   • На повторении первыми идут слова с ошибкой, раньше слов уровнем выше.
-- =============================================================================

insert into public.app_config (key, value, note) values
  ('sessions_per_day_free', '1', 'Бесплатно: сеансов в день'),
  ('sessions_per_day_basic', '2', '«Базовая»: сеансов с новыми словами в день (повторение — без ограничений)'),
  ('sessions_per_day_advanced', '0', '«Продвинутая»: сеансов в день (0 — без ограничений)')
on conflict (key) do nothing;

create or replace function public.sessions_limit(p_tier text)
returns int language sql stable security definer set search_path = '' as $$
  select public.cfg_int('sessions_per_day_' || coalesce(p_tier, 'free'), case p_tier when 'free' then 1 when 'basic' then 2 else 0 end)
$$;

-- Выдача подписки: продление с конца текущей того же уровня; «Продвинутая» отодвигает «Базовую» на свой срок,
-- «Базовая», купленная во время «Продвинутой», начинается после неё.
create or replace function public.grant_subscription(p_user uuid, p_tier text, p_months int, p_source text, p_ref text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_start timestamptz;
  v_end   timestamptz;
  v_d     interval;
  v_id    bigint;
begin
  perform pg_advisory_xact_lock(hashtext('subs:' || p_user::text));
  select greatest(now(), coalesce(max(ends_at), now())) into v_start
    from public.subscriptions
   where user_id = p_user and ends_at > now()
     and (tier = p_tier or (p_tier = 'basic' and tier = 'advanced'));
  v_end := v_start + make_interval(months => p_months);
  v_d := v_end - v_start;
  if p_tier = 'advanced' then
    -- будущие «Базовые» сдвигаются целиком, текущая — продлевается на срок «Продвинутой»
    update public.subscriptions set starts_at = starts_at + v_d, ends_at = ends_at + v_d
     where user_id = p_user and tier = 'basic' and starts_at >= v_start;
    update public.subscriptions set ends_at = ends_at + v_d
     where user_id = p_user and tier = 'basic' and starts_at < v_start and ends_at > v_start;
  end if;
  insert into public.subscriptions (user_id, tier, starts_at, ends_at, source, source_ref)
  values (p_user, p_tier, v_start, v_end, p_source, p_ref)
  returning id into v_id;
  return jsonb_build_object('sub_id', v_id, 'starts_at', v_start, 'ends_at', v_end);
end
$$;

-- Подписка от администратора (команда бота /grant)
create or replace function public.admin_grant(p_tg_id bigint, p_tier text, p_months int, p_admin bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user public.profiles%rowtype;
  v_g    jsonb;
begin
  if not exists (select 1 from public.admins where tg_id = p_admin) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if p_tier not in ('basic','advanced') or p_months not in (1, 3, 6, 12) then return jsonb_build_object('ok', false, 'error', 'bad_args'); end if;
  select * into v_user from public.profiles where tg_id = p_tg_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_user'); end if;
  v_g := public.grant_subscription(v_user.id, p_tier, p_months, 'manual', 'admin:' || p_admin);
  return v_g || jsonb_build_object('ok', true, 'name', v_user.first_name, 'username', v_user.username, 'tier', p_tier,
    'tier_ends_at', (select max(ends_at) from public.subscriptions where user_id = v_user.id and tier = p_tier));
end
$$;

create or replace function public.session_params(p_user uuid, p_tier text)
returns table (size int, new_max int) language sql stable security definer set search_path = '' as $$
  select
    case when p_tier = 'free' then 15
         when p_tier = 'basic' then 30            -- «Базовая»: только лёгкая интенсивность
         else least(60, greatest(10, coalesce((p.settings->>'session_size')::int, 30))) end,
    case when p_tier = 'free' then 10
         when p_tier = 'basic' then 20
         else least(30, greatest(0, coalesce((p.settings->>'new_max')::int, 20))) end
  from public.profiles p where p.id = p_user
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
  v_r        int;
  v_n        int;
  v_review   int[];
  v_new      int[];
  v_unlocked text;
  v_limit    int;
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
    -- лимит сеансов в день (0 — без ограничений); бесплатно считаются все сеансы, в подписке — только с новыми словами
    v_limit := public.sessions_limit(v_tier);
    if v_limit > 0 and (v_tier = 'free' or p_mode = 'normal') and (
         select count(*) from public.study_sessions
          where user_id = v_uid and local_day = v_today and (v_tier = 'free' or mode = 'normal')) >= v_limit then
      return jsonb_build_object('error', 'daily_limit', 'tier', v_tier, 'limit', v_limit);
    end if;

    select size, new_max into v_size, v_new_max from public.session_params(v_uid, v_tier);

    select count(*) into v_due from public.word_progress
     where user_id = v_uid and due_on <= v_today;

    if p_mode = 'review' then
      v_r := least(v_due, v_size);
      v_n := 0;
    else
      -- не меньше половины new_max новых слов (если они есть), остальное — повторения
      v_r := least(v_due, v_size - ceil(v_new_max / 2.0)::int, 10 + ceil(greatest(0, v_due - 10) / 2.0)::int);
      v_n := least(v_new_max, v_size - v_r);
    end if;

    select coalesce(array_agg(word_id order by grp, lvl_order, ratio desc, eff), '{}') into v_review
    from (
      select wp.word_id,
             public.effective_level(wp.level, wp.level_at, v_now) as eff,
             case when wp.fail_streak > 0 then 0       -- слово с ошибкой — первым, раньше слов уровнем выше
                  when wp.level >= 2 and v_now - wp.level_at >= interval '75 days' then 1
                  when public.effective_level(wp.level, wp.level_at, v_now) <= 6 then 2
                  else 3 end as grp,
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
  v_limit int;
  v_done int;
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
  v_r := least(v_due, v_size - ceil(v_new_max / 2.0)::int, 10 + ceil(greatest(0, v_due - 10) / 2.0)::int);
  v_n := least(v_new_max, v_size - v_r, v_left);
  v_limit := public.sessions_limit(v_tier);
  select count(*) into v_done from public.study_sessions
   where user_id = v_uid and local_day = v_today and (v_tier = 'free' or mode = 'normal');
  v_free_used := v_limit > 0 and v_done >= v_limit;
  v_passed_unlocked := exists (select 1 from public.level_test_attempts
                                where user_id = v_uid and cefr = v_unlocked and passed);
  return jsonb_build_object(
    'tier', v_tier,
    'today', v_today,
    'plan_new', v_n,
    'plan_review', v_r,
    'due_total', v_due,
    'daily_limit_reached', v_free_used,
    'sessions_limit', v_limit,
    'sessions_done', v_done,
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
  end if;
  update public.profiles
     set ui_lang = coalesce(p_ui_lang, ui_lang),
         settings = settings || v_clean
   where id = v_uid;
  return public.get_me();
end
$$;

create or replace function public.redeem_code(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid       uuid := auth.uid();
  v_code      public.access_codes%rowtype;
  v_start     timestamptz;
  v_end       timestamptz;
  v_sub_id    bigint;
  v_attempts  int;
  v_grant     jsonb;
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

  v_grant := public.grant_subscription(v_uid, v_code.tier, v_code.months, 'code', v_code.id::text);
  v_sub_id := (v_grant->>'sub_id')::bigint;
  v_start := (v_grant->>'starts_at')::timestamptz;
  v_end := (v_grant->>'ends_at')::timestamptz;

  insert into public.code_redemptions (code_id, user_id, subscription_id)
  values (v_code.id, v_uid, v_sub_id);

  update public.access_codes set used_count = used_count + 1 where id = v_code.id;
  insert into public.code_attempts (user_id, success) values (v_uid, true);

  return jsonb_build_object('ok', true, 'tier', v_code.tier, 'starts_at', v_start, 'ends_at', v_end);
end
$$;

create or replace function public.stars_grant_payment(p_payload text, p_tg_id bigint, p_amount int, p_charge_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_check jsonb;
  v_plan  public.plans%rowtype;
  v_user  uuid;
  v_start timestamptz;
  v_end   timestamptz;
  v_sub   bigint;
  v_pay   public.payments%rowtype;
  v_parts text[] := string_to_array(coalesce(p_payload, ''), ':');
begin
  if p_charge_id is null or p_charge_id = '' then return jsonb_build_object('ok', false, 'error', 'no_charge_id'); end if;
  select * into v_pay from public.payments where charge_id = p_charge_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'tier', v_pay.tier,
      'ends_at', (select ends_at from public.subscriptions where id = v_pay.subscription_id));
  end if;

  -- деньги уже списаны: цену не сверяем строго (могла измениться между счётом и оплатой), записываем фактическую сумму
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

  return jsonb_build_object('ok', true, 'tier', v_plan.tier, 'months', v_plan.months, 'starts_at', v_start, 'ends_at', v_end);
end
$$;

create or replace function public.stars_refund_payment(p_charge_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_pay  public.payments%rowtype;
  v_sub  public.subscriptions%rowtype;
  v_cut  interval;
  v_tg   bigint;
begin
  select * into v_pay from public.payments where charge_id = p_charge_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select tg_id into v_tg from public.profiles where id = v_pay.user_id;
  if v_pay.status = 'refunded' then return jsonb_build_object('ok', true, 'duplicate', true, 'tg_id', v_tg); end if;
  select * into v_sub from public.subscriptions where id = v_pay.subscription_id for update;
  if found then
    -- сколько ещё оставалось оплачено этим платежом
    v_cut := v_sub.ends_at - greatest(now(), v_sub.starts_at);
    if v_sub.starts_at >= now() then
      update public.payments set subscription_id = null where id = v_pay.id;   -- сначала снимаем ссылку, потом удаляем
      delete from public.subscriptions where id = v_sub.id;
    elsif v_sub.ends_at > now() then
      -- подписка заканчивается прямо сейчас (начало сдвигаем на секунду назад, чтобы ends_at > starts_at)
      update public.subscriptions set starts_at = least(starts_at, now() - interval '1 second'), ends_at = now() where id = v_sub.id;
    end if;
    if v_cut > interval '0' then
      update public.subscriptions set starts_at = starts_at - v_cut, ends_at = ends_at - v_cut
       where user_id = v_pay.user_id and tier = v_pay.tier and starts_at >= v_sub.ends_at and id <> v_sub.id;
      -- «Базовая» была отодвинута этой «Продвинутой» — возвращаем неиспользованное время
      if v_pay.tier = 'advanced' then
        update public.subscriptions set starts_at = greatest(now(), starts_at - v_cut), ends_at = greatest(now() + interval '1 second', ends_at - v_cut)
         where user_id = v_pay.user_id and tier = 'basic' and starts_at >= now();
        update public.subscriptions set ends_at = greatest(now(), ends_at - v_cut)
         where user_id = v_pay.user_id and tier = 'basic' and starts_at < now() and ends_at > now();
      end if;
    end if;
  end if;
  update public.payments set status = 'refunded', refunded_at = now() where id = v_pay.id;
  return jsonb_build_object('ok', true, 'tg_id', v_tg, 'stars', v_pay.stars);
end
$$;

revoke execute on function public.sessions_limit(text) from public, anon, authenticated;
revoke execute on function public.grant_subscription(uuid, text, int, text, text) from public, anon, authenticated;
revoke execute on function public.admin_grant(bigint, text, int, bigint) from public, anon, authenticated;
grant execute on function public.admin_grant(bigint, text, int, bigint) to service_role;
