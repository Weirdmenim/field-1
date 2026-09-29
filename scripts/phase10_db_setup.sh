#!/usr/bin/env bash
set -euo pipefail
source scripts/phase10_psql_common.sh
p10_psql -f scripts/phase10_runtime_setup.sql
printf '%s\n' 'PASS Phase 10 PostgreSQL runtime fixture setup'
