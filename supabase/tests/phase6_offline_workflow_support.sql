BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, auth, pg_temp;
SELECT plan(7);

SELECT has_function('public','set_count_variance_reason',ARRAY['uuid','bigint','text','text'],'blind-count variance reason follow-up exists');
SELECT has_trigger('public','inventory_count_approvals','trg_phase6_count_approval_reason','approval reason guard trigger exists');
SELECT ok(has_function_privilege('authenticated','public.set_count_variance_reason(uuid,bigint,text,text)','EXECUTE'),'authenticated may record a final count variance reason');
SELECT ok(NOT has_function_privilege('anon','public.set_count_variance_reason(uuid,bigint,text,text)','EXECUTE'),'anonymous role cannot record a count variance reason');

INSERT INTO inventory_count_observations (
  id, company_id, count_session_id, count_line_id, location_id, product_id, attempt_number,
  entered_unit_id, observed_entered_quantity, observed_base_quantity,
  expected_snapshot_base_quantity, expected_physical_revision,
  reason_code, notes, observed_by, client_recorded_at
) VALUES (
  'f6000000-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111',
  'c0093000-0000-4000-8000-000000000000','c0093000-0000-4000-8000-000000000001',
  '33333333-3333-3333-3333-333333333331','44444444-4444-4444-4444-444444444401',99,
  '55555555-5555-5555-5555-555555555501',39,39,40,1,'PENDING_REASON',NULL,
  '44444444-4444-4444-4444-444444444441','2026-09-17T09:00:00Z'
);
UPDATE inventory_count_lines SET line_status='PENDING_APPROVAL' WHERE id='c0093000-0000-4000-8000-000000000001';

SELECT throws_ok(
  $$INSERT INTO inventory_count_approvals (
      company_id,count_session_id,count_line_id,observation_id,location_id,decision,decision_reason,decided_by
    ) VALUES (
      '11111111-1111-1111-1111-111111111111','c0093000-0000-4000-8000-000000000000',
      'c0093000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001',
      '33333333-3333-3333-3333-333333333331','APPROVED',NULL,'44444444-4444-4444-4444-444444444441'
    )$$,
  '22023', 'Count variance requires a final operator reason before approval',
  'approval fails while blind variance reason is still pending'
);

UPDATE inventory_count_observations SET reason_code='Shortage' WHERE id='f6000000-0000-4000-8000-000000000001';
SELECT lives_ok(
  $$INSERT INTO inventory_count_approvals (
      id,company_id,count_session_id,count_line_id,observation_id,location_id,decision,decision_reason,decided_by
    ) VALUES (
      'f6000000-0000-4000-8000-000000000002','11111111-1111-1111-1111-111111111111','c0093000-0000-4000-8000-000000000000',
      'c0093000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001',
      '33333333-3333-3333-3333-333333333331','APPROVED',NULL,'44444444-4444-4444-4444-444444444441'
    )$$,
  'approval succeeds after a final variance reason exists'
);

SELECT is((SELECT reason_code FROM inventory_count_observations WHERE id='f6000000-0000-4000-8000-000000000001'),'Shortage','final reason is retained on the observation');
ROLLBACK;
