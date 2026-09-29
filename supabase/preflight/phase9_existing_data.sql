-- Phase 9 read-only preflight. Run before applying stock revision preconditions.
-- Every result is diagnostic; this file performs no writes.

SELECT 'balance_rows_without_positive_revision' AS check_name, count(*) AS affected_rows
FROM inventory_balances
WHERE physical_status_revision IS NULL OR physical_status_revision < 0;

SELECT 'active_reservations_without_positive_revision' AS check_name, count(*) AS affected_rows
FROM inventory_reservations
WHERE status IN ('ACTIVE','PARTIALLY_FULFILLED')
  AND (reservation_revision IS NULL OR reservation_revision < 0);

SELECT 'stock_sensitive_documents' AS check_name, count(*) AS affected_rows
FROM (
  SELECT id FROM inventory_sales_orders WHERE status NOT IN ('COMPLETED','CANCELLED')
  UNION ALL
  SELECT id FROM inventory_transfer_documents WHERE status NOT IN ('COMPLETED','CANCELLED')
  UNION ALL
  SELECT id FROM inventory_count_sessions WHERE status NOT IN ('COMPLETED','CANCELLED')
) d;

-- Phase 9 intentionally revokes authenticated execution of the legacy final-stock RPCs.
-- Verify all deployed clients are Phase-9 capable before migration rollout.
SELECT 'legacy_terminal_commands_present' AS check_name, count(*) AS affected_rows
FROM inventory_document_commands
WHERE command_type IN ('SALES_DISPATCH','TRANSFER_SHIP','TRANSFER_RECEIVE','COUNT_FINALIZE')
  AND status IN ('PROCESSING','TRANSIENT_ERROR');
