-- Проверка алгоритма обучения (шаг 5). Запуск локально после импорта словаря.
\set ON_ERROR_STOP 1
\pset tuples_only on
delete from public.profiles where id in ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002');
insert into public.profiles (id, tg_id, first_name, timezone) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 5001, 'Paid', 'Asia/Tashkent'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 5002, 'Free', 'Asia/Tashkent');
insert into public.subscriptions (user_id, tier, starts_at, ends_at, source)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'advanced', '2026-01-01', '2028-12-31', 'manual');

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
create or replace function pg_temp.wp(w int) returns record language sql as $$
  select level, due_on, fail_streak, correct_count, wrong_count, level_at
  from public.word_progress where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and word_id = w $$;

set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';

-- ===== День 1: 05.10.2026
set app.now = '2026-10-05 10:00+05';
select pg_temp.check((public.get_home()->>'plan_new')::int = 20, 'главный экран: 20 новых');
create temp table s1 as select public.start_session() as r;
select pg_temp.check((select (r->>'new_count')::int = 20 and (r->>'review_count')::int = 0 from s1), 'сеанс 1: 20 новых + 0 повторений');
select pg_temp.check((select r->'items'->0->>'uz' = 'men' and r->'items'->0->>'stage' = 'new' from s1), 'первое слово — men, стадия new');
select pg_temp.check((select jsonb_array_length(r->'items'->0->'distractors') >= 3 from s1), 'есть кандидаты в неверные варианты');
select pg_temp.check((select not exists (
  select 1 from jsonb_array_elements(r->'items'->2->'distractors') d where d->>'ru' ilike '%он%' and d->>'ru' ilike '%она%') from s1),
  'у слова «u» среди вариантов нет других «он/она»');
select pg_temp.check((select public.start_session()->>'session_id' = r->>'session_id' from s1), 'повторный вызов возвращает тот же незавершённый сеанс');

-- слово A = men (1): показ, верно, верно → уровень 2, следующий показ 06.10
select public.submit_answers((select (r->>'session_id')::uuid from s1), '[
  {"seq":1,"kind":"shown","word_id":1},
  {"seq":2,"kind":"answer","word_id":1,"ex_type":"uz_ru_choice","target":"ru","answer":"Я","attempt":"first"},
  {"seq":3,"kind":"answer","word_id":1,"ex_type":"ru_uz_choice","target":"uz","answer":"Men","attempt":"first"}]'::jsonb) is not null;
select pg_temp.check((select level = 2 and due_on = '2026-10-06' and correct_count = 2 from pg_temp.wp(1) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)),
  'A: два верных ответа в сеансе → уровень 2, повтор 06.10');

-- повторная отправка той же пачки ничего не меняет
select pg_temp.check((public.submit_answers((select (r->>'session_id')::uuid from s1),
  '[{"seq":2,"kind":"answer","word_id":1,"target":"ru","answer":"я"}]'::jsonb)->'results'->0->>'duplicate') = 'true', 'повторная отправка распознана');

-- слово B = sen (2): ошибка → уровень 0; верный повтор (шаг заучивания) → 1; верно → 2
select public.submit_answers((select (r->>'session_id')::uuid from s1), '[
  {"seq":4,"kind":"shown","word_id":2},
  {"seq":5,"kind":"answer","word_id":2,"ex_type":"uz_ru_choice","target":"ru","answer":"мы","attempt":"first"},
  {"seq":6,"kind":"answer","word_id":2,"ex_type":"ru_uz_choice","target":"uz","answer":"sen","attempt":"retry"},
  {"seq":7,"kind":"answer","word_id":2,"ex_type":"letters","target":"uz","answer":"sen","attempt":"first"}]'::jsonb) is not null;
select pg_temp.check((select level = 2 and wrong_count = 1 and correct_count = 2 from pg_temp.wp(2) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)),
  'B: ошибка на шаге заучивания уровень не снижает, верный повтор засчитан → уровень 2');

-- «вставь слово»: пример 1 слова «u» — «U mening doʻstim.»
select pg_temp.check((public.submit_answers((select (r->>'session_id')::uuid from s1), '[
  {"seq":8,"kind":"shown","word_id":3},
  {"seq":9,"kind":"answer","word_id":3,"ex_type":"fill_input","target":"blank","answer":"u","example":{"word_id":3,"n":1}}]'::jsonb)->'results'->1->>'correct') = 'true',
  'вставь слово: ответ проверяется по примеру');
-- чужое слово не из сеанса
select pg_temp.check((public.submit_answers((select (r->>'session_id')::uuid from s1),
  '[{"seq":10,"kind":"answer","word_id":5000,"target":"ru","answer":"x"}]'::jsonb)->'results'->0->>'error') = 'word_not_in_session',
  'слово не из сеанса отклоняется');
select public.finish_session((select (r->>'session_id')::uuid from s1), 600) is not null;

-- ===== День 2: 06.10 — A верно → 3; B ошибка → уровень 2, счётчик 1; повтор верный не засчитан
set app.now = '2026-10-06 09:00+05';
create temp table s2 as select public.start_session() as r;
select pg_temp.check((select (r->>'review_count')::int >= 2 and r->'items'->0->>'stage' = 'learning' from s2), 'день 2: повторения идут первыми');
select public.submit_answers((select (r->>'session_id')::uuid from s2), '[
  {"seq":1,"kind":"answer","word_id":1,"target":"uz","answer":"men","attempt":"first"},
  {"seq":2,"kind":"answer","word_id":2,"target":"ru","answer":"я","attempt":"first"},
  {"seq":3,"kind":"answer","word_id":2,"target":"ru","answer":"ты","attempt":"retry"}]'::jsonb) is not null;
select pg_temp.check((select level = 3 and due_on = '2026-10-08' from pg_temp.wp(1) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)), 'A: 06.10 верно → уровень 3, повтор 08.10');
select pg_temp.check((select level = 2 and fail_streak = 1 and due_on = '2026-10-06' from pg_temp.wp(2) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)),
  'B: 1-я ошибка → уровень не меняется, слово в следующем сеансе; верный повтор не засчитан');
select public.finish_session((select (r->>'session_id')::uuid from s2), 300) is not null;

-- ===== следующий сеанс: B снова ошибка → уровень 1
set app.now = '2026-10-06 19:00+05';
create temp table s3 as select public.start_session() as r;
select public.submit_answers((select (r->>'session_id')::uuid from s3),
  '[{"seq":1,"kind":"answer","word_id":2,"target":"ru","answer":"он","attempt":"first"}]'::jsonb) is not null;
select pg_temp.check((select level = 1 and fail_streak = 0 from pg_temp.wp(2) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)),
  'B: 2-я ошибка подряд → уровень −1, счётчик обнулён');
select public.finish_session((select (r->>'session_id')::uuid from s3), 60) is not null;

-- ===== Слово C и правило 3 месяцев: уровень 9 с 29.01.2027, возвращение 15.06.2027
reset role;
update public.word_progress set level = 9, level_at = '2027-01-29 12:00+05', due_on = '2027-03-10', fail_streak = 0
 where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and word_id = 1;
set role authenticated;
set app.now = '2027-04-28 12:00+05';
select pg_temp.check((select public.effective_level(level, level_at, public.app_now()) = 9 from pg_temp.wp(1) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)), 'C: через 89 дней уровень ещё 9');
set app.now = '2027-06-15 12:00+05';
select pg_temp.check((select public.effective_level(level, level_at, public.app_now()) = 8 and level = 9 from pg_temp.wp(1) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)), 'C: через 137 дней действующий уровень 8, в базе ничего не записано');
create temp table s4 as select public.start_session() as r;
select pg_temp.check((select r->'items'->0->>'id' = '1' from s4), 'C: слово на грани понижения/просроченное — первым в очереди');
select public.submit_answers((select (r->>'session_id')::uuid from s4),
  '[{"seq":1,"kind":"answer","word_id":1,"target":"ru","answer":"я","attempt":"first"}]'::jsonb) is not null;
select pg_temp.check((select level = 9 and due_on = '2027-07-25' from pg_temp.wp(1) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)), 'C: верно → 8 + 1 = 9, повтор через 40 дней (25.07)');
select public.finish_session((select (r->>'session_id')::uuid from s4), 60) is not null;
-- вариант с ошибкой: понижение записывается, level_at сдвигается на 29.04
reset role;
update public.word_progress set level = 9, level_at = '2027-01-29 12:00+05', due_on = '2027-03-10'
 where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and word_id = 1;
set role authenticated;
set app.now = '2027-06-15 20:00+05';
create temp table s5 as select public.start_session() as r;
select public.submit_answers((select (r->>'session_id')::uuid from s5),
  '[{"seq":1,"kind":"answer","word_id":1,"target":"ru","answer":"ты","attempt":"first"}]'::jsonb) is not null;
select pg_temp.check((select level = 8 and level_at::date = '2027-04-29' and fail_streak = 1 from pg_temp.wp(1) as (level smallint, due_on date, fail_streak smallint, correct_count int, wrong_count int, level_at timestamptz)),
  'C: ошибка → в базу записан уровень 8, отсчёт 90 дней с 29.04');

-- ===== Бесплатный пользователь: 15 слов, 1 сеанс в день
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
set app.now = '2026-10-05 10:00+05';
create temp table f1 as select public.start_session() as r;
select pg_temp.check((select (r->>'new_count')::int = 10 and r->>'tier' = 'free' from f1), 'бесплатно: 10 новых (сеанс 15 слов)');
select public.finish_session((select (r->>'session_id')::uuid from f1), 100) is not null;
select pg_temp.check(public.start_session()->>'error' = 'daily_limit', 'бесплатно: второй сеанс в тот же день — лимит');
select pg_temp.check((public.get_home()->>'daily_limit_reached')::boolean, 'главный экран показывает, что лимит исчерпан');
set app.now = '2026-10-06 08:00+05';
select pg_temp.check(public.start_session()->>'error' is null, 'бесплатно: на следующий день сеанс снова доступен');

-- ===== чужие данные
select pg_temp.check((select count(*) = 0 from public.word_progress where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 'RLS: чужой прогресс не виден');
select pg_temp.check((public.submit_answers((select (r->>'session_id')::uuid from s5),
  '[{"seq":99,"kind":"answer","word_id":1,"target":"ru","answer":"я"}]'::jsonb)->>'error') = 'session_not_found', 'нельзя отправить ответы в чужой сеанс');
reset role;
