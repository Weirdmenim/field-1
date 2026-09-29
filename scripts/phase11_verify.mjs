import fs from 'node:fs'
import { execFileSync } from 'node:child_process'
const failures=[]
const pass=(name,condition,detail='')=>{if(condition)console.log(`PASS ${name}${detail?` - ${detail}`:''}`);else{console.error(`FAIL ${name}${detail?` - ${detail}`:''}`);failures.push(name)}}
const must=[
  'docs/project/MASTER_PRODUCT_BUILD_CONTEXT.md','docs/phase11/PHASE11_CHARTER.md','docs/phase11/PHASE11_IMPLEMENTATION_PLAN.md',
  'docs/phase11/PHASE11_TEST_EVIDENCE_PLAN.md','docs/phase11/PHASE11_RISK_REGISTER.md','docs/phase11/PHASE11_ENTRY_AUDIT.md',
  'scripts/phase11_evidence_audit.mjs','scripts/phase11_final_evidence_audit.mjs','scripts/phase11_release_candidate.sh',
  'scripts/phase11_runner.sh','scripts/phase11_security_baseline.sh'
]
for(const f of must) pass(`Phase 11 asset ${f}`,fs.existsSync(f))
const state=JSON.parse(fs.readFileSync('docs/project/PROJECT_STATE.json','utf8'))
pass('Phase 11 remains current until real evidence seals it',state.current_phase===11&&state.current_phase_status==='IN_PROGRESS')
pass('Phase 11 program baseline remains unsealed before execution',state.program_approval?.phase11_program_baseline==='NOT_SEALED')
pass('Phase 12 remains only the next phase',state.next_phase_after_current===12)
const raw=fs.readFileSync('scripts/phase11_runner.sh','utf8')
pass('raw Phase 11 runner is fail-closed',raw.includes('set -euo pipefail'))
pass('raw Phase 11 runner cannot mint pass marker',!raw.includes('PHASE11_GATE_PASSED.txt'))
const py=fs.readFileSync('scripts/phase11_runner.py','utf8')
pass('legacy Python runner is safe delegate',py.includes('phase11_runner.sh')&&!py.includes('write_text('))
const all=fs.readFileSync('scripts/phase11_test_all.sh','utf8')
pass('legacy test-all runner is safe delegate',all.includes('phase11_runner.sh')&&!all.includes('|| echo'))
const audit=fs.readFileSync('scripts/phase11_final_evidence_audit.mjs','utf8')
pass('only independent auditor mints final marker',audit.includes('PHASE11_GATE_PASSED.txt')&&audit.includes('evidence_sha256'))
const release=fs.readFileSync('scripts/phase11_release_candidate.sh','utf8')
pass('release candidate requires clean Git provenance',release.includes('Git worktree must be clean')&&release.includes('git rev-parse HEAD'))
pass('release candidate runs independent final auditor',release.includes('phase11_final_evidence_audit.mjs'))
const backup=fs.readFileSync('scripts/phase11_backup_restore.sh','utf8')
pass('backup proof targets real public inventory_balances',backup.includes('public.inventory_balances')&&!backup.includes('phase10_test.inventory_balances'))
const stress=fs.readFileSync('scripts/phase11_offline_stress_test.py','utf8')
pass('offline stress targets production OutboxV2 schema',stress.includes("'FieldOneOffline'")&&stress.includes("'OutboxV2'")&&stress.includes("schemaVersion: 2"))
const vite=fs.readFileSync('vite.config.ts','utf8')
pass('clean checkout does not require generated Figma metadata',!vite.includes("from './.figma/make/site.json'")&&vite.includes('loadOptionalFigmaSiteConfiguration'))
pass('Vite config uses ESM-safe project root',vite.includes('fileURLToPath(import.meta.url)')&&!vite.includes('__dirname'))
const gitignore=fs.existsSync('.gitignore')?fs.readFileSync('.gitignore','utf8'):''
pass('repository ignores node_modules',/(^|\n)node_modules\/(\n|$)/.test(gitignore))
pass('repository ignores dist output',/(^|\n)dist\/(\n|$)/.test(gitignore))
pass('repository ignores generated Phase 11 evidence',gitignore.includes('.phase11-evidence/'))
if(fs.existsSync('.git')){
  const trackedNodeModules=execFileSync('git',['ls-files','node_modules'],{encoding:'utf8'}).trim()
  const trackedDist=execFileSync('git',['ls-files','dist'],{encoding:'utf8'}).trim()
  pass('node_modules is not tracked by Git',trackedNodeModules==='')
  pass('dist is not tracked by Git',trackedDist==='')
}
const manifest=fs.readFileSync('docs/phase11/PHASE11_RELEASE_MANIFEST.md','utf8')
pass('documentation does not claim Phase 11 already passed',manifest.includes('PENDING EXECUTION')&&!manifest.includes('officially sealed'))
if(failures.length){console.error(`\n${failures.length} Phase 11 verification check(s) failed.`);process.exit(1)}
console.log('\nPASS Phase 11 hardened-candidate static verification.')
