-- Исправление: у слова без прогресса (NULL) действующий уровень получался 1 вместо 0,
-- потому что greatest() в Postgres пропускает NULL. Теперь NULL остаётся NULL,
-- а word_card превращает его в 0 (coalesce).
create or replace function public.effective_level(p_level int, p_level_at timestamptz, p_now timestamptz)
returns int language sql immutable as $$
  select case when p_level is null or p_level_at is null then p_level
              when p_level <= 1 then p_level
              else greatest(1, p_level - floor(extract(epoch from (p_now - p_level_at)) / (90 * 86400))::int)
         end
$$;
