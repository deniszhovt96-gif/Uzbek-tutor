-- Шаг 6: функции для экранов «Мой прогресс», «Темы», «Настройки».

-- Статистика: распределение по уровням и активность за последние N дней
create or replace function public.get_stats(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_today date;
  v_days int := least(greatest(coalesce(p_days, 30), 7), 365);
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  return jsonb_build_object(
    'levels', (
      select coalesce(jsonb_object_agg(lvl, n), '{}'::jsonb) from (
        select public.effective_level(level, level_at, v_now) as lvl, count(*) as n
        from public.word_progress where user_id = v_uid group by 1) t),
    'totals', (
      select jsonb_build_object(
        'started', count(*),
        'learning', count(*) filter (where public.effective_level(level, level_at, v_now) between 0 and 6),
        'basic', count(*) filter (where public.effective_level(level, level_at, v_now) between 7 and 11),
        'strong', count(*) filter (where public.effective_level(level, level_at, v_now) >= 12),
        'due_today', count(*) filter (where due_on <= v_today),
        'correct', coalesce(sum(correct_count), 0),
        'wrong', coalesce(sum(wrong_count), 0))
      from public.word_progress where user_id = v_uid),
    'days', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', gd.day, 'new_words', coalesce(d.new_words, 0), 'reviews', coalesce(d.reviews, 0),
               'correct', coalesce(d.correct, 0), 'wrong', coalesce(d.wrong, 0), 'seconds', coalesce(d.seconds, 0))
             order by gd.day), '[]'::jsonb)
      from (select (v_today - i)::date as day from generate_series(0, v_days - 1) as i) gd
      left join public.daily_stats d on d.user_id = v_uid and d.day = gd.day),
    'today', v_today
  );
end
$$;

-- Темы с прогрессом пользователя (для ручного выбора темы)
create or replace function public.get_topics()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'name', t.name_ru, 'name_uz', t.name_uz, 'name_en', t.name_en, 'cefr', t.cefr,
           'total', c.total, 'started', c.started)
         order by t.sort_order), '[]'::jsonb)
  from public.topics t
  cross join lateral (
    select count(*) as total,
           count(wp.word_id) as started
    from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = auth.uid()
    where w.topic_id = t.id and w.is_active and w.canonical_id is null
  ) c
  where c.total > 0
$$;

-- Настройки: язык интерфейса и параметры обучения (с проверкой значений)
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
  end if;
  update public.profiles
     set ui_lang = coalesce(p_ui_lang, ui_lang),
         settings = settings || v_clean
   where id = v_uid;
  return public.get_me();
end
$$;

revoke execute on function public.get_stats(int) from public, anon;
revoke execute on function public.get_topics() from public, anon;
revoke execute on function public.update_settings(text, jsonb) from public, anon;
grant execute on function public.get_stats(int) to authenticated;
grant execute on function public.get_topics() to authenticated;
grant execute on function public.update_settings(text, jsonb) to authenticated;
