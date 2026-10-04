-- Проверка шага 10: тесты по темам, проверка вопросов администратором, ссылка на сообщество.
\set ON_ERROR_STOP 1
\pset tuples_only on
delete from public.profiles where tg_id in (182665947, 9201);
insert into public.profiles (id, tg_id, first_name) values
  ('abcdabcd-0000-0000-0000-000000000001', 182665947, 'Admin'),
  ('abcdabcd-0000-0000-0000-000000000002', 9201, 'User');
insert into public.admins (tg_id) values (182665947) on conflict do nothing;
insert into public.subscriptions (user_id, tier, starts_at, ends_at, source) values
  ('abcdabcd-0000-0000-0000-000000000002', 'advanced', now() - interval '1 day', now() + interval '30 days', 'manual');
update public.unit_tasks set status = 'draft' where kind = 'choice';

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
create temp table u as select id from public.course_units where course_id = 'history' and source_no = 12;
grant select on u to authenticated;

select pg_temp.check((select count(*) = 454 from public.unit_tasks where kind = 'choice'), '454 вопроса загружены черновиками');
select pg_temp.check((select bool_and(source_quote is not null and jsonb_array_length(options->'ru') = 4
                                      and jsonb_array_length(options->'uz') = 4 and jsonb_array_length(options->'en') = 4)
                      from public.unit_tasks where kind = 'choice'), 'у каждого вопроса цитата и по 4 варианта на трёх языках');

set role authenticated;
set request.jwt.claim.sub = 'abcdabcd-0000-0000-0000-000000000002';
select pg_temp.check(public.start_unit_test((select id from u))->>'error' = 'no_questions', 'черновики пользователям не показываются');
select pg_temp.check((public.unit_test_info((select id from u))->>'available')::boolean = false, 'тест недоступен, пока вопросы не одобрены');
select pg_temp.check(public.admin_review_summary()->>'error' = 'forbidden', 'не администратор: проверка вопросов закрыта');
select pg_temp.check(public.admin_set_question(null, 'approved', (select id from u))->>'error' = 'forbidden', 'не администратор не может одобрять');

set request.jwt.claim.sub = 'abcdabcd-0000-0000-0000-000000000001';
select pg_temp.check((public.admin_review_summary()->>'draft')::int = 454, 'администратор: 454 черновика');
select pg_temp.check(jsonb_array_length(public.admin_unit_questions((select id from u))->'questions') = 8, 'администратор: 8 вопросов темы с цитатами');
select pg_temp.check((public.admin_set_question((select (q->>'id')::int from jsonb_array_elements(public.admin_unit_questions((select id from u))->'questions') q limit 1), 'rejected')->>'updated')::int = 1,
  'отклонить один вопрос');
select pg_temp.check((public.admin_set_question(null, 'approved', (select id from u))->>'updated')::int = 7, 'одобрить остальные 7 черновиков темы');

set request.jwt.claim.sub = 'abcdabcd-0000-0000-0000-000000000002';
select pg_temp.check((public.unit_test_info((select id from u))->>'available')::boolean, 'тест доступен');
create temp table t1 as select public.start_unit_test((select id from u)) as r;
select pg_temp.check((select (r->>'total')::int = 5 and jsonb_array_length(r->'questions') = 5 from t1), 'тест: 5 вопросов');
select pg_temp.check((select bool_and(not (q ? 'answer') and jsonb_array_length(q->'options_ru') = 4) from t1, jsonb_array_elements(r->'questions') q),
  'верные ответы не передаются');
reset role;
select pg_temp.check((select bool_and(t.status = 'approved') from public.unit_test_attempts a, jsonb_array_elements(a.questions) q
                      join public.unit_tasks t on t.id = (q->>'task_id')::int where a.id = (select (r->>'attempt_id')::uuid from t1)),
  'в тест попали только одобренные вопросы');
-- верные индексы (по сохранённому порядку): ответим верно на 4 из 5
create temp table ans as
select jsonb_agg(case when k = 1 then ((rk + 1) % 4) else rk end order by k) as a
from (select k, (select (j - 1) from jsonb_array_elements_text(q->'order') with ordinality as x(o, j) where o::int = 0) as rk
      from public.unit_test_attempts at, jsonb_array_elements(at.questions) with ordinality as e(q, k)
      where at.id = (select (r->>'attempt_id')::uuid from t1)) z;
grant select on ans to authenticated;
set role authenticated;
create temp table f1 as select public.finish_unit_test((select (r->>'attempt_id')::uuid from t1), (select a from ans)) as r;
select pg_temp.check((select (r->>'score')::int = 4 and (r->>'passed')::boolean from f1), 'тест сдан: 4 из 5');
select pg_temp.check((select (r->'results'->0->>'correct')::boolean = false and r->'results'->0->>'quote_ru' is not null from f1), 'разбор: ошибка показана с цитатой из темы');
select pg_temp.check(public.finish_unit_test((select (r->>'attempt_id')::uuid from t1), (select a from ans))->>'error' = 'finished', 'повторно завершить нельзя');
select pg_temp.check((select (u2->>'tested')::boolean and (u2->>'best_score')::int = 4 from jsonb_array_elements(public.get_course('history')->'units') u2 where (u2->>'id')::int = (select id from u)),
  'в списке тем: тест сдан, лучший результат 4');
select pg_temp.check((select (u2->>'tasks_total')::int = 5 from jsonb_array_elements(public.get_course('history')->'units') u2 where (u2->>'id')::int = (select id from u)),
  'задания для самопроверки считаются отдельно от вопросов теста');
-- не сдан
create temp table t2 as select public.start_unit_test((select id from u)) as r;
select pg_temp.check((public.finish_unit_test((select (r->>'attempt_id')::uuid from t2), '[-1,-1,-1,-1,-1]')->>'passed')::boolean = false, 'все «не знаю» — не сдан');
select pg_temp.check((select (u2->>'tested')::boolean and (u2->>'best_score')::int = 4 from jsonb_array_elements(public.get_course('history')->'units') u2 where (u2->>'id')::int = (select id from u)),
  'неудачная попытка не отменяет сданный тест');
reset role;
-- изменение текста вопроса возвращает его на проверку
update public.unit_tasks set status = 'approved' where kind = 'choice' and unit_id = (select id from u);
select pg_temp.check(public.get_app_info() ? 'community_url', 'get_app_info: ссылка на сообщество');
set role anon;
select pg_temp.check(has_function_privilege('anon', 'public.get_app_info()', 'execute'), 'ссылка на сообщество доступна без входа');
reset role;
