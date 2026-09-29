-- Phase 4 read-only rollout preflight.
-- Every nonzero integrity count should be reconciled before the migration is applied.

SELECT 'duplicate_active_transit_lots_per_transfer_line' AS check_name, count(*) AS problem_count
FROM (
  SELECT company_id, transfer_line_id
  FROM inventory_transit_lots
  WHERE transfer_line_id IS NOT NULL AND status <> 'CANCELLED'
  GROUP BY company_id, transfer_line_id
  HAVING count(*) > 1
) x;

SELECT 'transfer_transit_exceeds_expected' AS check_name, count(*) AS problem_count
FROM inventory_transfer_lines l
JOIN LATERAL (
  SELECT COALESCE(sum(t.base_quantity), 0) AS transit_qty
  FROM inventory_transit_lots t
  WHERE t.company_id = l.company_id
    AND t.transfer_line_id = l.id
    AND t.status <> 'CANCELLED'
) t ON true
WHERE t.transit_qty > l.expected_base_quantity;

SELECT 'transfer_posted_exceeds_transit_received' AS check_name, count(*) AS problem_count
FROM inventory_transfer_lines l
LEFT JOIN LATERAL (
  SELECT COALESCE(sum(t.received_base_quantity), 0) AS received_qty
  FROM inventory_transit_lots t
  WHERE t.company_id = l.company_id
    AND t.transfer_line_id = l.id
    AND t.status <> 'CANCELLED'
) t ON true
WHERE l.posted_base_quantity > COALESCE(t.received_qty, 0);

SELECT 'sales_posted_exceeds_captured' AS check_name, count(*) AS problem_count
FROM inventory_sales_order_lines
WHERE posted_base_quantity > captured_picked_base_quantity;

SELECT 'sales_progress_exceeds_requested' AS check_name, count(*) AS problem_count
FROM inventory_sales_order_lines
WHERE posted_base_quantity + backordered_base_quantity > requested_base_quantity
   OR captured_picked_base_quantity + backordered_base_quantity > requested_base_quantity;

SELECT 'reservation_progress_exceeds_total' AS check_name, count(*) AS problem_count
FROM inventory_reservations
WHERE fulfilled_base_qty + released_base_qty > reserved_base_qty;

SELECT 'reservation_sales_line_tenant_or_position_mismatch' AS check_name, count(*) AS problem_count
FROM inventory_reservations r
JOIN inventory_sales_order_lines l ON l.id = r.sales_order_line_id
WHERE r.sales_order_line_id IS NOT NULL
  AND (r.company_id <> l.company_id OR r.location_id <> l.source_location_id OR r.product_id <> l.product_id);

SELECT 'transit_transfer_line_tenant_or_route_mismatch' AS check_name, count(*) AS problem_count
FROM inventory_transit_lots t
JOIN inventory_transfer_lines l ON l.id = t.transfer_line_id
WHERE t.transfer_line_id IS NOT NULL
  AND (
    t.company_id <> l.company_id OR t.product_id <> l.product_id
    OR t.source_location_id <> l.source_location_id
    OR t.destination_location_id <> l.destination_location_id
  );

SELECT 'count_finalized_without_posted_variance_consistency' AS check_name, count(*) AS problem_count
FROM inventory_count_lines l
LEFT JOIN LATERAL (
  SELECT o.variance_base_quantity
  FROM inventory_count_observations o
  WHERE o.company_id = l.company_id AND o.count_line_id = l.id
  ORDER BY o.attempt_number DESC LIMIT 1
) o ON true
WHERE l.line_status = 'FINALIZED'
  AND o.variance_base_quantity IS DISTINCT FROM l.posted_variance_base_quantity;

SELECT 'document_completed_with_unposted_transfer_quantity' AS check_name, count(*) AS problem_count
FROM inventory_transfer_documents d
WHERE d.status = 'COMPLETED'
  AND EXISTS (
    SELECT 1 FROM inventory_transfer_lines l
    WHERE l.company_id = d.company_id AND l.transfer_id = d.id
      AND l.line_status <> 'CANCELLED'
      AND l.posted_base_quantity < l.expected_base_quantity
  );

SELECT 'document_completed_with_unaccounted_sales_quantity' AS check_name, count(*) AS problem_count
FROM inventory_sales_orders d
WHERE d.status = 'COMPLETED'
  AND EXISTS (
    SELECT 1 FROM inventory_sales_order_lines l
    WHERE l.company_id = d.company_id AND l.sales_order_id = d.id
      AND l.line_status <> 'CANCELLED'
      AND l.posted_base_quantity + l.backordered_base_quantity < l.requested_base_quantity
  );

-- Informational reconciliation set: Phase 3 intentionally preserved unmatched legacy provenance.
SELECT
  t.id,
  t.source_reference_key,
  t.product_id,
  t.base_quantity,
  t.status
FROM inventory_transit_lots t
WHERE t.transfer_line_id IS NULL
ORDER BY t.created_at, t.id;

-- Linked sales reservations must either be location-level or match the authoritative order-line bin.
SELECT 'sales_reservation_bin_mismatch' AS check_name, count(*) AS issue_count
FROM inventory_reservations r
JOIN inventory_sales_order_lines l
  ON l.company_id = r.company_id AND l.id = r.sales_order_line_id
WHERE r.sales_order_line_id IS NOT NULL
  AND r.bin_id IS NOT NULL
  AND r.bin_id <> l.source_bin_id;
