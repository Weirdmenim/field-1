-- Phase 8 read-only rollout preflight.
-- Run before applying 20260918210000_phase8_production_hardening.sql to an existing database.

WITH canonical_ops AS (
  SELECT company_id, client_transaction_id, count(*) AS n
  FROM inventory_operations
  WHERE client_transaction_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  GROUP BY company_id, client_transaction_id
  HAVING count(*) > 1
), reservation_state AS (
  SELECT r.company_id, r.location_id, r.product_id,
         COALESCE(sum(r.reserved_base_quantity-r.fulfilled_base_quantity-r.released_base_quantity)
           FILTER (WHERE r.status IN ('ACTIVE','PARTIALLY_FULFILLED')),0) AS reserved_remaining,
         COALESCE((SELECT sum(b.on_hand_base_qty)
                   FROM inventory_balances b
                   WHERE b.company_id=r.company_id AND b.location_id=r.location_id
                     AND b.product_id=r.product_id AND b.inventory_status='AVAILABLE'),0) AS available_physical
  FROM inventory_reservations r
  GROUP BY r.company_id,r.location_id,r.product_id
), receipt_exceptions_requiring_disposition AS (
  -- This preflight runs BEFORE the Phase 8 migration, so the new disposition table
  -- does not exist yet. Every existing non-shortage receipt exception must be
  -- reviewed and resolved through the new disposition workflow after migration.
  SELECT l.company_id,l.transfer_id,l.id AS transfer_line_id,l.exception_code,l.line_status
  FROM inventory_transfer_lines l
  WHERE l.exception_code IS NOT NULL
    AND upper(l.exception_code) NOT IN ('SHORTAGE','SHORT_RECEIPT')
), historical_non_uuid_ops AS (
  SELECT count(*) AS n FROM inventory_operations
  WHERE client_transaction_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
), historical_non_uuid_movements AS (
  SELECT count(*) AS n FROM inventory_movements
  WHERE client_transaction_id IS NOT NULL
    AND client_transaction_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
)
SELECT 'duplicate_uuid_operation_identity' AS check_name, count(*)::bigint AS issue_count FROM canonical_ops
UNION ALL
SELECT 'reservation_remainder_exceeds_nonnegative_available', count(*)::bigint
FROM reservation_state WHERE reserved_remaining < 0 OR reserved_remaining > GREATEST(available_physical,0)
UNION ALL
SELECT 'nonshortage_receipt_exceptions_requiring_phase8_disposition', count(*)::bigint FROM receipt_exceptions_requiring_disposition
UNION ALL
SELECT 'historical_non_uuid_operations_preserved', n::bigint FROM historical_non_uuid_ops
UNION ALL
SELECT 'historical_non_uuid_movements_preserved', n::bigint FROM historical_non_uuid_movements
ORDER BY check_name;

-- Detailed blockers for operator reconciliation.
SELECT company_id, client_transaction_id, count(*) AS duplicate_count
FROM inventory_operations
WHERE client_transaction_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
GROUP BY company_id, client_transaction_id
HAVING count(*) > 1
ORDER BY company_id, client_transaction_id;

SELECT company_id, location_id, product_id,
       sum(reserved_base_quantity-fulfilled_base_quantity-released_base_quantity)
         FILTER (WHERE status IN ('ACTIVE','PARTIALLY_FULFILLED')) AS reserved_remaining
FROM inventory_reservations
GROUP BY company_id,location_id,product_id
HAVING COALESCE(sum(reserved_base_quantity-fulfilled_base_quantity-released_base_quantity)
         FILTER (WHERE status IN ('ACTIVE','PARTIALLY_FULFILLED')),0) >
       GREATEST(COALESCE((SELECT sum(b.on_hand_base_qty) FROM inventory_balances b
         WHERE b.company_id=inventory_reservations.company_id
           AND b.location_id=inventory_reservations.location_id
           AND b.product_id=inventory_reservations.product_id
           AND b.inventory_status='AVAILABLE'),0),0);


-- Existing receipt exceptions that require an explicit Phase 8 disposition after migration.
SELECT company_id, transfer_id, id AS transfer_line_id, exception_code, line_status
FROM inventory_transfer_lines
WHERE exception_code IS NOT NULL
  AND upper(exception_code) NOT IN ('SHORTAGE','SHORT_RECEIPT')
ORDER BY company_id, transfer_id, id;
