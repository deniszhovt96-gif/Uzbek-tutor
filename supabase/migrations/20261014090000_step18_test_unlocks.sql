-- =============================================================================
-- Шаг 18: сданный тест уровня засчитывает темы грамматики этого уровня и ниже
--   • спряжение и склонение: времена/падежи этих тем открыты, потолок уровня растёт;
--   • рекомендации не предлагают темы грамматики уже подтверждённого уровня.
-- =============================================================================

create or replace function public.morph_state(p_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with lvl as (
    select max(cefr) as cefr from public.level_test_attempts where user_id = p_user and passed),
  passed as (
    select u.source_no from public.course_units u
     where u.course_id = 'grammar'
       and (exists (select 1 from public.course_progress cp
                     where cp.user_id = p_user and cp.unit_id = u.id and (cp.read_at is not null or cp.status = 'tested'))
            or u.cefr <= (select cefr from lvl)))
  select jsonb_build_object(
    'grammar', coalesce((select jsonb_agg(source_no order by source_no) from passed), '[]'::jsonb),
    'by_test', (select cefr from lvl),
    'conj_cap', (select case when count(*) = 13 then 15 else greatest(1, floor(15.0 * count(*) / 13))::int end
                   from passed where source_no in (3,5,6,7,8,16,21,22,23,24,25,26,27)),
    'decl_cap', (select case when count(*) = 3 then 15 else greatest(1, floor(15.0 * count(*) / 3))::int end
                   from passed where source_no in (9,10,11)))
$$;
revoke execute on function public.morph_state(uuid) from public, anon, authenticated;

create or replace function public.get_next_step()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid      uuid := auth.uid();
  v_today    date;
  v_tz       text;
  v_unlocked text;
  v_words    boolean;
  v_course   boolean;
  v_dialog   boolean;
  v_cons     boolean;
  v_last     text;
  v_order    text[] := array['grammar','culture','civics','history'];
  v_start    int;
  v_c        text;
  v_unit     record;
  v_next     jsonb;
  k          int;
  v_passed   text;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  v_today := public.user_today(v_uid);
  v_tz := coalesce((select timezone from public.profiles where id = v_uid), 'Asia/Tashkent');
  v_unlocked := public.unlocked_cefr(v_uid);
  v_passed := (select max(cefr) from public.level_test_attempts where user_id = v_uid and passed);

  v_words := exists (select 1 from public.study_sessions where user_id = v_uid and local_day = v_today and finished_at is not null);
  v_course := exists (select 1 from public.course_progress cp join public.course_units u on u.id = cp.unit_id
                       where cp.user_id = v_uid and u.course_id <> 'dialogs' and (cp.read_at at time zone v_tz)::date = v_today);
  v_dialog := exists (select 1 from public.course_progress cp join public.course_units u on u.id = cp.unit_id
                       where cp.user_id = v_uid and u.course_id = 'dialogs' and (cp.read_at at time zone v_tz)::date = v_today);
  v_cons := exists (select 1 from public.verb_progress where user_id = v_uid and (last_at at time zone v_tz)::date = v_today)
         or exists (select 1 from public.sentence_progress where user_id = v_uid and (last_at at time zone v_tz)::date = v_today)
         or exists (select 1 from public.word_check_attempts where user_id = v_uid and (started_at at time zone v_tz)::date = v_today);

  if not v_words then
    v_next := jsonb_build_object('kind', 'words');
  elsif not v_course then
    -- курс, следующий за последним изученным
    select u.course_id into v_last from public.course_progress cp join public.course_units u on u.id = cp.unit_id
     where cp.user_id = v_uid and u.course_id <> 'dialogs' and cp.read_at is not null
     order by cp.read_at desc limit 1;
    v_start := coalesce(array_position(v_order, v_last), 0);
    for k in 1..4 loop
      v_c := v_order[(v_start + k - 1) % 4 + 1];
      select u.id, u.course_id, u.title_ru, u.title_uz, u.title_en, u.cefr into v_unit
        from public.course_units u
        left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = v_uid
       where u.course_id = v_c and u.cefr <= v_unlocked and cp.read_at is null and public.unit_allowed(u)
         and (v_c <> 'grammar' or v_passed is null or u.cefr > v_passed)
       order by u.cefr, u.sort_order limit 1;
      if found then
        v_next := jsonb_build_object('kind', 'course', 'course', v_unit.course_id, 'unit_id', v_unit.id, 'cefr', v_unit.cefr,
                                     'title_ru', v_unit.title_ru, 'title_uz', v_unit.title_uz, 'title_en', v_unit.title_en);
        exit;
      end if;
    end loop;
  end if;
  if v_next is null and v_words and not v_dialog then
    select u.id, u.title_ru, u.title_uz, u.title_en, u.cefr into v_unit
      from public.course_units u
      left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = v_uid
     where u.course_id = 'dialogs' and u.cefr <= v_unlocked and cp.read_at is null and public.unit_allowed(u)
     order by u.cefr, u.sort_order limit 1;
    if found then
      v_next := jsonb_build_object('kind', 'dialog', 'course', 'dialogs', 'unit_id', v_unit.id, 'cefr', v_unit.cefr,
                                   'title_ru', v_unit.title_ru, 'title_uz', v_unit.title_uz, 'title_en', v_unit.title_en);
    end if;
  end if;
  if v_next is null and v_words and not v_cons then
    v_next := jsonb_build_object('kind', 'consolidate', 'what',
      case when exists (select 1 from public.verb_progress where user_id = v_uid and due_on <= v_today) then 'conj'
           when exists (select 1 from public.sentence_progress where user_id = v_uid and due_on <= v_today) then 'sentences'
           when (select count(*) from public.word_progress where user_id = v_uid) >= 20 then 'quiz'
           else 'conj' end);
  end if;
  return jsonb_build_object(
    'next', coalesce(v_next, jsonb_build_object('kind', 'done')),
    'steps', jsonb_build_object('words', v_words, 'course', v_course, 'dialog', v_dialog, 'consolidate', v_cons));
end
$$;
