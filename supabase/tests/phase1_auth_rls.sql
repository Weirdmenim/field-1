BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, auth, pg_temp;

SELECT plan(12);

-- Bind the seeded Inventory Officer to a deterministic test auth identity.
INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'authenticated',
  'authenticated',
  'phase1-operator@example.test',
  'not-used-by-sql-test',
  now(),
  '{}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
)
ON CONFLICT (id) DO NOTHING;

UPDATE public.profiles
SET auth_user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
WHERE id = '44444444-4444-4444-4444-444444444441';

-- A second tenant proves RLS and product/company validation do not cross company boundaries.
INSERT INTO public.companies (id, name)
VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Other Tenant')
ON CONFLICT (id) DO NOTHING;

SET CONSTRAINTS ALL DEFERRED;

INSERT INTO public.products (id, company_id, name, sku, base_unit_id, default_sale_unit_id)
VALUES (
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'Other Tenant Product',
  'OTHER-001',
  '88888888-8888-8888-8888-888888888888',
  '88888888-8888-8888-8888-888888888888'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.product_units (id, company_id, product_id, unit_name, unit_code, conversion_to_base, is_base_unit, is_default_sale_unit, is_active)
VALUES (
  '88888888-8888-8888-8888-888888888888',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'Pieces',
  'pcs',
  1,
  true,
  true,
  true
)
ON CONFLICT (id) DO NOTHING;

-- Same tenant, but deliberately not assigned to the authenticated operator.
INSERT INTO public.inventory_locations (
  id, company_id, name, code, location_type, is_active, allow_direct_sales
) VALUES (
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  '11111111-1111-1111-1111-111111111111',
  'Unassigned Test Warehouse',
  'TEST-NO-ACCESS',
  'OTHER_INTERNAL',
  true,
  true
)
ON CONFLICT (id) DO NOTHING;

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.inventory_balances', 'INSERT'),
  'authenticated cannot directly insert inventory balances'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.inventory_movements', 'UPDATE'),
  'authenticated cannot directly update inventory movement history'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.post_inventory_operation(uuid,text,text,text,uuid,uuid,movement_type,uuid,uuid,inventory_status,inventory_status,numeric,numeric,text,uuid,text)',
    'EXECUTE'
  ),
  'authenticated cannot execute the low-level inventory mutation primitive'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.post_inventory_operation(jsonb)', 'EXECUTE'),
  'authenticated cannot execute the retired generic JSON inventory wrapper'
);

SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;

SELECT is(
  public.current_profile_id()::text,
  '44444444-4444-4444-4444-444444444441',
  'authenticated identity maps to the expected operational profile'
);
SELECT is(
  (public.get_my_operational_context()->'profile'->>'id'),
  '44444444-4444-4444-4444-444444444441',
  'operational context is derived from auth.uid()'
);
SELECT is(
  (SELECT count(*) FROM public.companies WHERE id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  0::bigint,
  'RLS hides another tenant company'
);
SELECT is(
  (SELECT count(*) FROM public.products WHERE id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  0::bigint,
  'RLS hides another tenant product'
);
SELECT is(
  (SELECT count(*) FROM public.inventory_locations WHERE id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  0::bigint,
  'RLS hides a warehouse without membership'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.dispatch_sales_order_v2(uuid,bigint,uuid,jsonb,timestamptz)', 'EXECUTE'),
  'authenticated can execute the revision-protected sales dispatch command'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.receive_transfer_document_v2(uuid,bigint,uuid,jsonb,boolean,timestamptz)', 'EXECUTE'),
  'authenticated can execute the revision-protected transfer receipt command'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.finalize_count_session_v2(uuid,bigint,uuid,jsonb,timestamptz)', 'EXECUTE'),
  'authenticated can execute the revision-protected count finalization command'
);

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;

