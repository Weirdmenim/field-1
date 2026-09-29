import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'

const ROOT = process.cwd()
const EVIDENCE = process.env.PHASE11_EVIDENCE_DIR || '.phase11-evidence'
const failures = []
const pass = (name, ok, detail = '') => {
  const line = `${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` - ${detail}` : ''}`
  ;(ok ? console.log : console.error)(line)
  if (!ok) failures.push(name)
}
const p = (...parts) => path.join(EVIDENCE, ...parts)
const exists = (...parts) => fs.existsSync(p(...parts))
const text = (...parts) => exists(...parts) ? fs.readFileSync(p(...parts), 'utf8') : ''
const json = (...parts) => JSON.parse(text(...parts))

console.log(`=== Independent Phase 11 Final Evidence Auditor: ${EVIDENCE} ===`)

// The historical Phase 10 seal remains a prerequisite.
try {
  execFileSync(process.execPath, ['scripts/phase11_evidence_audit.mjs'], { cwd: ROOT, stdio: 'pipe' })
  pass('Phase 10 canonical evidence remains valid', true)
} catch (error) {
  pass('Phase 10 canonical evidence remains valid', false, String(error?.stderr || error?.message || error))
}

// Provenance.
pass('provenance run.json exists', exists('provenance', 'run.json'))
let provenance = {}
try { provenance = json('provenance', 'run.json') } catch { failures.push('provenance JSON parse') }
pass('source commit is a 40-character Git SHA', /^[0-9a-f]{40}$/.test(provenance.source_commit || ''))
pass('worktree was clean at test start', provenance.dirty_worktree_at_start === false)
try {
  const currentCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim()
  const dirtyNow = execFileSync('git', ['status', '--porcelain'], { cwd: ROOT, encoding: 'utf8' }).trim()
  pass('source commit remained unchanged during the gate', currentCommit === provenance.source_commit, currentCommit)
  pass('worktree is still clean at seal time', dirtyNow === '', dirtyNow || 'clean')
} catch (error) {
  pass('Git provenance remains readable at seal time', false, String(error?.message || error))
}
for (const f of ['npm-ci.log','phase11-verify.log','phase10-evidence-audit.log','typecheck.log','build.log','db-reset.log','runtime-setup.log','raw-runner.log']) {
  pass(`provenance evidence ${f}`, exists('provenance', f))
}

// Guard against the exact false-positive mechanism discovered in prior packages.
for (const file of ['scripts/phase11_runner.py','scripts/phase11_runner.sh','scripts/phase11_test_all.sh']) {
  const src = fs.readFileSync(file, 'utf8')
  pass(`${file} cannot mint the Phase 11 pass marker`, !src.includes('PHASE11_GATE_PASSED.txt'))
}
const pyRunner = fs.readFileSync('scripts/phase11_runner.py', 'utf8')
pass('Python compatibility runner delegates instead of synthesizing evidence', pyRunner.includes('phase11_runner.sh') && !pyRunner.includes('write_text('))

// Real E2E flow evidence.
for (const name of ['auth','receive','dispatch','count','recovery']) {
  const file = p('e2e', `${name}.log`)
  pass(`E2E ${name} log exists`, fs.existsSync(file))
  if (!fs.existsSync(file)) continue
  const body = fs.readFileSync(file, 'utf8')
  pass(`E2E ${name} passed`, /^Status: PASS$/m.test(body))
  const errors = body.split('Errors:\n')[1]?.trim() || ''
  pass(`E2E ${name} has no captured browser errors`, errors === '')
}

// Tenant isolation evidence must prove the expected semantics, not merely exist.
for (const f of ['cross-tenant-read.log','cross-tenant-write.log','rpc-bypass.log']) {
  pass(`tenant evidence ${f}`, exists('tenant-security', f) && /result=PASS/.test(text('tenant-security', f)))
}
pass('cross-tenant read returned an empty RLS result', /http_code=200/.test(text('tenant-security','cross-tenant-read.log')) && /body=\[\]/.test(text('tenant-security','cross-tenant-read.log')))
pass('cross-tenant write did not return success', !/http_code=20[01]/.test(text('tenant-security','cross-tenant-write.log')))
pass('cross-tenant RPC failed authorization', !/http_code=200/.test(text('tenant-security','rpc-bypass.log')) && /(permission|authoriz|42501|warehouse)/i.test(text('tenant-security','rpc-bypass.log')))

// Backup/restore evidence. The source table is never destructively truncated;
// pg_dump output is restored into an isolated shadow table and compared byte-for-byte.
pass('backup archive exists and is non-empty', exists('backup-restore','inventory-balances.sql') && fs.statSync(p('backup-restore','inventory-balances.sql')).size > 0)
for (const f of ['backup.log','source-stability.log','restore-setup.log','restore.log','reconciliation.log','source-before.tsv','source-after-dump.tsv','restored.tsv']) {
  pass(`backup/restore ${f}`, exists('backup-restore', f))
}
pass('backup source stayed stable while pg_dump ran', /source_unchanged_during_dump=true/.test(text('backup-restore','source-stability.log')))
pass('backup/restore inventory fingerprint matches', /Match: True/.test(text('backup-restore','reconciliation.log')))
const before = text('backup-restore','reconciliation.log').match(/^hash_before=([0-9a-f]{64})$/m)?.[1]
const after = text('backup-restore','reconciliation.log').match(/^hash_after=([0-9a-f]{64})$/m)?.[1]
const rowsBefore = Number(text('backup-restore','reconciliation.log').match(/^rows_before=(\d+)$/m)?.[1] || 0)
const rowsAfter = Number(text('backup-restore','reconciliation.log').match(/^rows_after=(\d+)$/m)?.[1] || 0)
pass('backup/restore compares real non-empty SHA-256 fingerprints', Boolean(before) && before === after)
pass('backup/restore row counts match and are non-zero', rowsBefore > 0 && rowsBefore === rowsAfter)
pass('backup/restore canonical snapshots are byte-identical', exists('backup-restore','source-before.tsv') && exists('backup-restore','restored.tsv') && fs.readFileSync(p('backup-restore','source-before.tsv')).equals(fs.readFileSync(p('backup-restore','restored.tsv'))))

// Offline/restart stress evidence.
pass('offline stress results exist', exists('offline-stress','results.json'))
let stress = {}
try { stress = json('offline-stress','results.json') } catch { failures.push('offline stress JSON parse') }
pass('offline stress status PASS', stress.status === 'PASS')
pass('offline stress enqueued at least 200 valid commands', Number(stress.commands_enqueued) >= 200)
pass('offline stress confirmed every enqueued command', Number(stress.commands_confirmed) >= Number(stress.commands_enqueued) && Number(stress.commands_enqueued) >= 200)
pass('offline stress survived browser restart', Number(stress.restart_persisted) >= Number(stress.commands_enqueued) && Number(stress.commands_enqueued) >= 200)
pass('offline stress measured positive throughput', Number.isFinite(Number(stress.throughput_ops_sec)) && Number(stress.throughput_ops_sec) > 0)
pass('restart evidence exists', exists('offline-stress','restart.log'))
pass('stable-key evidence exists', exists('offline-stress','duplicate-command.log') && /"result":\s*"PASS"/.test(text('offline-stress','duplicate-command.log')))

// Performance is a measured baseline, not an invented SLA.
pass('performance benchmark exists', exists('performance','benchmark.json'))
let perf = {}
try { perf = json('performance','benchmark.json') } catch { failures.push('performance JSON parse') }
pass('performance baseline status PASS', perf.status === 'PASS' && perf.baseline_only_no_sla_claim === true)
for (const scenario of ['inventory_balance_read','identifier_resolution']) {
  const item = perf.scenarios?.[scenario]
  pass(`${scenario} has >=20 real samples`, Number(item?.samples) >= 20)
  pass(`${scenario} contains finite measured latency`, Number.isFinite(Number(item?.avg_ms)) && Number(item?.avg_ms) > 0 && Number.isFinite(Number(item?.p95_ms)) && Number(item?.p95_ms) > 0)
}
pass('performance baseline incorporates measured offline sync throughput', Number.isFinite(Number(perf.scenarios?.offline_sync?.throughput_ops_sec)) && Number(perf.scenarios?.offline_sync?.throughput_ops_sec) > 0)

// Security evidence and policy.
for (const f of ['dependency-audit.json','dependency-audit-policy.log','secrets-scan.log','rls-audit.log','security-definer-audit.log','production-config-baseline.log']) pass(`security evidence ${f}`, exists('security', f))
let audit = {}
try { audit = json('security','dependency-audit.json') } catch { failures.push('dependency audit JSON parse') }
const vuln = audit.metadata?.vulnerabilities || {}
pass('dependency audit has no high vulnerabilities', Number(vuln.high || 0) === 0)
pass('dependency audit has no critical vulnerabilities', Number(vuln.critical || 0) === 0)
pass('dependency policy passed', /result=PASS/.test(text('security','dependency-audit-policy.log')))
pass('high-signal source secret scan passed', /result=PASS/.test(text('security','secrets-scan.log')))
pass('RLS audit passed', /result=PASS/.test(text('security','rls-audit.log')))
pass('SECURITY DEFINER search_path audit passed', /result=PASS/.test(text('security','security-definer-audit.log')))
pass('production config limitations explicitly recorded', /local-development-config-only/.test(text('security','production-config-baseline.log')))

if (failures.length) {
  console.error(`\nPhase 11 final evidence audit FAILED with ${failures.length} problem(s). No pass marker was written.`)
  process.exit(1)
}

// Hash every raw evidence artifact before writing the manifest/marker.
const listFiles = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
  const full = path.join(dir, entry.name)
  if (entry.isDirectory()) return listFiles(full)
  return [full]
})
const rawFiles = listFiles(EVIDENCE).filter((f) => !f.endsWith('manifest.json') && !f.endsWith('PHASE11_GATE_PASSED.txt') && !f.endsWith('provenance/final-evidence-audit.log'))
const hashes = Object.fromEntries(rawFiles.sort().map((f) => {
  const rel = path.relative(EVIDENCE, f).replaceAll('\\','/')
  return [rel, crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex')]
}))
const completedAt = new Date().toISOString()
const manifest = {
  phase: 11,
  phase_name: 'Truth Gate and Inventory Baseline',
  status: 'EVIDENCE_VERIFIED_SEALABLE',
  source_commit: provenance.source_commit,
  completed_at: completedAt,
  gates: {
    phase10_truth_gate: 'PASS', application_e2e: 'PASS', tenant_isolation: 'PASS',
    backup_restore: 'PASS', offline_stress: 'PASS', performance_baseline: 'PASS', security_baseline: 'PASS'
  },
  evidence_sha256: hashes,
}
fs.writeFileSync(p('manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
fs.writeFileSync(p('PHASE11_GATE_PASSED.txt'), [
  'FieldOne Phase 11 final evidence gate passed.',
  `source_commit=${provenance.source_commit}`,
  `completed_at=${completedAt}`,
  'application_e2e=PASS', 'tenant_isolation=PASS', 'backup_restore=PASS',
  'offline_stress=PASS', 'performance_baseline=PASS', 'security_baseline=PASS', ''
].join('\n'))
console.log('\nPASS Phase 11 final evidence audit: raw evidence is complete, semantic checks passed, hashes recorded, and the baseline is SEALABLE.')
