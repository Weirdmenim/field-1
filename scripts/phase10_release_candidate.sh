#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

EVIDENCE=${PHASE10_EVIDENCE_DIR:-.phase10-evidence}
if [[ -e "$EVIDENCE" ]]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  archive="${EVIDENCE}.previous.${stamp}"
  suffix=0
  while [[ -e "$archive" ]]; do
    suffix=$((suffix + 1))
    archive="${EVIDENCE}.previous.${stamp}.${suffix}"
  done
  mv "$EVIDENCE" "$archive"
  echo "Preserved prior Phase 10 evidence at $archive"
fi
mkdir -p "$EVIDENCE"
export PHASE10_EVIDENCE_DIR="$EVIDENCE"

VITE_PID=''
STARTED_SUPABASE=0
cleanup(){
  if [[ -n "$VITE_PID" ]]; then kill "$VITE_PID" >/dev/null 2>&1 || true; wait "$VITE_PID" >/dev/null 2>&1 || true; fi
  if [[ "$STARTED_SUPABASE" == 1 && "${PHASE10_KEEP_SERVICES:-0}" != 1 ]]; then npx --no-install supabase stop --no-backup >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

require(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing required executable: $1" >&2; exit 2; }; }
require node; require npm; require docker; require psql; require curl; require git; require bash
if command -v python3 >/dev/null 2>&1; then PYTHON=${PHASE10_PYTHON:-python3}
elif command -v python >/dev/null 2>&1; then PYTHON=${PHASE10_PYTHON:-python}
else echo 'Python is required' >&2; exit 2; fi
"$PYTHON" -c 'import playwright' >/dev/null 2>&1 || { echo 'Python playwright package is required' >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo 'Docker daemon is not available' >&2; exit 2; }
node -e "const [M,m]=process.versions.node.split('.').map(Number);if(M!==22||m<12)process.exit(1)" || { echo 'Node 22.12-22.x is required' >&2; exit 2; }

printf '%s\n' '=== Phase 10 release-candidate verification ===' | tee "$EVIDENCE/release.log"
printf 'commit=%s\n' "$(git rev-parse HEAD)" | tee -a "$EVIDENCE/release.log"
printf 'dirty_worktree=%s\n' "$(git status --porcelain | wc -l | tr -d ' ')" | tee -a "$EVIDENCE/release.log"
printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$EVIDENCE/release.log"

if [[ "${PHASE10_SKIP_NPM_CI:-0}" != 1 ]]; then
  npm ci --no-audit --no-fund 2>&1 | tee "$EVIDENCE/npm-ci.log"
fi

{
  echo "node=$(node --version)"
  echo "npm=$(npm --version)"
  echo "docker=$(docker --version)"
  echo "supabase=$(npx --no-install supabase --version)"
  echo "psql=$(psql --version)"
  echo "python=$($PYTHON --version 2>&1)"
  playwright_version=$("$PYTHON" -c "import importlib.metadata as m; print(m.version('playwright'))")
  echo "playwright=$playwright_version"
} | tee "$EVIDENCE/runtime-versions.txt" | tee -a "$EVIDENCE/release.log"
npm run context:verify 2>&1 | tee "$EVIDENCE/context-verify.log"
npm run verify 2>&1 | tee "$EVIDENCE/cumulative-verify.log"
npm run phase10:verify 2>&1 | tee "$EVIDENCE/phase10-verify.log"
npm run typecheck 2>&1 | tee "$EVIDENCE/typecheck.log"
npm run build 2>&1 | tee "$EVIDENCE/build.log"

if npx --no-install supabase status >/dev/null 2>&1; then :; else
  npx --no-install supabase start 2>&1 | tee "$EVIDENCE/supabase-start.log"
  STARTED_SUPABASE=1
fi
npx --no-install supabase db reset 2>&1 | tee "$EVIDENCE/db-reset.log"
npm run phase9:db-test 2>&1 | tee "$EVIDENCE/cumulative-pgtap.log"

scripts/phase10_db_setup.sh 2>&1 | tee "$EVIDENCE/runtime-setup.log"
scripts/phase10_concurrent_dispatch.sh 2>&1 | tee "$EVIDENCE/f147.log"
scripts/phase10_failure_injection.sh 2>&1 | tee "$EVIDENCE/f149-injection.log"
scripts/phase10_killed_client_rollback.sh 2>&1 | tee "$EVIDENCE/f149-killed-client.log"
scripts/phase10_duplicate_bin_db.sh 2>&1 | tee "$EVIDENCE/f157-db.log"
scripts/phase10_reconcile.sh 2>&1 | tee "$EVIDENCE/reconciliation-before-browser.log"

npm run dev -- --host 127.0.0.1 --port 4173 >"$EVIDENCE/vite.log" 2>&1 &
VITE_PID=$!
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:4173 >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:4173 >/dev/null || { echo 'Vite app did not become reachable' >&2; exit 1; }
export PHASE10_APP_URL=${PHASE10_APP_URL:-http://127.0.0.1:4173}
"$PYTHON" scripts/phase10_browser_outbox_runtime.py 2>&1 | tee "$EVIDENCE/browser-runtime.log"
"$PYTHON" scripts/phase10_browser_duplicate_bin.py 2>&1 | tee "$EVIDENCE/browser-duplicate-bin.log"
scripts/phase10_reconcile.sh 2>&1 | tee "$EVIDENCE/reconciliation-after-browser.log"

cat > "$EVIDENCE/RELEASE_GATE_PASSED.txt" <<PASS
FieldOne Inventory Phase 10 release-candidate gate passed.
commit=$(git rev-parse HEAD)
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
F-147=PASS
F-149=PASS
F-153=PASS
F-154=PASS
F-157=PASS
cumulative_pgTAP=PASS
typecheck=PASS
production_build=PASS
reconciliation=PASS
PASS
printf '%s\n' 'PASS Phase 10 release-candidate verification: all five runtime proofs and mandatory gates are green' | tee -a "$EVIDENCE/release.log"
