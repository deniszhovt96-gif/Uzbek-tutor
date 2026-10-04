-- Данные платежа для сообщений администратору (бот: уведомления об оплате и ответ на /refund)
create or replace function public.admin_payment_info(p_charge_id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'name', pr.first_name, 'username', pr.username, 'tg_id', pr.tg_id,
    'tier', p.tier, 'months', p.months, 'stars', p.stars, 'status', p.status, 'created_at', p.created_at,
    -- до какой даты у пользователя теперь действует подписка этого уровня (null — подписки нет)
    'tier_ends_at', (select max(s.ends_at) from public.subscriptions s
                      where s.user_id = p.user_id and s.tier = p.tier and s.ends_at > now()),
    'current_tier', coalesce((select s.tier from public.subscriptions s
                               where s.user_id = p.user_id and s.starts_at <= now() and s.ends_at > now()
                               order by public.tier_rank(s.tier) desc limit 1), 'free'))
  from public.payments p join public.profiles pr on pr.id = p.user_id
  where p.charge_id = p_charge_id
$$;
revoke execute on function public.admin_payment_info(text) from public, anon, authenticated;
grant execute on function public.admin_payment_info(text) to service_role;

-- Возврат: подписка из платежа заканчивается ровно в момент возврата (раньше могла оставаться ещё на секунду)
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
      update public.payments set subscription_id = null where id = v_pay.id;   -- сначала снимаем ссылку, потом удаляем
      delete from public.subscriptions where id = v_sub.id;
    elsif v_sub.ends_at > now() then
      -- подписка заканчивается прямо сейчас (начало сдвигаем на секунду назад, чтобы ends_at > starts_at)
      update public.subscriptions set starts_at = least(starts_at, now() - interval '1 second'), ends_at = now() where id = v_sub.id;
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

