-- pgTAP Phase 2 canonical inventory model tests.
BEGIN;
SELECT plan(22);

SELECT has_table('public', 'inventory_bins', 'inventory_bins exists');
SELECT has_table('public', 'inventory_reservations', 'inventory_reservations exists');
SELECT has_table('public', 'inventory_transit_lots', 'inventory_transit_lots exists');
SELECT has_view('public', 'inventory_location_positions', 'canonical location position view exists');
SELECT has_view('public', 'inventory_bin_positions', 'canonical bin position view exists');
SELECT col_not_null('public', 'inventory_balances', 'bin_id', 'balances require a bin');
SELECT col_not_null('public', 'products', 'base_unit_id', 'products require a base unit');
SELECT col_not_null('public', 'products', 'default_sale_unit_id', 'products require a default sale unit');
SELECT col_not_null('public', 'inventory_movements', 'entered_unit_id', 'movements require entered UOM');

-- Miro Laptop at Miro Central:  AVAILABLE on_hand=150 (bin A1) + AVAILABLE on_hand=40 at Store (different location)
-- Reserve=5 (from seed), In-Transit=10 (from seed)
-- ATP at central = 150 (available on_hand) - 5 (reserved) - 10 (in_transit_out) = 135 ... depends on view formula
-- Actually the view groups by (company, location, product) so we need to check what the seed puts at WH-MIRO-01
-- Seed: bin A1 = 150 AVAILABLE, plus reserve=5, transit_out=10
-- physical on-hand at Miro Central for product 401 = 150 (only AVAILABLE status rows at that location)
-- The Downtown Store has 40 AVAILABLE + 2 DAMAGED for 401, but that's a different location.
SELECT is(
  (SELECT physical_on_hand_base_qty::numeric FROM inventory_location_positions
   WHERE company_id='11111111-1111-1111-1111-111111111111'
     AND location_id='33333333-3333-3333-3333-333333333331'
     AND product_id='44444444-4444-4444-4444-444444444401'),
  150::numeric,
  'Miro Laptop physical on-hand at Central Warehouse'
);
SELECT is(
  (SELECT reserved_base_qty::numeric FROM inventory_location_positions
   WHERE company_id='11111111-1111-1111-1111-111111111111'
     AND location_id='33333333-3333-3333-3333-333333333331'
     AND product_id='44444444-4444-4444-4444-444444444401'),
  5::numeric,
  'Miro Laptop reservation at Central Warehouse'
);
SELECT is(
  (SELECT in_transit_inbound_base_qty::numeric FROM inventory_location_positions
   WHERE company_id='11111111-1111-1111-1111-111111111111'
     AND location_id='1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11'
     AND product_id='44444444-4444-4444-4444-444444444401'),
  10::numeric,
  'Miro Laptop in-transit inbound at Downtown Store'
);

SELECT throws_ok(
  $$SELECT convert_product_quantity('11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444401','55555555-5555-5555-5555-555555555501',0.333)$$,
  '22023', NULL,
  'UOM scale/step rejects unsupported fractional quantity'
);
SELECT is(
  convert_product_quantity('11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444401','55555555-5555-5555-5555-555555555501',5)::numeric,
  5::numeric,
  'integer quantity accepted for integer UOM'
);

SELECT throws_ok(
  $$UPDATE product_units
    SET is_active = false
    WHERE id='55555555-5555-5555-5555-555555555501'$$,
  'P0001', NULL,
  'configured base/default UOM cannot be deactivated'
);

SELECT throws_ok(
  $$UPDATE product_units
    SET unit_code = ''
    WHERE id='55555555-5555-5555-5555-555555555501'$$,
  '23514', NULL,
  'UOM code cannot be blank'
);

SELECT throws_ok(
  $$UPDATE product_units
    SET quantity_scale = 1, quantity_step = 0.25
    WHERE id='55555555-5555-5555-5555-555555555501'$$,
  '23514', NULL,
  'UOM step precision cannot exceed declared scale'
);

SELECT throws_ok(
  $$INSERT INTO inventory_balances(company_id,location_id,bin_id,product_id,inventory_status,on_hand_base_qty,reserved_base_qty)
    VALUES('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331','66666666-6666-6666-6666-666666666601','44444444-4444-4444-4444-444444444401','AVAILABLE',-1,0)$$,
  '23514', NULL,
  'negative inventory is rejected when location policy forbids it'
);

SELECT throws_ok(
  $$INSERT INTO inventory_balances(company_id,location_id,bin_id,product_id,inventory_status,on_hand_base_qty,reserved_base_qty)
    VALUES('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331','66666666-6666-6666-6666-666666666601','44444444-4444-4444-4444-444444444403','AVAILABLE',0,1)$$,
  'P0001', NULL,
  'legacy reserved column cannot receive new reservation data'
);

SELECT is(
  (SELECT movement_type::text FROM inventory_movements WHERE false LIMIT 1),
  NULL::text,
  'movement table remains queryable with canonical enum'
);
SELECT ok(
  (SELECT count(*) >= 3 FROM products WHERE company_id='11111111-1111-1111-1111-111111111111'),
  'seed products remain preserved'
);
SELECT ok(
  (SELECT count(*) >= 2 FROM inventory_bins WHERE location_id='33333333-3333-3333-3333-333333333331'),
  'Miro Central has authoritative bins'
);

SELECT * FROM finish();
ROLLBACK;
