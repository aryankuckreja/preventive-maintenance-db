#!/usr/bin/env bash
# Build the database from scratch: schema, stage 1 data, certification requirements, stage 2 data.
# Usage: scripts/load.sh            (uses MYSQL="mysql -u root" unless MYSQL is set)
set -euo pipefail
cd "$(dirname "$0")/.."
MYSQL=${MYSQL:-"mysql -u root"}
[ -f build/load_stage2.sql ] || python3 generator/gen_data.py
$MYSQL < schema/01_schema.sql
$MYSQL pm_tracker < build/load_stage1.sql
$MYSQL pm_tracker < schema/02_requires.sql
$MYSQL pm_tracker < build/load_stage2.sql
$MYSQL pm_tracker -e "SELECT COUNT(*) AS work_orders FROM Work_Order; SELECT COUNT(*) AS time_entries FROM Time_Entry;"
