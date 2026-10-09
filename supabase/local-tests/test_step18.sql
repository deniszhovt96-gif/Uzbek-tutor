-- Проверка шага 18: сданный тест уровня открывает времена и падежи тем грамматики этого уровня.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id = 1801;
insert into public.profiles (id, tg_id, first_name) values ('18010000-0000-0000-0000-000000000001', 1801, 'Test');
create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
select pg_temp.check((public.morph_state('18010000-0000-0000-0000-000000000001')->>'conj_cap')::int = 1, 'без тестов и тем: потолок 1');
insert into public.level_test_attempts (user_id, cefr, questions, total, score, passed, finished_at)
values ('18010000-0000-0000-0000-000000000001', 'A1', '[]', 35, 33, true, now());
select pg_temp.check((public.morph_state('18010000-0000-0000-0000-000000000001')->'grammar') @> '[3,5,7,8,9,10,11]', 'тест A1: темы A1 засчитаны');
select pg_temp.check(not ((public.morph_state('18010000-0000-0000-0000-000000000001')->'grammar') @> '[6]'), 'тест A1: тема A2 (-gan) ещё закрыта');
select pg_temp.check((public.morph_state('18010000-0000-0000-0000-000000000001')->>'decl_cap')::int = 15, 'тест A1: склонение — потолок 15');
insert into public.level_test_attempts (user_id, cefr, questions, total, score, passed, finished_at)
values ('18010000-0000-0000-0000-000000000001', 'B2', '[]', 35, 33, true, now());
select pg_temp.check((public.morph_state('18010000-0000-0000-0000-000000000001')->>'conj_cap')::int = 15, 'тест B2: спряжение — потолок 15');
insert into public.study_sessions (user_id, local_day, mode, tier, word_ids, finished_at)
values ('18010000-0000-0000-0000-000000000001', public.user_today('18010000-0000-0000-0000-000000000001'), 'normal', 'free', '{}', now());
set role authenticated;
set request.jwt.claim.sub = '18010000-0000-0000-0000-000000000001';
select pg_temp.check(coalesce(public.get_next_step()->'next'->>'course', '') <> 'grammar', 'рекомендации не предлагают грамматику подтверждённого уровня');
reset role;
delete from public.profiles where tg_id = 1801;
