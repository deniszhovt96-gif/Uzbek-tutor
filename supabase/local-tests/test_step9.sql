-- Проверка шага 9: курсы. Запуск после загрузки data/build/courses.sql.
\set ON_ERROR_STOP 1
\pset tuples_only on
delete from public.profiles where tg_id in (9101, 9102, 9103);
insert into public.profiles (id, tg_id, first_name) values
  ('ffffffff-0000-0000-0000-000000000001', 9101, 'Free'),
  ('ffffffff-0000-0000-0000-000000000002', 9102, 'Basic'),
  ('ffffffff-0000-0000-0000-000000000003', 9103, 'Adv');
insert into public.subscriptions (user_id, tier, starts_at, ends_at, source) values
  ('ffffffff-0000-0000-0000-000000000002', 'basic', now() - interval '1 day', now() + interval '30 days', 'manual'),
  ('ffffffff-0000-0000-0000-000000000003', 'advanced', now() - interval '1 day', now() + interval '30 days', 'manual');

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
create temp table ids as select course_id, source_no, id from public.course_units;
grant select on ids to authenticated;

-- контент
select pg_temp.check((select count(*) = 89 from public.course_units), '89 тем: грамматика 27, история 22, обществознание 20, культура 20');
select pg_temp.check((select count(*) = 445 from public.unit_tasks where status = 'approved' and kind = 'open'), '445 заданий (по 5 на тему)');
select pg_temp.check((select bool_and(express_ru is not null and express_uz is not null and express_en is not null
                                     and detailed_ru is not null and detailed_uz is not null and detailed_en is not null) from public.course_units),
  'у каждой темы кратко и подробно на трёх языках');
select pg_temp.check((select bool_and(title_uz is not null and title_en is not null) from public.course_units), 'названия тем на трёх языках');
select pg_temp.check((select count(*) = 0 from public.course_units where detailed_uz ~ '[oOgG][‘’'']'), 'апострофы узбекского текста приведены к oʻ gʻ');
select pg_temp.check((select count(*) = 24 from public.timeline_events where course_id = 'history'), 'хронология: 24 события');
select pg_temp.check((select count(*) = 13 from public.reference_items where kind = 'contact'), 'контакты: 13');
select pg_temp.check((select count(*) = 20 from public.reference_items where kind = 'vocab'), 'базовая лексика: 20 слов');
select pg_temp.check((select bool_and((select count(*) from public.examples e where e.uz ~* u.example_pattern) >= 40)
                      from public.course_units u where course_id = 'grammar'), 'у каждой темы грамматики не меньше 40 примеров из словаря');

set role authenticated;
-- бесплатный: превью 2 темы
set request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000001';
select pg_temp.check((select bool_and(not (c->>'allowed')::boolean) from jsonb_array_elements(public.get_courses()) c), 'бесплатно: курсы закрыты');
select pg_temp.check((select count(*) filter (where not (u->>'locked')::boolean) = 2 from jsonb_array_elements(public.get_course('grammar')->'units') u),
  'бесплатно: открыты 2 первые темы грамматики');
select pg_temp.check(public.get_unit((select id from ids where course_id = 'grammar' and source_no = 1))->>'title_ru' is not null, 'бесплатно: первая тема читается');
select pg_temp.check(public.get_unit((select id from ids where course_id = 'grammar' and source_no = 5))->>'error' = 'locked_tier', 'бесплатно: 5-я тема закрыта');
select pg_temp.check(public.get_unit((select id from ids where course_id = 'history' and source_no = 12))->>'need' = 'advanced', 'история требует «Продвинутую»');

-- базовая: грамматика вся, история — превью
set request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000002';
select pg_temp.check((select count(*) filter (where (u->>'locked')::boolean) = 0 from jsonb_array_elements(public.get_course('grammar')->'units') u),
  'базовая: вся грамматика открыта');
select pg_temp.check(public.get_unit((select id from ids where course_id = 'history' and source_no = 12))->>'error' = 'locked_tier', 'базовая: история (кроме превью) закрыта');

-- продвинутая
set request.jwt.claim.sub = 'ffffffff-0000-0000-0000-000000000003';
create temp table u9 as select public.get_unit((select id from ids where course_id = 'grammar' and source_no = 7)) as r;
select pg_temp.check((select jsonb_array_length(r->'tasks') = 5 from u9), 'тема: 5 заданий');
select pg_temp.check((select jsonb_array_length(r->'examples') = 8 from u9) and (select bool_and(x->>'match' ~* 'yap') from u9, jsonb_array_elements(r->'examples') x),
  'тема -yap: 8 примеров из словаря, в каждом найдено -yap');
select pg_temp.check((select jsonb_array_length(public.unit_examples((select id from ids where course_id = 'grammar' and source_no = 7), 8, 8)) = 8), 'ещё примеры (следующие 8)');
select pg_temp.check((select (r->>'prev_id') is not null and (r->>'next_id') is not null from u9), 'ссылки на предыдущую и следующую тему');
select pg_temp.check((public.mark_unit((select id from ids where course_id = 'grammar' and source_no = 7), true, null, null)->>'read')::boolean, 'отметка «прочитано»');
select pg_temp.check(public.mark_unit((select id from ids where course_id = 'grammar' and source_no = 7), null, 2, true)->'tasks_done' = '[2]', 'задание 2 выполнено');
select pg_temp.check(public.mark_unit((select id from ids where course_id = 'grammar' and source_no = 7), null, 4, true)->'tasks_done' = '[2, 4]', 'задание 4 выполнено');
select pg_temp.check(public.mark_unit((select id from ids where course_id = 'grammar' and source_no = 7), null, 2, false)->'tasks_done' = '[4]', 'снять отметку задания 2');
select pg_temp.check((select (c->>'read')::int = 1 from jsonb_array_elements(public.get_courses()) c where c->>'id' = 'grammar'), 'в списке курсов: 1 тема прочитана');
select pg_temp.check((select jsonb_array_length(c->'timeline') = 24 from (select public.get_course('history') c) x), 'история: хронология в курсе');
select pg_temp.check((select count(*) = 13 from jsonb_array_elements(public.get_course('civics')->'reference') r where r->>'kind' = 'contact'), 'обществознание: контакты в курсе');
select pg_temp.check(not has_table_privilege('authenticated', 'public.course_units', 'select') or
                     (select count(*) = 0 from public.course_units), 'тексты курсов не читаются напрямую — только через функции');
reset role;
