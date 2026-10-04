-- Проверка шага 11: состав сеанса, лимиты подписок, очередь подписок, /grant, экспресс-проверка темы, контрольная.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (1101, 1102, 1103, 1104);
insert into public.admins (tg_id) values (1199) on conflict do nothing;
insert into public.profiles (id, tg_id, first_name, timezone) values
  ('11110000-0000-0000-0000-000000000001', 1101, 'Basic', 'Asia/Tashkent'),
  ('11110000-0000-0000-0000-000000000002', 1102, 'Adv', 'Asia/Tashkent'),
  ('11110000-0000-0000-0000-000000000003', 1103, 'Stack', 'Asia/Tashkent'),
  ('11110000-0000-0000-0000-000000000004', 1104, 'Check', 'Asia/Tashkent');
insert into public.subscriptions (user_id, tier, starts_at, ends_at, source) values
  ('11110000-0000-0000-0000-000000000001', 'basic', now() - interval '1 day', now() + interval '30 days', 'manual'),
  ('11110000-0000-0000-0000-000000000002', 'advanced', now() - interval '1 day', now() + interval '30 days', 'manual');

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;

-- ===== состав сеанса (чистая функция)
select pg_temp.check((select r = 20 and n = 10 from public.session_plan(100, 30, 20, 500, 'normal')), 'лёгкая, много повторений: 20 повторений + 10 новых');
select pg_temp.check((select r = 32 and n = 13 from public.session_plan(100, 45, 25, 500, 'normal')), 'средняя: не меньше 13 новых');
select pg_temp.check((select r = 45 and n = 15 from public.session_plan(200, 60, 30, 500, 'normal')), 'интенсивная: не меньше 15 новых');
select pg_temp.check((select r = 27 and n = 3 from public.session_plan(100, 30, 20, 3, 'normal')), 'новых осталось 3 — сеанс добирается повторениями');
select pg_temp.check((select r = 5 and n = 20 from public.session_plan(5, 30, 20, 500, 'normal')), 'мало повторений — новых до максимума');
select pg_temp.check((select r = 30 and n = 0 from public.session_plan(100, 30, 20, 500, 'review')), 'режим «повторение»: только повторения');

-- ===== «Базовая»: 2 обучающих сеанса в день, повторение без ограничений, только лёгкая интенсивность
set app.now = '2026-10-10 10:00+05';
set role authenticated;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select pg_temp.check((public.start_session('normal')->>'new_count')::int = 20, 'базовая: 1-й сеанс — 20 новых слов');
reset role; update public.study_sessions set finished_at = now() where finished_at is null; set role authenticated;
select pg_temp.check((public.start_session('normal')->>'session_id') is not null, 'базовая: 2-й сеанс разрешён');
reset role; update public.study_sessions set finished_at = now() where finished_at is null; set role authenticated;
select pg_temp.check(public.start_session('normal')->>'error' = 'daily_limit', 'базовая: 3-й сеанс — лимит');
select pg_temp.check((public.get_home()->>'daily_limit_reached')::boolean and (public.get_home()->>'sessions_used')::int = 2, 'главная: лимит достигнут, 2 из 2');
reset role;
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
select u, w.id, 5, '2026-10-01', '2026-10-01', '2026-10-01'
from (values ('11110000-0000-0000-0000-000000000001'::uuid), ('11110000-0000-0000-0000-000000000002'::uuid)) v(u),
     (select id from public.words where cefr = 'A1' and is_active and canonical_id is null order by sort_key limit 30) w;
set role authenticated;
select pg_temp.check((public.start_session('review')->>'review_count')::int > 0, 'базовая: повторение после лимита — можно');
select pg_temp.check(public.update_settings(null, '{"intensity":"medium"}')->>'error' = 'locked_tier', 'базовая: средняя интенсивность закрыта');
select pg_temp.check(public.update_settings(null, '{"intensity":"light"}')->>'error' is null, 'базовая: лёгкая — можно');

-- ===== «Продвинутая»: без ограничений
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select pg_temp.check(public.update_settings(null, '{"intensity":"intense","session_size":60,"new_max":30}')->>'error' is null, 'продвинутая: интенсивная — можно');
do $$ begin
  for i in 1..4 loop
    if public.start_session('normal')->>'error' is not null then raise exception 'FAIL: продвинутая, сеанс % не начался', i; end if;
    reset role; update public.study_sessions set finished_at = now() where finished_at is null; set role authenticated;
  end loop;
end $$;
select 'ok  продвинутая: 4 сеанса подряд без лимита';
select pg_temp.check((public.get_home()->>'daily_limit_reached')::boolean = false, 'продвинутая: лимита нет');

-- ===== приоритет ошибок на повторении
reset role;
update public.word_progress set due_on = '2026-10-01', level = 10, level_at = '2026-10-01', fail_streak = 0
 where user_id = '11110000-0000-0000-0000-000000000002';
update public.word_progress set level = 12, fail_streak = 1
 where user_id = '11110000-0000-0000-0000-000000000002'
   and word_id = (select max(word_id) from public.word_progress where user_id = '11110000-0000-0000-0000-000000000002');
set role authenticated;
select pg_temp.check((select (public.start_session('review')->'items'->0->>'id')::int
                      = (select max(word_id) from public.word_progress where user_id = auth.uid())),
  'слово с ошибкой (уровень 12) — первым, раньше слов уровня 10');
reset role;

-- ===== очередь подписок
select pg_temp.check((public.grant_subscription('11110000-0000-0000-0000-000000000003', 'basic', 1, 'manual', 't')->>'sub_id') is not null, 'выдана «Базовая» на 1 месяц');
create temp table st as select (select ends_at from public.subscriptions where user_id = '11110000-0000-0000-0000-000000000003') as basic_end;
select pg_temp.check((public.admin_grant(1103, 'advanced', 1, 1199)->>'ok')::boolean, '/grant: «Продвинутая» поверх «Базовой»');
select pg_temp.check(public.admin_grant(1103, 'advanced', 1, 555)->>'error' = 'forbidden', '/grant не от администратора — отказ');
select pg_temp.check(public.admin_grant(999999, 'advanced', 1, 1199)->>'error' = 'no_user', '/grant: неизвестный пользователь');
grant select on st to authenticated;
set role authenticated;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000003';
select pg_temp.check(public.current_tier() = 'advanced', 'сейчас действует старшая — «Продвинутая»');
select pg_temp.check((select (s->>'ends_at')::timestamptz > (select basic_end from st) + interval '27 days'
                      from jsonb_array_elements(public.get_my_subscriptions()) s where s->>'tier' = 'basic'),
  '«Базовая» продлена на срок «Продвинутой» — остаток сохраняется');
select pg_temp.check(jsonb_array_length(public.get_my_subscriptions()) = 2, 'экран подписки: 2 периода в очереди');
reset role;
select pg_temp.check((public.grant_subscription('11110000-0000-0000-0000-000000000003', 'basic', 1, 'manual', 't2')->>'starts_at')::timestamptz
                     >= (select ends_at from public.subscriptions where user_id = '11110000-0000-0000-0000-000000000003' and tier = 'advanced'),
  '«Базовая», купленная во время «Продвинутой», начинается после неё');

-- ===== экспресс-проверка темы
set role authenticated;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000004';
create temp table tc as select public.start_topic_check((select id from public.topics where cefr = 'A1' order by sort_order limit 1)) as r;
select pg_temp.check((select (r->>'total')::int = (select count(*) from public.words w
                       where w.topic_id = (r->>'topic_id')::int and w.is_active and w.canonical_id is null) from tc),
  'проверка темы: все слова темы');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(r->'questions') q where q ? 'answer') from tc), 'верные ответы не отдаются');
select pg_temp.check((select count(distinct q->>'type') = 2 from tc, jsonb_array_elements(r->'questions') q), 'вопросы в обе стороны (RU→UZ и UZ→RU)');
select pg_temp.check(public.start_topic_check((select id from public.topics where cefr = 'B2' order by sort_order limit 1))->>'error' = 'level_locked',
  'тема закрытого уровня — недоступна');
reset role;
create temp table qa as
  select (q->>'i')::int as i, q->>'type' as type, w.uz, w.ru, (q->>'word_id')::int as word_id, (select (r->>'attempt_id')::uuid from tc) as att
  from tc, jsonb_array_elements(r->'questions') q join public.words w on w.id = (q->>'word_id')::int;
grant select on qa to authenticated;
-- одно слово начато заранее (для проверки ошибки)
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
select '11110000-0000-0000-0000-000000000004', word_id, 3, now(), '2026-12-01', now() from qa where i = 1;
set role authenticated;
select pg_temp.check((public.answer_word_check(att, 0, case when type = 'ru_uz_input' then uz else (string_to_array(ru, ','))[1] end)->>'correct')::boolean,
  'верный ответ принят') from qa where i = 0;
select pg_temp.check(not (public.answer_word_check(att, 1, 'xyzxyz')->>'correct')::boolean, 'неверный ответ') from qa where i = 1;
select pg_temp.check((public.answer_word_check(att, 1, 'xyzxyz')->>'duplicate')::boolean, 'повторный ответ не считается') from qa where i = 1;
reset role;
select pg_temp.check((select level = 15 and due_on = date '2026-10-10' + public.interval_days(15) from public.word_progress
                      where user_id = '11110000-0000-0000-0000-000000000004' and word_id = (select word_id from qa where i = 0)),
  'знакомое слово: уровень 15, следующий показ в конце очереди');
select pg_temp.check((select level = 3 and due_on = '2026-10-10' from public.word_progress
                      where user_id = '11110000-0000-0000-0000-000000000004' and word_id = (select word_id from qa where i = 1)),
  'ошибка в начатом слове: уровень не меняется, повторение сегодня');
set role authenticated;
select pg_temp.check((select (r->>'correct')::int = 1 and jsonb_array_length(r->'mistakes') = 1
                      from (select public.finish_word_check(att) r from qa where i = 0) x), 'итог: 1 верно, 1 ошибка');
select pg_temp.check((select (public.start_topic_check((select id from public.topics where cefr = 'A1' order by sort_order limit 1))->>'total')::int
                      = (select count(*) from qa) - 1), 'повторная проверка темы — без слов уровня 15');

-- ===== контрольная по пройденному
select pg_temp.check(public.start_review_quiz()->>'error' = 'not_enough', 'контрольная: мало начатых слов — недоступна');
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
reset role;
update public.word_progress set level = 5 where user_id = '11110000-0000-0000-0000-000000000002';
create temp table lv as select word_id, level from public.word_progress where user_id = '11110000-0000-0000-0000-000000000002';
set role authenticated;
create temp table rq as select public.start_review_quiz() as r;
select pg_temp.check((select (r->>'total')::int = 20 from rq), 'контрольная: 20 вопросов');
select pg_temp.check((select count(distinct q->>'type') = 4 from rq, jsonb_array_elements(r->'questions') q), 'контрольная: 4 вида вопросов');
select pg_temp.check((select bool_and(jsonb_array_length(q->'options') = 4) from rq, jsonb_array_elements(r->'questions') q where q ? 'options'), 'по 4 варианта');
select public.answer_word_check((r->>'attempt_id')::uuid, 0, 'неверно') from rq;
reset role;
select pg_temp.check((select count(*) = 0 from public.word_progress wp join lv using (word_id)
                      where wp.user_id = '11110000-0000-0000-0000-000000000002' and wp.level <> lv.level), 'контрольная не меняет уровни');
select pg_temp.check(not has_table_privilege('authenticated', 'public.word_check_attempts', 'select'), 'попытки (с ответами) не читаются напрямую');
select pg_temp.check((select value #>> '{}' from public.app_config where key = 'community_url') = 'https://t.me/+luNI8b4qZ1Y4MTA6', 'ссылка на группу');
