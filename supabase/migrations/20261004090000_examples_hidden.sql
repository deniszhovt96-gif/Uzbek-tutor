-- Пример можно скрыть (например, если в узбекском тексте осталось русское слово),
-- не удаляя его из базы: скрытые примеры не показываются и не используются в заданиях.
alter table public.examples add column if not exists is_hidden boolean not null default false;
