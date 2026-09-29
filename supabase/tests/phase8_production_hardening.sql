BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, auth, pg_temp;
SELECT plan(19);

SELECT has_table('public','inventory_transfer_receipt_dispositions','receipt disposition table exists');
SELECT has_function('public','resolve_transfer_receipt_exception',ARRAY['uuid','bigint','uuid','transfer_receipt_disposition_type','text','timestamp with time zone'],'receipt disposition command exists');
SELECT ok(NOT has_function_privilege('authenticated','public.post_inventory_operation(jsonb)','EXECUTE'),'retired generic JSON posting is not app-callable');
SELECT ok(has_function_privilege('authenticated','public.resolve_transfer_receipt_exception(uuid,bigint,uuid,transfer_receipt_disposition_type,text,timestamp with time zone)','EXECUTE'),'authenticated user can execute disposition command');
SELECT ok(NOT has_function_privilege('anon','public.resolve_transfer_receipt_exception(uuid,bigint,uuid,transfer_receipt_disposition_type,text,timestamp with time zone)','EXECUTE'),'anonymous user cannot execute disposition command');
SELECT has_index('public','inventory_operations','inventory_operations_canonical_transaction_identity_idx','canonical transaction identity unique index exists');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='inventory_operations_identity_immutable' AND NOT tgisinternal),'operation identity immutability trigger exists');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='inventory_reservation_integrity_reservation' AND tgdeferrable AND tginitdeferred),'reservation integrity trigger is deferred');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='inventory_reservation_integrity_balance' AND tgdeferrable AND tginitdeferred),'balance-side reservation integrity trigger is deferred');

-- Bind seeded operator to a deterministic auth identity for command execution.
INSERT INTO auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
VALUES('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','authenticated','authenticated','phase8-operator@example.test','not-used',now(),'{}'::jsonb,'{}'::jsonb,now(),now())
ON CONFLICT(id) DO NOTHING;
UPDATE profiles SET auth_user_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' WHERE id='44444444-4444-4444-4444-444444444441';

-- TR-00291 receives a same-quantity DAMAGED exception and a linked transit lot.
INSERT INTO inventory_transit_lots(
  id,company_id,product_id,source_location_id,source_bin_id,destination_location_id,destination_bin_id,
  base_quantity,status,source_reference_type,source_reference_key,source_document_id,transfer_line_id,dispatched_at
) VALUES(
  'e8000000-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444401',
  '33333333-3333-3333-3333-333333333331','66666666-6666-6666-6666-666666666601',
  '1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11',(SELECT default_inventory_bin('1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11')),5,'IN_TRANSIT','TRANSFER','PHASE8-TR-00291',
  'a2910000-0000-4000-8000-000000000000','a2910000-0000-4000-8000-000000000004',now()
);

SELECT set_config('request.jwt.claim.sub','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
-- Phase 9: execute the historical Phase 8 command mechanics as migration owner with authenticated JWT claims.

SELECT lives_ok($$
  SELECT public.record_transfer_receipt_line(
    'a2910000-0000-4000-8000-000000000004',1,5,'55555555-5555-5555-5555-555555555501',(SELECT default_inventory_bin('1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11')),
    'DAMAGED','Outer packaging damaged',now()
  )
$$,'same-quantity damaged receipt can be captured as an exception');

SELECT is((SELECT line_status::text FROM inventory_transfer_lines WHERE id='a2910000-0000-4000-8000-000000000004'),'EXCEPTION','damaged capture remains an exception until disposition');

SELECT lives_ok($$
  SELECT public.resolve_transfer_receipt_exception(
    'a2910000-0000-4000-8000-000000000004',2,'e8000000-0000-4000-8000-000000000011','ACCEPT_DAMAGED','Accept into damaged stock',now()
  )
$$,'operator can create authoritative damaged disposition');

SELECT is((SELECT disposition::text FROM inventory_transfer_receipt_dispositions WHERE transfer_line_id='a2910000-0000-4000-8000-000000000004'),'ACCEPT_DAMAGED','disposition is stored immutably');
SELECT ok((SELECT applied_at IS NULL FROM inventory_transfer_receipt_dispositions WHERE transfer_line_id='a2910000-0000-4000-8000-000000000004'),'disposition is resolved but not applied before final receipt command');

SELECT lives_ok($$
  SELECT public.receive_transfer_document('a2910000-0000-4000-8000-000000000000',3,'e8000000-0000-4000-8000-000000000012',true,now())
$$,'final transfer receipt atomically applies resolved disposition');

SELECT ok((SELECT applied_at IS NOT NULL FROM inventory_transfer_receipt_dispositions WHERE transfer_line_id='a2910000-0000-4000-8000-000000000004'),'disposition becomes applied with final receipt');
SELECT is((SELECT line_status::text FROM inventory_transfer_lines WHERE id='a2910000-0000-4000-8000-000000000004'),'POSTED','disposed receipt line becomes posted');
SELECT is((SELECT COALESCE(sum(on_hand_base_qty),0)::numeric FROM inventory_balances WHERE company_id='11111111-1111-1111-1111-111111111111' AND location_id='1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11' AND bin_id=(SELECT default_inventory_bin('1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11')) AND product_id='44444444-4444-4444-4444-444444444401' AND inventory_status='DAMAGED'),7::numeric,'damaged disposition posts received quantity only to DAMAGED stock');
SELECT is((SELECT status::text FROM inventory_transit_lots WHERE id='e8000000-0000-4000-8000-000000000001'),'RECEIVED','authoritative transit custody is closed by applied disposition');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;

