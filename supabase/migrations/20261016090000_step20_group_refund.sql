-- Шаг 20: групповая подписка возврату не подлежит.
--   • /refund администратора для группового платежа отказывает (stars_refund_payment → error 'group_no_refund').
--   • Если Telegram всё же вернул звёзды (поддержка, спор) — бот вызывает stars_refund_payment(…, true):
--     подписка снимается у покупателя и у всех, кто активировал коды группы; неактивированные коды отключаются.
--     Каждому возвращается подходящий личный тариф (тот же уровень, срок ≥ оставшегося), бот предлагает его оформить.

-- Обрезать одну подписку «на сейчас» и сдвинуть следующие за ней подписки того же уровня. Возвращает снятый остаток.
create or replace function public.cut_subscription(p_sub_id bigint)
returns interval language plpgsql volatile security definer set search_path = '' as $$
declare
  v_sub public.subscriptions%rowtype;
  v_cut interval;
begin
  select * into v_sub from public.subscriptions where id = p_sub_id for update;
  if not found then return interval '0'; end if;
  v_cut := v_sub.ends_at - greatest(now(), v_sub.starts_at);
  if v_sub.starts_at >= now() then
    update public.payments set subscription_id = null where subscription_id = v_sub.id;
    update public.code_redemptions set subscription_id = null where subscription_id = v_sub.id;
    delete from public.subscriptions where id = v_sub.id;
  elsif v_sub.ends_at > now() then
    update public.subscriptions set starts_at = least(starts_at, now() - interval '1 second'), ends_at = now() where id = v_sub.id;
  end if;
  if v_cut > interval '0' then
    update public.subscriptions set starts_at = starts_at - v_cut, ends_at = ends_at - v_cut
     where user_id = v_sub.user_id and tier = v_sub.tier and starts_at >= v_sub.ends_at and id <> v_sub.id;
    if v_sub.tier = 'advanced' then
      update public.subscriptions set starts_at = greatest(now(), starts_at - v_cut), ends_at = greatest(now() + interval '1 second', ends_at - v_cut)
       where user_id = v_sub.user_id and tier = 'basic' and starts_at >= now();
      update public.subscriptions set ends_at = greatest(now(), ends_at - v_cut)
       where user_id = v_sub.user_id and tier = 'basic' and starts_at < now() and ends_at > now();
    end if;
  end if;
  return greatest(v_cut, interval '0');
end
$$;

-- Личный тариф того же уровня, срок которого покрывает оставшиеся дни
create or replace function public.personal_offer(p_user uuid, p_tier text, p_left interval)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('tg_id', pr.tg_id, 'lang', pr.ui_lang, 'tier', p.tier, 'months', p.months,
                            'stars', p.price_stars, 'plan_id', p.id, 'days_left', ceil(extract(epoch from p_left) / 86400)::int)
  from public.profiles pr
  cross join lateral (
    select * from public.plans
     where tier = p_tier and seats = 1 and is_active
     order by (now() + make_interval(months => months) + interval '1 day' < now() + p_left), months
     limit 1) p
  where pr.id = p_user and not coalesce(pr.bot_blocked, false)
$$;

drop function if exists public.stars_refund_payment(text);
create or replace function public.stars_refund_payment(p_charge_id text, p_forced boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_pay    public.payments%rowtype;
  v_seats  int;
  v_tg     bigint;
  v_left   interval;
  v_offers jsonb := '[]'::jsonb;
  v_off    jsonb;
  r        record;
begin
  select * into v_pay from public.payments where charge_id = p_charge_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select tg_id into v_tg from public.profiles where id = v_pay.user_id;
  if v_pay.status = 'refunded' then return jsonb_build_object('ok', true, 'duplicate', true, 'tg_id', v_tg); end if;
  select coalesce(seats, 1) into v_seats from public.plans where id = v_pay.plan_id;
  v_seats := coalesce(v_seats, 1);
  if v_seats > 1 and not p_forced then
    return jsonb_build_object('ok', false, 'error', 'group_no_refund', 'tg_id', v_tg);
  end if;

  v_left := public.cut_subscription(v_pay.subscription_id);
  if v_seats > 1 and v_left > interval '0' then
    v_off := public.personal_offer(v_pay.user_id, v_pay.tier, v_left);
    if v_off is not null then v_offers := v_offers || jsonb_build_array(v_off || '{"role":"owner"}'); end if;
  end if;

  if v_seats > 1 then
    for r in
      select a.id as code_id, cr.user_id, cr.subscription_id
        from public.group_codes g
        join public.access_codes a on a.code_hash = public.hash_code(replace(g.code, '-', ''))
        left join public.code_redemptions cr on cr.code_id = a.id
       where g.charge_id = p_charge_id
    loop
      update public.access_codes set is_active = false where id = r.code_id;
      if r.subscription_id is not null then
        v_left := public.cut_subscription(r.subscription_id);
        if v_left > interval '0' then
          v_off := public.personal_offer(r.user_id, v_pay.tier, v_left);
          if v_off is not null then v_offers := v_offers || jsonb_build_array(v_off || '{"role":"member"}'); end if;
        end if;
      end if;
    end loop;
  end if;

  update public.payments set status = 'refunded', refunded_at = now() where id = v_pay.id;
  return jsonb_build_object('ok', true, 'tg_id', v_tg, 'stars', v_pay.stars, 'seats', v_seats, 'offers', v_offers);
end
$$;

-- коды отменённой группы помечаются в списке владельца
create or replace function public.get_group_codes()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', g.code, 'tier', g.tier, 'months', g.months,
           'used', coalesce(a.used_count, 0) >= coalesce(a.max_uses, 1), 'revoked', not coalesce(a.is_active, true),
           'created_at', g.created_at)
           order by g.created_at desc, g.id), '[]'::jsonb)
  from public.group_codes g
  left join public.access_codes a on a.code_hash = public.hash_code(replace(g.code, '-', ''))
  where g.owner_id = auth.uid()
$$;

revoke execute on function public.cut_subscription(bigint) from public, anon, authenticated;
revoke execute on function public.personal_offer(uuid, text, interval) from public, anon, authenticated;
revoke execute on function public.stars_refund_payment(text, boolean) from public, anon, authenticated;
grant execute on function public.stars_refund_payment(text, boolean) to service_role;
revoke execute on function public.get_group_codes() from public, anon;
grant execute on function public.get_group_codes() to authenticated;
