-- Проверка шага 16: уровни форм и потолок по грамматике, очередь слов из тем, пометки форм, диалоги,
-- предложения по уровням и бонус, рекомендации, цель недели, недельное сообщение, групповая подписка, аналитика.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (1611, 1612);
delete from public.admins where tg_id = 1612;
insert into public.profiles (id, tg_id, first_name, timezone, settings) values
  ('16110000-0000-0000-0000-000000000001', 1611, 'Morph', 'Asia/Tashkent', '{}'),
  ('16120000-0000-0000-0000-000000000001', 1612, 'Admin', 'Asia/Tashkent', '{}');
insert into public.admins (tg_id) values (1612);

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
create temp table v as select 21015 as bormoq, (select id from public.words where uz = 'kitob' and is_active and canonical_id is null limit 1) as kitob;
grant select on v to authenticated;

-- словарь: переводы форм и части речи
select pg_temp.check((select count(*) > 1100 from public.words where word_class = 'verb' and morph is not null), 'у глаголов есть переводы форм (morph)');
select pg_temp.check((select morph->'ru'->'pres'->>0 = 'иду' from public.words where id = 21015), 'bormoq: «я иду»');
select pg_temp.check((select count(*) > 3000 from public.words where pos = 'n'), 'существительные размечены (pos = n)');
select pg_temp.check((select word_class = 'other' from public.words where uz = 'tomoq' limit 1), 'tomoq (горло) — не глагол');

-- потолок уровня по темам грамматики
select pg_temp.check((public.morph_state('16110000-0000-0000-0000-000000000001')->>'conj_cap')::int = 1, 'ничего не пройдено: потолок 1');
set role authenticated;
set request.jwt.claim.sub = '16110000-0000-0000-0000-000000000001';
select pg_temp.check((select (public.answer_morph(bormoq, 'table', 6, 6)->>'level')::int = 1 from v), 'таблица верно: уровень 1');
select pg_temp.check((select (public.answer_morph(bormoq, 'table', 6, 6)->>'level')::int = 1 from v), 'уровень не выше потолка (1)');
reset role;
insert into public.course_progress (user_id, unit_id, status, read_at)
select '16110000-0000-0000-0000-000000000001', id, 'read', now() from public.course_units where course_id = 'grammar' and source_no in (3,5,6,7,8,16,21,22,23,24,25,26,27);
select pg_temp.check((public.morph_state('16110000-0000-0000-0000-000000000001')->>'conj_cap')::int = 15, 'все 13 тем о глаголе: потолок 15');
set role authenticated;
select pg_temp.check((select (public.answer_morph(bormoq, 'table', 6, 6)->>'level')::int = 2 from v), 'после тем уровень растёт');
select pg_temp.check((select (public.answer_morph(bormoq, 'form', 1, 1)->>'level')::int = 1 from v), 'уровень «форма» — отдельный');
select pg_temp.check((select (public.answer_morph(bormoq, 'table', 2, 6)->>'level')::int = 1 from v), 'много ошибок: уровень −1');
select pg_temp.check((select (public.answer_morph(kitob, 'decl', 5, 5)->>'cap')::int = 1 from v), 'склонение: свой потолок (темы 9–11 не пройдены)');
select pg_temp.check((select (x->>'t')::int = 1 and (x->>'f')::int = 1 from jsonb_array_elements(public.get_verbs()->'verbs') x, v where (x->>'i')::int = bormoq),
  'get_verbs: уровни формы и таблицы');
select pg_temp.check((select x->>'c' from jsonb_array_elements(public.get_verbs()->'verbs') with ordinality a(x, k) order by k limit 1) = 'A1', 'глаголы: сначала A1');
select pg_temp.check((select public.get_morph(jsonb_build_array(bormoq, kitob)) ? '21015' from v), 'get_morph: формы перевода');

-- пометка формы
select pg_temp.check((select (public.report_form(bormoq, 'conj', 'pres_fut', 0, 'boraman — я иду', 'лучше «я пойду»')->>'ok')::boolean from v), 'пометка формы сохранена');
select pg_temp.check(public.admin_form_reports('new') ? 'error', 'не админ: список пометок закрыт');
reset role;
select pg_temp.check(jsonb_array_length(public.take_form_notifications()) >= 1, 'уведомление о пометке для бота');
select pg_temp.check(jsonb_array_length(public.take_form_notifications()) = 0, 'уведомление не повторяется');
set role authenticated;
set request.jwt.claim.sub = '16120000-0000-0000-0000-000000000001';
select pg_temp.check(jsonb_array_length(public.admin_form_reports('new')->'items') >= 1, 'админ видит пометку');
select pg_temp.check((public.admin_resolve_form_report((select (public.admin_form_reports('new')->'items'->0->>'id')::bigint), 'fixed')->>'ok')::boolean, 'админ закрыл пометку');
select pg_temp.check((public.admin_analytics()->'users'->>'total')::int > 0, 'аналитика для админа');
set request.jwt.claim.sub = '16110000-0000-0000-0000-000000000001';
select pg_temp.check(public.admin_analytics() ? 'error', 'аналитика закрыта для остальных');
reset role;

-- курсы: уровни тем, диалоги, слова тем → очередь
select pg_temp.check((select count(*) = 30 from public.course_units where course_id = 'dialogs'), 'диалоги: 30');
select pg_temp.check((select count(distinct cefr) = 4 from public.course_units where course_id = 'dialogs'), 'диалоги на 4 уровнях');
select pg_temp.check((select bool_and(jsonb_array_length(extra->'lines') >= 6) from public.course_units where course_id = 'dialogs'), 'в каждом диалоге 6+ реплик');
select pg_temp.check((select count(distinct cefr) >= 3 from public.course_units where course_id = 'grammar'), 'темы грамматики по уровням');
select pg_temp.check((select count(*) > 150 from public.unit_words w join public.course_units u on u.id = w.unit_id where u.course_id = 'dialogs'),
  'слова диалогов найдены в словаре');
create temp table d1 as select u.id from public.course_units u where course_id = 'dialogs' and source_no = 1;
grant select on d1 to authenticated;
set role authenticated;
set request.jwt.claim.sub = '16110000-0000-0000-0000-000000000001';
select pg_temp.check((select (public.mark_unit(id, true)->>'read')::boolean from d1), 'диалог отмечен пройденным');
reset role;
select pg_temp.check((select count(*) >= 3 from public.word_queue where user_id = '16110000-0000-0000-0000-000000000001'), 'слова диалога в очереди заучивания');
set role authenticated;
create temp table sess as select public.start_session('normal') s;
reset role;
select pg_temp.check((select count(*) >= 3 from sess, jsonb_array_elements(s->'items') x
                      where (x->>'id')::int in (select word_id from public.word_queue where user_id = '16110000-0000-0000-0000-000000000001')),
  'сессия: новые слова начинаются со слов пройденных тем');

-- рекомендации
set role authenticated;
select pg_temp.check(public.get_next_step()->'next'->>'kind' = 'words', 'рекомендация: сначала слова');
reset role;
update public.study_sessions set finished_at = now() where user_id = '16110000-0000-0000-0000-000000000001';
update public.course_progress set read_at = now() - interval '2 days' where user_id = '16110000-0000-0000-0000-000000000001';
set role authenticated;
select pg_temp.check(public.get_next_step()->'next'->>'kind' = 'course', 'после слов: тема курса');
select pg_temp.check(public.get_next_step()->'next'->>'course' = 'culture', 'по очереди: после грамматики — культура');
reset role;
update public.course_progress set read_at = now() where user_id = '16110000-0000-0000-0000-000000000001';
delete from public.verb_progress where user_id = '16110000-0000-0000-0000-000000000001';
set role authenticated;
select pg_temp.check(public.get_next_step()->'next'->>'kind' = 'consolidate', 'тема и диалог сегодня — закрепление');
reset role;
insert into public.verb_progress (user_id, word_id, kind, level, last_at) values ('16110000-0000-0000-0000-000000000001', 21015, 'table', 1, now());
set role authenticated;
select pg_temp.check(public.get_next_step()->'next'->>'kind' = 'done', 'всё сделано — план выполнен');
-- цель недели
select pg_temp.check((public.get_week()->>'goal')::int = 5, 'цель недели по умолчанию 5 дней');
select pg_temp.check(((public.update_settings(null, '{"week_goal": 9}'))->'settings'->>'week_goal')::int = 7, 'цель недели не больше 7');
-- предложения
select pg_temp.check(jsonb_array_length(public.get_sentence_levels()->'levels') = 4, 'предложения: 4 уровня');
select pg_temp.check((select bool_and((x->>'nw')::int between 2 and 3) from jsonb_array_elements(public.start_sentences('A1', 'bonus')->'items') x),
  'бонус: короткие фразы (2–3 слова)');
select pg_temp.check(jsonb_array_length(public.start_sentences('A1', 'bonus')->'items') > 0, 'бонус доступен сразу');
-- ошибки
select pg_temp.check(public.start_mistakes() ? 'items', 'игра «Мои ошибки»');
reset role;

-- недельное сообщение
select pg_temp.check(public.weekly_text('ru', '{"days5": 10, "days3": 40, "ans100": 25, "course": 30, "acc": 87}', 3) like '%10% занимались 5 дней%', 'текст недельного сообщения (ru)');
select pg_temp.check(public.weekly_text('uz', null, 3) like 'Yangi haftangiz%', 'недельное сообщение без статистики (uz)');

-- групповая подписка
select pg_temp.check((select count(*) = 8 from public.plans where seats = 3), 'групповые тарифы: 8');
select pg_temp.check((select g.price_stars = round(p.price_stars * 3 * 0.85 / 10.0) * 10 from public.plans g join public.plans p on p.tier = g.tier and p.months = g.months and p.seats = 1
                      where g.seats = 3 and g.tier = 'basic' and g.months = 1), 'цена группы = 3 × цена × 0,85');
select pg_temp.check((select jsonb_array_length(public.stars_grant_payment('p:' || id || ':16110000-0000-0000-0000-000000000001', 1611, price_stars, 'group-test-1')->'codes') = 2
                      from public.plans where seats = 3 and tier = 'basic' and months = 1), 'оплата группы: 2 кода для друзей');
create temp table gc as select code from public.group_codes where charge_id = 'group-test-1' limit 1;
grant select on gc to authenticated;
set role authenticated;
select pg_temp.check(jsonb_array_length(public.get_group_codes()) = 2, 'покупатель видит коды');
set request.jwt.claim.sub = '16120000-0000-0000-0000-000000000001';
select pg_temp.check((public.redeem_code((select code from gc))->>'ok')::boolean, 'друг активирует код');
set request.jwt.claim.sub = '16110000-0000-0000-0000-000000000001';
select pg_temp.check((select count(*) = 1 from jsonb_array_elements(public.get_group_codes()) x where (x->>'used')::boolean), 'код отмечен использованным');
reset role;

delete from public.payments where charge_id = 'group-test-1';
delete from public.group_codes where charge_id = 'group-test-1';
delete from public.profiles where tg_id in (1611, 1612);
delete from public.admins where tg_id = 1612;
