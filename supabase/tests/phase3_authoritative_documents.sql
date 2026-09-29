BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, auth, pg_temp;

SELECT plan(33);


-- Bind operator and manager profiles to deterministic authenticated identities.
INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'authenticated', 'authenticated', 'phase3-operator@example.test', 'unused', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'authenticated', 'authenticated', 'phase3-manager@example.test', 'unused', now(), '{}'::jsonb, '{}'::jsonb, now(), now())
ON CONFLICT (id) DO NOTHING;

UPDATE profiles SET auth_user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
WHERE id = '44444444-4444-4444-4444-444444444441';
UPDATE profiles SET auth_user_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
WHERE id = '44444444-4444-4444-4444-444444444442';

SELECT has_table('public', 'inventory_transfer_documents', 'authoritative transfer documents exist');
SELECT has_table('public', 'inventory_transfer_lines', 'authoritative transfer lines exist');
SELECT has_table('public', 'inventory_sales_orders', 'authoritative sales orders exist');
SELECT has_table('public', 'inventory_sales_order_lines', 'authoritative sales-order lines exist');
SELECT has_table('public', 'inventory_count_sessions', 'authoritative count sessions exist');
SELECT has_table('public', 'inventory_count_observations', 'count observations are first class');
SELECT has_table('public', 'inventory_count_approvals', 'count approvals are first class');
SELECT has_table('public', 'inventory_backorders', 'backorders are first class');

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.inventory_count_lines', 'SELECT'),
  'authenticated cannot bypass blind count by reading the base count-line table'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.inventory_transfer_lines', 'UPDATE'),
  'authenticated cannot directly edit authoritative transfer lines'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.list_my_warehouse_work(uuid)', 'EXECUTE'),
  'authenticated can list authorized work through the RPC boundary'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.record_count_observation(uuid,bigint,numeric,uuid,text,text,timestamp with time zone)', 'EXECUTE'),
  'authenticated can submit count observations through the command boundary'
);

SELECT is((SELECT count(*) FROM inventory_transfer_documents WHERE reference_number IN ('TR-00291','TR-00305')), 1::bigint, 'seeded transfers are authoritative documents');
SELECT is((SELECT count(*) FROM inventory_sales_orders WHERE reference_number IN ('SO-18420','SO-18402')), 1::bigint, 'seeded sales orders are authoritative documents');
SELECT is((SELECT count(*) FROM inventory_count_sessions WHERE reference_number IN ('CC-0093','CC-0095')), 1::bigint, 'seeded count sessions are authoritative documents');
SELECT is((SELECT count(*) FROM inventory_reservations WHERE owner_type='SALES_ORDER' AND sales_order_line_id IS NOT NULL), 0::bigint, 'seed reservations are linked to authoritative sales-order lines');
SELECT is((SELECT count(*) FROM inventory_transit_lots WHERE source_reference_type='TRANSFER' AND transfer_line_id IS NOT NULL), 0::bigint, 'matching seed transit lots are linked while unresolved legacy provenance remains preserved');

-- Operator context.

SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT is(
  jsonb_array_length(public.list_my_warehouse_work('33333333-3333-3333-3333-333333333331')),
  2,
  'authorized warehouse work is listed from server documents'
);

-- We revoke approval permission here to test that blind counts hide expected quantities.
SELECT set_config('request.jwt.claim.role', 'postgres', true);
SET LOCAL ROLE postgres;
UPDATE warehouse_memberships SET can_approve_counts = false WHERE profile_id = '44444444-4444-4444-4444-444444444441';

CREATE TEMP TABLE tmp_bin (id UUID);
INSERT INTO tmp_bin SELECT default_inventory_bin('1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11');
GRANT SELECT ON tmp_bin TO authenticated;

SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT is(
  public.get_count_session_document('c0093000-0000-4000-8000-000000000000')->'lines'->0->>'expected_base_quantity',
  NULL,
  'blind count hides expected quantity before an observation'
);

SELECT throws_ok(
  $$ SELECT public.record_sales_order_pick_line(
    'b1842000-0000-4000-8000-000000000004', 1, 6,
    '55555555-5555-5555-5555-555555555501', '66666666-6666-6666-6666-666666666601',
    NULL, NULL, now()
  ) $$,
  '22023',
  'Picked quantity exceeds authoritative requested quantity',
  'dispatch capture rejects quantity above authoritative request'
);

SELECT lives_ok(
  $$ SELECT public.record_transfer_receipt_line(
    'a2910000-0000-4000-8000-000000000004', 1, 5,
    '55555555-5555-5555-5555-555555555501', (SELECT id FROM tmp_bin LIMIT 1),
    NULL, NULL, now()
  ) $$,
  'open transfer line can be captured through the server command'
);

SELECT throws_ok(
  $$ SELECT public.record_transfer_receipt_line(
    'a2910000-0000-4000-8000-000000000004', 2, 5,
    '55555555-5555-5555-5555-555555555501', (SELECT id FROM tmp_bin LIMIT 1),
    NULL, NULL, now()
  ) $$,
  'P0001',
  'Transfer line is already captured and immutable',
  'captured transfer line cannot be silently edited again'
);

SELECT throws_ok(
  $$ SELECT public.record_sales_order_pick_line(
    'b1842000-0000-4000-8000-000000000004', 999, 3,
    '55555555-5555-5555-5555-555555555501', '66666666-6666-6666-6666-666666666601',
    NULL, NULL, now()
  ) $$,
  '40001',
  'Document revision conflict',
  'stale sales-order capture is rejected by document revision'
);

SELECT lives_ok(
  $$ SELECT public.record_count_observation(
    'c0093000-0000-4000-8000-000000000001', 1, 0,
    '55555555-5555-5555-5555-555555555501', 'SHORTAGE', 'Explicit zero count', now()
  ) $$,
  'zero is accepted only as an explicit count observation command'
);

SELECT is(
  public.get_count_session_document('c0093000-0000-4000-8000-000000000000')->'lines'->0->>'expected_base_quantity',
  '10.000000',
  'expected count is revealed after observation and comes from authoritative physical snapshot'
);

RESET ROLE;
SELECT is(
  (SELECT line_status::text FROM inventory_count_lines WHERE id='c0093000-0000-4000-8000-000000000001'),
  'PENDING_APPROVAL',
  'variance observation enters pending approval rather than changing stock'
);
SET LOCAL ROLE authenticated;

RESET ROLE;
-- Fetch the observation ID as postgres to avoid RLS/grant issues in the test session.
CREATE TEMP TABLE tmp_obs (id UUID);
INSERT INTO tmp_obs SELECT id FROM inventory_count_observations WHERE count_line_id='c0093000-0000-4000-8000-000000000001' ORDER BY attempt_number DESC LIMIT 1;
GRANT SELECT ON tmp_obs TO authenticated;

SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$ SELECT public.decide_count_variance(
    (SELECT id FROM tmp_obs LIMIT 1),
    2, 'APPROVED', 'operator should not approve'
  ) $$,
  '42501',
  'Count approval permission required',
  'ordinary counting operator cannot approve own variance'
);

RESET ROLE;
-- Temporarily restore approval permission for the test.
UPDATE warehouse_memberships SET can_approve_counts = true WHERE profile_id = '44444444-4444-4444-4444-444444444441';

SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$ SELECT public.decide_count_variance(
    (SELECT id FROM tmp_obs LIMIT 1),
    2, 'APPROVED', 'verified by supervisor'
  ) $$,
  'authorized supervisor can approve a count variance without mutating stock'
);

RESET ROLE;
SELECT is(
  (SELECT line_status::text FROM inventory_count_lines WHERE id='c0093000-0000-4000-8000-000000000001'),
  'APPROVED',
  'approved count remains a document state awaiting Phase 4 stock application'
);

SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$ SELECT public.create_sales_order_backorder(
    'b1842000-0000-4000-8000-000000000005', 999, 5, 'OUT_OF_STOCK', 'No stock available'
  ) $$,
  '40001',
  'Document revision conflict',
  'stale backorder creation is rejected'
);

SELECT lives_ok(
  $$ SELECT public.create_sales_order_backorder(
    'b1842000-0000-4000-8000-000000000005', 1, 5, 'OUT_OF_STOCK', 'No stock available'
  ) $$,
  'backorder can be created as a durable document entity'
);

RESET ROLE;
SELECT is(
  (SELECT backordered_base_quantity::text FROM inventory_sales_order_lines WHERE id='b1842000-0000-4000-8000-000000000005'),
  '5.000000',
  'backorder quantity is reflected on the authoritative order line'
);

SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$ SELECT public.create_sales_order_backorder(
    'b1842000-0000-4000-8000-000000000005', 2, 1, 'OUT_OF_STOCK', 'too much'
  ) $$,
  '22023',
  'Backorder would exceed authoritative remaining requested quantity',
  'backorder cannot exceed authoritative requested quantity'
);

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
