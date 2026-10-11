-- =============================================================================
-- Шаг 21 (дополнение): тест уровня — слова средней и высокой сложности
--   • неверные варианты и предложения-варианты тоже только из «тестовых» слов (без «Алло!», kaloriya…);
--   • числа, дни, месяцы и время суток — не больше 3 вопросов на тест;
--   • слова короче 3 букв не берём; среди слов уровня чаще выбираются более поздние (сложнее) по порядку изучения.
-- =============================================================================
create or replace function public.pick_distractors(p_word_id int, p_n int default 3, p_side text default null)
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
    where c.is_active and c.canonical_id is null and c.id <> w.id and c.test_ok
      and (c.topic_id = w.topic_id or c.cefr = w.cefr)
      and not (c.accept_ru && w.accept_ru)
      and (p_side is null
           or (p_side = 'ru' and public.wc(c.ru) = public.wc(w.ru))
           or (p_side = 'uz' and public.wc(c.uz) = public.wc(w.uz)))
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
    select x.* from (
      select w.*, row_number() over (partition by (t.name_ru ~ '^(Числа|Дни недели|Месяцы|Часы\. Время суток)') order by random()) as basic_rn,
             (t.name_ru ~ '^(Числа|Дни недели|Месяцы|Часы\. Время суток)') as basic,
             wp.word_id as wp_word, wp.wrong_count as wp_wrong,
             percent_rank() over (order by w.sort_key) as hard
      from public.words w
      join public.topics t on t.id = w.topic_id
      left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
      where w.cefr = p_cefr and w.is_active and w.canonical_id is null and w.test_ok and length(w.uz_key) >= 3
    ) x
    where not x.basic or x.basic_rn <= 3
    -- сначала начатые слова (чаще — с ошибками), затем остальные; более поздние по порядку изучения — чаще
    order by (x.wp_word is null), -ln(1 - random()) / ((1 + coalesce(x.wp_wrong, 0)) * (0.5 + x.hard))
    limit v_n_word
  loop
    v_type := v_pattern[1 + (v_i % array_length(v_pattern, 1))];
    v_i := v_i + 1;
    if v_type = 'audio_choice' and not r.audio_ok then v_type := 'uz_ru_choice'; end if;
    v_d := public.pick_distractors(r.id, 3, case when v_type = 'uz_ru_choice' then 'ru' else 'uz' end);
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
    where w.cefr = p_cefr and w.is_active and w.canonical_id is null and w.test_ok and length(w.uz_key) >= 3 and not (w.id = any (v_used))
      and not exists (select 1 from public.topics t2 where t2.id = w.topic_id and t2.name_ru ~ '^(Числа|Дни недели|Месяцы|Часы\. Время суток)')
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
      v_d := public.pick_distractors(r.id, 3, 'uz');
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
          and w2.is_active and w2.test_ok and public.wc(x.ru) = public.wc(e.ru)
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
