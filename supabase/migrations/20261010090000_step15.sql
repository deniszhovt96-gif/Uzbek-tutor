-- =============================================================================
-- Шаг 15
--   • Примеры к словам: длинные (4+ слова) попадают в задания, только когда пользователь знает большую часть
--     остальных слов предложения (уровень 4+ у ≥ 70% слов). Слова предложения — examples.word_ids (сборка словаря).
--   • «Предложения»: отдельная тренировка готовых длинных примеров со своим интервальным повторением.
--   • Спряжение и склонение: список глаголов для тренажёра (формы строит приложение по правилам).
-- =============================================================================

alter table public.examples add column if not exists word_ids int[] not null default '{}';
alter table public.examples add column if not exists n_words smallint not null default 0;

insert into public.app_config (key, value, note) values
  ('example_ready_pct',   '70', 'Длинный пример готов, если столько % его слов выучено (уровень 4+)'),
  ('example_ready_level', '4',  'Уровень слова, с которого оно считается выученным для примеров'),
  ('sentences_per_set',   '12', 'Предложений в одной тренировке')
on conflict (key) do nothing;

insert into public.feature_access (feature, min_tier, note) values
  ('sentences',   'free', 'Тренировка предложений'),
  ('conjugation', 'free', 'Спряжение и склонение')
on conflict (feature) do nothing;

-- Готов ли пример для пользователя: короткий (до 3 слов) — всегда; длинный — если выучено ≥ N% остальных слов
create or replace function public.example_ready(p_user uuid, p_word int, p_word_ids int[], p_n_words int, p_now timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when p_n_words <= 3 then true
    when cardinality(p_word_ids) = 0 then false
    else coalesce((
      select count(*) filter (where public.effective_level(wp.level, wp.level_at, p_now) >= public.cfg_int('example_ready_level', 4))::numeric
             / nullif(count(*), 0) * 100 >= public.cfg_int('example_ready_pct', 70)
      from unnest(p_word_ids) x(id)
      left join public.word_progress wp on wp.user_id = p_user and wp.word_id = x.id
      where x.id <> p_word), true) end
$$;

-- Карточка слова: у примеров — число слов и готовность
create or replace function public.word_card(p_word_id integer, p_user uuid, p_now timestamptz)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', w.id, 'uz', w.uz, 'ru', w.ru, 'topic_id', w.topic_id, 'cefr', w.cefr,
    'word_class', w.word_class, 'audio_ok', w.audio_ok,
    'register', w.register, 'literary', w.literary, 'note', w.note,
    'accept_ru', w.accept_ru, 'accept_uz', w.accept_uz,
    'level', coalesce(public.effective_level(wp.level, wp.level_at, p_now), 0),
    'stage', case when wp.word_id is null or wp.level = 0 then 'new'
                  when public.effective_level(wp.level, wp.level_at, p_now) <= 6 then 'learning'
                  else 'review' end,
    'examples', coalesce((
      select jsonb_agg(jsonb_build_object(
               'word_id', e.word_id, 'n', e.n, 'uz', e.uz, 'ru', e.ru,
               'blank_start', e.blank_start, 'blank_len', e.blank_len, 'audio_ok', e.audio_ok,
               'nw', e.n_words, 'ready', public.example_ready(p_user, w.id, e.word_ids, e.n_words, p_now))
             order by (e.word_id <> w.id), e.n)
      from public.examples e
      where not e.is_hidden
        and (e.word_id = w.id or e.word_id in (select a.id from public.words a where a.canonical_id = w.id))
    ), '[]'::jsonb),
    'distractors', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'uz', d.uz, 'ru', d.ru))
      from (
        select x.id, x.uz, x.ru from (
          select c.id, c.uz, c.ru
          from public.words c
          where c.is_active and c.canonical_id is null and c.id <> w.id
            and (c.topic_id = w.topic_id or c.cefr = w.cefr)
            and c.uz_key <> w.uz_key
            and not (c.uz_key = any (w.accept_uz))
            and not (c.accept_ru && w.accept_ru)
          order by (c.topic_id = w.topic_id) desc, (c.word_class = w.word_class) desc, random()
          limit 8
        ) x
      ) d
    ), '[]'::jsonb)
  )
  from public.words w
  left join public.word_progress wp on wp.word_id = w.id and wp.user_id = p_user
  where w.id = p_word_id
$$;

-- ---------------------------------------------------------------- тренировка предложений
create table if not exists public.sentence_progress (
  user_id   uuid not null references public.profiles(id) on delete cascade,
  word_id   int not null,
  n         smallint not null,
  level     smallint not null default 0,
  due_on    date not null,
  correct   int not null default 0,
  wrong     int not null default 0,
  last_at   timestamptz,
  primary key (user_id, word_id, n)
);
alter table public.sentence_progress enable row level security;
revoke all on public.sentence_progress from anon, authenticated;

-- Интервалы повторения предложений (дни) по уровню 0–7
create or replace function public.sentence_interval(p_level int)
returns int language sql immutable as $$
  select (array[0, 1, 3, 7, 14, 30, 60, 120])[least(greatest(p_level, 0), 7) + 1]
$$;

create or replace function public.start_sentences()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_now   timestamptz := public.app_now();
  v_today date;
  v_lvl   int := public.cfg_int('example_ready_level', 4);
  v_n     int := least(30, greatest(5, public.cfg_int('sentences_per_set', 12)));
  v_items jsonb;
  v_ready int;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not public.feature_allowed('sentences') then return jsonb_build_object('error', 'locked_tier'); end if;
  v_today := public.user_today(v_uid);

  -- кандидаты: примеры (4+ слова) к словам, которые пользователь сам знает на уровень 4+
  with mine as (
    select wp.word_id from public.word_progress wp
    join public.words w on w.id = wp.word_id and w.is_active
    where wp.user_id = v_uid and public.effective_level(wp.level, wp.level_at, v_now) >= v_lvl),
  cand as (
    select e.*, sp.level as s_level, sp.due_on as s_due
    from public.examples e
    join mine m on m.word_id = e.word_id
    left join public.sentence_progress sp on sp.user_id = v_uid and sp.word_id = e.word_id and sp.n = e.n
    where not e.is_hidden and e.n_words >= 4 and cardinality(e.word_ids) > 0
      and (sp.due_on is null or sp.due_on <= v_today)
      and public.example_ready(v_uid, -1, e.word_ids, e.n_words, v_now)),
  pick as (
    select * from cand order by (s_due is null), s_due, random() limit v_n)
  select coalesce(jsonb_agg(jsonb_build_object(
           'word_id', p.word_id, 'n', p.n, 'uz', p.uz, 'ru', p.ru, 'audio_ok', p.audio_ok,
           'blank_start', p.blank_start, 'blank_len', p.blank_len, 'nw', p.n_words,
           'level', coalesce(p.s_level, 0),
           'word', jsonb_build_object('id', w.id, 'uz', w.uz, 'ru', w.ru))), '[]'::jsonb),
         (select count(*) from cand)
    into v_items, v_ready
    from pick p join public.words w on w.id = p.word_id;

  return jsonb_build_object(
    'items', v_items, 'ready', v_ready,
    -- переводы других предложений — для вариантов ответа
    'pool', (select coalesce(jsonb_agg(ru), '[]'::jsonb) from (
               select e.ru from public.examples e join public.words w on w.id = e.word_id
               where w.cefr <= public.unlocked_cefr(v_uid) and e.n_words between 4 and 9 and not e.is_hidden
               order by random() limit 60) x));
end
$$;

create or replace function public.answer_sentence(p_word int, p_n int, p_correct boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_sp    public.sentence_progress%rowtype;
  v_level int;
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if not exists (select 1 from public.examples where word_id = p_word and n = p_n) then
    return jsonb_build_object('error', 'not_found');
  end if;
  v_today := public.user_today(v_uid);
  select * into v_sp from public.sentence_progress where user_id = v_uid and word_id = p_word and n = p_n for update;
  v_level := case when p_correct then least(7, coalesce(v_sp.level, 0) + 1) else greatest(0, coalesce(v_sp.level, 0) - 1) end;
  insert into public.sentence_progress (user_id, word_id, n, level, due_on, correct, wrong, last_at)
  values (v_uid, p_word, p_n, v_level, v_today + public.sentence_interval(case when p_correct then v_level else 0 end),
          case when p_correct then 1 else 0 end, case when p_correct then 0 else 1 end, now())
  on conflict (user_id, word_id, n) do update set
    level = excluded.level, due_on = excluded.due_on, last_at = now(),
    correct = public.sentence_progress.correct + excluded.correct,
    wrong = public.sentence_progress.wrong + excluded.wrong;
  insert into public.daily_stats (user_id, day, correct, wrong)
  values (v_uid, v_today, case when p_correct then 1 else 0 end, case when p_correct then 0 else 1 end)
  on conflict (user_id, day) do update set
    correct = public.daily_stats.correct + excluded.correct, wrong = public.daily_stats.wrong + excluded.wrong;
  return jsonb_build_object('ok', true, 'level', v_level);
end
$$;

-- ---------------------------------------------------------------- спряжение: список глаголов
create or replace function public.get_verbs()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  return jsonb_build_object('verbs', (
    select coalesce(jsonb_agg(jsonb_build_object('i', w.id, 'u', w.uz, 'r', w.ru, 'c', w.cefr,
             'l', public.effective_level(wp.level, wp.level_at, public.app_now()))
             order by (wp.word_id is null), w.sort_key), '[]'::jsonb)
    from public.words w
    left join public.word_progress wp on wp.word_id = w.id and wp.user_id = v_uid
    where w.is_active and w.canonical_id is null and w.word_class = 'verb' and w.uz ~ '(moq|mak)$'));
end
$$;

revoke execute on function public.example_ready(uuid, int, int[], int, timestamptz) from public, anon, authenticated;
revoke execute on function public.start_sentences() from public, anon;
revoke execute on function public.answer_sentence(int, int, boolean) from public, anon;
revoke execute on function public.get_verbs() from public, anon;
grant execute on function public.start_sentences() to authenticated;
grant execute on function public.answer_sentence(int, int, boolean) to authenticated;
grant execute on function public.get_verbs() to authenticated;
