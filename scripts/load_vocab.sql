-- Загрузка словаря из data/build/*.csv (результат scripts/build_vocab.py).
-- Запуск: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f scripts/load_vocab.sql
-- Повторный запуск безопасен: данные обновляются по ID, прогресс пользователей не трогается,
-- слова, исчезнувшие из источника, помечаются неактивными, а не удаляются.

\set ON_ERROR_STOP 1
begin;

create temp table s_topics (
  id smallint, source_no smallint, name_ru text, name_uz text, name_en text, cefr text, sort_order int
) on commit drop;
\copy s_topics from 'data/build/topics.csv' with (format csv, header true)

create temp table s_words (
  id int, topic_id smallint, cefr text, uz text, ru text, uz_key text,
  accept_ru text[], accept_uz text[], word_class text, canonical_id int, audio_ok boolean, sort_key int,
  register text, literary text, note text, en text, pos text, morph jsonb
) on commit drop;
\copy s_words from 'data/build/words.csv' with (format csv, header true)

create temp table s_examples (
  word_id int, n smallint, uz text, ru text, blank_start smallint, blank_len smallint,
  blank_answer text, audio_ok boolean, is_hidden boolean, word_ids int[], n_words smallint
) on commit drop;
\copy s_examples from 'data/build/examples.csv' with (format csv, header true)

-- темы
insert into public.topics (id, source_no, name_ru, name_uz, name_en, cefr, sort_order)
select id, source_no, name_ru, nullif(name_uz, ''), nullif(name_en, ''), cefr, sort_order from s_topics
on conflict (id) do update set
  source_no = excluded.source_no, name_ru = excluded.name_ru, cefr = excluded.cefr, sort_order = excluded.sort_order,
  name_uz = coalesce(excluded.name_uz, public.topics.name_uz), name_en = coalesce(excluded.name_en, public.topics.name_en);

-- слова: сначала без ссылок на дубли, затем ссылки
insert into public.words (id, topic_id, cefr, uz, ru, uz_key, accept_ru, accept_uz, word_class,
                          canonical_id, audio_ok, is_active, sort_key, register, literary, note, en, pos, morph)
select id, topic_id, cefr, uz, ru, uz_key, accept_ru, accept_uz, word_class, null, audio_ok, true, sort_key,
       coalesce(nullif(register, ''), 'lit'), nullif(literary, ''), nullif(note, ''), nullif(en, ''), nullif(pos, ''), morph
from s_words
on conflict (id) do update set
  topic_id = excluded.topic_id, cefr = excluded.cefr, uz = excluded.uz, ru = excluded.ru,
  uz_key = excluded.uz_key, accept_ru = excluded.accept_ru, accept_uz = excluded.accept_uz,
  word_class = excluded.word_class, audio_ok = excluded.audio_ok, is_active = true,
  sort_key = excluded.sort_key, register = excluded.register, literary = excluded.literary,
  note = excluded.note, en = excluded.en, pos = excluded.pos, morph = excluded.morph;

-- уровни, изменённые администраторами по пометкам пользователей, сохраняются при повторном импорте
update public.word_level_overrides o set base_cefr = s.cefr from s_words s where s.id = o.word_id;
update public.words w set cefr = o.cefr from public.word_level_overrides o where o.word_id = w.id;

update public.words w set canonical_id = s.canonical_id
from s_words s where s.id = w.id and w.canonical_id is distinct from s.canonical_id;

update public.words set is_active = false
where is_active and id not in (select id from s_words);

-- примеры
insert into public.examples (word_id, n, uz, ru, blank_start, blank_len, blank_answer, audio_ok, is_hidden, word_ids, n_words)
select word_id, n, uz, ru, blank_start, blank_len, nullif(blank_answer, ''), audio_ok, is_hidden,
       coalesce(word_ids, '{}'), coalesce(n_words, 0) from s_examples
on conflict (word_id, n) do update set
  uz = excluded.uz, ru = excluded.ru, blank_start = excluded.blank_start, blank_len = excluded.blank_len,
  blank_answer = excluded.blank_answer, audio_ok = excluded.audio_ok, is_hidden = excluded.is_hidden,
  word_ids = excluded.word_ids, n_words = excluded.n_words;

delete from public.examples e
where not exists (select 1 from s_examples s where s.word_id = e.word_id and s.n = e.n);

-- отключённые слова (повреждённые записи) больше не приходят на повторение
delete from public.word_progress wp using public.words w where w.id = wp.word_id and not w.is_active;

-- итоговая проверка: если цифры не сходятся, транзакция откатывается
do $$
declare
  v_words int; v_examples int; v_topics int; v_src_words int; v_src_examples int;
begin
  select count(*) into v_src_words from s_words;
  select count(*) into v_src_examples from s_examples;
  select count(*) into v_words from public.words where is_active;
  select count(*) into v_examples from public.examples e join public.words w on w.id = e.word_id where w.is_active;
  select count(*) into v_topics from public.topics;
  if v_words <> v_src_words or v_examples <> v_src_examples then
    raise exception 'Проверка не прошла: слов % из %, примеров % из %', v_words, v_src_words, v_examples, v_src_examples;
  end if;
  raise notice 'Импорт OK: тем %, слов %, примеров %', v_topics, v_words, v_examples;
end $$;

-- слова тем курсов и диалогов (шаг 16) пересчитываются после смены словаря
do $$ begin
  if to_regprocedure('public.refresh_unit_words()') is not null then perform public.refresh_unit_words(); end if;
end $$;

commit;
analyze public.topics, public.words, public.examples;
