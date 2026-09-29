-- Phase 6 read-only rollout preflight.
-- This migration adds no stock mutations. Review these rows before rollout.

SELECT 'processing_document_commands_older_than_5m' AS check_name, count(*) AS row_count
FROM inventory_document_commands
WHERE status = 'PROCESSING' AND created_at < now() - interval '5 minutes';

SELECT 'count_variances_with_placeholder_reason' AS check_name, count(*) AS row_count
FROM inventory_count_observations
WHERE variance_base_quantity <> 0
  AND (reason_code IS NULL OR btrim(reason_code) = '' OR upper(btrim(reason_code)) = 'PENDING_REASON');

SELECT 'approvals_that_would_violate_phase6_reason_guard' AS check_name, count(*) AS row_count
FROM inventory_count_approvals a
JOIN inventory_count_observations o ON o.company_id = a.company_id AND o.id = a.observation_id
WHERE o.variance_base_quantity <> 0
  AND (o.reason_code IS NULL OR btrim(o.reason_code) = '' OR upper(btrim(o.reason_code)) = 'PENDING_REASON');

SELECT 'open_count_lines_waiting_for_operator_or_approval' AS check_name, count(*) AS row_count
FROM inventory_count_lines
WHERE line_status IN ('OPEN','PENDING_APPROVAL','RECOUNT_REQUIRED','REJECTED');
