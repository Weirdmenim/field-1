BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, auth, pg_temp;
SELECT plan(28);

-- Deterministic authenticated inventory manager with reverse permission at all seeded warehouses.
INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES (
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'authenticated', 'authenticated',
  'phase5-manager@example.test', 'unused', now(), '{}'::jsonb, '{}'::jsonb, now(), now()
) ON CONFLICT (id) DO NOTHING;
UPDATE profiles SET auth_user_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
WHERE id = '44444444-4444-4444-4444-444444444441';

SELECT has_table('public', 'inventory_ledger_commands', 'ledger correction command table exists');
SELECT col_type_is('public', 'inventory_ledger_commands', 'client_command_id', 'uuid', 'reversal command id is canonical UUID');
SELECT has_function('public', 'reverse_inventory_movement', ARRAY['uuid','numeric','uuid','text','timestamp with time zone'], 'validated reversal command exists');
SELECT has_function('public', 'get_movement_reversal_state', ARRAY['uuid'], 'reversal eligibility API exists');
SELECT has_trigger('public', 'inventory_movements', 'inventory_movements_append_only_trigger', 'movement history has append-only trigger');
SELECT ok(NOT has_table_privilege('authenticated', 'public.inventory_movements', 'INSERT'), 'authenticated cannot directly insert movements');
SELECT ok(NOT has_table_privilege('authenticated', 'public.inventory_movements', 'UPDATE'), 'authenticated cannot directly update movements');
SELECT ok(NOT has_table_privilege('authenticated', 'public.inventory_movements', 'DELETE'), 'authenticated cannot directly delete movements');
SELECT ok(has_function_privilege('authenticated', 'public.reverse_inventory_movement(uuid,numeric,uuid,text,timestamp with time zone)', 'EXECUTE'), 'authenticated may call only the validated reversal command');

-- Standalone inbound correction movement: simulate the original stock effect and then reverse it in two parts.
UPDATE inventory_balances
SET on_hand_base_qty = on_hand_base_qty + 10, physical_status_revision = physical_status_revision + 1
WHERE company_id='11111111-1111-1111-1111-111111111111'
  AND location_id='33333333-3333-3333-3333-333333333331'
  AND bin_id='66666666-6666-6666-6666-666666666601'
  AND product_id='44444444-4444-4444-4444-444444444401'
  AND inventory_status='AVAILABLE';

INSERT INTO inventory_movements (
  id, company_id, product_id, movement_type,
  destination_location_id, destination_bin_id, destination_inventory_status,
  entered_quantity, entered_unit_id, base_quantity, direction,
  client_recorded_at, reference_type, reference_number, reason_code, reason_text,
  performed_by, client_transaction_id, posted_at
) VALUES (
  'e5000000-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111',
  '44444444-4444-4444-4444-444444444401', 'STOCK_ADJUSTMENT_IN',
  '33333333-3333-3333-3333-333333333331', '66666666-6666-6666-6666-666666666601', 'AVAILABLE',
  10, '55555555-5555-5555-5555-555555555501', 10, 'IN',
  '2026-09-17T06:00:00Z', 'TEST', 'P5-ORIGINAL-1', 'TEST_SETUP', 'Phase 5 original',
  '44444444-4444-4444-4444-444444444441', 'e5000000-0000-4000-8000-000000000201', '2026-09-17T06:00:00Z'
);

SELECT set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT is((public.get_movement_reversal_state('e5000000-0000-4000-8000-000000000001')->>'eligible')::boolean, true, 'standalone original movement is initially reversible');


SELECT is(
  public.reverse_inventory_movement(
    'e5000000-0000-4000-8000-000000000001', 4,
    'e5000000-0000-4000-8000-000000000101', 'Correct four units', '2026-09-17T07:00:00Z'
  )->>'outcome',
  'accepted', 'partial reversal is accepted'
);
SELECT is(
  (public.get_movement_reversal_state('e5000000-0000-4000-8000-000000000001')->>'remaining_reversible_base_quantity')::numeric,
  6::numeric, 'partial reversal leaves authoritative remainder'
);
SELECT is(
  (SELECT on_hand_base_qty::numeric FROM inventory_balances
   WHERE company_id='11111111-1111-1111-1111-111111111111'
     AND location_id='33333333-3333-3333-3333-333333333331'
     AND bin_id='66666666-6666-6666-6666-666666666601'
     AND product_id='44444444-4444-4444-4444-444444444401'
     AND inventory_status='AVAILABLE'),
  156::numeric, 'partial reversal applies only the requested compensating stock delta'
);
SELECT is(
  (SELECT movement_type::text FROM inventory_movements
   WHERE reversal_of_movement_id='e5000000-0000-4000-8000-000000000001' ORDER BY posted_at LIMIT 1),
  'STOCK_ADJUSTMENT_OUT', 'reversal movement uses the inverse movement type'
);
SELECT is(
  public.reverse_inventory_movement(
    'e5000000-0000-4000-8000-000000000001', 4,
    'e5000000-0000-4000-8000-000000000101', 'Correct four units', '2026-09-17T07:00:00Z'
  )->>'outcome',
  'duplicate', 'same stable reversal command is idempotent'
);
SELECT is(
  public.reverse_inventory_movement(
    'e5000000-0000-4000-8000-000000000001', 5,
    'e5000000-0000-4000-8000-000000000101', 'Correct four units', '2026-09-17T07:00:00Z'
  )->>'code',
  'IDEMPOTENCY_KEY_REUSED', 'same reversal id with changed immutable content is rejected'
);
SELECT is(
  public.reverse_inventory_movement(
    'e5000000-0000-4000-8000-000000000001', 6,
    'e5000000-0000-4000-8000-000000000102', 'Correct remaining six units', '2026-09-17T07:01:00Z'
  )->>'outcome',
  'accepted', 'second partial reversal can complete the original quantity'
);
SELECT is(
  (public.get_movement_reversal_state('e5000000-0000-4000-8000-000000000001')->>'remaining_reversible_base_quantity')::numeric,
  0::numeric, 'full reversal leaves zero reversible quantity'
);
SELECT is(
  public.reverse_inventory_movement(
    'e5000000-0000-4000-8000-000000000001', 1,
    'e5000000-0000-4000-8000-000000000103', 'Attempt too much', '2026-09-17T07:02:00Z'
  )->>'outcome',
  'validation_error', 'over reversal is rejected'
);
SELECT is(
  (SELECT count(*)::int FROM inventory_movements WHERE reversal_of_movement_id='e5000000-0000-4000-8000-000000000001'),
  2, 'only the two accepted compensating movements exist'
);
SELECT is(
  public.reverse_inventory_movement(
    (SELECT id FROM inventory_movements WHERE reversal_of_movement_id='e5000000-0000-4000-8000-000000000001' ORDER BY posted_at LIMIT 1),
    1, 'e5000000-0000-4000-8000-000000000104', 'No reversal chains', '2026-09-17T07:03:00Z'
  )->>'outcome',
  'validation_error', 'reversal of a reversal is rejected'
);

RESET ROLE;

SELECT throws_ok(
  $$UPDATE inventory_movements SET reason_text='tampered' WHERE id='e5000000-0000-4000-8000-000000000001'$$,
  '0A000', NULL, 'append-only trigger rejects UPDATE'
);
SELECT throws_ok(
  $$DELETE FROM inventory_movements WHERE id='e5000000-0000-4000-8000-000000000001'$$,
  '0A000', NULL, 'append-only trigger rejects DELETE'
);

-- A direct malformed reversal cannot point at the correct original using the wrong product.
SELECT throws_ok(
  $$INSERT INTO inventory_movements (
      company_id, product_id, movement_type, source_location_id, source_bin_id, source_inventory_status,
      entered_quantity, entered_unit_id, base_quantity, direction, client_recorded_at,
      reference_type, reason_code, reason_text, performed_by, client_transaction_id,
      ledger_command_id, reversal_of_movement_id
    ) VALUES (
      '11111111-1111-1111-1111-111111111111', '44444444-4444-4444-8444-444444444442',
      'STOCK_ADJUSTMENT_OUT', '33333333-3333-3333-3333-333333333331', '66666666-6666-6666-6666-666666666602', 'AVAILABLE',
      1, '55555555-5555-5555-5555-555555555501', 1, 'OUT', now(),
      'TEST', 'REVERSAL', 'Wrong product', '44444444-4444-4444-4444-444444444441', 'e5000000-0000-4000-8000-000000000301',
      (SELECT id FROM inventory_ledger_commands WHERE client_command_id='e5000000-0000-4000-8000-000000000101'),
      'e5000000-0000-4000-8000-000000000001'
    )$$,
  '23514', NULL, 'wrong-product reversal row is rejected'
);

-- Downstream activity on an affected position blocks later generic reversal.
UPDATE inventory_balances
SET on_hand_base_qty = on_hand_base_qty + 5, physical_status_revision = physical_status_revision + 1
WHERE company_id='11111111-1111-1111-1111-111111111111'
  AND location_id='33333333-3333-3333-3333-333333333331'
  AND bin_id='66666666-6666-6666-6666-666666666601'
  AND product_id='44444444-4444-4444-4444-444444444443' AND inventory_status='AVAILABLE';
INSERT INTO inventory_movements (
  id, company_id, product_id, movement_type, destination_location_id, destination_bin_id, destination_inventory_status,
  entered_quantity, entered_unit_id, base_quantity, direction, client_recorded_at, reference_type, reason_code, reason_text,
  performed_by, client_transaction_id, posted_at
) VALUES (
  'e5000000-0000-4000-8000-000000000201','11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444401',
  'STOCK_ADJUSTMENT_IN','33333333-3333-3333-3333-333333333331','66666666-6666-6666-6666-666666666601','AVAILABLE',
  5,'55555555-5555-5555-5555-555555555501',5,'IN','2026-09-17T06:10:00Z','TEST','TEST_SETUP','Original before downstream',
  '44444444-4444-4444-4444-444444444441','11111111-2222-3333-8444-555555555555','2026-09-17T06:10:00Z'
);
UPDATE inventory_balances
SET on_hand_base_qty = on_hand_base_qty - 1, physical_status_revision = physical_status_revision + 1
WHERE company_id='11111111-1111-1111-1111-111111111111'
  AND location_id='33333333-3333-3333-3333-333333333331'
  AND bin_id='66666666-6666-6666-6666-666666666601'
  AND product_id='44444444-4444-4444-4444-444444444401' AND inventory_status='AVAILABLE';
INSERT INTO inventory_movements (
  id, company_id, product_id, movement_type, source_location_id, source_bin_id, source_inventory_status,
  entered_quantity, entered_unit_id, base_quantity, direction, client_recorded_at, reference_type, reason_code, reason_text,
  performed_by, client_transaction_id, posted_at
) VALUES (
  'e5000000-0000-4000-8000-000000000202','11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444401',
  'STOCK_ADJUSTMENT_OUT','33333333-3333-3333-3333-333333333331','66666666-6666-6666-6666-666666666601','AVAILABLE',
  1,'55555555-5555-5555-5555-555555555501',1,'OUT','2026-09-17T06:11:00Z','TEST','TEST_SETUP','Later movement',
  '44444444-4444-4444-4444-444444444441','e5000000-0000-4000-8000-000000000402','2026-09-17T06:11:00Z'
);

SET LOCAL ROLE authenticated;
SELECT is(public.get_movement_reversal_state('e5000000-0000-4000-8000-000000000201')->>'reason', 'DOWNSTREAM_ACTIVITY', 'downstream activity makes original ineligible');
SELECT is(
  public.reverse_inventory_movement('e5000000-0000-4000-8000-000000000201', 1, 'e5000000-0000-4000-8000-000000000203', 'Too late', '2026-09-17T07:04:00Z')->>'outcome',
  'conflict', 'downstream-dependent reversal returns typed conflict'
);
RESET ROLE;

-- Document-linked movements cannot be generically reversed because document/reservation state would diverge.
INSERT INTO inventory_document_commands (
  id, company_id, client_command_id, command_type, source_document_id, expected_document_revision,
  request_fingerprint, initiating_actor, status, client_recorded_at, completed_at
) VALUES (
  'e5000000-0000-4000-8000-000000000301','11111111-1111-1111-1111-111111111111','e5000000-0000-4000-8000-000000000302',
  'SALES_DISPATCH','e5000000-0000-4000-8000-000000000399',1,'phase5-doc-fixture','44444444-4444-4444-4444-444444444441',
  'COMPLETED','2026-09-17T06:20:00Z','2026-09-17T06:20:00Z'
);
UPDATE inventory_balances
SET on_hand_base_qty = on_hand_base_qty + 2, physical_status_revision = physical_status_revision + 1
WHERE company_id='11111111-1111-1111-1111-111111111111'
  AND location_id='33333333-3333-3333-3333-333333333331'
  AND bin_id='66666666-6666-6666-6666-666666666602'
  AND product_id='44444444-4444-4444-4444-444444444402' AND inventory_status='AVAILABLE';
INSERT INTO inventory_movements (
  id, company_id, product_id, movement_type, destination_location_id, destination_bin_id, destination_inventory_status,
  entered_quantity, entered_unit_id, base_quantity, direction, client_recorded_at, reference_type, reason_code, reason_text,
  performed_by, client_transaction_id, document_command_id, posted_at
) VALUES (
  'e5000000-0000-4000-8000-000000000303','11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444402',
  'STOCK_ADJUSTMENT_IN','33333333-3333-3333-3333-333333333331','66666666-6666-6666-6666-666666666602','AVAILABLE',
  2,'55555555-5555-5555-5555-555555555502',2,'IN','2026-09-17T06:20:00Z','TEST','TEST_SETUP','Document linked fixture',
  '44444444-4444-4444-4444-444444444441','e5000000-0000-4000-8000-000000000305','e5000000-0000-4000-8000-000000000301','2026-09-17T06:20:00Z'
);
SET LOCAL ROLE authenticated;
SELECT is(
  public.reverse_inventory_movement('e5000000-0000-4000-8000-000000000303', 1, 'e5000000-0000-4000-8000-000000000304', 'Needs document correction', '2026-09-17T07:05:00Z')->>'code',
  'DOCUMENT_CORRECTION_REQUIRED', 'document-linked movement requires document correction'
);
RESET ROLE;

-- Cross-tenant movement fixture. Product/unit circular references are deferrable by design.
INSERT INTO companies(id,name) VALUES('e5000000-0000-4000-8000-000000000401','Phase5 Other Tenant');
INSERT INTO profiles(id,company_id,full_name,role) VALUES('e5000000-0000-4000-8000-000000000402','e5000000-0000-4000-8000-000000000401','Other Actor','Manager');
INSERT INTO company_memberships(company_id,profile_id,role,status) VALUES('e5000000-0000-4000-8000-000000000401','e5000000-0000-4000-8000-000000000402','INVENTORY_MANAGER','ACTIVE');
INSERT INTO inventory_locations(id,company_id,name,code,location_type,is_active,allow_direct_sales)
VALUES('e5000000-0000-4000-8000-000000000403','e5000000-0000-4000-8000-000000000401','Other Warehouse','P5-OTHER','OTHER_INTERNAL',true,true);
INSERT INTO products(id,company_id,name,sku,base_unit_id,default_sale_unit_id)
VALUES('e5000000-0000-4000-8000-000000000404','e5000000-0000-4000-8000-000000000401','Other Product','P5-OTHER-SKU','e5000000-0000-4000-8000-000000000405','e5000000-0000-4000-8000-000000000405');
INSERT INTO product_units(id,company_id,product_id,unit_name,unit_code,conversion_to_base,is_base_unit,is_default_sale_unit,is_active,quantity_scale,quantity_step)
VALUES('e5000000-0000-4000-8000-000000000405','e5000000-0000-4000-8000-000000000401','e5000000-0000-4000-8000-000000000404','Pieces','pcs',1,true,true,true,0,1);
INSERT INTO inventory_balances(company_id,location_id,bin_id,product_id,inventory_status,on_hand_base_qty,reserved_base_qty)
VALUES('e5000000-0000-4000-8000-000000000401','e5000000-0000-4000-8000-000000000403',public.default_inventory_bin('e5000000-0000-4000-8000-000000000403'),'e5000000-0000-4000-8000-000000000404','AVAILABLE',3,0);
INSERT INTO inventory_movements(
  id,company_id,product_id,movement_type,destination_location_id,destination_bin_id,destination_inventory_status,
  entered_quantity,entered_unit_id,base_quantity,direction,client_recorded_at,reference_type,reason_code,reason_text,performed_by,client_transaction_id
) VALUES(
  'e5000000-0000-4000-8000-000000000406','e5000000-0000-4000-8000-000000000401','e5000000-0000-4000-8000-000000000404','STOCK_ADJUSTMENT_IN',
  'e5000000-0000-4000-8000-000000000403',public.default_inventory_bin('e5000000-0000-4000-8000-000000000403'),'AVAILABLE',
  3,'e5000000-0000-4000-8000-000000000405',3,'IN',now(),'TEST','TEST_SETUP','Other tenant movement','e5000000-0000-4000-8000-000000000402','e5000000-0000-4000-8000-000000000407'
);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.get_movement_reversal_state('e5000000-0000-4000-8000-000000000406')$$,
  '42501', NULL, 'cross-tenant reversal is denied'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;

