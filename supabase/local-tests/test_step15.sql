-- Проверка шага 15: числа, ответ цифрами, готовность примеров, «Предложения», глаголы, новые темы грамматики.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (1501);
insert into public.profiles (id, tg_id, first_name, timezone) values ('15010000-0000-0000-0000-000000000001', 1501, 'Sent', 'Asia/Tashkent');

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;

-- числа
select pg_temp.check((select count(*) = 52 from public.words w join public.topics t on t.id = w.topic_id
                      where t.name_ru = 'Числа от 1 до 100' and w.is_active), 'числа от 1 до 100: добавлены 10–19 и 30–33');
select pg_temp.check((select string_agg(uz, ',' order by sort_key) from public.words where id in (57, 21001, 21002, 58)) = 'toʻqqiz,oʻn,oʻn bir,yigirma',
  'порядок изучения: девять → десять → одиннадцать → двадцать');
select pg_temp.check((select uz = 'yetti' from public.words where id = 55), 'современная орфография: yetti');
select pg_temp.check((select '4' = any(accept_ru) from public.words where id = 52), 'ответ цифрами: «четыре» = 4');
select pg_temp.check((select '2000' = any(accept_ru) from public.words where id = 96), 'ответ цифрами: «две тысячи» = 2000');
select pg_temp.check((select '1000000' = any(accept_ru) from public.words where id = 99), 'ответ цифрами: «миллион» = 1000000');

-- примеры: короткие готовы всегда, длинные — когда выучены слова
create temp table ex as select e.* from public.examples e where e.word_id = 1 and e.n_words >= 5 and cardinality(e.word_ids) >= 3 limit 1;
grant select on ex to authenticated;
select pg_temp.check((select count(*) = 1 from ex), 'есть длинный пример со словами словаря');
select pg_temp.check((select count(*) > 30000 from public.examples where cardinality(word_ids) > 0), 'у примеров определены слова словаря');
select pg_temp.check(not (select public.example_ready('15010000-0000-0000-0000-000000000001', 1, word_ids, n_words, now()) from ex),
  'новичок: длинный пример не готов');
select pg_temp.check(public.example_ready('15010000-0000-0000-0000-000000000001', 1, '{}', 3, now()), 'короткий пример (до 3 слов) готов всегда');
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
select '15010000-0000-0000-0000-000000000001', x, 5, now(), current_date + 5, now() from ex, unnest(word_ids) x
on conflict do nothing;
select pg_temp.check((select public.example_ready('15010000-0000-0000-0000-000000000001', 1, word_ids, n_words, now()) from ex),
  'слова выучены — длинный пример готов');
select pg_temp.check((select bool_or((e->>'ready')::boolean and (e->>'nw')::int >= 4)
                      from jsonb_array_elements(public.word_card(1, '15010000-0000-0000-0000-000000000001', now())->'examples') e), 'карточка слова: готовность примеров');
set role authenticated;
set request.jwt.claim.sub = '15010000-0000-0000-0000-000000000001';
create temp table s as select public.start_sentences() as r;
select pg_temp.check((select jsonb_array_length(r->'items') >= 1 from s), 'предложения: есть готовые');
select pg_temp.check((select bool_and((i->>'nw')::int >= 4) from s, jsonb_array_elements(r->'items') i), 'в тренировке только длинные предложения');
select pg_temp.check((select (public.answer_sentence((r->'items'->0->>'word_id')::int, (r->'items'->0->>'n')::int, true)->>'level')::int = 1 from s),
  'верный ответ: уровень предложения 1');
reset role;
select pg_temp.check((select due_on > current_date from public.sentence_progress where user_id = '15010000-0000-0000-0000-000000000001' limit 1),
  'предложение уходит на повторение позже');
set role authenticated;
select pg_temp.check((select jsonb_array_length(public.get_verbs()->'verbs') > 1000), 'глаголы для спряжения: больше 1000');
reset role;

-- грамматика
select pg_temp.check((select count(*) = 27 from public.course_units where course_id = 'grammar'), 'грамматика: 27 тем (новые 21–27: времена и наклонения)');
select pg_temp.check((select bool_and((select count(*) from public.examples e where e.uz ~* u.example_pattern) >= 40)
                      from public.course_units u where course_id = 'grammar'), 'у каждой темы грамматики не меньше 40 примеров');
select pg_temp.check((select count(*) = 42 from public.unit_tasks t join public.course_units u on u.id = t.unit_id
                      where u.course_id = 'grammar' and u.source_no >= 21 and t.kind = 'choice'), '42 вопроса к новым темам');
