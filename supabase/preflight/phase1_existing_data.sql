-- Phase 1 preflight: read-only checks against the pre-Phase-1 schema.
-- Run before applying 20260917090000_phase1_auth_membership_rls.sql on any
-- non-disposable database. All cross-tenant mismatch counts must be zero.

WITH checks AS (
  SELECT 'balance_location_company_mismatch' AS check_name, count(*)::bigint AS issue_count
  FROM inventory_balances b
  JOIN inventory_locations l ON l.id = b.location_id
  WHERE b.company_id <> l.company_id

  UNION ALL
  SELECT 'balance_product_company_mismatch', count(*)::bigint
  FROM inventory_balances b
  JOIN products p ON p.id = b.product_id
  WHERE b.company_id <> p.company_id

  UNION ALL
  SELECT 'location_responsible_user_company_mismatch', count(*)::bigint
  FROM inventory_locations l
  JOIN profiles p ON p.id = l.responsible_user_id
  WHERE l.responsible_user_id IS NOT NULL
    AND l.company_id <> p.company_id

  UNION ALL
  SELECT 'operation_actor_company_mismatch', count(*)::bigint
  FROM inventory_operations o
  JOIN profiles p ON p.id = o.initiating_actor
  WHERE o.initiating_actor IS NOT NULL
    AND o.company_id <> p.company_id

  UNION ALL
  SELECT 'movement_product_company_mismatch', count(*)::bigint
  FROM inventory_movements m
  JOIN products p ON p.id = m.product_id
  WHERE m.company_id <> p.company_id

  UNION ALL
  SELECT 'movement_source_location_company_mismatch', count(*)::bigint
  FROM inventory_movements m
  JOIN inventory_locations l ON l.id = m.source_location_id
  WHERE m.source_location_id IS NOT NULL
    AND m.company_id <> l.company_id

  UNION ALL
  SELECT 'movement_destination_location_company_mismatch', count(*)::bigint
  FROM inventory_movements m
  JOIN inventory_locations l ON l.id = m.destination_location_id
  WHERE m.destination_location_id IS NOT NULL
    AND m.company_id <> l.company_id

  UNION ALL
  SELECT 'movement_performed_by_company_mismatch', count(*)::bigint
  FROM inventory_movements m
  JOIN profiles p ON p.id = m.performed_by
  WHERE m.performed_by IS NOT NULL
    AND m.company_id <> p.company_id

  UNION ALL
  SELECT 'movement_approved_by_company_mismatch', count(*)::bigint
  FROM inventory_movements m
  JOIN profiles p ON p.id = m.approved_by
  WHERE m.approved_by IS NOT NULL
    AND m.company_id <> p.company_id

  UNION ALL
  SELECT 'movement_unit_product_or_company_mismatch', count(*)::bigint
  FROM inventory_movements m
  JOIN product_units u ON u.id = m.entered_unit_id
  WHERE m.entered_unit_id IS NOT NULL
    AND (m.company_id <> u.company_id OR m.product_id <> u.product_id)
)
SELECT *
FROM checks
ORDER BY check_name;

-- Review these operational flags before rollout. These are not integrity errors,
-- but Phase 1 will enforce them server-side and can therefore block operations
-- that the prototype previously allowed.
SELECT
  id,
  company_id,
  code,
  name,
  is_active,
  allow_direct_sales,
  allow_negative_inventory
FROM inventory_locations
ORDER BY company_id, code;

-- Legacy unattributed history is preserved, but Phase 1 prevents new unattributed
-- writes. Capture counts so the later ledger/reconciliation phase knows what must
-- be retained and potentially annotated.
SELECT
  (SELECT count(*) FROM inventory_operations WHERE initiating_actor IS NULL) AS legacy_operations_without_actor,
  (SELECT count(*) FROM inventory_movements WHERE performed_by IS NULL) AS legacy_movements_without_actor;
