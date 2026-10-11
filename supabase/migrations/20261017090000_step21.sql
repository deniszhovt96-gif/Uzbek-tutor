-- =============================================================================
-- Шаг 21: честные тесты, синонимы, марафон, альфа-тестеры
--   • тест уровня и контрольная: без приветствий и «банальных» восклицаний, без слов, созвучных русским
--     (официант, юмор, бар), англицизмов, стран и городов, без разговорной лексики (words.test_ok);
--   • варианты ответа — с тем же числом слов, что и верный ответ;
--   • ответ без личного местоимения (boraman вместо men boraman) засчитывается;
--   • words.syn_note — чем слово отличается от синонимов с тем же переводом;
--   • игра «Марафон»: все слова уровня по порядку;
--   • коды альфа-тестера: вся грамматика считается пройденной;
--   • на пути разговорные темы выше, если включено «Сначала разговорные формы».
-- =============================================================================

alter table public.words add column if not exists syn_note text;
alter table public.words add column if not exists test_ok boolean not null default true;
alter table public.profiles add column if not exists alpha boolean not null default false;
alter table public.access_codes add column if not exists alpha boolean not null default false;

-- ---------------------------------------------------------------- созвучие с русским
create or replace function public.lev(a text, b text)
returns int language plpgsql immutable as $$
declare
  la int := length(a); lb int := length(b);
  prev int[]; cur int[]; i int; j int; c int;
begin
  if la = 0 then return lb; end if;
  if lb = 0 then return la; end if;
  prev := array(select generate_series(0, lb));
  for i in 1..la loop
    cur := array[i];
    for j in 1..lb loop
      c := case when substr(a, i, 1) = substr(b, j, 1) then 0 else 1 end;
      cur := cur || least(prev[j + 1] + 1, cur[j] + 1, prev[j] + c);
    end loop;
    prev := cur;
  end loop;
  return prev[lb + 1];
end
$$;

create or replace function public.ru_translit(p text)
returns text language sql immutable as $$
  select regexp_replace(
    replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(lower(p),
      'щ','sh'),'ш','sh'),'ч','ch'),'ж','j'),'ц','ts'),'ю','yu'),'я','ya'),'ё','yo'),'х','x'),'й','y'),'ъ',''),'ь',''),
    '[^a-zа-я]', '', 'g')
$$;
-- оставшиеся одиночные буквы
create or replace function public.ru_lat(p text)
returns text language sql immutable as $$
  select translate(public.ru_translit(p), 'абвгдезиклмнопрстуфыэ', 'abvgdeziklmnoprstufie')
$$;

-- «созвучно русскому»: основное узбекское слово почти совпадает с русским переводом в латинице
create or replace function public.is_cognate(p_uz_key text, p_ru text[])
returns boolean language plpgsql immutable as $$
declare
  u text; v text; r text; tok text[]; n int; pre int;
begin
  tok := array(select t from unnest(string_to_array(replace(p_uz_key, '''', ''), ' ')) t
               where t not in ('qilmoq','etmoq','bolmoq','olmoq','bermoq','qilish','etish','bolish','va','bilan'));
  if coalesce(array_length(tok, 1), 0) = 0 then return false; end if;
  foreach r in array p_ru loop
    v := public.ru_lat(r);
    continue when length(v) < 3;
    foreach u in array tok || array[array_to_string(tok, '')] loop
      continue when length(u) < 3;
      n := greatest(length(u), length(v));
      if 1 - public.lev(u, v)::numeric / n >= 0.72 then return true; end if;
      pre := 0;
      while pre < least(length(u), length(v)) and substr(u, pre + 1, 1) = substr(v, pre + 1, 1) loop pre := pre + 1; end loop;
      if pre >= 5 and pre >= 0.75 * length(u) then return true; end if;
    end loop;
  end loop;
  return false;
end
$$;
create or replace function public.ru_variants(p_ru text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(public.key_ru(x)) filter (where public.key_ru(x) <> ''), '{}')
  from unnest(regexp_split_to_array(regexp_replace(p_ru, '\([^)]*\)', '', 'g'), '[,;/]')) x
$$;

-- число слов (без пояснений в скобках)
create or replace function public.wc(p text)
returns int language sql immutable as $$
  select coalesce(array_length(regexp_split_to_array(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '\([^)]*\)', '', 'g'), '[-–—]', ' ', 'g')), '\s+'), 1), 0)
$$;

-- ответ на узбекском без личных местоимений: «men boraman» = «boraman»
create or replace function public.uz_strip_pron(p text)
returns text language sql immutable as $$
  select btrim(regexp_replace(' ' || replace(public.key_uz(p), ' ', '  ') || ' ', ' (men|sen|u|biz|siz|ular) ', ' ', 'g'))
$$;
create or replace function public.uz_same(a text, b text)
returns boolean language sql immutable as $$
  select public.key_uz(a) <> '' and (public.key_uz(a) = public.key_uz(b)
         or (public.uz_strip_pron(a) <> '' and regexp_replace(public.uz_strip_pron(a), '\s+', ' ', 'g') = regexp_replace(public.uz_strip_pron(b), '\s+', ' ', 'g')))
$$;

-- ---------------------------------------------------------------- какие слова годятся для тестов
create or replace function public.refresh_test_flags()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare v_n int;
begin
  update public.words w set test_ok = x.ok
  from (
    select w2.id, not (
        w2.register <> 'lit'                                         -- разговорная лексика — только в обучении
        or w2.uz ~ '[!?]\s*$'                                         -- восклицания и готовые фразы: Salom!, Allo!
        or t.name_ru ~ '^(Приветствия|Обращения|Разговорная речь)'   -- приветствия, прощания, «алло»
        or t.name_ru in ('Западная Европа','Центральная и Восточная Европа','Страны СНГ','Азия','Северная Америка',
                         'Центральная и Южная Америка','Африка','Австралия и Океания','Города','Страны. Разное')
        or public.is_cognate(w2.uz_key, public.ru_variants(w2.ru))   -- созвучно русскому: ofitsiant, yumor, bar
      ) as ok
    from public.words w2 join public.topics t on t.id = w2.topic_id
  ) x
  where x.id = w.id and w.test_ok is distinct from x.ok;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;
select public.refresh_test_flags();

-- ---------------------------------------------------------------- неверные варианты: то же число слов
drop function if exists public.pick_distractors(int, int);
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
    where c.is_active and c.canonical_id is null and c.id <> w.id
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

-- ---------------------------------------------------------------- тест уровня
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
    select w.* from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
    where w.cefr = p_cefr and w.is_active and w.canonical_id is null and w.test_ok
    order by (wp.word_id is null), -ln(1 - random()) / (1 + coalesce(wp.wrong_count, 0))
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
    where w.cefr = p_cefr and w.is_active and w.canonical_id is null and w.test_ok and not (w.id = any (v_used))
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
          and w2.is_active and public.wc(x.ru) = public.wc(e.ru)
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

-- ---------------------------------------------------------------- контрольная
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
    order by random() limit v_n
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

-- ---------------------------------------------------------------- карточка слова
create or replace function public.word_card(p_word_id integer, p_user uuid, p_now timestamptz)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', w.id, 'uz', w.uz, 'ru', w.ru, 'topic_id', w.topic_id, 'cefr', w.cefr,
    'word_class', w.word_class, 'audio_ok', w.audio_ok,
    'register', w.register, 'literary', w.literary, 'note', w.note, 'syn_note', w.syn_note,
    'accept_ru', w.accept_ru, 'accept_uz', w.accept_uz,
    'level', coalesce(public.effective_level(wp.level, wp.level_at, p_now), 0),
    'stage', case when wp.word_id is null or wp.level = 0 then 'new'
                  when public.effective_level(wp.level, wp.level_at, p_now) <= 6 then 'learning'
                  else 'review' end,
    'examples', coalesce((
      select jsonb_agg(jsonb_build_object(
               'word_id', e.word_id, 'n', e.n, 'uz', e.uz, 'ru', e.ru,
               'blank_start', e.blank_start, 'blank_len', e.blank_len, 'audio_ok', e.audio_ok,
               'nw', e.n_words, 'ready', public.example_ready(p_user, w.id, e.word_ids, e.n_words, p_now))
             order by (e.word_id <> w.id), e.n)
      from public.examples e
      where not e.is_hidden
        and (e.word_id = w.id or e.word_id in (select a.id from public.words a where a.canonical_id = w.id))
    ), '[]'::jsonb),
    'distractors', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'uz', d.uz, 'ru', d.ru))
      from (
        select x.id, x.uz, x.ru from (
          select c.id, c.uz, c.ru
          from public.words c
          where c.is_active and c.canonical_id is null and c.id <> w.id
            and (c.topic_id = w.topic_id or c.cefr = w.cefr)
            and c.uz_key <> w.uz_key
            and not (c.uz_key = any (w.accept_uz))
            and not (c.accept_ru && w.accept_ru)
          order by (public.wc(c.uz) = public.wc(w.uz) and public.wc(c.ru) = public.wc(w.ru)) desc,
                   (c.topic_id = w.topic_id) desc, (c.word_class = w.word_class) desc, random()
          limit 12
        ) x
      ) d
    ), '[]'::jsonb)
  )
  from public.words w
  left join public.word_progress wp on wp.word_id = w.id and wp.user_id = p_user
  where w.id = p_word_id
$$;

-- ---------------------------------------------------------------- ответы сеанса
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
  v_ex       public.examples%rowtype;
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
  v_right    text;
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

    insert into public.answer_log (user_id, word_id, session_id, seq, ex_type, answer, is_correct, counted)
    values (v_uid, v_word.id, p_session_id, v_seq, coalesce(ev->>'ex_type', '?'), left(ev->>'answer', 200), false, false)
    on conflict (user_id, session_id, seq) do nothing;
    get diagnostics v_inserted = row_count;
    if v_inserted = 0 then
      v_results := v_results || jsonb_build_object('seq', v_seq, 'duplicate', true);
      continue;
    end if;

    v_target := ev->>'target';
    v_answer := coalesce(ev->>'answer', '');
    v_right := null;
    v_ex := null;
    if v_target in ('blank','token','sentence_ru','sentence_uz') then
      select e.* into v_ex from public.examples e
       where e.word_id = (ev->'example'->>'word_id')::int and e.n = (ev->'example'->>'n')::int
         and not e.is_hidden
         and (e.word_id = v_word.id or e.word_id in (select a.id from public.words a where a.canonical_id = v_word.id));
    end if;

    if v_target = 'ru' then
      v_correct := public.key_ru(v_answer) <> '' and public.key_ru(v_answer) = any (v_word.accept_ru);
      v_right := v_word.ru;
    elsif v_target = 'uz' then
      v_correct := public.key_uz(v_answer) <> ''
                   and (public.key_uz(v_answer) = v_word.uz_key or public.key_uz(v_answer) = any (v_word.accept_uz)
                        or public.uz_same(v_answer, v_word.uz));
      v_right := v_word.uz;
    elsif v_target = 'blank' then
      v_right := v_ex.blank_answer;
      v_correct := v_right is not null and public.uz_same(v_answer, v_right);
    elsif v_target = 'token' then
      -- слово целиком вместе с окончанием, начиная с места пропуска
      if v_ex.blank_start is not null then
        v_right := substring(substr(v_ex.uz, v_ex.blank_start + 1) from '^[A-Za-zʻʼ'']+');
      end if;
      v_correct := v_right is not null and public.uz_same(v_answer, v_right);
    elsif v_target = 'sentence_ru' then
      v_right := v_ex.ru;
      v_correct := v_right is not null and public.key_ru(v_answer) <> '' and public.key_ru(v_answer) = public.key_ru(v_right);
    elsif v_target = 'sentence_uz' then
      v_right := v_ex.uz;
      v_correct := v_right is not null and public.uz_same(v_answer, v_right);
    else
      v_correct := false;
    end if;
    v_first := coalesce(ev->>'attempt', 'first') = 'first';

    insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
    values (v_uid, v_word.id, 0, v_now, v_today, v_now)
    on conflict (user_id, word_id) do nothing;
    select * into v_wp from public.word_progress
     where user_id = v_uid and word_id = v_word.id for update;

    v_eff := public.effective_level(v_wp.level, v_wp.level_at, v_now);
    if v_eff < v_wp.level then
      v_level_at := v_wp.level_at + make_interval(days => 90 * (v_wp.level - v_eff));
    else
      v_level_at := v_wp.level_at;
    end if;

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
      v_due := v_today;
      if v_eff >= 2 then
        v_fail := v_fail + 1;
        if v_fail >= 2 then
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
      'level', v_new, 'due_on', v_due, 'correct_answer', v_right);
  end loop;

  return jsonb_build_object('ok', true, 'results', v_results);
end
$$;

-- ---------------------------------------------------------------- альфа-тестеры
create or replace function public.morph_state(p_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with lvl as (
    select max(cefr) as cefr from public.level_test_attempts where user_id = p_user and passed),
  passed as (
    select u.source_no from public.course_units u
     where u.course_id = 'grammar'
       and (exists (select 1 from public.course_progress cp
                     where cp.user_id = p_user and cp.unit_id = u.id and (cp.read_at is not null or cp.status = 'tested'))
            or u.cefr <= (select cefr from lvl)
            or coalesce((select p.alpha from public.profiles p where p.id = p_user), false)))
  select jsonb_build_object(
    'grammar', coalesce((select jsonb_agg(source_no order by source_no) from passed), '[]'::jsonb),
    'by_test', (select cefr from lvl),
    'alpha', coalesce((select p.alpha from public.profiles p where p.id = p_user), false),
    'conj_cap', (select case when count(*) = 13 then 15 else greatest(1, floor(15.0 * count(*) / 13))::int end
                   from passed where source_no in (3,5,6,7,8,16,21,22,23,24,25,26,27)),
    'decl_cap', (select case when count(*) = 3 then 15 else greatest(1, floor(15.0 * count(*) / 3))::int end
                   from passed where source_no in (9,10,11)))
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

  if v_code.alpha then update public.profiles set alpha = true where id = v_uid; end if;
  return jsonb_build_object('ok', true, 'tier', v_code.tier, 'starts_at', v_start, 'ends_at', v_end, 'alpha', v_code.alpha);
end
$$;

-- коды альфа-тестера: «Продвинутая» на p_months мес. + вся грамматика открыта
create or replace function public.admin_create_alpha_codes(p_count int, p_months int default 1, p_created_by bigint default null)
returns setof text language plpgsql security definer set search_path = '' as $$
declare
  v_note text := 'alpha ' || to_char(now(), 'YYYY-MM-DD') || ' ' || substr(md5(random()::text), 1, 6);
  v_code text;
begin
  for v_code in select * from public.admin_create_codes('advanced', p_months, p_count, 1, null, v_note, p_created_by) loop
    return next v_code;
  end loop;
  update public.access_codes set alpha = true where note = v_note;
end
$$;

-- ---------------------------------------------------------------- путь
create or replace function public.get_path()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := public.app_now();
  v_unlocked text;
  v_colloq   boolean := coalesce(((select settings from public.profiles where id = auth.uid())->>'colloquial_first')::boolean, false);
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
             order by c.node_cefr, (v_colloq and t.name_ru like 'Разговорная речь.%') desc, t.sort_order), '[]'::jsonb)
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

-- ---------------------------------------------------------------- игра «Марафон»
-- Все слова уровня по порядку изучения. Место, где остановился, сохраняется. На уровни слов не влияет.
create table if not exists public.marathon_progress (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  cefr        text not null check (cefr in ('A1','A2','B1','B2')),
  pos         int not null default 0,
  correct     int not null default 0,
  wrong       int not null default 0,
  best_pct    int,
  started_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  finished_at timestamptz,
  primary key (user_id, cefr)
);
alter table public.marathon_progress enable row level security;
revoke all on public.marathon_progress from anon, authenticated;

create or replace function public.get_marathon()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_unl text;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_unl := public.unlocked_cefr(v_uid);
  return jsonb_build_object('allowed', public.feature_allowed('games'), 'levels', (
    select jsonb_agg(jsonb_build_object(
             'cefr', l.cefr, 'locked', l.cefr > v_unl,
             'total', (select count(*) from public.words w where w.cefr = l.cefr and w.is_active and w.canonical_id is null),
             'pos', coalesce(m.pos, 0), 'correct', coalesce(m.correct, 0), 'wrong', coalesce(m.wrong, 0),
             'best_pct', m.best_pct, 'finished', m.finished_at is not null) order by l.cefr)
    from (values ('A1'), ('A2'), ('B1'), ('B2')) l(cefr)
    left join public.marathon_progress m on m.user_id = v_uid and m.cefr = l.cefr));
end
$$;

-- начать (p_restart — с начала) или продолжить
create or replace function public.start_marathon(p_cefr text, p_restart boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_m public.marathon_progress%rowtype;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('games') then return jsonb_build_object('error', 'locked_tier'); end if;
  if p_cefr not in ('A1','A2','B1','B2') then return jsonb_build_object('error', 'bad_level'); end if;
  if p_cefr > public.unlocked_cefr(v_uid) then return jsonb_build_object('error', 'level_locked'); end if;
  insert into public.marathon_progress (user_id, cefr) values (v_uid, p_cefr) on conflict do nothing;
  if p_restart then
    update public.marathon_progress set pos = 0, correct = 0, wrong = 0, started_at = now(), updated_at = now(), finished_at = null
     where user_id = v_uid and cefr = p_cefr;
  end if;
  select * into v_m from public.marathon_progress where user_id = v_uid and cefr = p_cefr;
  return jsonb_build_object('cefr', p_cefr, 'pos', v_m.pos, 'correct', v_m.correct, 'wrong', v_m.wrong,
    'total', (select count(*) from public.words w where w.cefr = p_cefr and w.is_active and w.canonical_id is null));
end
$$;

-- следующие слова, начиная с сохранённого места
create or replace function public.marathon_batch(p_cefr text, p_n int default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_pos int; v_now timestamptz := public.app_now();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  select pos into v_pos from public.marathon_progress where user_id = v_uid and cefr = p_cefr;
  if v_pos is null then return jsonb_build_object('error', 'not_started'); end if;
  return jsonb_build_object('pos', v_pos, 'items', coalesce((
    select jsonb_agg(public.word_card(x.id, v_uid, v_now) || jsonb_build_object('mpos', x.rn) order by x.rn)
    from (select w.id, (row_number() over (order by w.sort_key, w.id))::int - 1 as rn
            from public.words w where w.cefr = p_cefr and w.is_active and w.canonical_id is null) x
    where x.rn >= v_pos and x.rn < v_pos + least(greatest(p_n, 1), 50)), '[]'::jsonb));
end
$$;

-- ответ на слово номер p_pos (засчитывается один раз, по порядку)
create or replace function public.marathon_answer(p_cefr text, p_pos int, p_correct boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_m public.marathon_progress%rowtype;
  v_total int;
  v_pct int;
begin
  select * into v_m from public.marathon_progress where user_id = v_uid and cefr = p_cefr for update;
  if not found then return jsonb_build_object('error', 'not_started'); end if;
  if p_pos <> v_m.pos then return jsonb_build_object('duplicate', true, 'pos', v_m.pos); end if;
  select count(*) into v_total from public.words w where w.cefr = p_cefr and w.is_active and w.canonical_id is null;
  update public.marathon_progress
     set pos = pos + 1, correct = correct + case when p_correct then 1 else 0 end,
         wrong = wrong + case when p_correct then 0 else 1 end, updated_at = now()
   where user_id = v_uid and cefr = p_cefr returning * into v_m;
  if v_m.pos >= v_total and v_m.finished_at is null then
    v_pct := round(100.0 * v_m.correct / greatest(v_m.correct + v_m.wrong, 1));
    update public.marathon_progress set finished_at = now(), best_pct = greatest(coalesce(best_pct, 0), v_pct)
     where user_id = v_uid and cefr = p_cefr returning * into v_m;
  end if;
  return jsonb_build_object('pos', v_m.pos, 'total', v_total, 'correct', v_m.correct, 'wrong', v_m.wrong,
                            'finished', v_m.finished_at is not null, 'best_pct', v_m.best_pct);
end
$$;

-- ---------------------------------------------------------------- права
revoke execute on function public.lev(text, text) from public, anon, authenticated;
revoke execute on function public.is_cognate(text, text[]) from public, anon, authenticated;
revoke execute on function public.refresh_test_flags() from public, anon, authenticated;
revoke execute on function public.pick_distractors(int, int, text) from public, anon, authenticated;
revoke execute on function public.admin_create_alpha_codes(int, int, bigint) from public, anon, authenticated;
grant execute on function public.admin_create_alpha_codes(int, int, bigint) to service_role;
revoke execute on function public.start_marathon(text, boolean) from public, anon;
revoke execute on function public.marathon_batch(text, int) from public, anon;
revoke execute on function public.marathon_answer(text, int, boolean) from public, anon;
revoke execute on function public.get_marathon() from public, anon;
grant execute on function public.start_marathon(text, boolean) to authenticated;
grant execute on function public.marathon_batch(text, int) to authenticated;
grant execute on function public.marathon_answer(text, int, boolean) to authenticated;
grant execute on function public.get_marathon() to authenticated;
