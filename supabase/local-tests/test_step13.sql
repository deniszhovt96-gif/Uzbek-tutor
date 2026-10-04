-- Проверка шага 13: расширенная статистика, настройки напоминаний, напоминания, названия тем.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (1301, 1302);
insert into public.profiles (id, tg_id, first_name, timezone) values
  ('13010000-0000-0000-0000-000000000001', 1301, 'Free', 'Asia/Tashkent'),
  ('13010000-0000-0000-0000-000000000002', 1302, 'Adv', 'Asia/Tashkent');
insert into public.subscriptions (user_id, tier, starts_at, ends_at, source)
values ('13010000-0000-0000-0000-000000000002', 'advanced', now() - interval '1 day', now() + interval '30 days', 'manual');
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at, wrong_count, correct_count)
select '13010000-0000-0000-0000-000000000002', id, 4, now(), current_date + (id % 9), now(), id % 5, 3
from public.words where cefr = 'A1' and is_active and canonical_id is null order by sort_key limit 60;
insert into public.daily_stats (user_id, day, correct, wrong, seconds, new_words)
select '13010000-0000-0000-0000-000000000002', current_date - i, 20, 3, 600, 10 from generate_series(0, 4) i;
insert into public.daily_stats (user_id, day, correct, wrong, seconds)
values ('13010000-0000-0000-0000-000000000002', current_date - 9, 5, 1, 120);

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;

set role authenticated;
set request.jwt.claim.sub = '13010000-0000-0000-0000-000000000001';
select pg_temp.check(public.get_stats_ext()->>'error' = 'locked_tier', 'расширенная статистика: бесплатно — закрыта');
select pg_temp.check((public.update_settings(null, '{"remind": false, "remind_hour": 21, "onboarded": true}')->'settings'->>'remind_hour')::int = 21,
  'настройки: час напоминания');
select pg_temp.check((public.update_settings(null, '{"remind_hour": 3}')->'settings'->>'remind_hour')::int = 6, 'час напоминания не раньше 6:00');
select pg_temp.check((public.get_me()->'settings'->>'onboarded')::boolean and not (public.get_me()->'settings'->>'remind')::boolean,
  'приветствие пройдено, напоминания выключены');

set request.jwt.claim.sub = '13010000-0000-0000-0000-000000000002';
create temp table x as select public.get_stats_ext() as r;
select pg_temp.check((select jsonb_array_length(r->'forecast') = 7 from x), 'прогноз на 7 дней');
select pg_temp.check((select sum((d->>'due')::int) > 0 from x, jsonb_array_elements(r->'forecast') d), 'в прогнозе есть повторения');
select pg_temp.check((select jsonb_array_length(r->'hard') between 1 and 15 from x), 'трудные слова: до 15');
select pg_temp.check((select (r->'hard'->0->>'wrong')::int >= (r->'hard'->1->>'wrong')::int from x), 'трудные слова — по числу ошибок');
select pg_temp.check((select (r->'totals'->>'days_active')::int = 6 and (r->'totals'->>'best_streak')::int = 5 and (r->'totals'->>'minutes')::int = 52 from x),
  'итоги: 6 дней, лучшая серия 5, 52 минуты');
select pg_temp.check((select jsonb_array_length(r->'weeks') >= 1 from x), 'недели');
reset role;

-- напоминания: пропуск одноразовый
insert into public.cron_tokens (token) values ('t13');
select pg_temp.check((public.reminders_take('t13')->>'ok')::boolean, 'пропуск принят');
select pg_temp.check(public.reminders_take('t13')->>'error' = 'bad_token', 'повторно пропуск не работает');
insert into public.cron_tokens (token, created_at) values ('old', now() - interval '1 hour');
select pg_temp.check(public.reminders_take('old')->>'error' = 'bad_token', 'старый пропуск (больше 15 минут) не работает');
select pg_temp.check(not has_function_privilege('authenticated', 'public.reminders_take(text)', 'execute'), 'напоминания вызывает только бот');

-- названия тем
select pg_temp.check((select count(*) = 0 from public.topics where name_uz is null or name_en is null), 'у всех тем есть названия на узбекском и английском');
select pg_temp.check((select name_uz = 'Olmoshlar' and name_en = 'Pronouns' from public.topics where id = 1), 'Местоимения → Olmoshlar / Pronouns');
