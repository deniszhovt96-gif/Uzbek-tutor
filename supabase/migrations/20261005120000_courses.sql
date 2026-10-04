-- =============================================================================
-- Шаг 9: курсы «Грамматика», «История», «Обществознание» (контент — scripts/build_courses.py).
--
--   Доступ: feature_access (grammar — basic, history/civics/culture — advanced).
--   Первые темы каждого курса открыты всем (app_config.course_preview_units, по умолчанию 2).
--   Грамматика: к теме подбираются настоящие примеры из словаря по шаблону course_units.example_pattern
--   (регулярное выражение PostgreSQL; меняется в Table Editor без программиста).
-- =============================================================================

-- ---------------------------------------------------------------- дополнения схемы
alter table public.course_units add column if not exists period text;              -- история: «1370–1405 гг.»
alter table public.course_units add column if not exists period_uz text;
alter table public.course_units add column if not exists period_en text;
alter table public.course_units add column if not exists example_pattern text;     -- грамматика: шаблон поиска примеров
alter table public.reference_items add column if not exists kind text not null default 'contact';
alter table public.reference_items add column if not exists extra jsonb;
alter table public.course_progress add column if not exists tasks_done smallint[] not null default '{}';
alter table public.course_progress add column if not exists read_at timestamptz;

create unique index if not exists course_sections_uniq on public.course_sections (course_id, title_ru);
create unique index if not exists course_units_uniq on public.course_units (course_id, source_no);
create unique index if not exists timeline_events_uniq on public.timeline_events (course_id, sort_order);
create unique index if not exists reference_items_uniq on public.reference_items (course_id, kind, sort_order);

insert into public.app_config (key, value, note) values
  ('course_preview_units', '2', 'Сколько первых тем каждого курса открыто без подписки')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- доступ к теме
create or replace function public.course_feature(p_course text)
returns text language sql immutable as $$
  select case p_course when 'grammar' then 'grammar' when 'history' then 'history'
                       when 'civics' then 'civics' else 'culture' end
$$;

create or replace function public.unit_allowed(p_unit public.course_units)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.feature_allowed(public.course_feature(p_unit.course_id))
      or p_unit.sort_order <= public.cfg_int('course_preview_units', 2)
$$;

-- ---------------------------------------------------------------- список курсов
create or replace function public.get_courses()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'title_ru', c.title_ru, 'title_uz', c.title_uz, 'title_en', c.title_en,
           'units', s.units, 'read', s.read,
           'allowed', public.feature_allowed(public.course_feature(c.id)),
           'min_tier', (select fa.min_tier from public.feature_access fa where fa.feature = public.course_feature(c.id)))
         order by c.sort_order), '[]'::jsonb)
  from public.courses c
  cross join lateral (
    select count(*) as units,
           count(cp.read_at) as read
    from public.course_units u
    left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = auth.uid()
    where u.course_id = c.id
  ) s
$$;

-- ---------------------------------------------------------------- курс: разделы, темы, хронология, справочник
create or replace function public.get_course(p_course text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not exists (select 1 from public.courses where id = p_course) then return jsonb_build_object('error', 'not_found'); end if;
  return (
    select jsonb_build_object(
      'id', c.id, 'title_ru', c.title_ru, 'title_uz', c.title_uz, 'title_en', c.title_en,
      'allowed', public.feature_allowed(public.course_feature(c.id)),
      'min_tier', (select fa.min_tier from public.feature_access fa where fa.feature = public.course_feature(c.id)),
      'preview', public.cfg_int('course_preview_units', 2),
      'sections', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', s.id, 'title_ru', s.title_ru, 'title_uz', s.title_uz, 'title_en', s.title_en) order by s.sort_order), '[]'::jsonb)
                   from public.course_sections s where s.course_id = c.id),
      'units', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', u.id, 'n', u.source_no, 'section_id', u.section_id,
                  'title_ru', u.title_ru, 'title_uz', u.title_uz, 'title_en', u.title_en,
                  'period', u.period, 'period_uz', u.period_uz, 'period_en', u.period_en,
                  'express_ru', u.express_ru, 'express_uz', u.express_uz, 'express_en', u.express_en,
                  'locked', not public.unit_allowed(u),
                  'read', cp.read_at is not null,
                  'tasks_done', coalesce(cardinality(cp.tasks_done), 0),
                  'tasks_total', (select count(*) from public.unit_tasks t where t.unit_id = u.id and t.status = 'approved'))
                order by u.sort_order), '[]'::jsonb)
                from public.course_units u
                left join public.course_progress cp on cp.unit_id = u.id and cp.user_id = v_uid
                where u.course_id = c.id),
      'timeline', (select coalesce(jsonb_agg(jsonb_build_object(
                     'date', e.date_label, 'text_ru', e.text_ru, 'text_uz', e.text_uz, 'text_en', e.text_en, 'unit_id', e.unit_id)
                     order by e.sort_order), '[]'::jsonb)
                   from public.timeline_events e where e.course_id = c.id),
      'reference', (select coalesce(jsonb_agg(jsonb_build_object(
                      'kind', r.kind, 'title_ru', r.title_ru, 'title_uz', r.title_uz, 'title_en', r.title_en,
                      'value', r.value, 'extra', r.extra) order by r.kind, r.sort_order), '[]'::jsonb)
                    from public.reference_items r where r.course_id = c.id))
    from public.courses c where c.id = p_course);
end
$$;

-- ---------------------------------------------------------------- примеры из словаря для темы грамматики
create or replace function public.unit_examples(p_unit int, p_limit int default 8, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_unit public.course_units%rowtype;
begin
  select * into v_unit from public.course_units where id = p_unit;
  if not found or v_unit.example_pattern is null or not public.unit_allowed(v_unit) then return '[]'::jsonb; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'word_id', x.word_id, 'n', x.n, 'uz', x.uz, 'ru', x.ru, 'audio_ok', x.audio_ok,
             'match', x.m, 'word_uz', x.word_uz, 'word_ru', x.word_ru) order by x.rk), '[]'::jsonb)
    from (
      select e.word_id, e.n, e.uz, e.ru, e.audio_ok, w.uz as word_uz, w.ru as word_ru,
             (regexp_match(e.uz, '(' || v_unit.example_pattern || ')', 'i'))[1] as m,
             row_number() over (order by w.cefr, (length(e.uz) > 60), md5(e.word_id::text || e.n::text || v_unit.id::text)) as rk
      from public.examples e
      join public.words w on w.id = e.word_id
      where not e.is_hidden and w.is_active and w.canonical_id is null
        and e.uz ~* v_unit.example_pattern
      order by rk
      offset greatest(coalesce(p_offset, 0), 0)
      limit least(greatest(coalesce(p_limit, 8), 1), 30)
    ) x);
exception when invalid_regular_expression then
  return '[]'::jsonb;
end
$$;

-- ---------------------------------------------------------------- тема целиком
create or replace function public.get_unit(p_unit int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_unit public.course_units%rowtype;
  v_prog public.course_progress%rowtype;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  select * into v_unit from public.course_units where id = p_unit;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if not public.unit_allowed(v_unit) then
    return jsonb_build_object('error', 'locked_tier',
      'need', (select fa.min_tier from public.feature_access fa where fa.feature = public.course_feature(v_unit.course_id)));
  end if;
  insert into public.course_progress (user_id, unit_id, status) values (v_uid, p_unit, 'opened')
  on conflict (user_id, unit_id) do update set updated_at = now()
  returning * into v_prog;
  return jsonb_build_object(
    'id', v_unit.id, 'course_id', v_unit.course_id, 'n', v_unit.source_no,
    'title_ru', v_unit.title_ru, 'title_uz', v_unit.title_uz, 'title_en', v_unit.title_en,
    'period', v_unit.period, 'period_uz', v_unit.period_uz, 'period_en', v_unit.period_en,
    'section', (select jsonb_build_object('title_ru', s.title_ru, 'title_uz', s.title_uz, 'title_en', s.title_en)
                from public.course_sections s where s.id = v_unit.section_id),
    'express_ru', v_unit.express_ru, 'express_uz', v_unit.express_uz, 'express_en', v_unit.express_en,
    'detailed_ru', v_unit.detailed_ru, 'detailed_uz', v_unit.detailed_uz, 'detailed_en', v_unit.detailed_en,
    'source', v_unit.source,
    'tasks', (select coalesce(jsonb_agg(jsonb_build_object(
                'n', t.n, 'kind', t.kind, 'prompt_ru', t.prompt_ru, 'prompt_uz', t.prompt_uz, 'prompt_en', t.prompt_en)
                order by t.n), '[]'::jsonb)
              from public.unit_tasks t where t.unit_id = v_unit.id and t.status = 'approved' and t.kind = 'open'),
    'has_examples', v_unit.example_pattern is not null,
    'examples', public.unit_examples(v_unit.id, 8, 0),
    'read', v_prog.read_at is not null,
    'tasks_done', to_jsonb(v_prog.tasks_done),
    'prev_id', (select u.id from public.course_units u where u.course_id = v_unit.course_id and u.sort_order < v_unit.sort_order order by u.sort_order desc limit 1),
    'next_id', (select u.id from public.course_units u where u.course_id = v_unit.course_id and u.sort_order > v_unit.sort_order order by u.sort_order limit 1)
  );
end
$$;

-- Отметки: тема прочитана / задание выполнено
create or replace function public.mark_unit(p_unit int, p_read boolean default null, p_task int default null, p_done boolean default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_unit public.course_units%rowtype;
  v_prog public.course_progress%rowtype;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  select * into v_unit from public.course_units where id = p_unit;
  if not found or not public.unit_allowed(v_unit) then return jsonb_build_object('error', 'not_allowed'); end if;
  insert into public.course_progress (user_id, unit_id, status) values (v_uid, p_unit, 'opened')
  on conflict (user_id, unit_id) do nothing;
  if p_read is not null then
    update public.course_progress
       set read_at = case when p_read then coalesce(read_at, now()) end,
           status = case when p_read and status = 'opened' then 'read' when not p_read and status = 'read' then 'opened' else status end,
           updated_at = now()
     where user_id = v_uid and unit_id = p_unit;
  end if;
  if p_task is not null and exists (select 1 from public.unit_tasks where unit_id = p_unit and n = p_task) then
    update public.course_progress
       set tasks_done = case when coalesce(p_done, true)
                             then (select array_agg(distinct x order by x) from unnest(tasks_done || p_task::smallint) x)
                             else array_remove(tasks_done, p_task::smallint) end,
           updated_at = now()
     where user_id = v_uid and unit_id = p_unit;
  end if;
  select * into v_prog from public.course_progress where user_id = v_uid and unit_id = p_unit;
  return jsonb_build_object('ok', true, 'read', v_prog.read_at is not null, 'tasks_done', to_jsonb(v_prog.tasks_done));
end
$$;

-- ---------------------------------------------------------------- права
revoke execute on function public.unit_allowed(public.course_units) from public, anon, authenticated;
revoke execute on function public.get_courses() from public, anon;
revoke execute on function public.get_course(text) from public, anon;
revoke execute on function public.unit_examples(int, int, int) from public, anon;
revoke execute on function public.get_unit(int) from public, anon;
revoke execute on function public.mark_unit(int, boolean, int, boolean) from public, anon;
grant execute on function public.get_courses() to authenticated;
grant execute on function public.get_course(text) to authenticated;
grant execute on function public.unit_examples(int, int, int) to authenticated;
grant execute on function public.get_unit(int) to authenticated;
grant execute on function public.mark_unit(int, boolean, int, boolean) to authenticated;
