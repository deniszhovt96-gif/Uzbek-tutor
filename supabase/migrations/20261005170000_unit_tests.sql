-- =============================================================================
-- Шаг 10: тесты по темам курсов + проверка вопросов администратором + ссылка на сообщество.
--
--   Вопросы (data/quiz/questions.json) загружаются как черновики (unit_tasks: kind 'choice',
--   origin 'generated', status 'draft'). Пользователи видят только одобренные администратором.
--   Тест по теме: 5 случайных одобренных вопросов, варианты перемешиваются, верные ответы — только на сервере.
--   Сдан при 4 из 5 и больше → course_progress.status = 'tested', лучший результат сохраняется.
-- =============================================================================

alter table public.unit_tasks add column if not exists quote_uz text;
alter table public.unit_tasks add column if not exists reviewed_at timestamptz;
alter table public.unit_tasks add column if not exists reviewed_by bigint;

insert into public.app_config (key, value, note) values
  ('unit_test_questions', '5', 'Вопросов в тесте по теме'),
  ('unit_test_pass', '4', 'Сколько верных ответов нужно, чтобы тест по теме считался сданным'),
  ('community_url', '""', 'Ссылка на группу/канал приложения в Telegram (например, https://t.me/имя). Пусто — кнопка скрыта')
on conflict (key) do nothing;

create table if not exists public.unit_test_attempts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  unit_id     int not null references public.course_units(id) on delete cascade,
  questions   jsonb not null,          -- [{task_id, order:[индексы вариантов в показанном порядке]}]
  answers     jsonb,
  score       int,
  total       int not null,
  passed      boolean,
  started_at  timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists unit_test_attempts_user_idx on public.unit_test_attempts (user_id, unit_id, started_at desc);
alter table public.unit_test_attempts enable row level security;
revoke all on public.unit_test_attempts from anon, authenticated;

-- Общедоступные настройки приложения (ссылка на сообщество)
create or replace function public.get_app_info()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'community_url', nullif((select value #>> '{}' from public.app_config where key = 'community_url'), ''))
$$;

-- ---------------------------------------------------------------- тест по теме
create or replace function public.start_unit_test(p_unit int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_unit public.course_units%rowtype;
  v_n    int := least(10, greatest(3, public.cfg_int('unit_test_questions', 5)));
  v_q    jsonb := '[]'::jsonb;
  v_show jsonb := '[]'::jsonb;
  r      record;
  v_ord  int[];
  v_att  uuid;
  v_lang text;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  select * into v_unit from public.course_units where id = p_unit;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if not public.unit_allowed(v_unit) then return jsonb_build_object('error', 'locked_tier'); end if;
  if (select count(*) from public.unit_tasks where unit_id = p_unit and kind = 'choice' and status = 'approved') < v_n then
    return jsonb_build_object('error', 'no_questions');
  end if;
  for r in
    select t.* from public.unit_tasks t
    where t.unit_id = p_unit and t.kind = 'choice' and t.status = 'approved'
    order by random() limit v_n
  loop
    select array_agg(i order by random()) into v_ord from generate_series(0, jsonb_array_length(r.options->'ru') - 1) i;
    v_q := v_q || jsonb_build_object('task_id', r.id, 'order', to_jsonb(v_ord));
    v_show := v_show || jsonb_build_object(
      'prompt_ru', r.prompt_ru, 'prompt_uz', r.prompt_uz, 'prompt_en', r.prompt_en,
      'options_ru', (select jsonb_agg(r.options->'ru'->o order by k) from unnest(v_ord) with ordinality as x(o, k)),
      'options_uz', (select jsonb_agg(r.options->'uz'->o order by k) from unnest(v_ord) with ordinality as x(o, k)),
      'options_en', (select jsonb_agg(r.options->'en'->o order by k) from unnest(v_ord) with ordinality as x(o, k)));
  end loop;
  insert into public.unit_test_attempts (user_id, unit_id, questions, total)
  values (v_uid, p_unit, v_q, jsonb_array_length(v_q)) returning id into v_att;
  return jsonb_build_object('attempt_id', v_att, 'total', jsonb_array_length(v_q),
                            'pass', least(public.cfg_int('unit_test_pass', 4), jsonb_array_length(v_q)), 'questions', v_show);
end
$$;

-- p_answers: индексы выбранных вариантов в показанном порядке, например [2,0,1,3,1]; -1 — «не знаю»
create or replace function public.finish_unit_test(p_attempt uuid, p_answers jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_att   public.unit_test_attempts%rowtype;
  v_score int := 0;
  v_need  int;
  v_res   jsonb := '[]'::jsonb;
  q       jsonb;
  i       int := 0;
  v_pick  int;
  v_right int;
  t       public.unit_tasks%rowtype;
begin
  select * into v_att from public.unit_test_attempts where id = p_attempt and user_id = v_uid for update;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if v_att.finished_at is not null then return jsonb_build_object('error', 'finished'); end if;
  if v_att.started_at < now() - interval '2 hours' then return jsonb_build_object('error', 'expired'); end if;
  for q in select * from jsonb_array_elements(v_att.questions) loop
    select * into t from public.unit_tasks where id = (q->>'task_id')::int;
    v_pick := coalesce((p_answers->>i)::int, -1);
    -- в исходном порядке верный вариант — с индексом 0; где он оказался после перемешивания:
    select (k - 1) into v_right from jsonb_array_elements_text(q->'order') with ordinality as x(o, k) where o::int = 0;
    if v_pick = v_right then v_score := v_score + 1; end if;
    v_res := v_res || jsonb_build_object('correct', v_pick = v_right, 'right_index', v_right, 'picked', v_pick,
                                         'quote_ru', t.source_quote, 'quote_uz', t.quote_uz);
    i := i + 1;
  end loop;
  v_need := least(public.cfg_int('unit_test_pass', 4), v_att.total);
  update public.unit_test_attempts
     set answers = p_answers, score = v_score, passed = v_score >= v_need, finished_at = now()
   where id = p_attempt;
  insert into public.course_progress (user_id, unit_id, status, best_score)
  values (v_uid, v_att.unit_id, case when v_score >= v_need then 'tested' else 'opened' end, v_score)
  on conflict (user_id, unit_id) do update set
    best_score = greatest(coalesce(public.course_progress.best_score, 0), excluded.best_score),
    status = case when excluded.status = 'tested' then 'tested' else public.course_progress.status end,
    updated_at = now();
  return jsonb_build_object('score', v_score, 'total', v_att.total, 'need', v_need, 'passed', v_score >= v_need, 'results', v_res);
end
$$;

-- ---------------------------------------------------------------- проверка вопросов администратором
create or replace function public.admin_review_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'draft', (select count(*) from public.unit_tasks where kind = 'choice' and status = 'draft'),
    'approved', (select count(*) from public.unit_tasks where kind = 'choice' and status = 'approved'),
    'rejected', (select count(*) from public.unit_tasks where kind = 'choice' and status = 'rejected'),
    'units', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', u.id, 'course_id', u.course_id, 'n', u.source_no, 'title_ru', u.title_ru,
                'draft', s.draft, 'approved', s.approved, 'rejected', s.rejected)
                order by c.sort_order, u.sort_order), '[]'::jsonb)
              from public.course_units u
              join public.courses c on c.id = u.course_id
              cross join lateral (
                select count(*) filter (where t.status = 'draft') as draft,
                       count(*) filter (where t.status = 'approved') as approved,
                       count(*) filter (where t.status = 'rejected') as rejected
                from public.unit_tasks t where t.unit_id = u.id and t.kind = 'choice') s
              where s.draft + s.approved + s.rejected > 0));
end
$$;

create or replace function public.admin_unit_questions(p_unit int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'unit', (select jsonb_build_object('id', u.id, 'course_id', u.course_id, 'n', u.source_no, 'title_ru', u.title_ru)
             from public.course_units u where u.id = p_unit),
    'questions', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', t.id, 'k', t.n - 100, 'status', t.status,
                    'prompt_ru', t.prompt_ru, 'prompt_uz', t.prompt_uz, 'prompt_en', t.prompt_en,
                    'options', t.options, 'quote_ru', t.source_quote) order by t.n), '[]'::jsonb)
                  from public.unit_tasks t where t.unit_id = p_unit and t.kind = 'choice'));
end
$$;

-- p_status: 'approved' | 'rejected' | 'draft'. p_task null + p_unit → для всех черновиков темы
create or replace function public.admin_set_question(p_task int, p_status text, p_unit int default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tg bigint := (select tg_id from public.profiles where id = auth.uid());
  v_n  int;
begin
  if not public.is_admin() then return jsonb_build_object('error', 'forbidden'); end if;
  if p_status not in ('approved','rejected','draft') then return jsonb_build_object('error', 'bad_status'); end if;
  if p_task is not null then
    update public.unit_tasks set status = p_status, reviewed_at = now(), reviewed_by = v_tg
     where id = p_task and kind = 'choice';
  else
    update public.unit_tasks set status = p_status, reviewed_at = now(), reviewed_by = v_tg
     where unit_id = p_unit and kind = 'choice' and status = 'draft';
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'updated', v_n);
end
$$;

-- ---------------------------------------------------------------- тема: есть ли тест и лучший результат
create or replace function public.unit_test_info(p_unit int)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'available', (select count(*) from public.unit_tasks t where t.unit_id = p_unit and t.kind = 'choice' and t.status = 'approved')
                 >= least(10, greatest(3, public.cfg_int('unit_test_questions', 5))),
    'best_score', (select cp.best_score from public.course_progress cp where cp.unit_id = p_unit and cp.user_id = auth.uid()),
    'passed', coalesce((select cp.status = 'tested' from public.course_progress cp where cp.unit_id = p_unit and cp.user_id = auth.uid()), false),
    'total', least(10, greatest(3, public.cfg_int('unit_test_questions', 5))))
$$;

-- ---------------------------------------------------------------- курс: отметка «тест сдан» у темы
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
                  'tested', coalesce(cp.status = 'tested', false),
                  'best_score', cp.best_score,
                  'tasks_done', coalesce(cardinality(cp.tasks_done), 0),
                  'tasks_total', (select count(*) from public.unit_tasks t where t.unit_id = u.id and t.status = 'approved' and t.kind = 'open'))
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


revoke execute on function public.start_unit_test(int) from public, anon;
revoke execute on function public.finish_unit_test(uuid, jsonb) from public, anon;
revoke execute on function public.admin_review_summary() from public, anon;
revoke execute on function public.admin_unit_questions(int) from public, anon;
revoke execute on function public.admin_set_question(int, text, int) from public, anon;
revoke execute on function public.unit_test_info(int) from public, anon;
grant execute on function public.get_app_info() to anon, authenticated;
grant execute on function public.start_unit_test(int) to authenticated;
grant execute on function public.finish_unit_test(uuid, jsonb) to authenticated;
grant execute on function public.admin_review_summary() to authenticated;
grant execute on function public.admin_unit_questions(int) to authenticated;
grant execute on function public.admin_set_question(int, text, int) to authenticated;
grant execute on function public.unit_test_info(int) to authenticated;
