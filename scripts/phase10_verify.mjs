import fs from 'node:fs'
import { execFileSync } from 'node:child_process'
const checks=[];const add=(n,o,d='')=>checks.push([n,Boolean(o),d])
const pkg=JSON.parse(fs.readFileSync('package.json','utf8'))
add('Phase 10 architecture audit script exists',fs.existsSync('scripts/phase10_architecture_gap_audit.mjs'))
add('Phase 10 release candidate runner exists',fs.existsSync('scripts/phase10_release_candidate.sh'))
add('Phase 10 concurrent dispatch proof exists',fs.existsSync('scripts/phase10_concurrent_dispatch.sh'))
add('Phase 10 deterministic failure injection proof exists',fs.existsSync('scripts/phase10_failure_injection.sh'))
add('Phase 10 killed-client rollback proof exists',fs.existsSync('scripts/phase10_killed_client_rollback.sh'))
add('Phase 10 browser outbox proof exists',fs.existsSync('scripts/phase10_browser_outbox_runtime.py'))
add('Phase 10 duplicate-bin DB proof exists',fs.existsSync('scripts/phase10_duplicate_bin_db.sh'))
add('Phase 10 duplicate-bin browser proof exists',fs.existsSync('scripts/phase10_browser_duplicate_bin.py'))
add('Phase 10 reconciliation SQL exists',fs.existsSync('scripts/phase10_release_reconciliation.sql'))
add('Phase 10 CI workflow exists',fs.existsSync('.github/workflows/phase10-release-candidate.yml'))
add('Phase 10 npm verify script registered',pkg.scripts?.['phase10:verify']==='node scripts/phase10_verify.mjs && node scripts/phase10_architecture_gap_audit.mjs')
add('Phase 10 release script registered',pkg.scripts?.['phase10:release-candidate']==='bash scripts/phase10_release_candidate.sh')
let bashPath = 'bash';
try { execFileSync('bash', ['--version']); } catch { bashPath = 'C:\\Program Files\\Git\\bin\\bash.exe'; }
for(const f of ['scripts/phase10_release_candidate.sh','scripts/phase10_db_setup.sh','scripts/phase10_concurrent_dispatch.sh','scripts/phase10_failure_injection.sh','scripts/phase10_killed_client_rollback.sh','scripts/phase10_duplicate_bin_db.sh','scripts/phase10_browser_test.sh','scripts/phase10_reconcile.sh']){
  let ok=true;try{execFileSync(bashPath,['-n',f])}catch{ok=false}add(`shell syntax ${f}`,ok)
}
for(const f of ['scripts/phase10_browser_outbox_runtime.py','scripts/phase10_browser_duplicate_bin.py']){
  let ok=true;try{execFileSync('python',['-m','py_compile',f],{shell:true})}catch{ok=false}add(`python syntax ${f}`,ok)
}
let failed=0;for(const [n,o,d] of checks){console.log(`${o?'PASS':'FAIL'} ${n}${d?` - ${d}`:''}`);if(!o)failed++}
if(failed){console.error(`\nPhase 10 preparation checks failed: ${failed}`);process.exit(1)}
console.log('\nPhase 10 release-runner preparation checks passed.')
