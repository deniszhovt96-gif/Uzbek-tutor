-- =============================================================================
-- Шаг 21 (дополнение 2): сложность слова = позиция в уровне + длина + как часто в нём ошибаются все пользователи
--   word_difficulty (кэш, пересчёт не чаще раза в сутки при старте теста). Тест уровня и контрольная
--   чаще берут слова посложнее; свои ошибки пользователя по-прежнему в приоритете.
-- =============================================================================
create table if not exists public.word_difficulty (
  word_id    int primary key references public.words(id) on delete cascade,
  err_rate   numeric not null,      -- доля ошибок по всем пользователям (сглаженная)
  answers    int not null,          -- сколько ответов учтено
  hard       numeric not null,      -- 0…1 внутри уровня: 0 — самые лёгкие, 1 — самые трудные
  updated_at timestamptz not null default now()
);
alter table public.word_difficulty enable row level security;
revoke all on public.word_difficulty from anon, authenticated;

create or replace function public.refresh_word_difficulty()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare v_n int;
begin
  with st as (
    select wp.word_id, sum(wp.wrong_count) as wr, sum(wp.correct_count) as ok
    from public.word_progress wp group by wp.word_id),
  base as (
    select w.id, w.cefr,
           -- сглаживание: 3 «виртуальных» ответа с долей ошибок 1/3, пока данных мало
           (coalesce(st.wr, 0) + 1)::numeric / (coalesce(st.wr, 0) + coalesce(st.ok, 0) + 3) as err,
           coalesce(st.wr, 0) + coalesce(st.ok, 0) as n,
           length(replace(w.uz_key, ' ', '')) as len, w.sort_key
    from public.words w left join st on st.word_id = w.id
    where w.is_active and w.canonical_id is null),
  ranked as (
    select id, err, n,
           0.4 * percent_rank() over (partition by cefr order by sort_key)
         + 0.25 * percent_rank() over (partition by cefr order by len)
         + 0.35 * percent_rank() over (partition by cefr order by err) as hard
    from base)
  insert into public.word_difficulty (word_id, err_rate, answers, hard, updated_at)
  select id, round(err, 4), n, round(hard::numeric, 4), now() from ranked
  on conflict (word_id) do update set err_rate = excluded.err_rate, answers = excluded.answers,
                                      hard = excluded.hard, updated_at = excluded.updated_at;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;
select public.refresh_word_difficulty();
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

  -- сложность слов пересчитывается не чаще раза в сутки
  if coalesce((select max(updated_at) from public.word_difficulty), '-infinity') < now() - interval '1 day' then
    perform public.refresh_word_difficulty();
  end if;

  v_n_sent := round(v_n * 0.3);
  v_n_word := v_n - v_n_sent;

  -- 1) вопросы по словам: сначала начатые слова (чаще — с ошибками), затем остальные слова уровня
  for r in
    select x.* from (
      select w.*, row_number() over (partition by (t.name_ru ~ '^(Числа|Дни недели|Месяцы|Часы\. Время суток)') order by random()) as basic_rn,
             (t.name_ru ~ '^(Числа|Дни недели|Месяцы|Часы\. Время суток)') as basic,
             wp.word_id as wp_word, wp.wrong_count as wp_wrong,
             coalesce(d.hard, 0.5) as hard
      from public.words w
      join public.topics t on t.id = w.topic_id
      left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
      left join public.word_difficulty d on d.word_id = w.id
      where w.cefr = p_cefr and w.is_active and w.canonical_id is null and w.test_ok and length(w.uz_key) >= 3
    ) x
    where not x.basic or x.basic_rn <= 3
    -- сначала начатые слова (чаще — с ошибками), затем остальные; трудные (позже в уровне, длиннее, с частыми ошибками у всех) — чаще
    order by (x.wp_word is null), -ln(1 - random()) / ((1 + coalesce(x.wp_wrong, 0)) * (0.3 + 1.4 * x.hard))
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
    order by -ln(1 - random()) / (0.3 + 1.4 * coalesce((select d.hard from public.word_difficulty d where d.word_id = w.id), 0.5))
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
    where wp.user_id = v_uid and wp.level >= 2 and w.test_ok and w.is_active
    -- чаще слова, в которых ошибался сам пользователь и которые трудны для всех
    order by -ln(1 - random()) / ((1 + wp.wrong_count) * (0.3 + 1.4 * coalesce((select d.hard from public.word_difficulty d where d.word_id = w.id), 0.5))) limit v_n
  loop
    v_type := v_pattern[1 + (v_i % 4)];
    v_i := v_i + 1;
    if v_type like '%choice' then
      v_d := public.pick_distractors(r.id, 3, case when v_type = 'uz_ru_choice' then 'ru' else 'uz' end);
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
revoke execute on function public.refresh_word_difficulty() from public, anon, authenticated;
