-- Проверка шага 19: «сначала разговорная речь», темы курсов на карте, состояние спряжения, данные для «Поделиться».
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id = 1901;
insert into public.profiles (id, tg_id, first_name) values ('19010000-0000-0000-0000-000000000001', 1901, 'Col');
create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
set role authenticated;
set request.jwt.claim.sub = '19010000-0000-0000-0000-000000000001';
select pg_temp.check(jsonb_array_length(public.get_path_courses()) = 89, 'на карте 89 тем курсов (без диалогов)');
select pg_temp.check((select bool_and((x->>'course') in ('grammar','culture','civics','history')) from jsonb_array_elements(public.get_path_courses()) x), 'только 4 курса');
select pg_temp.check((public.get_morph_state()->>'conj_cap')::int = 1, 'get_morph_state: потолок 1 для новичка');
select pg_temp.check((public.update_settings(null, '{"colloquial_first": true}')->'settings'->>'colloquial_first')::boolean, 'настройка «сначала разговорные»');
create temp table s1 as select public.start_session('normal') s;
reset role;
select pg_temp.check((select bool_and(w.register = 'colloquial') from s1, jsonb_array_elements(s->'items') x join public.words w on w.id = (x->>'id')::int
                      where (x->>'stage') = 'new'), 'новые слова — сначала разговорные');
select pg_temp.check((public.ref_share_data('19010000-0000-0000-0000-000000000001')->>'image') = 'promo', 'картинка для «Поделиться» — из настроек');
select pg_temp.check(length(public.ref_share_data('19010000-0000-0000-0000-000000000001')->>'code') = 6, 'код ссылки создан');
delete from public.profiles where tg_id = 1901;
