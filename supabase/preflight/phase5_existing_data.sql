-- Phase 5 read-only rollout preflight.
-- Reconcile every nonzero integrity count before applying the Phase 5 migration.

SELECT 'orphan_reversal_reference' AS check_name, count(*) AS problem_count
FROM inventory_movements r
LEFT JOIN inventory_movements o ON o.id = r.reversal_of_movement_id
WHERE r.reversal_of_movement_id IS NOT NULL AND o.id IS NULL;

SELECT 'cross_tenant_or_product_reversal_reference' AS check_name, count(*) AS problem_count
FROM inventory_movements r
JOIN inventory_movements o ON o.id = r.reversal_of_movement_id
WHERE r.reversal_of_movement_id IS NOT NULL
  AND (r.company_id <> o.company_id OR r.product_id <> o.product_id);

SELECT 'self_reversal_reference' AS check_name, count(*) AS problem_count
FROM inventory_movements
WHERE reversal_of_movement_id = id;

SELECT 'reversal_of_reversal_reference' AS check_name, count(*) AS problem_count
FROM inventory_movements r
JOIN inventory_movements o ON o.id = r.reversal_of_movement_id
WHERE r.reversal_of_movement_id IS NOT NULL
  AND o.reversal_of_movement_id IS NOT NULL;

SELECT 'aggregate_reversal_exceeds_original_quantity' AS check_name, count(*) AS problem_count
FROM (
  SELECT o.company_id, o.id, o.base_quantity, COALESCE(sum(r.base_quantity),0) AS reversed_quantity
  FROM inventory_movements o
  JOIN inventory_movements r
    ON r.company_id = o.company_id
   AND r.reversal_of_movement_id = o.id
  GROUP BY o.company_id, o.id, o.base_quantity
  HAVING COALESCE(sum(r.base_quantity),0) > o.base_quantity
) x;

SELECT 'document_linked_legacy_reversal' AS check_name, count(*) AS problem_count
FROM inventory_movements r
JOIN inventory_movements o ON o.id = r.reversal_of_movement_id
WHERE r.reversal_of_movement_id IS NOT NULL
  AND (
    o.document_command_id IS NOT NULL
    OR o.transfer_line_id IS NOT NULL
    OR o.sales_order_line_id IS NOT NULL
    OR o.count_line_id IS NOT NULL
  );

SELECT 'legacy_reversal_without_actor' AS check_name, count(*) AS problem_count
FROM inventory_movements
WHERE reversal_of_movement_id IS NOT NULL AND performed_by IS NULL;

SELECT 'legacy_reversal_without_reason' AS check_name, count(*) AS problem_count
FROM inventory_movements
WHERE reversal_of_movement_id IS NOT NULL
  AND (reason_text IS NULL OR btrim(reason_text) = '');

SELECT 'movement_rows_currently_directly_reversible' AS check_name, count(*) AS informational_count
FROM inventory_movements m
WHERE m.reversal_of_movement_id IS NULL
  AND m.document_command_id IS NULL
  AND m.transfer_line_id IS NULL
  AND m.sales_order_line_id IS NULL
  AND m.count_line_id IS NULL
  AND m.movement_type IN (
    'SALE','STOCK_ADJUSTMENT_IN','STOCK_ADJUSTMENT_OUT','STOCK_COUNT_VARIANCE_IN',
    'STOCK_COUNT_VARIANCE_OUT','CUSTOMER_RETURN','PURCHASE_RECEIPT','OPENING_BALANCE',
    'EXPIRY','DAMAGE','STATUS_CHANGE'
  );
