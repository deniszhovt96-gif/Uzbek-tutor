-- Исправление шага 8: возврат оплаты за продление, которое ещё не началось (подписка оплачена «вперёд»),
-- падал на ссылке payments → subscriptions. Теперь ссылка снимается до удаления будущей подписки.

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
      update public.payments set subscription_id = null where id = v_pay.id;   -- сначала снимаем ссылку, потом удаляем
      delete from public.subscriptions where id = v_sub.id;
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

