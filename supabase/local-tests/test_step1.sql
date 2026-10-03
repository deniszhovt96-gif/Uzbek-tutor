-- Проверка шага 1: RLS, подписки, коды. Запускается локально после local_stubs.sql и миграций.
\set ON_ERROR_STOP 1
insert into public.profiles (id, tg_id, first_name) values
  ('11111111-1111-1111-1111-111111111111', 1001, 'Alice'),
  ('22222222-2222-2222-2222-222222222222', 1002, 'Bob');
insert into public.topics values (1, 1, 'Местоимения', null, null, 'A1', 1);
insert into public.words (id, topic_id, cefr, uz, ru, uz_key, sort_key) values (1, 1, 'A1', 'men', 'я', 'men', 1);
insert into public.word_progress (user_id, word_id, due_on) values
  ('11111111-1111-1111-1111-111111111111', 1, current_date),
  ('22222222-2222-2222-2222-222222222222', 1, current_date);

-- коды генерирует сервер (service_role)
set role service_role;
create temp table codes as select * from public.admin_create_codes('basic', 1, 2, 1, null, 'test', 182665947) c;
create temp table codes_adv as select * from public.admin_create_codes('advanced', 3, 1, 2) c;
reset role;
select 'codes format ok' as t, bool_and(c ~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$') from codes;
select 'hash only stored', count(*) = 0 from public.access_codes a join codes c on a.code_hash = c.c;
grant select on codes, codes_adv to authenticated;

-- обычный пользователь не может генерировать коды
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$ begin
  perform public.admin_create_codes('basic',1,1);
  raise exception 'FAIL: authenticated created codes';
exception when insufficient_privilege then raise notice 'ok: admin_create_codes denied';
end $$;

-- RLS: Alice видит только свой прогресс
select 'alice sees own progress only', count(*) = 1 from public.word_progress;
select 'alice sees 1 profile', count(*) = 1 from public.profiles;
select 'alice cannot see codes', count(*) = 0 from public.access_codes;
do $$ begin
  update public.word_progress set level = 15;
  raise exception 'FAIL: direct update allowed';
exception when insufficient_privilege then raise notice 'ok: direct update denied';
end $$;
select 'tier before', public.current_tier() = 'free';

-- активация: строчные буквы и пробелы не мешают
select 'redeem ok', (public.redeem_code(lower(replace((select c from codes limit 1), '-', ' '))))->>'ok' = 'true';
select 'tier basic', public.current_tier() = 'basic';
select 'second time same code', (public.redeem_code((select c from codes limit 1)))->>'error' = 'already_redeemed';
-- второй код того же уровня продлевает с даты окончания
select 'extend ok', (public.redeem_code((select c from codes offset 1 limit 1)))->>'ok' = 'true';
select 'two subs chained', (select max(ends_at)::date from public.subscriptions) = (now() + interval '2 months')::date;
select 'advanced ok', (public.redeem_code((select c from codes_adv)))->>'ok' = 'true';
select 'tier advanced', public.current_tier() = 'advanced';

-- Bob: код basic уже израсходован (max_uses=1); advanced допускает 2 использования
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select 'bob sees own progress only', count(*) = 1 from public.word_progress where user_id = '22222222-2222-2222-2222-222222222222';
select 'bob cannot see alice subs', count(*) = 0 from public.subscriptions;
select 'used up', (public.redeem_code((select c from codes limit 1)))->>'error' = 'code_used_up';
select 'bob adv ok', (public.redeem_code((select c from codes_adv)))->>'ok' = 'true';
-- перебор: после 5 неудачных попыток — блок на час
select public.redeem_code('AAAA-AAAA-AAA' || g) from generate_series(1,4) g;
select 'blocked after 5 fails', (public.redeem_code('ZZZZ-ZZZZ-ZZZZ'))->>'error' = 'too_many_attempts';

-- без входа
reset request.jwt.claim.sub;
set role anon;
select 'anon sees 8 plans', count(*) = 8 from public.plans;
select 'anon sees no words', count(*) = 0 from public.words;
do $$ begin
  perform public.redeem_code('X');
  raise exception 'FAIL: anon redeem allowed';
exception when insufficient_privilege then raise notice 'ok: anon redeem denied';
end $$;
reset role;
