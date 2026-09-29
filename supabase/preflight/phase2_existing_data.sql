-- Phase 2 read-only preflight. Every error_count should be zero before migration.

SELECT 'duplicate normalized unit codes' AS check_name, count(*) AS error_count
FROM (
  SELECT company_id, product_id, lower(btrim(unit_code))
  FROM product_units
  GROUP BY 1,2,3
  HAVING count(*) > 1
) q;

SELECT 'multiple base units per product' AS check_name, count(*) AS error_count
FROM (
  SELECT product_id FROM product_units WHERE is_base_unit GROUP BY product_id HAVING count(*) > 1
) q;

SELECT 'multiple default sale units per product' AS check_name, count(*) AS error_count
FROM (
  SELECT product_id FROM product_units WHERE is_default_sale_unit GROUP BY product_id HAVING count(*) > 1
) q;

SELECT 'negative balances where location forbids negative inventory' AS check_name, count(*) AS error_count
FROM inventory_balances b
JOIN inventory_locations l ON l.id = b.location_id AND l.company_id = b.company_id
WHERE b.on_hand_base_qty < 0 AND NOT l.allow_negative_inventory;

SELECT 'balances outside Phase 2 numeric guardrail' AS check_name, count(*) AS error_count
FROM inventory_balances
WHERE on_hand_base_qty < -1000000000000 OR on_hand_base_qty > 1000000000000;

SELECT 'movement unit belongs to wrong product/company' AS check_name, count(*) AS error_count
FROM inventory_movements m
JOIN product_units u ON u.id = m.entered_unit_id
WHERE m.entered_unit_id IS NOT NULL
  AND (u.product_id <> m.product_id OR u.company_id <> m.company_id);

SELECT 'zero or negative historic movement quantities (will remain legacy but fail validation)' AS check_name, count(*) AS warning_count
FROM inventory_movements
WHERE entered_quantity <= 0 OR base_quantity <= 0;

SELECT 'legacy reserved balance rows to migrate' AS check_name, count(*) AS info_count,
       COALESCE(sum(reserved_base_qty),0) AS reserved_total
FROM inventory_balances
WHERE reserved_base_qty > 0;


-- Review legacy reservations that were stored on non-AVAILABLE status rows.
-- Phase 2 preserves these quantities as first-class reservations, but they may
-- require business reconciliation because reservations normally consume AVAILABLE stock.
SELECT
  'legacy_reserved_non_available_rows' AS check_name,
  count(*) AS row_count,
  COALESCE(sum(reserved_base_qty), 0) AS reserved_base_qty
FROM inventory_balances
WHERE reserved_base_qty > 0
  AND inventory_status <> 'AVAILABLE'::inventory_status;

-- Unit definitions must be clean before normalized uniqueness/precision constraints.
SELECT
  'blank_unit_codes_or_names' AS check_name,
  count(*) AS row_count
FROM product_units
WHERE btrim(unit_code) = '' OR btrim(unit_name) = '';

SELECT
  'unit_step_scale_mismatch' AS check_name,
  count(*) AS row_count
FROM product_units
WHERE quantity_step IS NOT NULL
  AND quantity_scale IS NOT NULL
  AND quantity_step <> round(quantity_step, quantity_scale);
