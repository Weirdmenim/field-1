
-- Celavi Pharmacy Products
INSERT INTO products (id, company_id, name, sku, base_unit_id, default_sale_unit_id) VALUES

('44444444-2222-2222-2222-000000000001', '22222222-2222-2222-2222-222222222222', '5ml Syringe', 'CEL-001', '55555555-2222-2222-2222-000000000001', '55555555-2222-2222-2222-000000000001');

-- Celavi Pharmacy Units
INSERT INTO product_units (id, company_id, product_id, unit_name, unit_code, conversion_to_base, is_base_unit, is_default_sale_unit, is_active, quantity_scale, quantity_step, max_transaction_quantity) VALUES

('55555555-2222-2222-2222-000000000001', '22222222-2222-2222-2222-222222222222', '44444444-2222-2222-2222-000000000001', 'piece', 'unit', 1, true, true, true, 0, 1, 1000000);

-- Celavi Pharmacy Balances
INSERT INTO inventory_balances (company_id, location_id, bin_id, product_id, inventory_status, on_hand_base_qty, reserved_base_qty) VALUES

('22222222-2222-2222-2222-222222222222', '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b21', '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2a', '44444444-2222-2222-2222-000000000001', 'AVAILABLE', 25, 0),
('22222222-2222-2222-2222-222222222222', '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b22', '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2b', '44444444-2222-2222-2222-000000000001', 'AVAILABLE', 12, 0),
('22222222-2222-2222-2222-222222222222', '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b23', '2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2c', '44444444-2222-2222-2222-000000000001', 'AVAILABLE', 13, 0);

COMMIT;
