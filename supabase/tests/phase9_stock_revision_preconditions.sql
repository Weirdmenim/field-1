BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, auth, pg_temp;
SELECT plan(16);

SELECT has_table('public','inventory_document_command_stock_preconditions','stock precondition ledger exists');
SELECT has_function('public','phase9_get_document_stock_preconditions',ARRAY['text','uuid'],'authoritative stock snapshot RPC exists');
SELECT has_function('public','dispatch_sales_order_v2',ARRAY['uuid','bigint','uuid','jsonb','timestamp with time zone'],'revision-protected dispatch RPC exists');
SELECT ok(NOT has_function_privilege('authenticated','public.dispatch_sales_order(uuid,bigint,uuid,timestamp with time zone)','EXECUTE'),'legacy dispatch RPC is no longer app-callable');
SELECT ok(has_function_privilege('authenticated','public.dispatch_sales_order_v2(uuid,bigint,uuid,jsonb,timestamp with time zone)','EXECUTE'),'authenticated can execute revision-protected dispatch');
SELECT ok(NOT has_function_privilege('authenticated','public.receive_transfer_document(uuid,bigint,uuid,boolean,timestamp with time zone)','EXECUTE'),'legacy receipt RPC is no longer app-callable');
SELECT ok(has_function_privilege('authenticated','public.receive_transfer_document_v2(uuid,bigint,uuid,jsonb,boolean,timestamp with time zone)','EXECUTE'),'authenticated can execute revision-protected receipt');
SELECT ok(NOT has_function_privilege('authenticated','public.finalize_count_session(uuid,bigint,uuid,timestamp with time zone)','EXECUTE'),'legacy count-finalize RPC is no longer app-callable');
SELECT ok(has_function_privilege('authenticated','public.finalize_count_session_v2(uuid,bigint,uuid,jsonb,timestamp with time zone)','EXECUTE'),'authenticated can execute revision-protected count finalize');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='trg_phase9_balance_position_lock' AND NOT tgisinternal),'balance changes acquire Phase 9 position lock');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='trg_phase9_reservation_position_lock' AND NOT tgisinternal),'reservation changes acquire Phase 9 position lock');

-- Deterministic document for snapshot and stale-revision validation.
INSERT INTO inventory_balances(company_id,location_id,bin_id,product_id,inventory_status,on_hand_base_qty,reserved_base_qty,physical_status_revision)
VALUES(
 '11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',
 public.default_inventory_bin('33333333-3333-3333-3333-333333333331'),'44444444-4444-4444-4444-444444444401','AVAILABLE',20,0,7
)
ON CONFLICT(company_id,location_id,bin_id,product_id,inventory_status)
DO UPDATE SET on_hand_base_qty=20, physical_status_revision=7;

INSERT INTO inventory_sales_orders(id,company_id,reference_number,source_location_id,destination_name,customer_name,assigned_profile_id,status,revision,created_by)
VALUES('f9000000-0000-4000-8000-000000000000','11111111-1111-1111-1111-111111111111','P9-SO-001',
 '33333333-3333-3333-3333-333333333331','Phase 9','Phase 9','44444444-4444-4444-4444-444444444441','IN_PROGRESS',1,'44444444-4444-4444-4444-444444444441');
INSERT INTO inventory_sales_order_lines(id,company_id,sales_order_id,source_location_id,line_number,product_id,entered_unit_id,source_bin_id,requested_entered_quantity,requested_base_quantity,captured_picked_base_quantity,line_status,captured_by,client_recorded_at,captured_at)
VALUES('f9000000-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111','f9000000-0000-4000-8000-000000000000',
 '33333333-3333-3333-3333-333333333331',1,'44444444-4444-4444-4444-444444444401','55555555-5555-5555-5555-555555555501',
 public.default_inventory_bin('33333333-3333-3333-3333-333333333331'),1,1,1,'CAPTURED','44444444-4444-4444-4444-444444444441',now(),now());

INSERT INTO auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
VALUES('f9000000-0000-4000-8000-000000000099','authenticated','authenticated','phase9@example.test','unused',now(),'{}'::jsonb,'{}'::jsonb,now(),now())
ON CONFLICT(id) DO NOTHING;
UPDATE profiles SET auth_user_id='f9000000-0000-4000-8000-000000000099' WHERE id='44444444-4444-4444-4444-444444444441';
SELECT set_config('request.jwt.claim.sub','f9000000-0000-4000-8000-000000000099',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE p9_snapshot(value jsonb);
INSERT INTO p9_snapshot SELECT public.phase9_get_document_stock_preconditions('SALES_DISPATCH','f9000000-0000-4000-8000-000000000000');
SELECT is((SELECT jsonb_array_length(value) FROM p9_snapshot),1,'sales document snapshot contains the exact stock position');
RESET ROLE;

SELECT is((public.phase9_validate_stock_preconditions('11111111-1111-1111-1111-111111111111','SALES_DISPATCH','f9000000-0000-4000-8000-000000000000',(SELECT value FROM p9_snapshot))->>'ok')::boolean,true,'fresh physical/reservation snapshot validates');
UPDATE inventory_balances SET physical_status_revision=physical_status_revision+1
WHERE company_id='11111111-1111-1111-1111-111111111111' AND location_id='33333333-3333-3333-3333-333333333331'
  AND bin_id=public.default_inventory_bin('33333333-3333-3333-3333-333333333331') AND product_id='44444444-4444-4444-4444-444444444401' AND inventory_status='AVAILABLE';
SELECT is(public.phase9_validate_stock_preconditions('11111111-1111-1111-1111-111111111111','SALES_DISPATCH','f9000000-0000-4000-8000-000000000000',(SELECT value FROM p9_snapshot))->>'code','STOCK_REVISION_CONFLICT','stale physical snapshot returns typed conflict');

SELECT is(public.phase9_prepare_stock_command('11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444441','SALES_DISPATCH','f9000000-0000-4000-8000-000000000090','f9000000-0000-4000-8000-000000000000',1,(SELECT value FROM p9_snapshot))->>'state','MATCH','first stable command stores immutable precondition fingerprint');
SELECT is(public.phase9_prepare_stock_command('11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444441','SALES_DISPATCH','f9000000-0000-4000-8000-000000000090','f9000000-0000-4000-8000-000000000000',1,(SELECT value FROM p9_snapshot) || jsonb_build_array(jsonb_build_object('unexpected',true)))->>'state','MISMATCH','same stable command cannot rewrite its stock preconditions');

SELECT * FROM finish();
ROLLBACK;

