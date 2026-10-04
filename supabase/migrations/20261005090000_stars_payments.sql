-- =============================================================================
-- Шаг 8: оплата подписки звёздами Telegram (валюта XTR).
--
--   1. Приложение просит у бота ссылку на счёт (telegram-bot/invoice) → createInvoiceLink.
--   2. Telegram присылает pre_checkout_query → бот проверяет тариф и цену (stars_check_plan).
--   3. Telegram присылает successful_payment → бот вызывает stars_grant_payment:
--      платёж записывается один раз (по telegram_payment_charge_id), подписка продлевается
--      с даты окончания текущей подписки того же уровня.
--   Возврат: команда администратора /refund <id платежа> → refundStarPayment + stars_refund_payment.
-- =============================================================================

create table if not exists public.payments (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  plan_id      int not null references public.plans(id),
  tier         text not null check (tier in ('basic','advanced')),
  months       smallint not null,
  stars        int not null check (stars > 0),
  charge_id    text not null unique,            -- telegram_payment_charge_id
  status       text not null default 'paid' check (status in ('paid','refunded')),
  subscription_id bigint references public.subscriptions(id),
  created_at   timestamptz not null default now(),
  refunded_at  timestamptz
);
create index if not exists payments_user_idx on public.payments (user_id, created_at desc);
alter table public.payments enable row level security;
revoke insert, update, delete, truncate on public.payments from anon, authenticated;
grant select on public.payments to authenticated;
drop policy if exists payments_own on public.payments;
create policy payments_own on public.payments for select to authenticated using (user_id = auth.uid());

-- Данные для счёта: тариф активен и у него есть цена в звёздах
create or replace function public.stars_invoice_data(p_user uuid, p_plan_id int)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when p.id is null or not p.is_active or coalesce(p.price_stars, 0) <= 0 or pr.id is null
              then jsonb_build_object('error', 'bad_plan')
              else jsonb_build_object('plan_id', p.id, 'tier', p.tier, 'months', p.months,
                                      'stars', p.price_stars, 'tg_id', pr.tg_id, 'ui_lang', pr.ui_lang) end
  from (select 1) one
  left join public.plans p on p.id = p_plan_id
  left join public.profiles pr on pr.id = p_user
$$;

-- Проверка перед оплатой: payload = 'p:<plan_id>:<user uuid>'
create or replace function public.stars_check_plan(p_payload text, p_tg_id bigint, p_amount int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_parts text[] := string_to_array(coalesce(p_payload, ''), ':');
  v_plan  public.plans%rowtype;
  v_user  public.profiles%rowtype;
begin
  if array_length(v_parts, 1) <> 3 or v_parts[1] <> 'p' then
    return jsonb_build_object('ok', false, 'error', 'bad_payload');
  end if;
  begin
    select * into v_plan from public.plans where id = v_parts[2]::int;
    select * into v_user from public.profiles where id = v_parts[3]::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_payload');
  end;
  if v_plan.id is null or not v_plan.is_active then return jsonb_build_object('ok', false, 'error', 'plan_inactive'); end if;
  if v_user.id is null or v_user.tg_id <> p_tg_id then return jsonb_build_object('ok', false, 'error', 'wrong_user'); end if;
  if v_plan.price_stars is distinct from p_amount then return jsonb_build_object('ok', false, 'error', 'price_changed'); end if;
  return jsonb_build_object('ok', true, 'plan_id', v_plan.id, 'user_id', v_user.id);
end
$$;

-- Зачисление оплаты (вызывает бот после successful_payment). Повторный вызов с тем же charge_id ничего не меняет.
create or replace function public.stars_grant_payment(p_payload text, p_tg_id bigint, p_amount int, p_charge_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_check jsonb;
  v_plan  public.plans%rowtype;
  v_user  uuid;
  v_start timestamptz;
  v_end   timestamptz;
  v_sub   bigint;
  v_pay   public.payments%rowtype;
  v_parts text[] := string_to_array(coalesce(p_payload, ''), ':');
begin
  if p_charge_id is null or p_charge_id = '' then return jsonb_build_object('ok', false, 'error', 'no_charge_id'); end if;
  select * into v_pay from public.payments where charge_id = p_charge_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'tier', v_pay.tier,
      'ends_at', (select ends_at from public.subscriptions where id = v_pay.subscription_id));
  end if;

  -- деньги уже списаны: цену не сверяем строго (могла измениться между счётом и оплатой), записываем фактическую сумму
  if array_length(v_parts, 1) <> 3 or v_parts[1] <> 'p' then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;
  select * into v_plan from public.plans where id = v_parts[2]::int;
  select id into v_user from public.profiles where id = v_parts[3]::uuid and tg_id = p_tg_id;
  if v_plan.id is null or v_user is null then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;

  perform pg_advisory_xact_lock(hashtext('stars:' || v_user::text));
  select greatest(now(), coalesce(max(ends_at), now())) into v_start
    from public.subscriptions where user_id = v_user and tier = v_plan.tier and ends_at > now();
  v_end := v_start + make_interval(months => v_plan.months);

  insert into public.subscriptions (user_id, tier, starts_at, ends_at, source, source_ref)
  values (v_user, v_plan.tier, v_start, v_end, 'stars', p_charge_id)
  returning id into v_sub;
  insert into public.payments (user_id, plan_id, tier, months, stars, charge_id, subscription_id)
  values (v_user, v_plan.id, v_plan.tier, v_plan.months, p_amount, p_charge_id, v_sub);

  return jsonb_build_object('ok', true, 'tier', v_plan.tier, 'months', v_plan.months, 'starts_at', v_start, 'ends_at', v_end);
end
$$;

-- Возврат: подписка из этого платежа прекращается сейчас, следующие подписки того же уровня сдвигаются назад
create or replace function public.stars_refund_payment(p_charge_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_pay  public.payments%rowtype;
  v_sub  public.subscriptions%rowtype;
  v_cut  interval;
  v_tg   bigint;
begin
  select * into v_pay from public.payments where charge_id = p_charge_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select tg_id into v_tg from public.profiles where id = v_pay.user_id;
  if v_pay.status = 'refunded' then return jsonb_build_object('ok', true, 'duplicate', true, 'tg_id', v_tg); end if;
  select * into v_sub from public.subscriptions where id = v_pay.subscription_id for update;
  if found then
    -- сколько ещё оставалось оплачено этим платежом
    v_cut := v_sub.ends_at - greatest(now(), v_sub.starts_at);
    if v_sub.starts_at >= now() then
      delete from public.subscriptions where id = v_sub.id;
      update public.payments set subscription_id = null where id = v_pay.id;
    elsif v_sub.ends_at > now() then
      update public.subscriptions set ends_at = greatest(now(), starts_at + interval '1 second') where id = v_sub.id;
    end if;
    if v_cut > interval '0' then
      update public.subscriptions set starts_at = starts_at - v_cut, ends_at = ends_at - v_cut
       where user_id = v_pay.user_id and tier = v_pay.tier and starts_at >= v_sub.ends_at and id <> v_sub.id;
    end if;
  end if;
  update public.payments set status = 'refunded', refunded_at = now() where id = v_pay.id;
  return jsonb_build_object('ok', true, 'tg_id', v_tg, 'stars', v_pay.stars);
end
$$;

-- Мои платежи (для экрана подписки)
create or replace function public.get_my_payments()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'tier', p.tier, 'months', p.months, 'stars', p.stars, 'status', p.status, 'created_at', p.created_at)
         order by p.created_at desc), '[]'::jsonb)
  from public.payments p where p.user_id = auth.uid()
$$;

-- Активные тарифы с id — приложению нужен id для счёта
create or replace function public.get_plans()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'tier', tier, 'months', months, 'price_stars', price_stars, 'price_uzs', price_uzs, 'price_usd', price_usd)
         order by tier desc, months), '[]'::jsonb)
  from public.plans where is_active
$$;

revoke execute on function public.stars_invoice_data(uuid, int) from public, anon, authenticated;
revoke execute on function public.stars_check_plan(text, bigint, int) from public, anon, authenticated;
revoke execute on function public.stars_grant_payment(text, bigint, int, text) from public, anon, authenticated;
revoke execute on function public.stars_refund_payment(text) from public, anon, authenticated;
revoke execute on function public.get_my_payments() from public, anon;
grant execute on function public.stars_invoice_data(uuid, int) to service_role;
grant execute on function public.stars_check_plan(text, bigint, int) to service_role;
grant execute on function public.stars_grant_payment(text, bigint, int, text) to service_role;
grant execute on function public.stars_refund_payment(text) to service_role;
grant execute on function public.get_my_payments() to authenticated;
grant execute on function public.get_plans() to anon, authenticated;
