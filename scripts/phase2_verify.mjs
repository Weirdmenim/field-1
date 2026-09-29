import fs from 'node:fs'

const failures = []
const pass = (name, condition, detail = '') => {
  const suffix = detail ? ` - ${detail}` : ''
  if (condition) console.log(`PASS ${name}${suffix}`)
  else {
    console.error(`FAIL ${name}${suffix}`)
    failures.push(name)
  }
}

const read = (path) => fs.readFileSync(path, 'utf8')
const migrationPath = 'supabase/migrations/20260917120000_phase2_canonical_inventory_model.sql'
pass('Phase 2 migration exists', fs.existsSync(migrationPath))
const migration = read(migrationPath)

const sqlChecks = [
  ['authoritative inventory bins exist', /CREATE TABLE IF NOT EXISTS inventory_bins/],
  ['one system default bin per location', /inventory_bins_one_system_default_idx/],
  ['balance key includes bin', /PRIMARY KEY \(company_id, location_id, bin_id, product_id, inventory_status\)/],
  ['bin FK is tenant/location safe', /inventory_balances_company_location_bin_fk/],
  ['first-class reservations exist', /CREATE TABLE IF NOT EXISTS inventory_reservations/],
  ['reservation provenance exists', /owner_type TEXT NOT NULL[\s\S]*owner_key TEXT NOT NULL/],
  ['legacy reserved balance quantity is migrated', /LEGACY_BALANCE/],
  ['legacy reserved balance column is forced to zero', /inventory_balances_reserved_column_deprecated/],
  ['in-transit custody table exists', /CREATE TABLE IF NOT EXISTS inventory_transit_lots/],
  ['transit source and destination must differ', /inventory_transit_locations_differ/],
  ['products require base UOM', /ALTER TABLE products ALTER COLUMN base_unit_id SET NOT NULL/],
  ['products require default sale UOM', /ALTER TABLE products ALTER COLUMN default_sale_unit_id SET NOT NULL/],
  ['normalized unit code uniqueness', /product_units_normalized_code_unique_idx/],
  ['UOM quantity scale enforced', /product_units_quantity_scale_check/],
  ['UOM quantity step enforced', /product_units_quantity_step_check/],
  ['UOM step precision matches declared scale', /quantity_step > 0 AND quantity_step = round\(quantity_step, quantity_scale\)/],
  ['UOM codes cannot be blank', /product_units_code_not_blank_check/],
  ['product base-default UOM configuration is validated', /FUNCTION validate_product_uom_configuration_values/],
  ['configured base/default units cannot be deactivated', /Configured base unit cannot be inactive[\s\S]*Configured default sale unit cannot be inactive/],
  ['UOM conversion function exists', /FUNCTION convert_product_quantity/],
  ['zero/negative entered quantities rejected', /p_entered_quantity IS NULL OR p_entered_quantity <= 0/],
  ['movement entered unit is required', /inventory_movements ALTER COLUMN entered_unit_id SET NOT NULL/],
  ['movement source/destination bin shape constrained', /inventory_movements_location_bin_shape/],
  ['movement source/destination statuses required when locations exist', /inventory_movements_status_shape/],
  ['status changes preserve bin identity', /STATUS_CHANGE[\s\S]*source_bin_id = destination_bin_id/],
  ['undefined transfer reversal semantics fail closed', /WHEN 'TRANSFER_REVERSAL' THEN false/],
  ['movement semantic shape constrained', /inventory_movements_semantic_shape/],
  ['negative inventory policy guard exists', /FUNCTION guard_inventory_balance_policy/],
  ['source balance is materialized then locked before deduction', /Materialize a zero row first[\s\S]*FOR UPDATE/],
  ['negative non-AVAILABLE status cannot be stored', /NEW\.inventory_status <> 'AVAILABLE'::inventory_status OR NOT v_allow_negative/],
  ['canonical location position view exists', /VIEW inventory_location_positions/],
  ['canonical ATP subtracts reservations from AVAILABLE physical', /available_physical_base_qty, 0\) - COALESCE\(rs\.reserved_base_qty, 0\) AS available_to_promise_base_qty/],
  ['in-transit remains separate in canonical view', /in_transit_inbound_base_qty/],
  ['bin-aware internal primitive exists', /FUNCTION post_inventory_operation_v2/],
  ['internal primitive revalidates active source/destination bins', /Source location\/bin is unknown, inactive[\s\S]*Destination location\/bin is unknown, inactive/],
  ['bin position view includes reservation-only and transit-only keys', /position_keys AS \([\s\S]*FROM reservations[\s\S]*FROM transit/],
  ['bin-aware primitive is not app-callable', /REVOKE ALL ON FUNCTION post_inventory_operation_v2[\s\S]*FROM PUBLIC, anon, authenticated/],
  ['legacy low-level primitive is disabled', /Deprecated Phase 1 mutation primitive/],
  ['dispatch maps to SALE', /v_movement_type := 'SALE'/],
  ['COUNT stock mutation fails closed', /COUNT is an observation and cannot mutate stock directly/],
  ['generic adjustment fails closed', /Generic ADJUSTMENT is ambiguous/],
  ['explicit adjustment in supported', /'ADJUSTMENT_IN'/],
  ['explicit adjustment out supported', /'ADJUSTMENT_OUT'/],
  ['damage status transition supported', /v_movement_type := 'DAMAGE'/],
  ['status change supported', /v_movement_type := 'STATUS_CHANGE'/],
  ['new canonical tables have RLS', /ALTER TABLE inventory_bins ENABLE ROW LEVEL SECURITY[\s\S]*ALTER TABLE inventory_reservations ENABLE ROW LEVEL SECURITY[\s\S]*ALTER TABLE inventory_transit_lots ENABLE ROW LEVEL SECURITY/],
  ['new canonical tables are SELECT-only to app role', /REVOKE ALL PRIVILEGES ON TABLE inventory_bins, inventory_reservations, inventory_transit_lots FROM anon, authenticated/],
]
for (const [name, pattern] of sqlChecks) pass(name, pattern.test(migration))

const queries = read('src/lib/queries.ts')
pass('inventory reads canonical location position view', queries.includes(".from('inventory_location_positions')"))
pass('bin detail reads canonical bin position view', queries.includes(".from('inventory_bin_positions')"))
pass('bin detail exposes inbound transit separately', queries.includes('in_transit_inbound_base_qty'))
pass('item movement detail reads real movement ledger', queries.includes(".from('inventory_movements')"))
const itemDetail = read('src/components/inventory/ItemDetail.tsx')
pass('item detail no longer mixes fixture related work with live stock', !itemDetail.includes('relatedTasksForItem'))
pass('inventory query no longer returns demo item list', !/return items\b/.test(queries))
pass('inventory query no longer uses itemById fallback', !queries.includes('itemById('))
pass('queries expose base UOM metadata', queries.includes('base_unit_id') && queries.includes('quantity_step'))

const data = read('src/components/inventory/data.ts')
pass('explicit live lists fail closed to zero-stock unknown item', data.includes('Live/empty production lists fail closed') && data.includes('onHand: 0'))
pass('PVC fixture demonstrates fractional UOM capability', data.includes('quantityScale: 2') && data.includes('quantityStep: 0.25'))

const primitives = read('src/components/ui/primitives.tsx')
pass('quantity input uses decimal keyboard', primitives.includes('inputMode="decimal"'))
pass('quantity input respects configured scale', primitives.includes('normalizedScale'))
pass('quantity input respects configured step', primitives.includes('safeStep'))

const sync = read('src/lib/syncEngine.ts')
pass('sync quantity preserves fractional numeric values', sync.includes('receivedQuantity: number') && sync.includes('pickedQuantity: number') && sync.includes('Number.isFinite(payload.receivedQuantity)'))
pass('sync payload carries authoritative bin identity', sync.includes('destinationBinId: string') && sync.includes('sourceBinId: string'))
pass('sync payload carries authoritative UOM id', sync.includes('unitId: string'))
pass('sync payload no longer exposes generic ADJUSTMENT', !sync.includes('| "ADJUSTMENT"'))

const workflows = ['ReceiveTransfer.tsx', 'Dispatch.tsx', 'CycleCount.tsx']
  .map((name) => read(`src/components/inventory/${name}`)).join('\n')
const authoritativeWorkflowCommands = ['ReceiveTransfer.tsx', 'Dispatch.tsx', 'CycleCount.tsx']
  .map((name) => read(`src/components/inventory/${name}`)).join('\n')
pass('workflow quantities use canonical UOM-aware authoritative commands',
  workflows.includes('formatQuantity(') ||
  (authoritativeWorkflowCommands.includes('unitId') &&
   (authoritativeWorkflowCommands.includes('receivedQuantity') ||
    authoritativeWorkflowCommands.includes('pickedQuantity') ||
    authoritativeWorkflowCommands.includes('observedQuantity'))))
pass('workflow commands carry authoritative bin identity',
  workflows.includes('bin_code: l.bin') ||
  authoritativeWorkflowCommands.includes('BinId'))
pass('workflow quantity controls receive UOM step/scale', workflows.includes('step={item.quantityStep}') && workflows.includes('scale={item.quantityScale}'))

const seed = read('supabase/seed.sql')
pass('seed is transactional for deferred product/UOM FKs', seed.trimStart().includes('BEGIN;') && seed.trimEnd().endsWith('COMMIT;'))
pass('seed provides authoritative operational bins', seed.includes('INSERT INTO inventory_bins'))
pass('seed provides base UOMs', seed.includes('INSERT INTO product_units'))
pass('seed reservations are first class', seed.includes('INSERT INTO inventory_reservations'))
pass('seed transit is first class', seed.includes('INSERT INTO inventory_transit_lots'))
pass('LED physical stock seed is 40 AVAILABLE + 2 DAMAGED', seed.includes("'44444444-4444-4444-4444-444444444401', 'AVAILABLE', 40") && seed.includes("'44444444-4444-4444-4444-444444444401', 'DAMAGED', 2"))
pass('seed no longer embeds reservations in balances', !/inventory_balances[\s\S]{0,2000}'AVAILABLE', 40, 6/.test(seed))

pass('Phase 2 preflight exists', fs.existsSync('supabase/preflight/phase2_existing_data.sql'))
pass('Phase 2 DB tests exist', fs.existsSync('supabase/tests/phase2_inventory_model.sql'))

if (failures.length) {
  console.error(`\n${failures.length} Phase 2 verification check(s) failed.`)
  process.exit(1)
}
console.log('\nPhase 2 static canonical-inventory checks passed.')
