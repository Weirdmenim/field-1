-- Phase 3 existing-data preflight (read only).
-- Run before applying the Phase 3 migration to a non-disposable database.
-- Any non-zero issue_count should be reconciled or explicitly accepted before rollout.

WITH checks AS (
  SELECT 'active_sales_reservations_without_document_id' AS check_name,
         count(*)::bigint AS issue_count,
         'Active sales-order reservations should be mapped to an authoritative sales-order line during Phase 3 reconciliation.' AS detail
  FROM inventory_reservations
  WHERE status = 'ACTIVE'
    AND owner_type = 'SALES_ORDER'
    AND source_document_id IS NULL

  UNION ALL
  SELECT 'sales_reservations_with_blank_owner_key', count(*)::bigint,
         'Owner keys must remain usable as legacy provenance until authoritative line IDs are attached.'
  FROM inventory_reservations
  WHERE owner_type = 'SALES_ORDER' AND btrim(owner_key) = ''

  UNION ALL
  SELECT 'transfer_transit_without_document_id', count(*)::bigint,
         'In-transit transfer lots should be mapped to authoritative transfer lines; unresolved legacy rows must remain preserved and quarantined.'
  FROM inventory_transit_lots
  WHERE status IN ('IN_TRANSIT', 'PARTIALLY_RECEIVED')
    AND source_reference_type = 'TRANSFER'
    AND source_document_id IS NULL

  UNION ALL
  SELECT 'transit_with_same_source_destination', count(*)::bigint,
         'Transit custody cannot have the same source and destination warehouse.'
  FROM inventory_transit_lots
  WHERE source_location_id = destination_location_id

  UNION ALL
  SELECT 'active_reservation_on_inactive_bin', count(*)::bigint,
         'Phase 3 authoritative order lines must reference active operational bins.'
  FROM inventory_reservations r
  JOIN inventory_bins b ON b.id = r.bin_id AND b.company_id = r.company_id
  WHERE r.status = 'ACTIVE' AND NOT b.is_active

  UNION ALL
  SELECT 'active_transit_destination_on_inactive_bin', count(*)::bigint,
         'Phase 3 transfer receipt lines must reference active destination bins.'
  FROM inventory_transit_lots t
  JOIN inventory_bins b ON b.id = t.destination_bin_id AND b.company_id = t.company_id
  WHERE t.status IN ('IN_TRANSIT', 'PARTIALLY_RECEIVED') AND NOT b.is_active

  UNION ALL
  SELECT 'movements_missing_client_recorded_at', count(*)::bigint,
         'Historical rows are preserved, but Phase 4 document commands must always carry the physical client action time.'
  FROM inventory_movements
  WHERE client_recorded_at IS NULL

  UNION ALL
  SELECT 'operations_without_source_document', count(*)::bigint,
         'Historical generic operations are preserved. New Phase 4 document commands must have durable document and line linkage.'
  FROM inventory_operations
  WHERE source_document_id IS NULL
)
SELECT * FROM checks ORDER BY check_name;
