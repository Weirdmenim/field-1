-- Phase 7 read-only rollout preflight.
SELECT company_id, public.normalize_inventory_identifier(sku) AS normalized_sku, count(*) AS duplicate_count
FROM products GROUP BY company_id, public.normalize_inventory_identifier(sku) HAVING count(*) > 1;

SELECT company_id, id, sku FROM products WHERE public.normalize_inventory_identifier(sku) = '';

SELECT i.company_id, i.id AS identifier_id, i.product_id, i.identifier_value, p.id AS conflicting_product_id, p.sku
FROM product_identifiers i
JOIN products p ON p.company_id=i.company_id
 AND p.normalized_sku=public.normalize_inventory_identifier(i.identifier_value)
 AND p.id<>i.product_id
WHERE i.is_active;

SELECT company_id, public.normalize_inventory_identifier(identifier_value) normalized_value, count(*)
FROM product_identifiers WHERE is_active
GROUP BY company_id, public.normalize_inventory_identifier(identifier_value)
HAVING count(*) > 1;
