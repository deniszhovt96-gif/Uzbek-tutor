-- Шаг 4: профиль текущего пользователя и признак администратора.

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p join public.admins a on a.tg_id = p.tg_id
    where p.id = auth.uid())
$$;

-- Сводка для приложения: кто я, какая подписка, админ ли
create or replace function public.get_me()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id',            p.id,
    'tg_id',         p.tg_id,
    'username',      p.username,
    'first_name',    p.first_name,
    'ui_lang',       p.ui_lang,
    'timezone',      p.timezone,
    'settings',      p.settings,
    'tier',          public.current_tier(),
    'tier_ends_at', (select max(s.ends_at) from public.subscriptions s
                      where s.user_id = p.id and s.ends_at > now() and s.tier = public.current_tier()),
    'is_admin',      exists (select 1 from public.admins a where a.tg_id = p.tg_id),
    'words_total',  (select count(*) from public.words w where w.canonical_id is null and w.is_active)
  )
  from public.profiles p
  where p.id = auth.uid()
$$;

revoke execute on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated;
revoke execute on function public.get_me() from public, anon;
grant  execute on function public.get_me() to authenticated;
