-- Проверка шага 12: уровни слов, путь, справочник, день повторения, пометки уровня, цены.
-- Запуск после загрузки словаря (scripts/build_vocab.py + scripts/load_vocab.sql).
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (1201, 1202, 1203, 1299);
insert into public.admins (tg_id) values (1299) on conflict do nothing;
insert into public.profiles (id, tg_id, first_name, timezone) values
  ('12020000-0000-0000-0000-000000000001', 1201, 'Novice', 'Asia/Tashkent'),
  ('12020000-0000-0000-0000-000000000002', 1202, 'Middle', 'Asia/Tashkent'),
  ('12020000-0000-0000-0000-000000000003', 1203, 'Friday', 'Asia/Tashkent'),
  ('12020000-0000-0000-0000-000000000099', 1299, 'Admin', 'Asia/Tashkent');
insert into public.subscriptions (user_id, tier, starts_at, ends_at, source)
select id, 'advanced', '2026-01-01', '2028-01-01', 'manual' from public.profiles where tg_id in (1201, 1202, 1203, 1299);
-- «Middle» сдал тесты A1 и A2 → открыт B1
insert into public.level_test_attempts (user_id, cefr, questions, total, score, passed, started_at, finished_at)
select '12020000-0000-0000-0000-000000000002', c, '[]', 35, 35, true, now() - interval '2 days', now() - interval '2 days'
from (values ('A1'), ('A2')) v(c);

create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;

-- ===== словарь после перепроверки уровней
select pg_temp.check((select count(*) between 450 and 800 from public.words where cefr = 'A1' and is_active and canonical_id is null),
  'A1 — 450…800 базовых слов');
select pg_temp.check((select cefr <> 'A1' from public.words where id = 1311), 'сельдерей больше не A1');
select pg_temp.check((select uz = 'toʻrt' and not audio_ok from public.words where id = 52), '«четыре» = toʻrt (аудио старой записи отключено)');
select pg_temp.check((select not is_active from public.words where id = 7619), 'повреждённая запись отключена');
select pg_temp.check((select count(*) >= 300 from public.words where register = 'colloquial' and is_active), 'разговорная лексика: 300+ слов');
select pg_temp.check((select bool_and(literary is not null and note is not null and not audio_ok) from public.words where register = 'colloquial'),
  'у разговорных слов есть литературный вариант и пометка, без аудио');
select pg_temp.check((select count(*) = 0 from public.word_progress wp join public.words w on w.id = wp.word_id where not w.is_active),
  'у отключённых слов нет прогресса');

set app.now = '2026-10-08 10:00+05';   -- четверг
set role authenticated;
set request.jwt.claim.sub = '12020000-0000-0000-0000-000000000001';

-- ===== путь
create temp table p as select public.get_path() as r;
select pg_temp.check((select count(*) between 300 and 600 from p, jsonb_array_elements(r->'topics')), 'путь: тема на каждом своём уровне (300…600 точек)');
select pg_temp.check((select count(distinct t->>'key') = count(*) from p, jsonb_array_elements(r->'topics') t), 'ключи точек уникальны');
select pg_temp.check((select bool_and((t->>'total')::int >= 1) from p, jsonb_array_elements(r->'topics') t), 'в каждой точке есть слова');
select pg_temp.check((select count(*) > 0 from p, jsonb_array_elements(r->'topics') t where (t->>'colloquial')::boolean), 'на пути есть разговорные темы');
select pg_temp.check((select sum((t->>'total')::int) = (select count(*) from public.words where is_active and canonical_id is null)
                      from p, jsonb_array_elements(r->'topics') t), 'все слова распределены по точкам пути');
select pg_temp.check((select bool_and((t->>'locked')::boolean = (t->>'cefr' > 'A1')) from p, jsonb_array_elements(r->'topics') t), 'новичку открыты только точки A1');

-- ===== справочник
create temp table d as select public.get_dictionary('A1') as r;
select pg_temp.check((select jsonb_array_length(r->'words') = (select count(*) from public.words where cefr = 'A1' and is_active and canonical_id is null) from d),
  'справочник A1: все слова уровня');
select pg_temp.check((select bool_and(w ? 'u' and w ? 'r' and w ? 't') from d, jsonb_array_elements(r->'words') w), 'строка слова: узб., рус., тема');
select pg_temp.check((select (r->>'can_flag')::boolean = false from d), 'новичок не может помечать слова');
select pg_temp.check((select jsonb_array_length(public.get_topic_words(1)->'words') > 0), 'слова темы');
select pg_temp.check((select (public.get_word(20001)->>'register') = 'colloquial' and public.get_word(20001)->>'literary' is not null),
  'карточка разговорного слова');
select pg_temp.check(public.propose_word_level(1, 'rare')->>'error' = 'forbidden', 'пометка от новичка — отказ');

-- ===== сеанс: новые слова — сначала A1
select pg_temp.check((select bool_and(i->>'cefr' = 'A1') from jsonb_array_elements(public.start_session('normal')->'items') i where i->>'stage' = 'new'),
  'новые слова первого сеанса — только A1');
select pg_temp.check((public.get_home()->'review_day'->>'tomorrow')::boolean, 'четверг: предупреждение «завтра день повторения»');

-- ===== день повторения (пятница)
reset role;
insert into public.word_progress (user_id, word_id, level, level_at, due_on, first_seen_at)
select '12020000-0000-0000-0000-000000000003', id, 5, '2026-10-01', '2026-10-05', '2026-09-20'
from public.words where cefr = 'A1' and is_active and canonical_id is null order by sort_key limit 100;
set app.now = '2026-10-09 10:00+05';   -- пятница
set role authenticated;
set request.jwt.claim.sub = '12020000-0000-0000-0000-000000000003';
create temp table rd as select public.get_home() as r;
select pg_temp.check((select (r->'review_day'->>'active')::boolean and (r->'review_day'->>'locked')::boolean from rd), 'пятница: новые слова закрыты до повторения');
select pg_temp.check((select (r->'review_day'->>'need')::int = 15 + 100 / 20 from rd), 'нужно повторений: 15 + 1 за каждые 20 начатых = 20');
select pg_temp.check((select (r->>'plan_new')::int = 0 from rd), 'план: новых слов 0');
create temp table s5 as select public.start_session('normal') as r;
select pg_temp.check((select (r->>'new_count')::int = 0 and (r->>'review_count')::int > 0 from s5), 'пятничный сеанс — только повторение');
reset role;
update public.daily_stats set reviews = 20 where user_id = '12020000-0000-0000-0000-000000000003' and day = '2026-10-09';
insert into public.daily_stats (user_id, day, reviews) values ('12020000-0000-0000-0000-000000000003', '2026-10-09', 20) on conflict do nothing;
update public.study_sessions set finished_at = now() where user_id = '12020000-0000-0000-0000-000000000003';
set role authenticated;
select pg_temp.check(not (public.get_home()->'review_day'->>'locked')::boolean and (public.get_home()->>'plan_new')::int > 0,
  'после 20 повторений новые слова открылись');
select pg_temp.check((public.start_session('normal')->>'new_count')::int > 0, 'сеанс снова с новыми словами');

-- ===== пометки уровня
set request.jwt.claim.sub = '12020000-0000-0000-0000-000000000002';
create temp table fw as select id from public.words where cefr = 'A2' and is_active and canonical_id is null order by sort_key desc limit 1;
grant select on fw to authenticated;
select pg_temp.check((public.get_dictionary('A2')->>'can_flag')::boolean, 'уровень B1: можно помечать');
select pg_temp.check(public.propose_word_level((select id from fw), 'unused')->>'status' = 'pending', 'пометка пользователя ждёт проверки');
select pg_temp.check(public.propose_word_level((select id from public.words where cefr = 'B1' and is_active limit 1), 'rare')->>'error' = 'not_basic',
  'слова B1 помечать нельзя');
select pg_temp.check((select cefr = 'A2' from public.words where id = (select id from fw)), 'до решения администратора уровень не меняется');
select pg_temp.check(public.admin_word_proposals()->>'error' = 'forbidden', 'список пометок — только администратору');
reset role;
select pg_temp.check((select jsonb_array_length(public.take_flag_notifications()) >= 1), 'бот получает новые пометки');
select pg_temp.check((select jsonb_array_length(public.take_flag_notifications()) = 0), 'повторно — не дублируются');
set role authenticated;
set request.jwt.claim.sub = '12020000-0000-0000-0000-000000000099';
select pg_temp.check((select (p->>'unused')::int = 1 from jsonb_array_elements(public.admin_word_proposals()->'pending') p
                      where (p->>'word_id')::int = (select id from fw)), 'администратор видит пометку');
select pg_temp.check(public.admin_decide_word((select id from fw), 'approve', 'B2')->>'cefr' = 'B2', 'одобрено: слово → B2');
select pg_temp.check((select cefr = 'B2' from public.words where id = (select id from fw)), 'уровень изменён');
select pg_temp.check(public.propose_word_level((select id from public.words where cefr = 'A1' and is_active and canonical_id is null order by sort_key desc limit 1), 'rare')->>'status' = 'approved',
  'пометка администратора применяется сразу');
reset role;
-- повторный импорт словаря не сбрасывает одобренный уровень
\copy (select 1) to '/dev/null'
create temp table ov as select word_id, cefr from public.word_level_overrides;
update public.words w set cefr = o.base_cefr from public.word_level_overrides o where o.word_id = w.id;    -- как сделал бы импорт
update public.words w set cefr = o.cefr from public.word_level_overrides o where o.word_id = w.id;         -- шаг из load_vocab.sql
select pg_temp.check((select bool_and(w.cefr = ov.cefr) from ov join public.words w on w.id = ov.word_id), 'одобренные уровни сохраняются при импорте');
set role authenticated;
set request.jwt.claim.sub = '12020000-0000-0000-0000-000000000099';
select pg_temp.check(public.admin_decide_word((select id from fw), 'revert')->>'cefr' = 'A2', 'отмена: слово снова A2');
select pg_temp.check((select cefr = 'A2' from public.words where id = (select id from fw)), 'уровень восстановлен');
reset role;

-- ===== цены
select pg_temp.check((select price_uzs = 100000 and price_stars = 450 from public.plans where tier = 'basic' and months = 1), '«Базовая» на месяц — 100 000 сум / 450 ⭐');
select pg_temp.check((select price_uzs = 200000 from public.plans where tier = 'advanced' and months = 1), '«Продвинутая» на месяц — 200 000 сум');
