#!/usr/bin/env bash
# Применяет новые миграции из supabase/migrations к базе по $SUPABASE_DB_URL.
# Без Supabase CLI: только psql. Учёт применённых миграций — в той же таблице,
# что использует Supabase CLI (supabase_migrations.schema_migrations), поэтому
# способы совместимы. Каждая миграция применяется в отдельной транзакции.
set -euo pipefail

: "${SUPABASE_DB_URL:?Не задана SUPABASE_DB_URL}"
PSQL=(psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -X -q)

"${PSQL[@]}" <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
SQL

applied=$("${PSQL[@]}" -tA -c "select version from supabase_migrations.schema_migrations")

count=0
for file in $(ls supabase/migrations/*.sql | sort); do
  base=$(basename "$file" .sql)
  version=${base%%_*}
  name=${base#*_}
  if grep -qx "$version" <<<"$applied"; then
    echo "уже применена: $base"
    continue
  fi
  echo "применяю: $base"
  "${PSQL[@]}" --single-transaction \
    -f "$file" \
    -c "insert into supabase_migrations.schema_migrations (version, name) values ('$version', '$name')"
  count=$((count + 1))
done
echo "Готово. Новых миграций применено: $count"
