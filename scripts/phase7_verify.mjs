import fs from 'node:fs'
const failures=[]
const read=(p)=>fs.readFileSync(p,'utf8')
const pass=(n,c,d='')=>{if(c)console.log(`PASS ${n}${d?` - ${d}`:''}`);else{console.error(`FAIL ${n}${d?` - ${d}`:''}`);failures.push(n)}}
const migration=read('supabase/migrations/20260918170000_phase7_identifiers_scanning.sql')
const scan=read('src/components/inventory/Scan.tsx')
const scanner=read('src/lib/scanner.ts')
const sync=read('src/lib/syncEngine.ts')
const docs=read('src/lib/documents.ts')
const queries=read('src/lib/queries.ts')
const receive=read('src/components/inventory/ReceiveTransfer.tsx')
const dispatch=read('src/components/inventory/Dispatch.tsx')
const count=read('src/components/inventory/CycleCount.tsx')
for(const [name,condition] of [
 ['normalized tenant SKU uniqueness',migration.includes('products_company_normalized_sku_unique_idx')&&migration.includes('normalized_sku')],
 ['production barcode/identifier table',migration.includes('CREATE TABLE IF NOT EXISTS product_identifiers')&&migration.includes("'BARCODE','GTIN','ALIAS'")],
 ['identifier namespace collision guards',migration.includes('phase7_guard_identifier_namespace')&&migration.includes('phase7_guard_sku_namespace')],
 ['exact server identifier resolver',migration.includes('resolve_inventory_identifier')&&!migration.includes('ILIKE')],
 ['transactional resolver uses actionable document lines',migration.includes("l.line_status IN ('OPEN','CAPTURED','EXCEPTION','READY_TO_POST')")],
 ['duplicate line/bin ambiguity returned',migration.includes("WHEN v_count=1 THEN 'resolved' ELSE 'ambiguous'")&&migration.includes("'bin_code'" )],
 ['durable unknown scan table',migration.includes('inventory_unknown_scan_events')&&migration.includes('client_event_id UUID NOT NULL')],
 ['unknown scan outbox command',sync.includes('unknown_scan_report')&&sync.includes('reportUnknownInventoryScan')],
 ['camera acquisition uses getUserMedia',scanner.includes('getUserMedia')&&scanner.includes('facingMode')],
 ['browser barcode detector adapter',scanner.includes('BarcodeDetector')&&scanner.includes('detect(')],
 ['hardware keyboard-wedge adapter',scanner.includes('attachHardwareScanner')&&scanner.includes('event.key === "Enter"')],
 ['duplicate scan state reachable',scanner.includes('onDuplicate')&&scan.includes('setState("duplicate")')],
 ['scanner lifecycle handles denied/unsupported',scan.includes('state === "denied" || state === "unsupported"')],
 ['scanner stops camera on background',scanner.includes('document.hidden')&&scanner.includes('visibilitychange')],
 ['manual transactional resolution is exact server resolution',scan.includes('resolveInventoryIdentifier')&&!scan.includes('dataResolveCode')],
 ['ambiguity UI requires line/bin selection',scan.includes('Choose the exact document line')&&scan.includes('Bin {candidate.binCode}')],
 ['unknown report carries document context',scan.includes('documentType: ctx === "receive" ? "TRANSFER"')],
 ['query item barcode no longer aliases SKU',!queries.includes('barcode: row.sku')&&queries.includes("from('product_identifiers')")],
 ['receive same-quantity exceptions reachable',receive.includes('Record condition / identity exception')],
 ['unresolved receive condition exceptions block final queue',receive.includes('unresolvedExceptions')&&receive.includes('receiptReady')],
 ['dispatch review gated until lines accounted',dispatch.includes('if (allTerminal) draft.updateState')],
 ['count reason has no default preselection',count.includes('reason ?? ""')&&count.includes('no default is preselected')],
 ['recount clears stale observation/reason draft state',count.includes('decision === "RECOUNT"')&&count.includes('observationCommandId: null')&&count.includes('reason: null')],
 ['Phase 7 migration does not mutate stock',!/UPDATE\s+inventory_balances/i.test(migration)&&!/INSERT\s+INTO\s+inventory_movements/i.test(migration)],
 ['Phase 7 preflight exists',fs.existsSync('supabase/preflight/phase7_existing_data.sql')],
 ['Phase 7 DB tests exist',fs.existsSync('supabase/tests/phase7_identifiers_scanning.sql')],
]) pass(name,condition)
const tests=read('supabase/tests/phase7_identifiers_scanning.sql')
const plan=Number(tests.match(/SELECT plan\((\d+)\)/)?.[1]??0)
const assertions=(tests.match(/SELECT\s+(?:is|isnt|ok|throws_ok|lives_ok|has_function|has_table|has_index)\s*\(/g)??[]).length
pass('Phase 7 pgTAP plan matches assertions',plan===assertions,`${plan} planned / ${assertions} found`)
if(failures.length){console.error(`\n${failures.length} Phase 7 verification check(s) failed.`);process.exit(1)}
console.log('\nPhase 7 static scanner/identifier/workflow checks passed.')
