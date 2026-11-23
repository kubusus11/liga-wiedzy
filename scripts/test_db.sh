#!/usr/bin/env bash
# Uruchamia migracje + seed + testy na lokalnym PostgreSQL (bez Dockera).
# Użycie: PGHOST=... PGPORT=... scripts/test_db.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=quizverse_test
export PGUSER=${PGUSER:-postgres}
dropdb --if-exists "$DB" >/dev/null
createdb "$DB"
run() { psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$1" >/dev/null; }
run supabase/tests/supabase_stub.sql
for f in supabase/migrations/*.sql; do run "$f"; done
[ -f supabase/seed.sql ] && run supabase/seed.sql
for t in supabase/tests/test_*.sql; do
  echo "== $t"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$t"
done
echo "OK"
