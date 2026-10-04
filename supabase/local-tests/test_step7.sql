-- Проверка шага 7: тесты уровней, открытие уровней, тренировка, новые виды ответов.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (7001, 7002);
insert into public.profiles (id, tg_id, first_name, timezone) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 7001, 'Pass', 'Asia/Tashkent'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 7002, 'Fail', 'Asia/Tashkent');
insert into public.subscriptions (user_id, tier, starts_at, ends_at, source)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'advanced', '2026-01-01', '2028-12-31', 'manual');

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;

set app.now = '2026-10-10 10:00+05';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';

-- ===== открытые уровни и запреты
select pg_temp.check(public.get_home()->>'unlocked' = 'A1', 'новый пользователь: открыт только A1');
select pg_temp.check(public.start_level_test('B1')->>'error' = 'level_locked', 'тест B1 закрыт, пока не сдан A2');
select pg_temp.check(public.start_session('normal', (select id from public.topics where cefr = 'A2' order by sort_order limit 1))->>'error' = 'level_locked',
  'тема уровня A2 закрыта');
select pg_temp.check((select bool_and(t->>'locked' = (t->>'cefr' > 'A1')::text) from jsonb_array_elements(public.get_path()->'topics') t),
  'карта пути: закрыты все темы выше A1');

-- ===== тест A1: структура
create temp table t1 as select public.start_level_test('A1') as r;
select pg_temp.check((select (r->>'total')::int = 35 and jsonb_array_length(r->'questions') = 35 from t1), 'тест A1: 35 вопросов');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(r->'questions') q where q ? 'answer') from t1),
  'верные ответы не отдаются в приложение');
select pg_temp.check((select count(distinct q->>'type') >= 6 from t1, jsonb_array_elements(r->'questions') q), 'не меньше 6 видов вопросов');
select pg_temp.check((select bool_and(jsonb_array_length(q->'options') = 4) from t1, jsonb_array_elements(r->'questions') q where q ? 'options'),
  'у вопросов с выбором по 4 варианта');
select pg_temp.check((select bool_and(w.cefr = 'A1') from t1, jsonb_array_elements(r->'questions') q join public.words w on w.id = (q->>'word_id')::int),
  'все вопросы — по словам A1');
select pg_temp.check((select public.start_level_test('A1')->>'attempt_id' = r->>'attempt_id' from t1), 'повторный вызов продолжает ту же попытку');

-- второй тест — другой набор (варианты не повторяются)
reset role;
create temp table qa as select questions from public.level_test_attempts where id = (select (r->>'attempt_id')::uuid from t1);
grant select on qa to authenticated;
set role authenticated;

-- ===== отвечаем: 29 верно, 6 неверно (порог 28 из 35)
do $$
declare q jsonb; i int; v_att uuid := (select (r->>'attempt_id')::uuid from t1); res jsonb;
begin
  for q, i in select x, n - 1 from qa, jsonb_array_elements(qa.questions) with ordinality as e(x, n) loop
    res := public.answer_level_test(v_att, i, case when i < 6 then 'неверно' else q->>'answer' end);
    if res->>'ok' is null then raise exception 'answer failed %', res; end if;
  end loop;
end $$;
select pg_temp.check((select public.answer_level_test((r->>'attempt_id')::uuid, 0, 'x')->>'duplicate' = 'true' from t1),
  'ответ на вопрос принимается только один раз');
create temp table f1 as select public.finish_level_test((select (r->>'attempt_id')::uuid from t1)) as r;
select pg_temp.check((select (r->>'score')::int = 29 and (r->>'need')::int = 28 and (r->>'passed')::boolean from f1), 'тест A1 сдан: 29 из 35 (нужно 28)');
select pg_temp.check((select jsonb_array_length(r->'mistakes') = 6 and r->>'next_cefr' = 'A2' from f1), 'итог: 6 ошибок с верными ответами, открыт A2');
select pg_temp.check(public.get_home()->>'unlocked' = 'A2', 'после сдачи открыт A2');
select pg_temp.check(public.start_level_test('A1')->>'error' = 'already_passed', 'сданный тест повторно не запускается');
select pg_temp.check((select l->>'state' = 'passed' from jsonb_array_elements(public.get_home()->'levels') l where l->>'cefr' = 'A1'), 'уровень A1 отмечен сданным');

-- ===== пользователь 2 (бесплатный): тест не сдан
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
-- начнём 3 слова A1, чтобы проверить возврат в повторение
reset role;
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
select 'bbbbbbbb-0000-0000-0000-000000000002', id, 5, '2026-10-09', '2026-10-20', '2026-10-01'
from public.words where cefr = 'A1' and canonical_id is null and is_active order by sort_key limit 3;
set role authenticated;
select pg_temp.check(public.start_practice('games', 20)->>'error' = 'locked_tier', 'игры закрыты в бесплатной подписке');
create temp table t2 as select public.start_level_test('A1') as r;
select pg_temp.check((select (r->>'total')::int = 35 from t2), 'тест доступен бесплатно');
reset role;
select pg_temp.check((select count(*) = 3 from public.level_test_attempts a, jsonb_array_elements(a.questions) q
                      where a.id = (select (r->>'attempt_id')::uuid from t2)
                        and (q->>'word_id')::int in (select word_id from public.word_progress where user_id = 'bbbbbbbb-0000-0000-0000-000000000002')),
  'начатые слова обязательно попадают в тест');
select pg_temp.check((select count(*) < 25 from (
    select q->>'word_id' from public.level_test_attempts a, jsonb_array_elements(a.questions) q where a.id = (select (r->>'attempt_id')::uuid from t2)
    intersect select q->>'word_id' from qa, jsonb_array_elements(qa.questions) q) x),
  'у второго пользователя другой набор вопросов');
set role authenticated;
select public.answer_level_test((select (r->>'attempt_id')::uuid from t2), i, 'не знаю') is not null from generate_series(0, 9) i limit 1;
create temp table f2 as select public.finish_level_test((select (r->>'attempt_id')::uuid from t2)) as r;
select pg_temp.check((select not (r->>'passed')::boolean and (r->>'score')::int = 0 and jsonb_array_length(r->'mistakes') = 35 from f2),
  'не сдан: 0 из 35, неотвеченные считаются ошибками');
select pg_temp.check((select (r->>'retry_at')::timestamptz = '2026-10-11 10:00+05' from f2), 'пересдача через 24 часа');
select pg_temp.check(public.start_level_test('A1')->>'error' = 'cooldown', 'раньше 24 часов тест не начать');
reset role;
select pg_temp.check((select bool_and(due_on = '2026-10-10') from public.word_progress where user_id = 'bbbbbbbb-0000-0000-0000-000000000002'),
  'слова с ошибками вернулись в повторение сегодня');
select pg_temp.check((select bool_and(level = 5) from public.word_progress where user_id = 'bbbbbbbb-0000-0000-0000-000000000002'),
  'уровни слов тестом не меняются');
set role authenticated;
set app.now = '2026-10-11 10:01+05';
select pg_temp.check(public.start_level_test('A1')->>'attempt_id' is not null, 'через 24 часа — новая попытка');
set app.now = '2026-10-11 13:00+05';
select pg_temp.check(public.answer_level_test(gen_random_uuid(), 0, 'x')->>'error' = 'not_found', 'чужая/несуществующая попытка — отказ');

-- ===== открытые уровни ограничивают новые слова
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
reset role;
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
select 'bbbbbbbb-0000-0000-0000-000000000002', id, 3, '2026-10-11', '2026-10-30', '2026-10-01'
from public.words where cefr = 'A1' and canonical_id is null and is_active
on conflict do nothing;
set role authenticated;
select pg_temp.check((public.get_home()->>'need_test')::boolean and (public.get_home()->>'plan_new')::int = 0,
  'все слова A1 начаты, тест не сдан → новых слов нет, нужен тест');

-- ===== тренировка (продвинутая подписка)
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
create temp table s1 as select public.start_session() as r;
select pg_temp.check((select bool_and(i->>'cefr' <= 'A2') from s1, jsonb_array_elements(r->'items') i), 'новые слова только из открытых уровней');
select pg_temp.check((public.start_practice('practice', 20)->>'started')::int = 0, 'тренировка: пока нет начатых слов');

-- ===== новые виды ответов в сеансе
reset role;
create temp table ex as
select e.word_id, e.n, e.uz, e.ru,
       substring(substr(e.uz, e.blank_start + 1) from '^[A-Za-zʻʼ'']+') as tok
from public.examples e
where e.word_id = (select (i->>'id')::int from s1, jsonb_array_elements(s1.r->'items') i
                   where exists (select 1 from public.examples x where x.word_id = (i->>'id')::int and x.blank_start is not null and not x.is_hidden)
                   limit 1)
  and e.blank_start is not null and not e.is_hidden
order by e.n limit 1;
grant select on ex to authenticated;
set role authenticated;
select pg_temp.check((select public.submit_answers((s1.r->>'session_id')::uuid, jsonb_build_array(
    jsonb_build_object('seq', 1, 'kind', 'answer', 'word_id', ex.word_id, 'ex_type', 'sentence_choice', 'target', 'sentence_ru',
                       'answer', ex.ru, 'attempt', 'first', 'example', jsonb_build_object('word_id', ex.word_id, 'n', ex.n)),
    jsonb_build_object('seq', 2, 'kind', 'answer', 'word_id', ex.word_id, 'ex_type', 'sentence_build', 'target', 'sentence_uz',
                       'answer', lower(regexp_replace(ex.uz, '[.,!?]', '', 'g')), 'attempt', 'first', 'example', jsonb_build_object('word_id', ex.word_id, 'n', ex.n)),
    jsonb_build_object('seq', 3, 'kind', 'answer', 'word_id', ex.word_id, 'ex_type', 'suffix_choice', 'target', 'token',
                       'answer', ex.tok, 'attempt', 'first', 'example', jsonb_build_object('word_id', ex.word_id, 'n', ex.n)),
    jsonb_build_object('seq', 4, 'kind', 'answer', 'word_id', ex.word_id, 'ex_type', 'suffix_choice', 'target', 'token',
                       'answer', ex.tok || 'ni', 'attempt', 'first', 'example', jsonb_build_object('word_id', ex.word_id, 'n', ex.n))
  ))->>'ok' = 'true' from s1, ex), 'новые виды ответов принимаются');
reset role;
select pg_temp.check((select array_agg(is_correct order by seq) = array[true, true, true, false]
                      from public.answer_log where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' and seq between 1 and 4),
  'сервер проверяет перевод предложения, сборку предложения и окончание');

-- ===== настройки: тема
set role authenticated;
select pg_temp.check(public.update_settings(null, '{"theme":"gray"}')->'settings'->>'theme' = 'gray', 'тема оформления сохраняется');
select pg_temp.check(public.update_settings(null, '{"theme":"pink"}')->'settings'->>'theme' = 'gray', 'неизвестная тема не сохраняется');

-- ===== права
set role anon;
select pg_temp.check(not has_function_privilege('anon', 'public.start_level_test(text)', 'execute'), 'аноним не может начать тест');
select pg_temp.check(not has_table_privilege('authenticated', 'public.level_test_attempts', 'select'), 'таблица попыток (с ответами) закрыта для чтения');
reset role;
