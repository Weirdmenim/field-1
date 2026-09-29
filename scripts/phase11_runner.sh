#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
EVIDENCE="${PHASE11_EVIDENCE_DIR:-.phase11-evidence}"
mkdir -p "$EVIDENCE"/{e2e,tenant-security,backup-restore,offline-stress,performance,security,provenance}

if command -v python3 >/dev/null 2>&1; then PYTHON=${PHASE11_PYTHON:-python3}
elif command -v python >/dev/null 2>&1; then PYTHON=${PHASE11_PYTHON:-python}
else echo 'Python is required' >&2; exit 2; fi
"$PYTHON" -c 'import playwright' >/dev/null 2>&1 || { echo 'Python Playwright is required' >&2; exit 2; }

echo '=== Phase 11B raw evidence generation (fail-closed) ==='
"$PYTHON" scripts/phase11_e2e_runner.py
bash scripts/phase11_tenant_attacks.sh
bash scripts/phase11_backup_restore.sh
"$PYTHON" scripts/phase11_offline_stress_test.py
"$PYTHON" scripts/phase11_performance_baseline.py
bash scripts/phase11_security_baseline.sh

echo 'PASS Phase 11B raw evidence generation. No seal marker is created by this runner.'
