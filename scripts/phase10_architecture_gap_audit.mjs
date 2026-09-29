import fs from 'node:fs'

function parseCsvLine(line){const out=[];let cur='',q=false;for(let i=0;i<line.length;i++){const c=line[i];if(c==='"'){if(q&&line[i+1]==='"'){cur+='"';i++}else q=!q}else if(c===','&&!q){out.push(cur);cur=''}else cur+=c}out.push(cur);return out}
const csv=fs.readFileSync('docs/remediation/REMEDIATION_MATRIX.csv','utf8').trim().split(/\r?\n/)
const header=parseCsvLine(csv[0]);const idx=Object.fromEntries(header.map((x,i)=>[x,i]));const rows=csv.slice(1).map(parseCsvLine)
const notClosed=rows.filter(r=>r[idx.Status]!=='CLOSED').map(r=>r[idx['Audit ID']]).sort()
const expected=[]
const checks=[]
const add=(name,ok,detail='')=>checks.push([name,ok,detail])
add('canonical matrix still has 186 rows',rows.length===186,String(rows.length))
add('all runtime proofs are verified and all findings are closed',notClosed.length===0,notClosed.join(','))
const srcFiles=[]
function walk(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=`${dir}/${e.name}`;if(e.isDirectory())walk(p);else if(/\.(ts|tsx)$/.test(e.name))srcFiles.push(p)}}
walk('src')
const source=srcFiles.map(f=>fs.readFileSync(f,'utf8')).join('\n')
add('client does not call retired generic post_inventory_operation',!source.includes('post_inventory_operation('))
add('client does not directly write inventory_balances',!/(?:from\(["']inventory_balances["']\))[\s\S]{0,120}\.(?:insert|update|delete)\(/.test(source))
add('client does not directly write inventory_movements',!/(?:from\(["']inventory_movements["']\))[\s\S]{0,120}\.(?:insert|update|delete)\(/.test(source))
add('client does not directly write inventory_operations',!/(?:from\(["']inventory_operations["']\))[\s\S]{0,120}\.(?:insert|update|delete)\(/.test(source))
add('production screens do not import legacy data.ts fixture exports',!srcFiles.some(f=>f!=='src/components/inventory/data.ts'&&fs.readFileSync(f,'utf8').match(/from\s+['"][^'"]*data['"]/)))
const required=[
 'scripts/phase10_runtime_setup.sql','scripts/phase10_concurrent_dispatch.sh','scripts/phase10_failure_injection.sh','scripts/phase10_killed_client_rollback.sh',
 'scripts/phase10_browser_outbox_runtime.py','scripts/phase10_browser_duplicate_bin.py','scripts/phase10_duplicate_bin_db.sh','scripts/phase10_release_candidate.sh',
 'scripts/phase10_release_reconciliation.sql','docs/remediation/PHASE10_HARNESS_AUDIT.md','docs/remediation/PHASE10_MIGRATION_CHECKLIST.md',
 'docs/remediation/PHASE10_RECONCILIATION_CHECKLIST.md','docs/remediation/PHASE10_RELEASE_CHECKLIST.md','.github/workflows/phase10-release-candidate.yml'
]
for(const f of required)add(`required Phase 10 asset ${f}`,fs.existsSync(f))
const conc=fs.existsSync('scripts/phase10_concurrent_dispatch.sh')?fs.readFileSync('scripts/phase10_concurrent_dispatch.sh','utf8'):''
add('F-147 harness asserts one accepted and one revision conflict',conc.includes("len(accepted)==1")&&conc.includes("STOCK_REVISION_CONFLICT")&&conc.includes("saleMovements"))
const fail=fs.existsSync('scripts/phase10_failure_injection.sh')?fs.readFileSync('scripts/phase10_failure_injection.sh','utf8'):''
const kill=fs.existsSync('scripts/phase10_killed_client_rollback.sh')?fs.readFileSync('scripts/phase10_killed_client_rollback.sh','utf8'):''
add('F-149 harness covers deterministic second-line rollback',fail.includes('PHASE10_INJECTED_SECOND_LINE_FAILURE')&&fail.includes("movements'])==0"))
add('F-149 harness covers killed client plus same-id retry',kill.includes('timeout --signal=KILL')&&kill.includes('post-crash same-id retry'))
const browser=fs.existsSync('scripts/phase10_browser_outbox_runtime.py')?fs.readFileSync('scripts/phase10_browser_outbox_runtime.py','utf8'):''
add('F-153 harness uses four contexts and exact-once RPC assertion',browser.includes('range(3)')&&browser.includes('TOTAL=40')&&browser.includes("calls.get(i)==1"))
add('F-154 harness closes and reopens persistent profile',browser.includes('launch_persistent_context')&&browser.includes("leaseOwner='dead-worker'")&&browser.includes('ctx2='))
const dup=fs.existsSync('scripts/phase10_browser_duplicate_bin.py')?fs.readFileSync('scripts/phase10_browser_duplicate_bin.py','utf8'):''
add('F-157 browser harness uses actual app exact-manual flow and both bins',dup.includes('Resolve exact')&&dup.includes('P10-DUP-A')&&dup.includes('P10-DUP-B')&&dup.includes('Confirm pick'))
let failed=0;for(const [name,ok,detail] of checks){console.log(`${ok?'PASS':'FAIL'} ${name}${detail?` - ${detail}`:''}`);if(!ok)failed++}
if(failed){console.error(`\nPhase 10 architecture gap audit failed: ${failed} check(s).`);process.exit(1)}
console.log('\nPhase 10 architecture gap audit passed: no untracked architectural finding is present outside the five explicit runtime-proof gates.')
