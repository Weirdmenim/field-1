BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, auth, pg_temp;
SELECT plan(36);

-- Deterministic authenticated manager with permissions at Ikeja and Abuja.
INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES
('ffffffff-ffff-4fff-8fff-ffffffffffff', 'authenticated', 'authenticated', 'phase4-manager@example.test', 'unused', now(), '{}'::jsonb, '{}'::jsonb, now(), now())
ON CONFLICT (id) DO NOTHING;
UPDATE profiles SET auth_user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
WHERE id = '44444444-4444-4444-4444-444444444441';

SELECT has_table('public', 'inventory_document_commands', 'document command ledger exists');
SELECT col_type_is('public', 'inventory_document_commands', 'client_command_id', 'uuid', 'command id is canonical UUID');
SELECT has_function('public', 'ship_transfer_document', ARRAY['uuid','bigint','uuid','timestamp with time zone'], 'transfer ship command exists');
SELECT has_function('public', 'receive_transfer_document', ARRAY['uuid','bigint','uuid','boolean','timestamp with time zone'], 'transfer receive command exists');
SELECT has_function('public', 'dispatch_sales_order', ARRAY['uuid','bigint','uuid','timestamp with time zone'], 'sales dispatch command exists');
SELECT has_function('public', 'finalize_count_session', ARRAY['uuid','bigint','uuid','timestamp with time zone'], 'count finalize command exists');
SELECT ok(NOT has_function_privilege('authenticated', 'public.phase4_apply_document_movement(uuid,uuid,uuid,uuid,uuid,uuid,movement_type,uuid,uuid,uuid,uuid,inventory_status,inventory_status,numeric,uuid,text,uuid,text,uuid,uuid,uuid,timestamp with time zone,text,text,uuid)', 'EXECUTE'), 'authenticated cannot invoke internal movement helper');
SELECT ok(NOT has_function_privilege('authenticated', 'public.dispatch_sales_order(uuid,bigint,uuid,timestamp with time zone)', 'EXECUTE'), 'legacy dispatch implementation is internal after Phase 9');

-- Build a clean one-line transfer from Abuja -> Ikeja.
INSERT INTO inventory_balances (company_id, location_id, bin_id, product_id, inventory_status, on_hand_base_qty, reserved_base_qty, physical_status_revision)
VALUES (
  '11111111-1111-1111-1111-111111111111', '1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11',
  public.default_inventory_bin('1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11'),
  '44444444-4444-4444-4444-444444444401', 'AVAILABLE', 10, 0, 1
)
ON CONFLICT (company_id, location_id, bin_id, product_id, inventory_status)
DO UPDATE SET on_hand_base_qty = 10, physical_status_revision = inventory_balances.physical_status_revision + 1;

INSERT INTO inventory_transfer_documents (
  id, company_id, reference_number, source_location_id, destination_location_id,
  assigned_profile_id, status, revision, created_by
) VALUES (
  'd4000000-0000-4000-8000-000000000000', '11111111-1111-1111-1111-111111111111', 'P4-TR-001',
  '1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11', '33333333-3333-3333-3333-333333333331',
  '44444444-4444-4444-4444-444444444441', 'ASSIGNED', 1, '44444444-4444-4444-4444-444444444441'
);
INSERT INTO inventory_transfer_lines (
  id, company_id, transfer_id, source_location_id, destination_location_id, line_number,
  product_id, entered_unit_id, source_bin_id, destination_bin_id,
  expected_entered_quantity, expected_base_quantity
) VALUES (
  'd4000000-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111', 'd4000000-0000-4000-8000-000000000000',
  '1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11', '33333333-3333-3333-3333-333333333331', 1,
  '44444444-4444-4444-4444-444444444401', '55555555-5555-5555-5555-555555555501',
  public.default_inventory_bin('1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11'), '66666666-6666-6666-6666-666666666601',
  5, 5
);

SELECT set_config('request.jwt.claim.sub', 'ffffffff-ffff-4fff-8fff-ffffffffffff', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
-- Phase 9: legacy command mechanics execute as migration owner; JWT claims still bind the actor.

SELECT is(
  public.ship_transfer_document('d4000000-0000-4000-8000-000000000000', 1, 'd4000000-0000-4000-8000-000000000101', now())->>'outcome',
  'accepted', 'transfer ship command is accepted'
);
SELECT is((SELECT shipped_base_quantity::text FROM inventory_transfer_lines WHERE id='d4000000-0000-4000-8000-000000000001'), '5.000000', 'transfer line records authoritative shipped quantity');
SELECT is((SELECT base_quantity::text FROM inventory_transit_lots WHERE transfer_line_id='d4000000-0000-4000-8000-000000000001'), '5.000000', 'transfer shipment creates linked transit custody');
SELECT is((SELECT count(*)::int FROM inventory_movements WHERE transfer_line_id='d4000000-0000-4000-8000-000000000001' AND movement_type='TRANSFER_OUT'), 1, 'transfer ship appends one outbound movement');

SELECT is(
  public.ship_transfer_document('d4000000-0000-4000-8000-000000000000', 1, 'd4000000-0000-4000-8000-000000000101', now())->>'outcome',
  'duplicate', 'same stable transfer command returns duplicate instead of shipping twice'
);
SELECT is((SELECT count(*)::int FROM inventory_movements WHERE transfer_line_id='d4000000-0000-4000-8000-000000000001' AND movement_type='TRANSFER_OUT'), 1, 'duplicate transfer retry does not append another movement');

SELECT is(
  public.ship_transfer_document('d4000000-0000-4000-8000-000000000000', 1, 'd4000000-0000-4000-8000-000000000101', now() + interval '1 second')->>'code',
  'IDEMPOTENCY_KEY_REUSED', 'same idempotency key cannot rewrite client physical-action timestamp'
);

SELECT is(
  public.ship_transfer_document('d4000000-0000-4000-8000-000000000000', 2, 'd4000000-0000-4000-8000-000000000101', now())->>'code',
  'IDEMPOTENCY_KEY_REUSED', 'same idempotency key with different canonical command is rejected'
);

-- Capture destination receipt then post it atomically from transit.
SELECT is(
  public.record_transfer_receipt_line(
    'd4000000-0000-4000-8000-000000000001', 2, 5,
    '55555555-5555-5555-5555-555555555501', '66666666-6666-6666-6666-666666666601',
    NULL, NULL, now()
  )->>'line_status', 'CAPTURED', 'transfer receipt capture succeeds after shipment'
);
SELECT is(
  public.receive_transfer_document('d4000000-0000-4000-8000-000000000000', 3, 'd4000000-0000-4000-8000-000000000102', false, now())->>'outcome',
  'accepted', 'transfer receipt atomically posts captured transit quantity'
);
SELECT is((SELECT received_base_quantity::text FROM inventory_transit_lots WHERE transfer_line_id='d4000000-0000-4000-8000-000000000001'), '5.000000', 'transit receipt progress is authoritative');
SELECT is((SELECT status::text FROM inventory_transit_lots WHERE transfer_line_id='d4000000-0000-4000-8000-000000000001'), 'RECEIVED', 'fully received transit closes custody');
SELECT is((SELECT count(*)::int FROM inventory_movements WHERE transfer_line_id='d4000000-0000-4000-8000-000000000001' AND movement_type='TRANSFER_IN'), 1, 'receipt appends exactly one inbound movement');
SELECT is(
  public.receive_transfer_document('d4000000-0000-4000-8000-000000000000', 4, 'd4000000-0000-4000-8000-000000000103', false, now())->>'outcome',
  'accepted', 'fresh command id can repost already-posted transfer quantity with no effect'
);

RESET ROLE;

-- Build a clean one-line sales order with exact reservation ownership.
INSERT INTO inventory_sales_orders (
  id, company_id, reference_number, source_location_id, destination_name, customer_name,
  assigned_profile_id, status, revision, created_by
) VALUES (
  'd4100000-0000-4000-8000-000000000000', '11111111-1111-1111-1111-111111111111', 'P4-SO-001',
  '33333333-3333-3333-3333-333333333331', 'Test customer', 'Test customer',
  '44444444-4444-4444-4444-444444444441', 'IN_PROGRESS', 1, '44444444-4444-4444-4444-444444444441'
);
INSERT INTO inventory_sales_order_lines (
  id, company_id, sales_order_id, source_location_id, line_number, product_id, entered_unit_id, source_bin_id,
  requested_entered_quantity, requested_base_quantity, captured_picked_base_quantity, line_status,
  captured_by, client_recorded_at, captured_at
) VALUES (
  'd4100000-0000-4000-8000-000000000001', '11111111-1111-1111-1111-111111111111', 'd4100000-0000-4000-8000-000000000000',
  '33333333-3333-3333-3333-333333333331', 1, '44444444-4444-4444-4444-444444444401', '55555555-5555-5555-5555-555555555501',
  '66666666-6666-6666-6666-666666666601', 3, 3, 3, 'CAPTURED',
  '44444444-4444-4444-4444-444444444441', now(), now()
);
INSERT INTO inventory_reservations (
  id, company_id, location_id, bin_id, product_id, owner_type, owner_key,
  source_document_type, source_document_id, source_document_line_id, sales_order_line_id,
  status, reserved_base_qty, created_by
) VALUES (
  'd4100000-0000-4000-8000-000000000010', '11111111-1111-1111-1111-111111111111',
  '33333333-3333-3333-3333-333333333331', '66666666-6666-6666-6666-666666666601',
  '44444444-4444-4444-4444-444444444401', 'SALES_ORDER', 'P4-SO-001:1',
  'SALES_ORDER', 'd4100000-0000-4000-8000-000000000000', 'd4100000-0000-4000-8000-000000000001',
  'd4100000-0000-4000-8000-000000000001', 'ACTIVE', 3,
  '44444444-4444-4444-4444-444444444441'
);

-- Contradictory provenance: same authoritative line, wrong physical bin. The command must fail closed.
INSERT INTO inventory_reservations (
  id, company_id, location_id, bin_id, product_id, owner_type, owner_key,
  source_document_type, source_document_id, source_document_line_id, sales_order_line_id,
  status, reserved_base_qty, created_by
) VALUES (
  'd4100000-0000-4000-8000-000000000011', '11111111-1111-1111-1111-111111111111',
  '33333333-3333-3333-3333-333333333331', '66666666-6666-6666-6666-666666666602',
  '44444444-4444-4444-4444-444444444401', 'SALES_ORDER', 'P4-SO-001:1:WRONG-BIN',
  'SALES_ORDER', 'd4100000-0000-4000-8000-000000000000', 'd4100000-0000-4000-8000-000000000001',
  'd4100000-0000-4000-8000-000000000001', 'ACTIVE', 1,
  '44444444-4444-4444-4444-444444444441'
);


SELECT set_config('request.jwt.claim.sub', 'ffffffff-ffff-4fff-8fff-ffffffffffff', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
-- Phase 9: legacy command mechanics execute as migration owner; JWT claims still bind the actor.

SELECT is(
  public.dispatch_sales_order('d4100000-0000-4000-8000-000000000000', 1, 'd4100000-0000-4000-8000-000000000099', now())->>'outcome',
  'validation_error', 'dispatch rejects a reservation linked to the line but assigned to a contradictory bin'
);
RESET ROLE;
DELETE FROM inventory_reservations WHERE id='d4100000-0000-4000-8000-000000000011';
-- Phase 9: legacy command mechanics execute as migration owner; JWT claims still bind the actor.

SELECT is(
  public.dispatch_sales_order('d4100000-0000-4000-8000-000000000000', 1, 'd4100000-0000-4000-8000-000000000101', now())->>'outcome',
  'accepted', 'sales order dispatch is accepted atomically'
);
SELECT is((SELECT fulfilled_base_qty::text FROM inventory_reservations WHERE id='d4100000-0000-4000-8000-000000000010'), '3.000000', 'dispatch fulfills the exact order reservation');
SELECT is((SELECT status::text FROM inventory_reservations WHERE id='d4100000-0000-4000-8000-000000000010'), 'FULFILLED', 'fully consumed reservation reaches fulfilled state');
SELECT is((SELECT count(*)::int FROM inventory_movements WHERE sales_order_line_id='d4100000-0000-4000-8000-000000000001' AND movement_type='SALE'), 1, 'dispatch appends one SALE movement with line provenance');
SELECT is(
  public.dispatch_sales_order('d4100000-0000-4000-8000-000000000000', 1, 'd4100000-0000-4000-8000-000000000101', now())->>'outcome',
  'duplicate', 'dispatch retry reuses authoritative result without another deduction'
);
SELECT is((SELECT count(*)::int FROM inventory_movements WHERE sales_order_line_id='d4100000-0000-4000-8000-000000000001' AND movement_type='SALE'), 1, 'dispatch retry does not duplicate movement');

-- Stale document command returns typed conflict rather than mutating stock.
SELECT is(
  public.dispatch_sales_order('b1842000-0000-4000-8000-000000000000', 999, 'd4200000-0000-4000-8000-000000000101', now())->>'outcome',
  'conflict', 'stale document revision returns typed conflict'
);

RESET ROLE;

-- One-line count session proving approved variance is the only applied delta.
INSERT INTO inventory_count_sessions (
  id, company_id, reference_number, location_id, zone, policy,
  assigned_profile_id, status, revision, created_by
) VALUES (
  'd4300000-0000-4000-8000-000000000000', '11111111-1111-1111-1111-111111111111', 'P4-CC-001',
  '33333333-3333-3333-3333-333333333331', 'P4 Test Bin', 'BLIND_COUNT',
  '44444444-4444-4444-4444-444444444441', 'ASSIGNED', 1,
  '44444444-4444-4444-4444-444444444441'
);
INSERT INTO inventory_count_lines (
  id, company_id, count_session_id, location_id, line_number, product_id, bin_id, base_unit_id,
  expected_snapshot_base_quantity, expected_physical_revision
)
SELECT
  'd4300000-0000-4000-8000-000000000001', b.company_id, 'd4300000-0000-4000-8000-000000000000', b.location_id,
  1, b.product_id, b.bin_id, '55555555-5555-5555-5555-555555555503',
  sum(b.on_hand_base_qty), max(b.physical_status_revision)
FROM inventory_balances b
WHERE b.company_id='11111111-1111-1111-1111-111111111111'
  AND b.location_id='33333333-3333-3333-3333-333333333331'
  AND b.bin_id='66666666-6666-6666-6666-666666666602'
  AND b.product_id='44444444-4444-4444-4444-444444444403'
GROUP BY b.company_id,b.location_id,b.product_id,b.bin_id;

SELECT set_config('request.jwt.claim.sub', 'ffffffff-ffff-4fff-8fff-ffffffffffff', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
-- Phase 9: legacy command mechanics execute as migration owner; JWT claims still bind the actor.

SELECT lives_ok(
  $$ SELECT public.record_count_observation(
    'd4300000-0000-4000-8000-000000000001', 1,
    (SELECT expected_snapshot_base_quantity - 1 FROM inventory_count_lines WHERE id='d4300000-0000-4000-8000-000000000001'),
    '55555555-5555-5555-5555-555555555503', 'SHORTAGE', 'Phase 4 count test', now()
  ) $$,
  'manager records count variance observation'
);
SELECT lives_ok(
  $$ SELECT public.decide_count_variance(
    (SELECT id FROM inventory_count_observations WHERE count_line_id='d4300000-0000-4000-8000-000000000001' ORDER BY attempt_number DESC LIMIT 1),
    2, 'APPROVED', 'approved for Phase 4 test'
  ) $$,
  'manager approves count variance'
);
SELECT is(
  public.finalize_count_session('d4300000-0000-4000-8000-000000000000', 3, 'd4300000-0000-4000-8000-000000000101', now())->>'outcome',
  'accepted', 'approved count variance finalizes atomically'
);
SELECT is((SELECT line_status::text FROM inventory_count_lines WHERE id='d4300000-0000-4000-8000-000000000001'), 'FINALIZED', 'count line reaches finalized only after stock command succeeds');
SELECT is((SELECT count(*)::int FROM inventory_movements WHERE count_line_id='d4300000-0000-4000-8000-000000000001'), 1, 'nonzero approved count variance creates exactly one movement');
SELECT ok((SELECT client_recorded_at IS NOT NULL FROM inventory_movements WHERE count_line_id='d4300000-0000-4000-8000-000000000001' LIMIT 1), 'count movement preserves client physical-action timestamp');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;

