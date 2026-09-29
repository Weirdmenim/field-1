import fs from 'node:fs'
import { execFileSync } from 'node:child_process'

const failures = []
const pass = (name, condition, detail = '') => {
  if (condition) console.log(`PASS ${name}${detail ? ` - ${detail}` : ''}`)
  else { console.error(`FAIL ${name}${detail ? ` - ${detail}` : ''}`); failures.push(name) }
}

const coreRequired = [
  'docs/project/PROJECT_STATE.json',
  'docs/project/CONTEXT_SYSTEM.md',
  'docs/project/INVARIANTS.md',
  'docs/project/DECISION_LOG.md',
  'docs/project/PHASE_JOURNAL.md',
  'docs/project/VERIFICATION_LEDGER.md',
  'docs/project/NEXT_PHASE_CONTRACT.md',
  'docs/remediation/REMEDIATION_MATRIX.csv',
]
for (const path of coreRequired) pass(`context file ${path}`, fs.existsSync(path))

const state = JSON.parse(fs.readFileSync('docs/project/PROJECT_STATE.json', 'utf8'))
for (const path of state.context_files ?? []) pass(`state context file ${path}`, fs.existsSync(path))

pass('canonical finding count remains 186', state.canonical_audit_findings === 186)
pass('current phase is recorded', Number.isInteger(state.current_phase) && state.current_phase >= 0 && typeof state.current_phase_name === 'string' && state.current_phase_name.length > 0)
pass('entry head recorded', /^[0-9a-f]{40}$/.test(state.entry_head))
pass('implementation commit recorded', !state.implementation_commit || /^[0-9a-f]{40}$/.test(state.implementation_commit))
pass('latest frozen phase is not ahead of current phase', Number.isInteger(state.latest_frozen_phase) && state.latest_frozen_phase <= state.current_phase)

const matrix = fs.readFileSync('docs/remediation/REMEDIATION_MATRIX.csv', 'utf8')
const findingRows = matrix.split(/\r?\n/).filter((line) => /^F-\d{3},/.test(line))
pass('matrix still contains 186 findings', findingRows.length === 186, `${findingRows.length} rows`)
const matrixStatusTotal = Object.values(state.matrix_status ?? {}).reduce((sum, value) => sum + Number(value || 0), 0)
pass('project-state matrix counts sum to 186', matrixStatusTotal === 186, `${matrixStatusTotal}`)

const invariants = fs.readFileSync('docs/project/INVARIANTS.md', 'utf8')
pass('Phase 1 trust boundary persisted', invariants.includes('Client-provided `user_id` and `company_id` are never authorization facts'))
pass('Phase 2 ATP invariant persisted', invariants.includes('Available-to-promise = AVAILABLE physical - remaining active reservations'))
pass('unsafe generic COUNT remains fail closed', invariants.includes('Direct COUNT mutation stays rejected'))
if (state.latest_frozen_phase >= 3) {
  pass('Phase 3 authoritative-document invariant persisted', invariants.includes('Transfers, sales orders, count sessions/observations/approvals, and backorders are authoritative server entities'))
  pass('Phase 3 no-stock-write invariant persisted', invariants.includes('Document capture/approval in Phase 3 never updates `inventory_balances`'))
  pass('Phase 3 handoff exists', fs.existsSync('docs/remediation/PHASE3_HANDOFF.md'))
}
if (state.latest_frozen_phase >= 4) {
  pass('Phase 4 stable command identity invariant persisted', invariants.includes('Document stock posting uses a company-scoped UUID `client_command_id` independent of command type'))
  pass('Phase 4 authoritative delta invariant persisted', invariants.includes('Authoritative stock delta is always derived server-side'))
  pass('Phase 4 generic document posting remains disabled', invariants.includes('Generic application RECEIVE/DISPATCH/COUNT posting remains disabled'))
  pass('Phase 4 handoff exists', fs.existsSync('docs/remediation/PHASE4_HANDOFF.md'))
  pass('Phase 4 migration exists', fs.existsSync('supabase/migrations/20260917200000_phase4_atomic_document_commands.sql'))
}

if (state.latest_frozen_phase >= 5) {
  pass('Phase 5 append-only ledger invariant persisted', invariants.includes('Posted `inventory_movements` rows are append-only'))
  pass('Phase 5 document-linked reversal fail-closed invariant persisted', invariants.includes('Document-linked transfer/sales/count movements never use generic movement reversal'))
  pass('Phase 5 handoff exists', fs.existsSync('docs/remediation/PHASE5_HANDOFF.md'))
  pass('Phase 5 migration exists', fs.existsSync('supabase/migrations/20260918090000_phase5_ledger_reversals.sql'))
  pass('Phase 5 admin repair runbook exists', fs.existsSync('docs/remediation/PHASE5_ADMIN_REPAIR_RUNBOOK.md'))
}

if (state.latest_frozen_phase >= 6) {
  pass('Phase 6 record-per-command outbox invariant persisted', invariants.includes('The executable outbox is record-per-command'))
  pass('Phase 6 owner quarantine invariant persisted', invariants.includes('Ownerless legacy or malformed records are quarantined'))
  pass('Phase 6 stable local command identity invariant persisted', invariants.includes('Stable business command UUID is created with the local action'))
  pass('Phase 6 cross-context coordination invariant persisted', invariants.includes('Multi-context execution is serialized through Web Locks'))
  pass('Phase 6 authoritative workflow cutover invariant persisted', invariants.includes('Receive, Dispatch, and Count use authoritative Phase 3 documents and Phase 4 commands'))
  pass('Phase 6 handoff exists', fs.existsSync('docs/remediation/PHASE6_HANDOFF.md'))
  pass('Phase 6 migration exists', fs.existsSync('supabase/migrations/20260918130000_phase6_offline_workflow_support.sql'))
  pass('Phase 6 offline-store implementation exists', fs.existsSync('src/lib/offlineStore.ts'))
}


if (state.latest_frozen_phase >= 7) {
  pass('Phase 7 exact transactional identifier invariant persisted', invariants.includes('Transactional product resolution is exact, tenant scoped, and server authorized'))
  pass('Phase 7 identifier namespace invariant persisted', invariants.includes('SKU and active BARCODE/GTIN/ALIAS namespaces cannot resolve to different products'))
  pass('Phase 7 scanner input-only invariant persisted', invariants.includes('Scanner acquisition (camera or hardware wedge) is an input adapter only'))
  pass('Phase 7 durable unknown-scan invariant persisted', invariants.includes('Unknown scans are durable, owner/context scoped, idempotent by client event UUID'))
  pass('Phase 7 unresolved receipt exception invariant persisted', invariants.includes('Non-shortage receipt condition/identity exceptions remain blocked from ordinary receipt finalization'))
  pass('Phase 7 handoff exists', fs.existsSync('docs/remediation/PHASE7_HANDOFF.md'))
  pass('Phase 7 migration exists', fs.existsSync('supabase/migrations/20260918170000_phase7_identifiers_scanning.sql'))
  pass('Phase 7 scanner implementation exists', fs.existsSync('src/lib/scanner.ts'))
}

if (state.latest_frozen_phase >= 8) {
  pass('Phase 8 active reachability invariant persisted', invariants.includes('Backend reachability is established by an active bounded Supabase probe'))
  pass('Phase 8 durable storage invariant persisted', invariants.includes('Durable storage errors are explicit and fail sync closed'))
  pass('Phase 8 cold-offline identity invariant persisted', invariants.includes('Cold offline operational context may be reused only for the same persisted authenticated user'))
  pass('Phase 8 receipt disposition invariant persisted', invariants.includes('Receipt condition/identity exceptions are business-complete only after an authoritative immutable disposition'))
  pass('Phase 8 legacy generic posting remains retired', invariants.includes('The client-callable generic `post_inventory_operation(JSONB)` compatibility path remains revoked'))
  pass('Phase 8 handoff exists', fs.existsSync('docs/remediation/PHASE8_HANDOFF.md'))
  pass('Phase 8 production-hardening migration exists', fs.existsSync('supabase/migrations/20260918210000_phase8_production_hardening.sql'))
  pass('Phase 8 service worker exists', fs.existsSync('public/sw.js'))
}

if (state.latest_frozen_phase >= 9) {
  pass('Phase 9 explicit stock revision invariant persisted', invariants.includes('Every public final stock command carries an explicit authoritative snapshot of physical-status revision'))
  pass('Phase 9 immutable precondition identity invariant persisted', invariants.includes('A company-scoped stable command UUID has one immutable stock-precondition fingerprint'))
  pass('Phase 9 shared position-lock invariant persisted', invariants.includes('Balance and reservation writers acquire the same transaction-scoped position locks'))
  pass('Phase 9 stale stock conflict invariant persisted', invariants.includes('A stale physical or reservation snapshot returns typed `STOCK_REVISION_CONFLICT`'))
  pass('Phase 9 handoff exists', fs.existsSync('docs/remediation/PHASE9_HANDOFF.md'))
  pass('Phase 9 migration exists', fs.existsSync('supabase/migrations/20260919090000_phase9_stock_revision_preconditions.sql'))
}

if (state.latest_frozen_phase >= 10) {
  pass('Phase 10 runtime evidence discipline persisted', invariants.includes('Runtime-only findings are promoted only from captured execution evidence'))
  pass('Phase 10 all-or-nothing release gate invariant persisted', invariants.includes('canonical Phase 10 gate runs clean install/typecheck/build'))
  pass('Phase 10 browser proof authority invariant persisted', invariants.includes('actual production outbox module with real browser IndexedDB/Web Locks/BroadcastChannel/persistent-profile semantics'))
  pass('Phase 10 handoff exists', fs.existsSync('docs/remediation/PHASE10_HANDOFF.md'))
  pass('Phase 10 runner exists', fs.existsSync('scripts/phase10_release_candidate.sh'))
  pass('Phase 10 CI workflow exists', fs.existsSync('.github/workflows/phase10-release-candidate.yml'))
}

try {
  const tags = execFileSync('git', ['tag', '--list'], { encoding: 'utf8' })
  pass('baseline tag retained', tags.includes(state.baseline_tag))
  for (const tag of state.phase_tags ?? []) pass(`phase tag retained ${tag}`, tags.includes(tag))
} catch (error) {
  pass('git tags readable', false, String(error))
}

if (failures.length) {
  console.error(`\n${failures.length} project-context check(s) failed.`)
  process.exit(1)
}
console.log('\nProject context continuity checks passed.')
