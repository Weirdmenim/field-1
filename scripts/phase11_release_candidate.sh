#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
EVIDENCE="${PHASE11_EVIDENCE_DIR:-.phase11-evidence}"
export PATH=$PATH:'/c/Program Files/PostgreSQL/17/bin'


require(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing required executable: $1" >&2; exit 2; }; }
for cmd in node npm git docker psql pg_dump pg_restore curl bash; do require "$cmd"; done
if command -v python3 >/dev/null 2>&1; then PYTHON=${PHASE11_PYTHON:-python3}
elif command -v python >/dev/null 2>&1; then PYTHON=${PHASE11_PYTHON:-python}
else echo 'Python is required' >&2; exit 2; fi
"$PYTHON" -c 'import playwright' >/dev/null 2>&1 || { echo 'Python Playwright is required' >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo 'Docker daemon unavailable' >&2; exit 2; }
node -e "const [M,m]=process.versions.node.split('.').map(Number); if(M!==22||m<12) process.exit(1)" || { echo 'Node 22.12-22.x is required' >&2; exit 2; }

# Provenance is checked before generating ignored evidence.
[[ -d .git ]] || { echo 'Phase 11 sealing must run from the real Git repository.' >&2; exit 2; }
DIRTY=$(git status --porcelain)
[[ -z "$DIRTY" ]] || { echo 'Git worktree must be clean before Phase 11 release candidate.' >&2; printf '%s\n' "$DIRTY" >&2; exit 1; }
COMMIT=$(git rev-parse HEAD)

if [[ -e "$EVIDENCE" ]]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  mv "$EVIDENCE" "${EVIDENCE}.previous.${stamp}"
fi
mkdir -p "$EVIDENCE/provenance"
export PHASE11_EVIDENCE_DIR="$EVIDENCE"
export PHASE11_APP_URL="${PHASE11_APP_URL:-http://127.0.0.1:4173}"
export PHASE11_SUPABASE_URL="${PHASE11_SUPABASE_URL:-http://127.0.0.1:54321}"
export PHASE11_DB_URL="${PHASE11_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
export SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-${VITE_SUPABASE_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0}}"

cat > "$EVIDENCE/provenance/run.json" <<JSON
{
  "source_commit": "$COMMIT",
  "dirty_worktree_at_start": false,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "node": "$(node --version)",
  "npm": "$(npm --version)",
  "python": "$($PYTHON --version 2>&1)",
  "psql": "$(psql --version | sed 's/"/\\"/g')"
}
JSON

VITE_PID=''
STARTED_SUPABASE=0
cleanup(){
  if [[ -n "$VITE_PID" ]]; then kill "$VITE_PID" >/dev/null 2>&1 || true; wait "$VITE_PID" >/dev/null 2>&1 || true; fi
  if [[ "$STARTED_SUPABASE" == 1 && "${PHASE11_KEEP_SERVICES:-0}" != 1 ]]; then npx --no-install supabase stop --no-backup >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

npm ci --no-audit --no-fund 2>&1 | tee "$EVIDENCE/provenance/npm-ci.log"
npm run phase11:verify 2>&1 | tee "$EVIDENCE/provenance/phase11-verify.log"
npm run phase11:evidence-audit 2>&1 | tee "$EVIDENCE/provenance/phase10-evidence-audit.log"
npm run typecheck 2>&1 | tee "$EVIDENCE/provenance/typecheck.log"
npm run build 2>&1 | tee "$EVIDENCE/provenance/build.log"

if ! npx --no-install supabase status >/dev/null 2>&1; then
  npx --no-install supabase start 2>&1 | tee "$EVIDENCE/provenance/supabase-start.log"
  STARTED_SUPABASE=1
fi
npx --no-install supabase db reset 2>&1 | tee "$EVIDENCE/provenance/db-reset.log"
bash scripts/phase10_db_setup.sh 2>&1 | tee "$EVIDENCE/provenance/runtime-setup.log"

npm run dev -- --host 127.0.0.1 --port 4173 > "$EVIDENCE/provenance/vite.log" 2>&1 &
VITE_PID=$!
for _ in $(seq 1 60); do
  curl -fsS "$PHASE11_APP_URL" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$PHASE11_APP_URL" >/dev/null || { echo 'Vite app did not become reachable' >&2; exit 1; }

bash scripts/phase11_runner.sh 2>&1 | tee "$EVIDENCE/provenance/raw-runner.log"
node scripts/phase11_final_evidence_audit.mjs 2>&1 | tee "$EVIDENCE/provenance/final-evidence-audit.log"

echo 'PASS Phase 11 release candidate: independent evidence audit sealed the evidence bundle.'
