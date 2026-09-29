import fs from 'node:fs'
import path from 'node:path'

const evidence = process.env.PHASE10_EVIDENCE_DIR || '.phase10-evidence'
const failures = []
const pass = (name, ok, detail = '') => {
  const line = `${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` - ${detail}` : ''}`
  ;(ok ? console.log : console.error)(line)
  if (!ok) failures.push(name)
}
const file = (name) => path.join(evidence, name)
const read = (name) => fs.existsSync(file(name)) ? fs.readFileSync(file(name), 'utf8') : ''
const requiresFile = (name) => pass(`evidence file ${name}`, fs.existsSync(file(name)))
const requiresText = (name, needle, label) => {
  const text = read(name)
  pass(label || `${name} contains ${needle}`, text.includes(needle))
}

console.log(`Auditing Phase 10 evidence: ${evidence}`)

for (const name of [
  'release.log',
  'runtime-versions.txt',
  'npm-ci.log',
  'context-verify.log',
  'cumulative-verify.log',
  'phase10-verify.log',
  'typecheck.log',
  'build.log',
  'db-reset.log',
  'cumulative-pgtap.log',
  'runtime-setup.log',
  'f147.log',
  'f149-injection.log',
  'f149-killed-client.log',
  'f157-db.log',
  'browser-runtime.log',
  'browser-duplicate-bin.log',
  'reconciliation-before-browser.log',
  'reconciliation-after-browser.log',
  'RELEASE_GATE_PASSED.txt',
]) requiresFile(name)

requiresText('release.log', 'PASS Phase 10 release-candidate verification: all five runtime proofs and mandatory gates are green', 'release log has terminal PASS')
requiresText('cumulative-pgtap.log', 'Result: PASS', 'cumulative pgTAP reports PASS')
requiresText('f147.log', 'PASS F-147', 'F-147 concurrency proof passed')
requiresText('f149-injection.log', 'PASS F-149 injected mid-batch failure', 'F-149 injected-failure proof passed')
requiresText('f149-killed-client.log', 'PASS F-149 killed-client rollback', 'F-149 killed-client rollback proof passed')
requiresText('f149-killed-client.log', 'PASS F-149 post-crash same-id retry', 'F-149 post-crash retry proof passed')
requiresText('browser-runtime.log', 'PASS F-153 real Chromium multi-context race', 'F-153 browser concurrency proof passed')
requiresText('browser-runtime.log', 'PASS F-154 real Chromium persistent-profile restart', 'F-154 restart proof passed')
requiresText('f157-db.log', 'PASS F-157 PostgreSQL resolver', 'F-157 DB ambiguity proof passed')
requiresText('browser-duplicate-bin.log', 'PASS F-157 real browser workflow', 'F-157 browser workflow proof passed')
requiresText('reconciliation-after-browser.log', 'reconciliation_summary', 'post-browser reconciliation executed')

const browserDup = read('browser-duplicate-bin.log')
const terminalFailurePatterns = [/Traceback \(most recent call last\)/, /TimeoutError:/, /AssertionError:/]
for (const pattern of terminalFailurePatterns) {
  pass(`F-157 browser log has no ${pattern.source}`, !pattern.test(browserDup))
}

const marker = read('RELEASE_GATE_PASSED.txt')
for (const finding of ['F-147=PASS', 'F-149=PASS', 'F-153=PASS', 'F-154=PASS', 'F-157=PASS']) {
  pass(`release marker contains ${finding}`, marker.includes(finding))
}

const releaseLog = read('release.log')
const releaseCommit = releaseLog.match(/^commit=([0-9a-f]{40})$/m)?.[1] || ''
const markerCommit = marker.match(/^commit=([0-9a-f]{40})$/m)?.[1] || ''
pass('release run started from clean worktree', /^dirty_worktree=0$/m.test(releaseLog))
pass('release marker commit matches release log commit', Boolean(releaseCommit) && releaseCommit === markerCommit, releaseCommit && markerCommit ? `${releaseCommit}` : 'commit missing')

if (failures.length) {
  console.error(`\nPhase 11 evidence audit FAILED with ${failures.length} problem(s). Baseline must remain NOT_SEALED.`)
  process.exit(1)
}
console.log('\nPASS Phase 11 evidence audit: Phase 10 release evidence is complete, internally consistent, and sealable.')
