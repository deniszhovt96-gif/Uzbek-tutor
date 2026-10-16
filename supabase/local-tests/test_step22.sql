-- Проверка шага 22: ежедневная чистка, права доступа, ограничение частоты, «Повторение» без новых слов.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (2201, 2202);
insert into public.profiles (id, tg_id, first_name) values
  ('22010000-0000-0000-0000-000000000001', 2201, 'Old'),
  ('22020000-0000-0000-0000-000000000001', 2202, 'New');
create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;

-- ===== 1. Ежедневная чистка
insert into public.study_sessions (id, user_id, local_day, mode, tier, word_ids, new_ids, started_at, finished_at) values
  ('22aa0000-0000-0000-0000-000000000001', '22010000-0000-0000-0000-000000000001', current_date - 90, 'normal', 'free', '{1,2}', '{}', now() - interval '90 days', now() - interval '90 days'),
  ('22aa0000-0000-0000-0000-000000000002', '22010000-0000-0000-0000-000000000001', current_date - 5, 'normal', 'free', '{1,2}', '{}', now() - interval '5 days', now() - interval '5 days');
insert into public.answer_log (user_id, word_id, session_id, seq, at, ex_type, answer, is_correct, counted) values
  ('22010000-0000-0000-0000-000000000001', 1, '22aa0000-0000-0000-0000-000000000001', 1, now() - interval '90 days', 'uz_ru_choice', 'я', true, true),
  ('22010000-0000-0000-0000-000000000001', 1, '22aa0000-0000-0000-0000-000000000002', 1, now() - interval '5 days', 'uz_ru_choice', 'я', true, true);
insert into public.level_test_attempts (user_id, cefr, questions, answers, total, score, passed, started_at, finished_at) values
  ('22010000-0000-0000-0000-000000000001', 'A1', '[{"q":1}]', '{"0":{"a":"x","c":true}}', 35, 30, true, now() - interval '60 days', now() - interval '60 days');
insert into public.code_attempts (user_id, success, at) values ('22010000-0000-0000-0000-000000000001', false, now() - interval '30 days');
create temp table mres as select public.maintenance_daily(true) r;
select pg_temp.check((select count(*) = 1 from public.answer_log where user_id = '22010000-0000-0000-0000-000000000001'), 'журнал ответов: старше 35 дней удалено, свежее осталось');
select pg_temp.check((select count(*) = 1 from public.study_sessions where user_id = '22010000-0000-0000-0000-000000000001'), 'сеансы старше 60 дней удалены');
select pg_temp.check((select questions = '[]'::jsonb and answers = '{}'::jsonb and score = 30 and passed
                      from public.level_test_attempts where user_id = '22010000-0000-0000-0000-000000000001'), 'тест: вопросы убраны, итог сохранён');
select pg_temp.check((select count(*) = 0 from public.code_attempts where user_id = '22010000-0000-0000-0000-000000000001'), 'старые попытки кодов удалены');
select pg_temp.check(public.maintenance_daily()->>'skipped' = 'true', 'второй запуск за день пропускается');

-- ===== 2. Права доступа
select pg_temp.check(not has_table_privilege('anon', 'public.words', 'select') and not has_table_privilege('authenticated', 'public.words', 'select')
                     and not has_table_privilege('authenticated', 'public.examples', 'select'), 'словарь и примеры не читаются напрямую');
select pg_temp.check(not has_table_privilege('anon', 'public.profiles', 'select') and not has_table_privilege('anon', 'public.payments', 'select'), 'без входа — никаких данных пользователей');
select pg_temp.check(not has_table_privilege('authenticated', 'public.words', 'insert') and not has_table_privilege('authenticated', 'public.word_progress', 'update')
                     and not has_table_privilege('authenticated', 'public.subscriptions', 'insert'), 'запись в таблицы напрямую закрыта');
select pg_temp.check(has_table_privilege('anon', 'public.plans', 'select'), 'цены видны всем');
select pg_temp.check(not has_function_privilege('authenticated', 'public.grant_subscription(uuid, text, integer, text, text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.maintenance_daily(boolean)', 'execute')
                     and not has_function_privilege('authenticated', 'public.admin_create_alpha_codes(integer, integer, bigint)', 'execute')
                     and not has_function_privilege('authenticated', 'public.refresh_test_flags()', 'execute'), 'служебные функции пользователю недоступны');
select pg_temp.check(has_function_privilege('authenticated', 'public.get_home()', 'execute')
                     and has_function_privilege('authenticated', 'public.start_session(text, integer)', 'execute'), 'функции приложения доступны');
select pg_temp.check(not has_function_privilege('anon', 'public.get_home()', 'execute') and not has_function_privilege('anon', 'public.get_dictionary(text)', 'execute'), 'без входа функции приложения закрыты');
select pg_temp.check(has_function_privilege('service_role', 'public.stars_grant_payment(text, bigint, integer, text)', 'execute'), 'сервер (бот) вызывает служебные функции');

-- ===== 3. Ограничение частоты и вход только через Telegram
update public.app_config set value = '2' where key = 'rate_dict_per_hour';
set role authenticated;
set request.jwt.claim.sub = '22020000-0000-0000-0000-000000000001';
select pg_temp.check(public.get_dictionary('A1') is not null, 'словарь: 1-й вызов');
select pg_temp.check(public.get_dictionary('A1') is not null, 'словарь: 2-й вызов');
do $$ begin
  perform public.get_dictionary('A1');
  raise exception 'FAIL: третий вызов должен быть ограничен';
exception when others then
  if sqlerrm <> 'rate_limited' then raise; end if;
end $$;
set request.jwt.claim.sub = '22990000-0000-0000-0000-000000000099';   -- пользователь без профиля (вход не через Telegram)
do $$ begin
  perform public.get_word(1);
  raise exception 'FAIL: без профиля доступ должен быть закрыт';
exception when others then
  if sqlerrm <> 'no_profile' then raise; end if;
end $$;
reset role;
update public.app_config set value = '40' where key = 'rate_dict_per_hour';

-- ===== 4. «Повторение»: только просмотренные слова
set role authenticated;
set request.jwt.claim.sub = '22020000-0000-0000-0000-000000000001';
select pg_temp.check(jsonb_array_length(public.start_session('review', null)->'items') = 0, 'нечего повторять — пусто, новых слов нет');
reset role;
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
select '22020000-0000-0000-0000-000000000001', id, 3, now() - interval '1 day', current_date + 5, now() - interval '3 days'
  from public.words where cefr = 'A1' and is_active and canonical_id is null order by sort_key limit 6;
set role authenticated;
create temp table rs as select public.start_session('review', null) r;
reset role;
select pg_temp.check((select jsonb_array_length(r->'items') = 6 from rs), 'не к сроку — всё равно повторяем уже просмотренные');
select pg_temp.check((select bool_and((x->>'id')::int in (select word_id from public.word_progress where user_id = '22020000-0000-0000-0000-000000000001'))
                      from rs, jsonb_array_elements(r->'items') x), 'в «Повторении» только знакомые слова');
select pg_temp.check((select coalesce(array_length(new_ids, 1), 0) = 0 from public.study_sessions
                      where user_id = '22020000-0000-0000-0000-000000000001' and mode = 'review'), 'новых слов в сеансе нет');

delete from public.profiles where tg_id in (2201, 2202);
