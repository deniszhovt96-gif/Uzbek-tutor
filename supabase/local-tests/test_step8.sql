-- Проверка шага 8: оплата звёздами.
\set ON_ERROR_STOP 1
\pset tuples_only on
delete from public.profiles where tg_id in (8001, 8002);
insert into public.profiles (id, tg_id, first_name) values
  ('eeeeeeee-0000-0000-0000-000000000001', 8001, 'Buyer'),
  ('eeeeeeee-0000-0000-0000-000000000002', 8002, 'Other');

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;

create temp table pl as select id, price_stars from public.plans where tier = 'basic' and months = 1;
create temp table pa as select id, price_stars from public.plans where tier = 'advanced' and months = 3;
grant select on pl, pa to service_role, authenticated;
set role service_role;

select pg_temp.check((public.stars_invoice_data('eeeeeeee-0000-0000-0000-000000000001', (select id from pl))->>'stars')::int = (select price_stars from pl),
  'данные счёта: цена тарифа в звёздах');
select pg_temp.check(public.stars_invoice_data('eeeeeeee-0000-0000-0000-000000000001', 99999)->>'error' = 'bad_plan', 'несуществующий тариф — отказ');

-- проверка перед оплатой
select pg_temp.check((public.stars_check_plan('p:' || (select id from pl) || ':eeeeeeee-0000-0000-0000-000000000001', 8001, (select price_stars from pl))->>'ok')::boolean,
  'pre_checkout: верный тариф, пользователь и цена');
select pg_temp.check(public.stars_check_plan('p:' || (select id from pl) || ':eeeeeeee-0000-0000-0000-000000000001', 8002, (select price_stars from pl))->>'error' = 'wrong_user',
  'pre_checkout: оплата за другого пользователя — отказ');
select pg_temp.check(public.stars_check_plan('p:' || (select id from pl) || ':eeeeeeee-0000-0000-0000-000000000001', 8001, 1)->>'error' = 'price_changed',
  'pre_checkout: цена изменилась — отказ');
select pg_temp.check(public.stars_check_plan('garbage', 8001, 1)->>'error' = 'bad_payload', 'pre_checkout: мусор — отказ');

-- оплата
create temp table g1 as select public.stars_grant_payment('p:' || (select id from pl) || ':eeeeeeee-0000-0000-0000-000000000001', 8001, (select price_stars from pl), 'charge-1') as r;
select pg_temp.check((select (r->>'ok')::boolean and r->>'tier' = 'basic' from g1), 'оплата: базовая подписка выдана');
select pg_temp.check((select public.stars_grant_payment('p:' || (select id from pl) || ':eeeeeeee-0000-0000-0000-000000000001', 8001, (select price_stars from pl), 'charge-1')->>'duplicate' = 'true'),
  'повтор того же платежа не продлевает второй раз');
select pg_temp.check((select count(*) = 1 from public.subscriptions where user_id = 'eeeeeeee-0000-0000-0000-000000000001'), 'одна подписка');
-- вторая оплата того же уровня продлевает с конца первой
create temp table g2 as select public.stars_grant_payment('p:' || (select id from pl) || ':eeeeeeee-0000-0000-0000-000000000001', 8001, (select price_stars from pl), 'charge-2') as r;
select pg_temp.check((select (g2.r->>'starts_at')::timestamptz = (g1.r->>'ends_at')::timestamptz from g1, g2), 'продление начинается с конца текущей подписки');
-- продвинутая
select pg_temp.check(public.stars_grant_payment('p:' || (select id from pa) || ':eeeeeeee-0000-0000-0000-000000000001', 8001, (select price_stars from pa), 'charge-3')->>'tier' = 'advanced',
  'продвинутая подписка поверх базовой');

reset role;
set role authenticated;
set request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000001';
select pg_temp.check(public.current_tier() = 'advanced', 'действующий уровень — продвинутая');
select pg_temp.check(jsonb_array_length(public.get_my_payments()) = 3, 'видны свои 3 платежа');
select pg_temp.check((select count(*) = 3 from public.payments), 'RLS: в таблице видны только свои платежи');
set request.jwt.claim.sub = 'eeeeeeee-0000-0000-0000-000000000002';
select pg_temp.check((select count(*) = 0 from public.payments), 'RLS: чужие платежи не видны');
select pg_temp.check(not has_function_privilege('authenticated', 'public.stars_grant_payment(text,bigint,int,text)', 'execute'), 'пользователь не может зачислить себе оплату');
reset role;

-- возврат первого платежа: вторая базовая подписка сдвигается назад
set role service_role;
create temp table before as select ends_at from public.subscriptions where source_ref = 'charge-2';
grant select on before to service_role;
select pg_temp.check((public.stars_refund_payment('charge-1')->>'tg_id')::bigint = 8001, 'возврат: найден пользователь');
select pg_temp.check((select s.ends_at < b.ends_at - interval '27 days' from public.subscriptions s, before b where s.source_ref = 'charge-2'),
  'после возврата следующая подписка сдвинута на неиспользованный срок');
select pg_temp.check((select status = 'refunded' from public.payments where charge_id = 'charge-1'), 'платёж отмечен как возвращённый');
select pg_temp.check(public.stars_refund_payment('charge-1')->>'duplicate' = 'true', 'повторный возврат ничего не меняет');
-- возврат продления, которое ещё не началось (оплачено «вперёд»)
select pg_temp.check((public.stars_grant_payment('p:' || (select id from pl) || ':eeeeeeee-0000-0000-0000-000000000001', 8001, (select price_stars from pl), 'charge-4')->>'starts_at')::timestamptz > now(),
  'оплата продления вперёд');
select pg_temp.check((public.stars_refund_payment('charge-4')->>'ok')::boolean, 'возврат будущего продления проходит');
select pg_temp.check((select subscription_id is null and status = 'refunded' from public.payments where charge_id = 'charge-4'), 'будущая подписка удалена, платёж возвращён');
reset role;
select pg_temp.check(jsonb_array_length(public.get_plans()) = 8, 'get_plans: 8 тарифов с id');
