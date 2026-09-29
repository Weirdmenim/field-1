#!/usr/bin/env bash
set -euo pipefail
source scripts/phase10_psql_common.sh
OUT_DIR=${PHASE10_EVIDENCE_DIR:-.phase10-evidence}; mkdir -p "$OUT_DIR"
p10_psql -f scripts/phase10_release_reconciliation.sql | tee "$OUT_DIR/reconciliation.log"
printf '%s\n' 'PASS Phase 10 release reconciliation invariants'
