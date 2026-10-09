-- Проверка шага 17: реферальная ссылка, купоны −5%, обычная и групповая оплата, возврат.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (1701, 1702, 1703);
insert into public.profiles (id, tg_id, first_name) values
  ('17010000-0000-0000-0000-000000000001', 1701, 'Author'),
  ('17020000-0000-0000-0000-000000000001', 1702, 'Friend'),
  ('17030000-0000-0000-0000-000000000001', 1703, 'Old');
update public.profiles set created_at = now() - interval '10 days' where tg_id = 1703;
create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
create temp table pl as select id, price_stars from public.plans where tier = 'basic' and months = 1 and seats = 1;
create temp table pg as select id, price_stars from public.plans where tier = 'basic' and months = 1 and seats = 3;

set role authenticated;
set request.jwt.claim.sub = '17010000-0000-0000-0000-000000000001';
create temp table ri as select public.get_referral_info() r;
select pg_temp.check((select length(r->>'code') = 6 from ri), 'у пользователя есть код ссылки');
reset role;
select pg_temp.check((public.ref_attach('17020000-0000-0000-0000-000000000001', (select r->>'code' from ri))->>'ok')::boolean, 'новичок привязан по ссылке');
select pg_temp.check((public.ref_attach('17020000-0000-0000-0000-000000000001', (select r->>'code' from ri))->>'error') = 'already', 'повторно не привязывается');
select pg_temp.check((public.ref_attach('17010000-0000-0000-0000-000000000001', (select r->>'code' from ri))->>'error') = 'self', 'свою ссылку нельзя');
select pg_temp.check((public.ref_attach('17030000-0000-0000-0000-000000000001', (select r->>'code' from ri))->>'error') = 'not_new', 'давний пользователь не привязывается');
select pg_temp.check(public.coupons_available('17020000-0000-0000-0000-000000000001') = 1, 'новичок: приветственный купон');

-- цена с купоном
select pg_temp.check((public.stars_invoice_data('17020000-0000-0000-0000-000000000001', (select id from pl), 1)->>'stars')::int
                     = (select price_stars - round(price_stars * 0.05) from pl), 'обычная подписка: −5%');
select pg_temp.check((public.stars_invoice_data('17020000-0000-0000-0000-000000000001', (select id from pl), 3)->>'coupons')::int = 1,
  'обычная подписка: не больше 1 купона (и не больше, чем есть)');
select pg_temp.check(public.coupon_price(3000, 3, 3) = 2850 and public.coupon_price(3000, 3, 1) = 2950, 'групповая: купон −5% на долю одного участника');
select pg_temp.check((public.stars_check_plan('p:' || (select id from pl) || ':17020000-0000-0000-0000-000000000001:2', 1702,
                      (select price_stars from pl))->>'error') = 'coupons_changed', 'нельзя применить больше купонов, чем есть');

-- оплата новичка с купоном → купон автору
create temp table pay1 as select public.stars_grant_payment('p:' || (select id from pl) || ':17020000-0000-0000-0000-000000000001:1', 1702,
  (select price_stars - round(price_stars * 0.05) from pl)::int, 'ref-test-1') r;
select pg_temp.check((select (r->>'coupons_used')::int = 1 and (r->'referrer'->>'tg_id')::bigint = 1701 from pay1), 'купон новичка использован, автору — сообщение');
select pg_temp.check(public.coupons_available('17010000-0000-0000-0000-000000000001') = 1, 'автор получил купон');
select public.stars_grant_payment('p:' || (select id from pl) || ':17020000-0000-0000-0000-000000000001', 1702, (select price_stars from pl), 'ref-test-2');
select pg_temp.check(public.coupons_available('17010000-0000-0000-0000-000000000001') = 1, 'за повторную оплату друга купона нет');

-- возврат первой оплаты: купон новичка вернулся, купон автора отменён
select public.stars_refund_payment('ref-test-1');
select pg_temp.check(public.coupons_available('17020000-0000-0000-0000-000000000001') = 1, 'возврат: купон новичка вернулся');
select pg_temp.check(public.coupons_available('17010000-0000-0000-0000-000000000001') = 0, 'возврат: купон автора отменён');

-- групповая оплата: 3 купона нужны, чтобы −5% получили все
insert into public.coupons (user_id, kind, source_user) select '17010000-0000-0000-0000-000000000001', 'referral', id
  from public.profiles where tg_id in (1702, 1703) on conflict do nothing;
update public.coupons set revoked_at = null where user_id = '17010000-0000-0000-0000-000000000001';
select pg_temp.check(public.coupons_available('17010000-0000-0000-0000-000000000001') = 2, 'у автора 2 купона');
select pg_temp.check((public.stars_invoice_data('17010000-0000-0000-0000-000000000001', (select id from pg), 3)->>'coupons')::int = 2,
  'групповая: применяется столько купонов, сколько есть (до 3)');
select pg_temp.check((select (public.stars_grant_payment('p:' || (select id from pg) || ':17010000-0000-0000-0000-000000000001:2', 1701,
                      public.coupon_price((select price_stars from pg), 3, 2), 'ref-test-3')->>'coupons_used')::int = 2), 'групповая оплата с 2 купонами');
select pg_temp.check(public.coupons_available('17010000-0000-0000-0000-000000000001') = 0, 'купоны израсходованы');

delete from public.group_codes where charge_id like 'ref-test-%';
delete from public.payments where charge_id like 'ref-test-%';
delete from public.profiles where tg_id in (1701, 1702, 1703);
