#!/usr/bin/env bash
# Run after scripts/load.sh. Fails if any integrity check finds a violation or if any
# rule-breaking statement in tests/trigger_tests.sql is accepted.
set -euo pipefail
cd "$(dirname "$0")/.."
MYSQL=${MYSQL:-"mysql -u root"}
fail=0

echo "== Integrity checks"
while IFS=$'\t' read -r rule n; do
  printf '  %-75s %s\n' "$rule" "$n"
  [ "$n" = "0" ] || fail=1
done < <($MYSQL -N pm_tracker < tests/integrity.sql)

echo "== Rule-breaking statements (each must be rejected)"
MYSQL="$MYSQL" python3 tests/run_trigger_tests.py || fail=1

echo "== Analytics queries run without errors"
$MYSQL pm_tracker < queries/analytics.sql > /dev/null && echo "  8 queries ok" || fail=1

[ $fail -eq 0 ] && echo "All checks passed." || { echo "Checks FAILED."; exit 1; }
