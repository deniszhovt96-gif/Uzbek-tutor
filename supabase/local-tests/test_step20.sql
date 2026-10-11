-- Проверка шага 20: групповая подписка не возвращается командой /refund; принудительный возврат (Telegram)
-- снимает подписку у покупателя и участников, отключает коды и предлагает личный тариф.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.group_codes where charge_id in ('g20-1', 'p20-1');
delete from public.payments where charge_id in ('g20-1', 'p20-1');
delete from public.profiles where tg_id in (2001, 2002, 2003);
insert into public.profiles (id, tg_id, first_name, ui_lang) values
  ('20010000-0000-0000-0000-000000000001', 2001, 'Owner', 'ru'),
  ('20020000-0000-0000-0000-000000000001', 2002, 'Member', 'uz'),
  ('20030000-0000-0000-0000-000000000001', 2003, 'Late', 'ru');
create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
create or replace function pg_temp.active(u uuid) returns boolean language sql as $$
  select exists (select 1 from public.subscriptions where user_id = u and starts_at <= now() and ends_at > now())
$$;

-- групповая «Базовая» на 3 месяца
select pg_temp.check((public.stars_grant_payment('p:' || id || ':20010000-0000-0000-0000-000000000001', 2001, price_stars, 'g20-1')->>'ok')::boolean,
                     'оплата группы') from public.plans where tier = 'basic' and months = 3 and seats = 3;
create temp table gc as select code from public.group_codes where charge_id = 'g20-1' order by id limit 1;
create temp table gc2 as select code from public.group_codes where charge_id = 'g20-1' order by id offset 1 limit 1;
grant select on gc, gc2 to authenticated;
set role authenticated;
set request.jwt.claim.sub = '20020000-0000-0000-0000-000000000001';
select pg_temp.check((public.redeem_code((select code from gc))->>'ok')::boolean, 'участник активировал код');
reset role;
select pg_temp.check(pg_temp.active('20010000-0000-0000-0000-000000000001') and pg_temp.active('20020000-0000-0000-0000-000000000001'), 'у обоих подписка');

-- /refund администратора: отказ
select pg_temp.check(public.stars_refund_payment('g20-1')->>'error' = 'group_no_refund', 'групповой платёж не возвращается');
select pg_temp.check((select status = 'paid' from public.payments where charge_id = 'g20-1'), 'платёж остался оплаченным');
select pg_temp.check(pg_temp.active('20020000-0000-0000-0000-000000000001'), 'у участника подписка сохранилась');

-- Telegram вернул звёзды сам: принудительно
create temp table rr as select public.stars_refund_payment('g20-1', true) r;
select pg_temp.check((select (r->>'ok')::boolean and (r->>'seats')::int = 3 from rr), 'принудительный возврат прошёл');
select pg_temp.check(not pg_temp.active('20010000-0000-0000-0000-000000000001'), 'у покупателя подписка снята');
select pg_temp.check(not pg_temp.active('20020000-0000-0000-0000-000000000001'), 'у участника подписка снята');
select pg_temp.check((select jsonb_array_length(r->'offers') = 2 from rr), 'два предложения личного тарифа');
select pg_temp.check((select bool_and(o->>'tier' = 'basic' and (o->>'months')::int = 3 and (o->>'stars')::int = (select price_stars from public.plans where tier = 'basic' and months = 3 and seats = 1))
                      from rr, jsonb_array_elements(r->'offers') o), 'предложение: личная «Базовая» на 3 мес.');
select pg_temp.check((select o->>'lang' = 'uz' from rr, jsonb_array_elements(r->'offers') o where o->>'role' = 'member'), 'язык участника');
set role authenticated;
set request.jwt.claim.sub = '20030000-0000-0000-0000-000000000001';
select pg_temp.check(not coalesce((public.redeem_code((select code from gc2))->>'ok')::boolean, false), 'неактивированный код отключён');
set request.jwt.claim.sub = '20010000-0000-0000-0000-000000000001';
select pg_temp.check((select bool_and((x->>'revoked')::boolean) from jsonb_array_elements(public.get_group_codes()) x), 'коды помечены отменёнными');
reset role;
select pg_temp.check(public.stars_refund_payment('g20-1', true)->>'duplicate' = 'true', 'повторный возврат ничего не меняет');

-- личная подписка по-прежнему возвращается
select pg_temp.check((public.stars_grant_payment('p:' || id || ':20030000-0000-0000-0000-000000000001', 2003, price_stars, 'p20-1')->>'ok')::boolean,
                     'личная оплата') from public.plans where tier = 'basic' and months = 1 and seats = 1;
select pg_temp.check((public.stars_refund_payment('p20-1')->>'ok')::boolean, 'личный платёж возвращается');
select pg_temp.check(not pg_temp.active('20030000-0000-0000-0000-000000000001'), 'личная подписка снята');

delete from public.group_codes where charge_id in ('g20-1', 'p20-1');
delete from public.payments where charge_id in ('g20-1', 'p20-1');
delete from public.profiles where tg_id in (2001, 2002, 2003);
