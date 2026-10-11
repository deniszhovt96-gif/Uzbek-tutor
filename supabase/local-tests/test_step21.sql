-- Проверка шага 21: слова для тестов, варианты одинаковой длины, ответы без местоимений, синонимы, альфа-коды, марафон.
\set ON_ERROR_STOP 1
\pset tuples_only on
\timing off
delete from public.profiles where tg_id in (2101, 2102);
insert into public.profiles (id, tg_id, first_name, settings) values
  ('21010000-0000-0000-0000-000000000001', 2101, 'Test', '{}'),
  ('21020000-0000-0000-0000-000000000001', 2102, 'Alpha', '{"colloquial_first": true}');
select public.grant_subscription('21010000-0000-0000-0000-000000000001', 'advanced', 1, 'manual', 't21');
create or replace function pg_temp.check(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok  ' || label;
end $$;
create or replace function pg_temp.ok(p_uz text) returns boolean language sql as $$
  select bool_and(test_ok) from public.words where uz = p_uz and is_active
$$;

-- 1, 3, 5, 9: что не попадает в тест уровня и контрольную
select pg_temp.check(not pg_temp.ok('Salom!') and not pg_temp.ok('Allo!'), 'приветствия и «алло» — не в тестах');
select pg_temp.check(not pg_temp.ok('ofitsiant') and not pg_temp.ok('yumor') and not pg_temp.ok('televizor'), 'созвучные русским — не в тестах');
select pg_temp.check(not pg_temp.ok('Finlyandiya'), 'страны — не в тестах');
select pg_temp.check((select bool_and(not test_ok) from public.words where register = 'colloquial'), 'разговорная лексика — не в тестах');
select pg_temp.check(pg_temp.ok('kitob') and pg_temp.ok('ota') and (select bool_and(test_ok) from public.words where uz = 'tuz' and ru = 'соль'), 'обычные слова остаются');
select pg_temp.check((select count(*) >= 400 from public.words where cefr = 'A1' and is_active and canonical_id is null and test_ok), 'для теста A1 хватает слов');

-- 4: местоимения и регистр
select pg_temp.check(public.uz_same('boraman', 'Men boraman.'), 'boraman = Men boraman');
select pg_temp.check(public.uz_same('men boraman', 'boraman'), 'men boraman = boraman');
select pg_temp.check(public.uz_same('BIZ UYGA BORAMIZ', 'Uyga boramiz.'), 'капслок и местоимение');
select pg_temp.check(not public.uz_same('boramiz', 'boraman'), 'другая форма — ошибка');

-- 2: тест уровня — варианты с тем же числом слов, только подходящие слова
set role authenticated;
set request.jwt.claim.sub = '21010000-0000-0000-0000-000000000001';
create temp table lt as select public.start_level_test('A1') r;
reset role;
select pg_temp.check((select (r->>'total')::int between 30 and 40 from lt), 'тест A1: 30–40 вопросов');
create temp table lq as
  select q from public.level_test_attempts a, jsonb_array_elements(a.questions) q
   where a.user_id = '21010000-0000-0000-0000-000000000001' and a.cefr = 'A1';
select pg_temp.check((select bool_and(w.test_ok) from lq join public.words w on w.id = (lq.q->>'word_id')::int), 'в тесте только слова для тестов');
select pg_temp.check((select bool_and((select count(distinct public.wc(o #>> '{}')) = 1 from jsonb_array_elements(q->'options') o))
                      from lq where q->>'type' in ('uz_ru_choice','ru_uz_choice','audio_choice','sentence_choice')), 'варианты одной длины');
select pg_temp.check(public.wc('стоить (того)') = 1 and public.wc('kiyim ilgich') = 2, 'подсчёт слов');

-- сложность: позиция в уровне + длина + доля ошибок всех пользователей
select pg_temp.check((select count(*) > 7000 from public.word_difficulty), 'сложность посчитана для всех слов');
select pg_temp.check((select d1.hard < d2.hard from public.word_difficulty d1, public.word_difficulty d2
                      where d1.word_id = (select id from public.words where uz = 'men' and is_active limit 1)
                        and d2.word_id = (select id from public.words where uz = 'qisqichbaqa' and cefr = 'A1' and is_active limit 1)), 'men легче, чем qisqichbaqa');

-- 6: синонимы — пояснение в карточке
select pg_temp.check((select public.word_card(id, '21010000-0000-0000-0000-000000000001', now())->>'syn_note' like '%muloqot%'
                      from public.words where uz = 'suhbat' and ru = 'разговор'), 'suhbat: пояснение разницы с muloqot');

-- 8: альфа-тестер
create temp table ac as select public.admin_create_alpha_codes(1, 1, null) c;
grant select on ac to authenticated;
set role authenticated;
set request.jwt.claim.sub = '21020000-0000-0000-0000-000000000001';
select pg_temp.check((public.redeem_code((select c from ac))->>'alpha')::boolean, 'альфа-код активирован');
reset role;
select pg_temp.check((select alpha from public.profiles where tg_id = 2102), 'профиль отмечен альфа-тестером');
select pg_temp.check((public.morph_state('21020000-0000-0000-0000-000000000001')->>'conj_cap')::int = 15
                     and (public.morph_state('21020000-0000-0000-0000-000000000001')->>'decl_cap')::int = 15, 'вся грамматика открыта');

-- 10: путь — разговорные темы первыми внутри уровня
set request.jwt.claim.sub = '21020000-0000-0000-0000-000000000001';
set role authenticated;
select pg_temp.check((select (x->>'colloquial')::boolean from jsonb_array_elements(public.get_path()->'topics') x
                      where x->>'cefr' = 'A2' limit 1), 'на A2 первой идёт разговорная тема');
-- 7: марафон
set request.jwt.claim.sub = '21010000-0000-0000-0000-000000000001';
select pg_temp.check((public.start_marathon('A1', true)->>'pos')::int = 0, 'марафон A1 начат');
select pg_temp.check(jsonb_array_length(public.marathon_batch('A1', 5)->'items') = 5, 'первые 5 слов');
select pg_temp.check((public.marathon_answer('A1', 0, true)->>'pos')::int = 1, 'ответ засчитан');
select pg_temp.check(public.marathon_answer('A1', 0, true)->>'duplicate' = 'true', 'повтор не засчитывается');
select pg_temp.check((public.marathon_batch('A1', 3)->'items'->0->>'mpos')::int = 1, 'продолжение с места остановки');
select pg_temp.check((select (x->>'pos')::int = 1 from jsonb_array_elements(public.get_marathon()->'levels') x where x->>'cefr' = 'A1'), 'прогресс виден в меню');
reset role;

delete from public.profiles where tg_id in (2101, 2102);
