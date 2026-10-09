-- =============================================================================
-- Шаг 17: реферальная программа и купоны −5%
--   • У каждого пользователя своя ссылка t.me/uzbek_tutor_bot?start=ref_КОД.
--   • Новый пользователь, пришедший по ссылке, получает приветственный купон −5% (один раз).
--   • Когда приглашённый впервые оплачивает подписку, автор ссылки получает купон −5% (за каждого — один раз).
--   • Купон личный (передать нельзя), действует при оплате звёздами в приложении, срок не ограничен.
--   • Обычная подписка: на одну оплату — один купон (−5%).
--     Групповая (3 человека, уже −15%): купон снижает долю одного участника ещё на 5%;
--     на одну оплату — до 3 купонов (3 купона = ещё −5% на всю группу).
--   • Возврат платежа: использованные купоны возвращаются; купон автору ссылки за этот платёж
--     отменяется, если ещё не использован.
-- =============================================================================

alter table public.profiles add column if not exists ref_code text unique;
alter table public.profiles add column if not exists referred_by uuid references public.profiles(id) on delete set null;
alter table public.profiles add column if not exists referred_at timestamptz;
alter table public.payments add column if not exists coupons smallint not null default 0;

-- ссылка открыта в боте до первого входа в приложение — запоминаем по Telegram ID
create table if not exists public.pending_referrals (
  tg_id      bigint primary key,
  code       text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.coupons (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('welcome','referral')),
  pct         smallint not null default 5,
  source_user uuid references public.profiles(id) on delete set null,   -- кого пригласили (для referral)
  source_charge text,                                                    -- платёж приглашённого
  created_at  timestamptz not null default now(),
  used_at     timestamptz,
  used_charge text,
  revoked_at  timestamptz
);
create unique index if not exists coupons_referral_once on public.coupons (user_id, source_user) where kind = 'referral';
create unique index if not exists coupons_welcome_once on public.coupons (user_id) where kind = 'welcome';
alter table public.pending_referrals enable row level security;
alter table public.coupons enable row level security;
revoke all on public.pending_referrals, public.coupons from anon, authenticated;

insert into public.app_config (key, value, note) values
  ('coupon_pct', '5', 'Скидка одного реферального купона, %'),
  ('referral_window_hours', '72', 'Сколько часов после первого входа новичок может привязаться к пригласившему')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- код и привязка
create or replace function public.ensure_ref_code(p_user uuid)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  j int;
begin
  select ref_code into v_code from public.profiles where id = p_user;
  if v_code is not null then return v_code; end if;
  loop
    v_code := '';
    for j in 1..6 loop v_code := v_code || substr(v_alphabet, 1 + floor(random() * 32)::int, 1); end loop;
    exit when not exists (select 1 from public.profiles where ref_code = v_code);
  end loop;
  update public.profiles set ref_code = v_code where id = p_user;
  return v_code;
end
$$;

-- Привязать пользователя к пригласившему: только новичка (первые 72 часа после первого входа, без оплат),
-- не самого себя и только один раз. Новичок получает приветственный купон.
create or replace function public.ref_attach(p_user uuid, p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_me  public.profiles%rowtype;
  v_ref uuid;
begin
  select * into v_me from public.profiles where id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_user'); end if;
  if v_me.referred_by is not null then return jsonb_build_object('ok', false, 'error', 'already'); end if;
  select id into v_ref from public.profiles where ref_code = upper(btrim(coalesce(p_code, '')));
  if v_ref is null then return jsonb_build_object('ok', false, 'error', 'bad_code'); end if;
  if v_ref = p_user then return jsonb_build_object('ok', false, 'error', 'self'); end if;
  if v_me.created_at < now() - make_interval(hours => public.cfg_int('referral_window_hours', 72))
     or exists (select 1 from public.payments where user_id = p_user) then
    return jsonb_build_object('ok', false, 'error', 'not_new');
  end if;
  update public.profiles set referred_by = v_ref, referred_at = now() where id = p_user;
  insert into public.coupons (user_id, kind, pct, source_user)
  values (p_user, 'welcome', public.cfg_int('coupon_pct', 5), v_ref)
  on conflict do nothing;
  return jsonb_build_object('ok', true);
end
$$;

-- Бот: /start ref_КОД. Профиль уже есть — привязываем сразу, иначе запоминаем до первого входа.
create or replace function public.ref_remember(p_tg_id bigint, p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid;
begin
  select id into v_user from public.profiles where tg_id = p_tg_id;
  if v_user is not null then return public.ref_attach(v_user, p_code); end if;
  if not exists (select 1 from public.profiles where ref_code = upper(btrim(coalesce(p_code, '')))) then
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;
  insert into public.pending_referrals (tg_id, code) values (p_tg_id, upper(btrim(p_code)))
  on conflict (tg_id) do nothing;
  return jsonb_build_object('ok', true, 'pending', true);
end
$$;

-- Приложение: при входе (код из ссылки на мини-приложение или запомненный ботом)
create or replace function public.apply_referral(p_code text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_tg   bigint;
  v_code text := nullif(btrim(coalesce(p_code, '')), '');
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  select tg_id into v_tg from public.profiles where id = v_uid;
  if v_code is null then
    delete from public.pending_referrals where tg_id = v_tg returning code into v_code;
  else
    delete from public.pending_referrals where tg_id = v_tg;
  end if;
  if v_code is null then return jsonb_build_object('ok', false, 'error', 'no_code'); end if;
  v_code := regexp_replace(v_code, '^ref_', '', 'i');
  return public.ref_attach(v_uid, v_code);
end
$$;

-- Сводка для экрана «Подписка»
create or replace function public.get_referral_info()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  return jsonb_build_object(
    'code', public.ensure_ref_code(v_uid),
    'pct', public.cfg_int('coupon_pct', 5),
    'invited', (select count(*) from public.profiles where referred_by = v_uid),
    'paid', (select count(*) from public.coupons where user_id = v_uid and kind = 'referral' and revoked_at is null),
    'coupons', (select count(*) from public.coupons where user_id = v_uid and used_at is null and revoked_at is null),
    'welcome', exists (select 1 from public.coupons where user_id = v_uid and kind = 'welcome' and used_at is null and revoked_at is null),
    'used', (select count(*) from public.coupons where user_id = v_uid and used_at is not null and revoked_at is null),
    'referred', (select referred_by is not null from public.profiles where id = v_uid));
end
$$;

-- ---------------------------------------------------------------- цена с купонами
create or replace function public.coupons_available(p_user uuid)
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.coupons where user_id = p_user and used_at is null and revoked_at is null
$$;

-- Сколько купонов можно применить к тарифу: обычный — 1, групповой — по одному на участника (3)
create or replace function public.coupon_price(p_stars int, p_seats int, p_n int)
returns int language sql immutable as $$
  select greatest(1, p_stars - round(p_stars::numeric / greatest(p_seats, 1) * 0.05 * least(greatest(p_n, 0), greatest(p_seats, 1)))::int)
$$;

drop function if exists public.stars_invoice_data(uuid, integer);
create or replace function public.stars_invoice_data(p_user uuid, p_plan_id integer, p_coupons integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  p  public.plans%rowtype;
  pr public.profiles%rowtype;
  v_n int;
begin
  select * into p from public.plans where id = p_plan_id;
  select * into pr from public.profiles where id = p_user;
  if p.id is null or not p.is_active or coalesce(p.price_stars, 0) <= 0 or pr.id is null then
    return jsonb_build_object('error', 'bad_plan');
  end if;
  v_n := least(greatest(coalesce(p_coupons, 0), 0), p.seats, public.coupons_available(p_user));
  return jsonb_build_object('plan_id', p.id, 'tier', p.tier, 'months', p.months, 'seats', p.seats, 'coupons', v_n,
    'stars', public.coupon_price(p.price_stars, p.seats, v_n), 'full_stars', p.price_stars,
    'tg_id', pr.tg_id, 'ui_lang', pr.ui_lang);
end
$$;

-- payload: p:<plan>:<user>[:<купонов>]
create or replace function public.stars_check_plan(p_payload text, p_tg_id bigint, p_amount integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_parts text[] := string_to_array(coalesce(p_payload, ''), ':');
  v_plan  public.plans%rowtype;
  v_user  public.profiles%rowtype;
  v_n     int := 0;
begin
  if array_length(v_parts, 1) not in (3, 4) or v_parts[1] <> 'p' then
    return jsonb_build_object('ok', false, 'error', 'bad_payload');
  end if;
  begin
    select * into v_plan from public.plans where id = v_parts[2]::int;
    select * into v_user from public.profiles where id = v_parts[3]::uuid;
    if array_length(v_parts, 1) = 4 then v_n := v_parts[4]::int; end if;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_payload');
  end;
  if v_plan.id is null or not v_plan.is_active then return jsonb_build_object('ok', false, 'error', 'plan_inactive'); end if;
  if v_user.id is null or v_user.tg_id <> p_tg_id then return jsonb_build_object('ok', false, 'error', 'wrong_user'); end if;
  if v_n < 0 or v_n > v_plan.seats or v_n > public.coupons_available(v_user.id) then
    return jsonb_build_object('ok', false, 'error', 'coupons_changed');
  end if;
  if public.coupon_price(v_plan.price_stars, v_plan.seats, v_n) is distinct from p_amount then
    return jsonb_build_object('ok', false, 'error', 'price_changed');
  end if;
  return jsonb_build_object('ok', true, 'plan_id', v_plan.id, 'user_id', v_user.id);
end
$$;

create or replace function public.stars_grant_payment(p_payload text, p_tg_id bigint, p_amount integer, p_charge_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_check jsonb;
  v_plan  public.plans%rowtype;
  v_user  uuid;
  v_start timestamptz;
  v_end   timestamptz;
  v_sub   bigint;
  v_pay   public.payments%rowtype;
  v_parts text[] := string_to_array(coalesce(p_payload, ''), ':');
  v_codes jsonb := '[]'::jsonb;
  v_code  text;
  v_n     int := 0;
  v_used  int := 0;
  v_ref   jsonb;
  v_refu  uuid;
begin
  if p_charge_id is null or p_charge_id = '' then return jsonb_build_object('ok', false, 'error', 'no_charge_id'); end if;
  select * into v_pay from public.payments where charge_id = p_charge_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'tier', v_pay.tier,
      'ends_at', (select ends_at from public.subscriptions where id = v_pay.subscription_id));
  end if;

  if array_length(v_parts, 1) not in (3, 4) or v_parts[1] <> 'p' then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;
  select * into v_plan from public.plans where id = v_parts[2]::int;
  select id into v_user from public.profiles where id = v_parts[3]::uuid and tg_id = p_tg_id;
  if v_plan.id is null or v_user is null then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;
  if array_length(v_parts, 1) = 4 then v_n := least(greatest(v_parts[4]::int, 0), v_plan.seats); end if;

  v_check := public.grant_subscription(v_user, v_plan.tier, v_plan.months, 'stars', p_charge_id);
  v_sub := (v_check->>'sub_id')::bigint;
  v_start := (v_check->>'starts_at')::timestamptz;
  v_end := (v_check->>'ends_at')::timestamptz;

  -- купоны: сначала приветственный, потом по порядку получения
  with c as (
    select id from public.coupons
     where user_id = v_user and used_at is null and revoked_at is null
     order by (kind = 'welcome') desc, created_at, id
     limit v_n for update)
  update public.coupons k set used_at = now(), used_charge = p_charge_id from c where k.id = c.id;
  get diagnostics v_used = row_count;

  insert into public.payments (user_id, plan_id, tier, months, stars, charge_id, subscription_id, coupons)
  values (v_user, v_plan.id, v_plan.tier, v_plan.months, p_amount, p_charge_id, v_sub, v_used);

  -- первая оплата приглашённого → купон автору ссылки
  select referred_by into v_refu from public.profiles where id = v_user;
  if v_refu is not null and (select count(*) from public.payments where user_id = v_user) = 1 then
    insert into public.coupons (user_id, kind, pct, source_user, source_charge)
    values (v_refu, 'referral', public.cfg_int('coupon_pct', 5), v_user, p_charge_id)
    on conflict do nothing;
    if found then
      select jsonb_build_object('tg_id', p.tg_id, 'lang', p.ui_lang, 'coupons', public.coupons_available(p.id))
        into v_ref from public.profiles p where p.id = v_refu and not p.bot_blocked;
    end if;
  end if;

  -- групповая подписка: коды для друзей
  if v_plan.seats > 1 then
    for v_code in select * from public.admin_create_codes(v_plan.tier, v_plan.months, v_plan.seats - 1, 1,
                                                          now() + interval '1 year', 'group ' || p_charge_id, null) loop
      insert into public.group_codes (owner_id, code, tier, months, charge_id) values (v_user, v_code, v_plan.tier, v_plan.months, p_charge_id);
      v_codes := v_codes || to_jsonb(v_code);
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'tier', v_plan.tier, 'months', v_plan.months, 'seats', v_plan.seats,
                            'starts_at', v_start, 'ends_at', v_end, 'codes', v_codes, 'coupons_used', v_used, 'referrer', v_ref);
end
$$;

-- Возврат: купоны платежа возвращаются, купон автору ссылки отменяется (если не использован)
create or replace function public.coupons_on_refund()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'refunded' and old.status is distinct from 'refunded' then
    update public.coupons set used_at = null, used_charge = null where used_charge = new.charge_id;
    update public.coupons set revoked_at = now() where source_charge = new.charge_id and used_at is null and revoked_at is null;
  end if;
  return new;
end
$$;
drop trigger if exists payments_coupons_refund on public.payments;
create trigger payments_coupons_refund after update on public.payments
  for each row execute function public.coupons_on_refund();

create or replace function public.get_my_payments()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'tier', p.tier, 'months', p.months, 'stars', p.stars, 'status', p.status, 'created_at', p.created_at,
           'coupons', p.coupons, 'seats', pl.seats)
         order by p.created_at desc), '[]'::jsonb)
  from public.payments p left join public.plans pl on pl.id = p.plan_id where p.user_id = auth.uid()
$$;

-- ---------------------------------------------------------------- аналитика: рефералы
create or replace function public.admin_referrals()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_admin() then jsonb_build_object('error', 'forbidden') else jsonb_build_object(
    'invited', (select count(*) from public.profiles where referred_by is not null),
    'paid', (select count(*) from public.coupons where kind = 'referral' and revoked_at is null),
    'coupons_open', (select count(*) from public.coupons where used_at is null and revoked_at is null),
    'coupons_used', (select count(*) from public.coupons where used_at is not null and revoked_at is null),
    'top', (select coalesce(jsonb_agg(jsonb_build_object('name', t.first_name, 'username', t.username, 'invited', t.n, 'paid', t.paid) order by t.paid desc, t.n desc), '[]'::jsonb)
              from (select r.first_name, r.username, count(*) n,
                           (select count(*) from public.coupons c where c.user_id = r.id and c.kind = 'referral' and c.revoked_at is null) paid
                      from public.profiles p join public.profiles r on r.id = p.referred_by
                     group by r.id, r.first_name, r.username order by 4 desc, 3 desc limit 10) t)) end
$$;

-- ---------------------------------------------------------------- права
revoke execute on function public.ensure_ref_code(uuid) from public, anon, authenticated;
revoke execute on function public.ref_attach(uuid, text) from public, anon, authenticated;
revoke execute on function public.ref_remember(bigint, text) from public, anon, authenticated;
revoke execute on function public.coupons_available(uuid) from public, anon, authenticated;
revoke execute on function public.coupons_on_refund() from public, anon, authenticated;
revoke execute on function public.stars_invoice_data(uuid, integer, integer) from public, anon, authenticated;
revoke execute on function public.stars_check_plan(text, bigint, integer) from public, anon, authenticated;
revoke execute on function public.stars_grant_payment(text, bigint, integer, text) from public, anon, authenticated;
grant execute on function public.ref_remember(bigint, text) to service_role;
grant execute on function public.stars_invoice_data(uuid, integer, integer) to service_role;
grant execute on function public.stars_check_plan(text, bigint, integer) to service_role;
grant execute on function public.stars_grant_payment(text, bigint, integer, text) to service_role;

revoke execute on function public.apply_referral(text) from public, anon;
revoke execute on function public.get_referral_info() from public, anon;
revoke execute on function public.admin_referrals() from public, anon;
grant execute on function public.apply_referral(text) to authenticated;
grant execute on function public.get_referral_info() to authenticated;
grant execute on function public.admin_referrals() to authenticated;
