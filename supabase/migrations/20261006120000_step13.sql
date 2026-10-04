-- =============================================================================
-- Шаг 13
--   • Расширенная статистика («Продвинутая»): точность по видам заданий, трудные слова, прогноз повторений,
--     недели, время занятий.
--   • Напоминания от бота: ежедневное (в выбранный час, если сегодня не занимались), в четверг — о дне повторения,
--     за 3 дня до конца подписки. Запускает GitHub Actions раз в час (workflow «Напоминания»): одноразовый
--     пропуск в cron_tokens → бот → reminders_take().
--   • Настройки: напоминания вкл/выкл и час; отметка «приветствие пройдено».
-- =============================================================================

alter table public.profiles add column if not exists bot_blocked boolean not null default false;

-- ---------------------------------------------------------------- расширенная статистика
create or replace function public.get_stats_ext()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_now   timestamptz := public.app_now();
  v_today date;
  v_tz    text;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('stats_ext') then
    return jsonb_build_object('error', 'locked_tier', 'need', (select min_tier from public.feature_access where feature = 'stats_ext'));
  end if;
  v_today := public.user_today(v_uid);
  select coalesce(timezone, 'Asia/Tashkent') into v_tz from public.profiles where id = v_uid;
  return jsonb_build_object(
    -- точность по видам заданий за 30 дней (только первые попытки)
    'by_type', (
      select coalesce(jsonb_agg(jsonb_build_object('type', ex_type, 'total', n, 'correct', c) order by n desc), '[]'::jsonb)
      from (select ex_type, count(*) n, count(*) filter (where is_correct) c
              from public.answer_log
             where user_id = v_uid and at > v_now - interval '30 days' and counted
             group by ex_type) x),
    -- слова, в которых чаще всего ошибаетесь
    'hard', (
      select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'uz', w.uz, 'ru', w.ru, 'wrong', wp.wrong_count,
                                                   'correct', wp.correct_count,
                                                   'level', public.effective_level(wp.level, wp.level_at, v_now))
                                order by wp.wrong_count desc, wp.correct_count), '[]'::jsonb)
      from (select * from public.word_progress
             where user_id = v_uid and wrong_count > 0
             order by wrong_count desc, correct_count limit 15) wp
      join public.words w on w.id = wp.word_id and w.is_active),
    -- прогноз повторений на 7 дней (сегодня — вместе с просроченными)
    'forecast', (
      select jsonb_agg(jsonb_build_object('day', d, 'due',
               (select count(*) from public.word_progress wp join public.words w on w.id = wp.word_id and w.is_active
                 where wp.user_id = v_uid
                   and case when d = v_today then wp.due_on <= d else wp.due_on = d end)) order by d)
      from (select (v_today + i)::date d from generate_series(0, 6) i) g),
    -- 12 недель: ответы, новые слова, минуты
    'weeks', (
      select coalesce(jsonb_agg(jsonb_build_object('week', wk, 'answers', a, 'new_words', nw, 'minutes', round(s / 60.0))
                                order by wk), '[]'::jsonb)
      from (select date_trunc('week', day)::date wk, sum(correct + wrong) a, sum(new_words) nw, sum(seconds) s
              from public.daily_stats
             where user_id = v_uid and day > v_today - 84
             group by 1) x),
    -- в какое время дня вы занимаетесь (по ответам за 30 дней)
    'hours', (
      select coalesce(jsonb_object_agg(h, n), '{}'::jsonb)
      from (select extract(hour from at at time zone v_tz)::int h, count(*) n
              from public.answer_log where user_id = v_uid and at > v_now - interval '30 days'
             group by 1) x),
    'totals', (
      select jsonb_build_object(
        'days_active', count(*) filter (where correct + wrong > 0),
        'minutes', round(coalesce(sum(seconds), 0) / 60.0),
        'answers', coalesce(sum(correct + wrong), 0),
        'best_streak', (
          select coalesce(max(len), 0) from (
            select count(*) len from (
              select day, day - (row_number() over (order by day))::int as grp
                from public.daily_stats where user_id = v_uid and correct + wrong > 0) s
            group by grp) z))
      from public.daily_stats where user_id = v_uid)
  );
end
$$;

-- ---------------------------------------------------------------- настройки: напоминания и приветствие
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

-- ---------------------------------------------------------------- напоминания
create table if not exists public.cron_tokens (
  token      text primary key,
  created_at timestamptz not null default now()
);
alter table public.cron_tokens enable row level security;
revoke all on public.cron_tokens from anon, authenticated;

create table if not exists public.reminder_log (
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind    text not null,           -- daily | sub_end
  day     date not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, kind, day)
);
alter table public.reminder_log enable row level security;
revoke all on public.reminder_log from anon, authenticated;

-- Кому отправить напоминание прямо сейчас. Вызывает бот по одноразовому пропуску из workflow «Напоминания».
-- Каждое напоминание отмечается в reminder_log — повторный вызов в тот же день его не повторит.
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
begin
  delete from public.cron_tokens where created_at < now() - interval '15 minutes';
  delete from public.cron_tokens where token = p_token;
  if not found then return jsonb_build_object('error', 'bad_token'); end if;

  for r in
    select p.id, p.tg_id, p.ui_lang, p.first_name, coalesce(p.timezone, 'Asia/Tashkent') tz,
           coalesce((p.settings->>'remind')::boolean, true) remind,
           coalesce((p.settings->>'remind_hour')::int, 19) remind_hour, p.created_at
      from public.profiles p
     where p.tg_id is not null and not p.bot_blocked
  loop
    v_local := now() at time zone r.tz;
    v_today := v_local::date;
    v_hour := extract(hour from v_local)::int;
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

-- Пользователь заблокировал бота — больше не пишем (снимается, когда он снова нажмёт /start)
create or replace function public.set_bot_blocked(p_tg_id bigint, p_blocked boolean)
returns void language sql volatile security definer set search_path = '' as $$
  update public.profiles set bot_blocked = p_blocked where tg_id = p_tg_id
$$;

revoke execute on function public.reminders_take(text) from public, anon, authenticated;
revoke execute on function public.set_bot_blocked(bigint, boolean) from public, anon, authenticated;
grant execute on function public.reminders_take(text) to service_role;
grant execute on function public.set_bot_blocked(bigint, boolean) to service_role;
revoke execute on function public.get_stats_ext() from public, anon;
grant execute on function public.get_stats_ext() to authenticated;

-- ---------------------------------------------------------------- справочник: названия тем на трёх языках
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
    'topics', (select jsonb_object_agg(t.id, jsonb_build_array(
                   regexp_replace(t.name_ru, '^Разговорная речь\. ', '💬 '),
                   regexp_replace(coalesce(t.name_uz, t.name_ru), '^Soʻzlashuv nutqi\. ', '💬 '),
                   regexp_replace(coalesce(t.name_en, t.name_ru), '^Spoken: ', '💬 ')))
                 from public.topics t where exists (select 1 from public.words w where w.topic_id = t.id and w.cefr = p_cefr)),
    'words', public.dict_rows(v_uid, p_cefr, null));
end
$$;

create or replace function public.get_word(p_word int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
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
