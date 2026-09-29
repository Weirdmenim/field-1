-- Phase 2: canonical inventory model
-- Adds authoritative bins, UOM metadata, reservations, in-transit custody,
-- canonical position views, and a bin/UOM-aware internal mutation primitive.
-- Phase 1 authorization invariants remain mandatory: actor/company are server-derived,
-- app roles receive SELECT-only table access, and low-level mutation functions are not client-callable.

-- ---------------------------------------------------------------------------
-- 1. Canonical enums for reservation and transit lifecycle.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'reservation_status') THEN
    CREATE TYPE reservation_status AS ENUM (
      'ACTIVE', 'PARTIALLY_FULFILLED', 'FULFILLED', 'RELEASED', 'CANCELLED'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'transit_status') THEN
    CREATE TYPE transit_status AS ENUM (
      'IN_TRANSIT', 'PARTIALLY_RECEIVED', 'RECEIVED', 'CANCELLED', 'LOST'
    );
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. Bins are authoritative warehouse sub-locations.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventory_bins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  location_id UUID NOT NULL REFERENCES inventory_locations(id),
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  is_system_default BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_bins_code_not_blank CHECK (btrim(code) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS inventory_bins_company_location_id_unique_idx
  ON inventory_bins (company_id, location_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS inventory_bins_normalized_code_unique_idx
  ON inventory_bins (company_id, location_id, lower(btrim(code)));
CREATE UNIQUE INDEX IF NOT EXISTS inventory_bins_one_system_default_idx
  ON inventory_bins (location_id)
  WHERE is_system_default;

ALTER TABLE inventory_bins
  DROP CONSTRAINT IF EXISTS inventory_bins_company_location_fk;
ALTER TABLE inventory_bins
  ADD CONSTRAINT inventory_bins_company_location_fk
  FOREIGN KEY (company_id, location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE inventory_bins VALIDATE CONSTRAINT inventory_bins_company_location_fk;

CREATE OR REPLACE FUNCTION ensure_inventory_location_default_bin()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO inventory_bins (company_id, location_id, code, name, is_system_default)
  VALUES (NEW.company_id, NEW.id, 'SYSTEM', 'System default bin', true)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_location_default_bin_trigger ON inventory_locations;
CREATE TRIGGER inventory_location_default_bin_trigger
AFTER INSERT ON inventory_locations
FOR EACH ROW EXECUTE FUNCTION ensure_inventory_location_default_bin();

INSERT INTO inventory_bins (company_id, location_id, code, name, is_system_default)
SELECT l.company_id, l.id, 'SYSTEM', 'System default bin', true
FROM inventory_locations l
WHERE NOT EXISTS (
  SELECT 1 FROM inventory_bins b WHERE b.location_id = l.id AND b.is_system_default
)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION default_inventory_bin(p_location_id UUID)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT b.id
  FROM inventory_bins b
  WHERE b.location_id = p_location_id
    AND b.is_system_default
    AND b.is_active
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION resolve_inventory_bin(
  p_company_id UUID,
  p_location_id UUID,
  p_bin_id UUID DEFAULT NULL,
  p_bin_code TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bin UUID;
BEGIN
  IF p_bin_id IS NOT NULL THEN
    SELECT b.id INTO v_bin
    FROM inventory_bins b
    WHERE b.id = p_bin_id
      AND b.company_id = p_company_id
      AND b.location_id = p_location_id
      AND b.is_active;
  ELSIF NULLIF(btrim(p_bin_code), '') IS NOT NULL THEN
    SELECT b.id INTO v_bin
    FROM inventory_bins b
    WHERE b.company_id = p_company_id
      AND b.location_id = p_location_id
      AND lower(btrim(b.code)) = lower(btrim(p_bin_code))
      AND b.is_active;
  ELSE
    v_bin := public.default_inventory_bin(p_location_id);
  END IF;

  IF v_bin IS NULL THEN
    RAISE EXCEPTION 'Unknown or inactive inventory bin for location %', p_location_id USING ERRCODE = '22023';
  END IF;
  RETURN v_bin;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Product UOM configuration becomes authoritative.
-- ---------------------------------------------------------------------------
ALTER TABLE product_units
  ADD COLUMN IF NOT EXISTS quantity_scale SMALLINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS quantity_step NUMERIC(28, 6) NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS max_transaction_quantity NUMERIC(28, 6);

ALTER TABLE product_units
  DROP CONSTRAINT IF EXISTS product_units_quantity_scale_check;
ALTER TABLE product_units
  ADD CONSTRAINT product_units_quantity_scale_check
  CHECK (quantity_scale BETWEEN 0 AND 6);

ALTER TABLE product_units
  DROP CONSTRAINT IF EXISTS product_units_quantity_step_check;
ALTER TABLE product_units
  ADD CONSTRAINT product_units_quantity_step_check
  CHECK (quantity_step > 0 AND quantity_step = round(quantity_step, quantity_scale));

ALTER TABLE product_units
  DROP CONSTRAINT IF EXISTS product_units_max_transaction_quantity_check;
ALTER TABLE product_units
  ADD CONSTRAINT product_units_max_transaction_quantity_check
  CHECK (
    max_transaction_quantity IS NULL
    OR (
      max_transaction_quantity > 0
      AND max_transaction_quantity = round(max_transaction_quantity, quantity_scale)
    )
  );

ALTER TABLE product_units
  DROP CONSTRAINT IF EXISTS product_units_code_not_blank_check;
ALTER TABLE product_units
  ADD CONSTRAINT product_units_code_not_blank_check
  CHECK (btrim(unit_code) <> '');

ALTER TABLE product_units
  DROP CONSTRAINT IF EXISTS product_units_name_not_blank_check;
ALTER TABLE product_units
  ADD CONSTRAINT product_units_name_not_blank_check
  CHECK (btrim(unit_name) <> '');

ALTER TABLE product_units
  DROP CONSTRAINT IF EXISTS product_units_base_conversion_check;
ALTER TABLE product_units
  ADD CONSTRAINT product_units_base_conversion_check
  CHECK (NOT is_base_unit OR conversion_to_base = 1);

CREATE UNIQUE INDEX IF NOT EXISTS product_units_normalized_code_unique_idx
  ON product_units (company_id, product_id, lower(btrim(unit_code)));

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS base_unit_id UUID,
  ADD COLUMN IF NOT EXISTS default_sale_unit_id UUID;

-- Preserve existing UOM rows. If a legacy product has no declared base unit,
-- add a synthetic 1:1 base unit rather than rewriting an unknown conversion.
INSERT INTO product_units (
  id, company_id, product_id, unit_name, unit_code, conversion_to_base,
  is_base_unit, is_default_sale_unit, is_active, quantity_scale, quantity_step
)
SELECT
  gen_random_uuid(), p.company_id, p.id,
  'Legacy base unit',
  'BASE-' || upper(substr(md5(p.id::text), 1, 6)),
  1, true,
  NOT EXISTS (SELECT 1 FROM product_units d WHERE d.product_id = p.id AND d.is_default_sale_unit),
  true, 6, 0.000001
FROM products p
WHERE NOT EXISTS (
  SELECT 1 FROM product_units u WHERE u.product_id = p.id AND u.is_base_unit
);

-- If a product has a base unit but no sale default, use the base as the default.
UPDATE product_units u
SET is_default_sale_unit = true
WHERE u.is_base_unit
  AND NOT EXISTS (
    SELECT 1 FROM product_units d
    WHERE d.product_id = u.product_id AND d.is_default_sale_unit
  );

UPDATE products p
SET base_unit_id = u.id
FROM product_units u
WHERE u.product_id = p.id
  AND u.is_base_unit
  AND p.base_unit_id IS NULL;

UPDATE products p
SET default_sale_unit_id = u.id
FROM product_units u
WHERE u.product_id = p.id
  AND u.is_default_sale_unit
  AND p.default_sale_unit_id IS NULL;

ALTER TABLE products ALTER COLUMN base_unit_id SET NOT NULL;
ALTER TABLE products ALTER COLUMN default_sale_unit_id SET NOT NULL;

ALTER TABLE products
  DROP CONSTRAINT IF EXISTS products_base_unit_fk;
ALTER TABLE products
  ADD CONSTRAINT products_base_unit_fk
  FOREIGN KEY (company_id, id, base_unit_id)
  REFERENCES product_units(company_id, product_id, id)
  DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE products
  DROP CONSTRAINT IF EXISTS products_default_sale_unit_fk;
ALTER TABLE products
  ADD CONSTRAINT products_default_sale_unit_fk
  FOREIGN KEY (company_id, id, default_sale_unit_id)
  REFERENCES product_units(company_id, product_id, id)
  DEFERRABLE INITIALLY DEFERRED;

CREATE OR REPLACE FUNCTION guard_product_unit_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_base_unit UUID;
  v_default_unit UUID;
BEGIN
  SELECT p.base_unit_id, p.default_sale_unit_id
    INTO v_base_unit, v_default_unit
  FROM products p
  WHERE p.id = NEW.product_id AND p.company_id = NEW.company_id;

  IF v_base_unit = NEW.id THEN
    IF NEW.conversion_to_base <> 1 THEN
      RAISE EXCEPTION 'Base unit conversion_to_base must equal 1';
    END IF;
    IF NOT NEW.is_active THEN
      RAISE EXCEPTION 'Configured base unit cannot be inactive';
    END IF;
  END IF;

  IF v_default_unit = NEW.id AND NOT NEW.is_active THEN
    RAISE EXCEPTION 'Configured default sale unit cannot be inactive';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS product_unit_role_guard_trigger ON product_units;
CREATE TRIGGER product_unit_role_guard_trigger
BEFORE INSERT OR UPDATE ON product_units
FOR EACH ROW EXECUTE FUNCTION guard_product_unit_role();

CREATE OR REPLACE FUNCTION validate_product_uom_configuration_values(
  p_company_id UUID,
  p_product_id UUID,
  p_base_unit_id UUID,
  p_default_sale_unit_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_base_conversion NUMERIC;
  v_base_active BOOLEAN;
  v_default_active BOOLEAN;
BEGIN
  SELECT u.conversion_to_base, u.is_active
    INTO v_base_conversion, v_base_active
  FROM product_units u
  WHERE u.company_id = p_company_id
    AND u.product_id = p_product_id
    AND u.id = p_base_unit_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Configured base unit must belong to the product and company';
  END IF;
  IF v_base_conversion <> 1 OR NOT v_base_active THEN
    RAISE EXCEPTION 'Configured base unit must be active with conversion_to_base = 1';
  END IF;

  SELECT u.is_active
    INTO v_default_active
  FROM product_units u
  WHERE u.company_id = p_company_id
    AND u.product_id = p_product_id
    AND u.id = p_default_sale_unit_id;

  IF NOT FOUND OR NOT v_default_active THEN
    RAISE EXCEPTION 'Configured default sale unit must be active and belong to the product and company';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION validate_product_uom_configuration()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM validate_product_uom_configuration_values(
    NEW.company_id, NEW.id, NEW.base_unit_id, NEW.default_sale_unit_id
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS product_uom_configuration_guard_trigger ON products;
CREATE CONSTRAINT TRIGGER product_uom_configuration_guard_trigger
AFTER INSERT OR UPDATE ON products
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_product_uom_configuration();

-- Validate the backfilled configuration immediately so this migration cannot
-- succeed with inactive or cross-product base/default units.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT company_id, id, base_unit_id, default_sale_unit_id FROM products
  LOOP
    PERFORM validate_product_uom_configuration_values(
      r.company_id, r.id, r.base_unit_id, r.default_sale_unit_id
    );
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION convert_product_quantity(
  p_company_id UUID,
  p_product_id UUID,
  p_unit_id UUID,
  p_entered_quantity NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_conversion NUMERIC;
  v_scale SMALLINT;
  v_step NUMERIC;
  v_max NUMERIC;
BEGIN
  IF p_entered_quantity IS NULL OR p_entered_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = '22023';
  END IF;

  SELECT u.conversion_to_base, u.quantity_scale, u.quantity_step, u.max_transaction_quantity
  INTO v_conversion, v_scale, v_step, v_max
  FROM product_units u
  WHERE u.id = p_unit_id
    AND u.company_id = p_company_id
    AND u.product_id = p_product_id
    AND u.is_active;

  IF v_conversion IS NULL THEN
    RAISE EXCEPTION 'Unit does not belong to the active product/company or is inactive' USING ERRCODE = '22023';
  END IF;
  IF p_entered_quantity <> round(p_entered_quantity, v_scale) THEN
    RAISE EXCEPTION 'Quantity exceeds allowed scale of % decimal places', v_scale USING ERRCODE = '22023';
  END IF;
  IF mod(p_entered_quantity, v_step) <> 0 THEN
    RAISE EXCEPTION 'Quantity must be a multiple of unit step %', v_step USING ERRCODE = '22023';
  END IF;
  IF v_max IS NOT NULL AND p_entered_quantity > v_max THEN
    RAISE EXCEPTION 'Quantity exceeds unit transaction maximum %', v_max USING ERRCODE = '22023';
  END IF;

  RETURN p_entered_quantity * v_conversion;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. First-class reservations replace reserved quantity embedded in balances.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventory_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  location_id UUID NOT NULL,
  bin_id UUID,
  product_id UUID NOT NULL,
  owner_type TEXT NOT NULL,
  owner_key TEXT NOT NULL,
  source_document_type TEXT,
  source_document_id UUID,
  source_document_line_id UUID,
  status reservation_status NOT NULL DEFAULT 'ACTIVE',
  reserved_base_qty NUMERIC(28, 6) NOT NULL,
  fulfilled_base_qty NUMERIC(28, 6) NOT NULL DEFAULT 0,
  released_base_qty NUMERIC(28, 6) NOT NULL DEFAULT 0,
  reservation_revision BIGINT NOT NULL DEFAULT 1,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_reservations_owner_not_blank CHECK (btrim(owner_type) <> '' AND btrim(owner_key) <> ''),
  CONSTRAINT inventory_reservations_reserved_positive CHECK (reserved_base_qty > 0),
  CONSTRAINT inventory_reservations_progress_nonnegative CHECK (fulfilled_base_qty >= 0 AND released_base_qty >= 0),
  CONSTRAINT inventory_reservations_progress_within_total CHECK (fulfilled_base_qty + released_base_qty <= reserved_base_qty)
);

ALTER TABLE inventory_reservations
  ADD CONSTRAINT inventory_reservations_company_location_fk
  FOREIGN KEY (company_id, location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE inventory_reservations VALIDATE CONSTRAINT inventory_reservations_company_location_fk;

ALTER TABLE inventory_reservations
  ADD CONSTRAINT inventory_reservations_company_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id)
  NOT VALID;
ALTER TABLE inventory_reservations VALIDATE CONSTRAINT inventory_reservations_company_product_fk;

ALTER TABLE inventory_reservations
  ADD CONSTRAINT inventory_reservations_company_location_bin_fk
  FOREIGN KEY (company_id, location_id, bin_id)
  REFERENCES inventory_bins(company_id, location_id, id)
  NOT VALID;
ALTER TABLE inventory_reservations VALIDATE CONSTRAINT inventory_reservations_company_location_bin_fk;

ALTER TABLE inventory_reservations
  ADD CONSTRAINT inventory_reservations_company_actor_fk
  FOREIGN KEY (company_id, created_by)
  REFERENCES company_memberships(company_id, profile_id)
  NOT VALID;
ALTER TABLE inventory_reservations VALIDATE CONSTRAINT inventory_reservations_company_actor_fk;

CREATE INDEX IF NOT EXISTS inventory_reservations_active_lookup_idx
  ON inventory_reservations (company_id, location_id, product_id, status);
CREATE INDEX IF NOT EXISTS inventory_reservations_owner_lookup_idx
  ON inventory_reservations (company_id, owner_type, owner_key);

-- ---------------------------------------------------------------------------
-- 5. Add bin identity to balances and migrate legacy reserved quantities.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_balances ADD COLUMN IF NOT EXISTS bin_id UUID;

UPDATE inventory_balances b
SET bin_id = public.default_inventory_bin(b.location_id)
WHERE b.bin_id IS NULL;

ALTER TABLE inventory_balances ALTER COLUMN bin_id SET NOT NULL;

ALTER TABLE inventory_balances
  DROP CONSTRAINT IF EXISTS inventory_balances_company_location_bin_fk;
ALTER TABLE inventory_balances
  ADD CONSTRAINT inventory_balances_company_location_bin_fk
  FOREIGN KEY (company_id, location_id, bin_id)
  REFERENCES inventory_bins(company_id, location_id, id)
  NOT VALID;
ALTER TABLE inventory_balances VALIDATE CONSTRAINT inventory_balances_company_location_bin_fk;

ALTER TABLE inventory_balances DROP CONSTRAINT IF EXISTS inventory_balances_pkey;
ALTER TABLE inventory_balances
  ADD CONSTRAINT inventory_balances_pkey
  PRIMARY KEY (company_id, location_id, bin_id, product_id, inventory_status);

-- Preserve every legacy reserved quantity as a first-class reservation record.
INSERT INTO inventory_reservations (
  company_id, location_id, bin_id, product_id,
  owner_type, owner_key, status, reserved_base_qty
)
SELECT
  b.company_id, b.location_id, b.bin_id, b.product_id,
  'LEGACY_BALANCE',
  b.location_id::text || ':' || b.product_id::text || ':' || b.inventory_status::text,
  'ACTIVE'::reservation_status,
  b.reserved_base_qty
FROM inventory_balances b
WHERE b.reserved_base_qty > 0
  AND NOT EXISTS (
    SELECT 1
    FROM inventory_reservations r
    WHERE r.company_id = b.company_id
      AND r.owner_type = 'LEGACY_BALANCE'
      AND r.owner_key = b.location_id::text || ':' || b.product_id::text || ':' || b.inventory_status::text
  );

UPDATE inventory_balances SET reserved_base_qty = 0 WHERE reserved_base_qty <> 0;

ALTER TABLE inventory_balances
  DROP CONSTRAINT IF EXISTS inventory_balances_reserved_column_deprecated;
ALTER TABLE inventory_balances
  ADD CONSTRAINT inventory_balances_reserved_column_deprecated
  CHECK (reserved_base_qty = 0) NOT VALID;

ALTER TABLE inventory_balances
  DROP CONSTRAINT IF EXISTS inventory_balances_quantity_floor;
ALTER TABLE inventory_balances
  ADD CONSTRAINT inventory_balances_quantity_floor
  CHECK (on_hand_base_qty >= -1000000000000 AND on_hand_base_qty <= 1000000000000) NOT VALID;

CREATE OR REPLACE FUNCTION guard_inventory_balance_policy()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_allow_negative BOOLEAN;
BEGIN
  IF NEW.reserved_base_qty <> 0 THEN
    RAISE EXCEPTION 'reserved_base_qty is deprecated; use inventory_reservations';
  END IF;

  SELECT l.allow_negative_inventory INTO v_allow_negative
  FROM inventory_locations l
  WHERE l.id = NEW.location_id AND l.company_id = NEW.company_id;

  IF v_allow_negative IS NULL THEN
    RAISE EXCEPTION 'Unknown inventory location';
  END IF;
  IF NEW.on_hand_base_qty < 0 AND (NEW.inventory_status <> 'AVAILABLE'::inventory_status OR NOT v_allow_negative) THEN
    RAISE EXCEPTION 'Negative inventory is not allowed for this status/location policy' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_balance_policy_guard_trigger ON inventory_balances;
CREATE TRIGGER inventory_balance_policy_guard_trigger
BEFORE INSERT OR UPDATE OF on_hand_base_qty, reserved_base_qty, location_id, company_id
ON inventory_balances
FOR EACH ROW EXECUTE FUNCTION guard_inventory_balance_policy();

-- ---------------------------------------------------------------------------
-- 6. Explicit in-transit custody, separate from on-hand.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventory_transit_lots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  product_id UUID NOT NULL,
  source_location_id UUID NOT NULL,
  source_bin_id UUID,
  destination_location_id UUID NOT NULL,
  destination_bin_id UUID,
  base_quantity NUMERIC(28, 6) NOT NULL CHECK (base_quantity > 0),
  received_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (received_base_quantity >= 0),
  lost_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (lost_base_quantity >= 0),
  status transit_status NOT NULL DEFAULT 'IN_TRANSIT',
  source_reference_type TEXT NOT NULL,
  source_reference_key TEXT NOT NULL,
  source_document_id UUID,
  transit_revision BIGINT NOT NULL DEFAULT 1,
  dispatched_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_transit_locations_differ CHECK (source_location_id <> destination_location_id),
  CONSTRAINT inventory_transit_progress_check CHECK (received_base_quantity + lost_base_quantity <= base_quantity),
  CONSTRAINT inventory_transit_reference_not_blank CHECK (btrim(source_reference_type) <> '' AND btrim(source_reference_key) <> '')
);

ALTER TABLE inventory_transit_lots
  ADD CONSTRAINT inventory_transit_company_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id)
  NOT VALID;
ALTER TABLE inventory_transit_lots VALIDATE CONSTRAINT inventory_transit_company_product_fk;
ALTER TABLE inventory_transit_lots
  ADD CONSTRAINT inventory_transit_company_source_location_fk
  FOREIGN KEY (company_id, source_location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE inventory_transit_lots VALIDATE CONSTRAINT inventory_transit_company_source_location_fk;
ALTER TABLE inventory_transit_lots
  ADD CONSTRAINT inventory_transit_company_destination_location_fk
  FOREIGN KEY (company_id, destination_location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE inventory_transit_lots VALIDATE CONSTRAINT inventory_transit_company_destination_location_fk;
ALTER TABLE inventory_transit_lots
  ADD CONSTRAINT inventory_transit_source_bin_fk
  FOREIGN KEY (company_id, source_location_id, source_bin_id)
  REFERENCES inventory_bins(company_id, location_id, id)
  NOT VALID;
ALTER TABLE inventory_transit_lots VALIDATE CONSTRAINT inventory_transit_source_bin_fk;
ALTER TABLE inventory_transit_lots
  ADD CONSTRAINT inventory_transit_destination_bin_fk
  FOREIGN KEY (company_id, destination_location_id, destination_bin_id)
  REFERENCES inventory_bins(company_id, location_id, id)
  NOT VALID;
ALTER TABLE inventory_transit_lots VALIDATE CONSTRAINT inventory_transit_destination_bin_fk;

CREATE INDEX IF NOT EXISTS inventory_transit_destination_lookup_idx
  ON inventory_transit_lots (company_id, destination_location_id, product_id, status);
CREATE INDEX IF NOT EXISTS inventory_transit_source_lookup_idx
  ON inventory_transit_lots (company_id, source_location_id, product_id, status);

-- ---------------------------------------------------------------------------
-- 7. Movement rows now record bin/UOM structure and reject invalid new rows.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_movements
  ADD COLUMN IF NOT EXISTS source_bin_id UUID,
  ADD COLUMN IF NOT EXISTS destination_bin_id UUID;

UPDATE inventory_movements m
SET source_bin_id = public.default_inventory_bin(m.source_location_id)
WHERE m.source_location_id IS NOT NULL AND m.source_bin_id IS NULL;

UPDATE inventory_movements m
SET destination_bin_id = public.default_inventory_bin(m.destination_location_id)
WHERE m.destination_location_id IS NOT NULL AND m.destination_bin_id IS NULL;

UPDATE inventory_movements m
SET entered_unit_id = p.base_unit_id
FROM products p
WHERE m.product_id = p.id
  AND m.company_id = p.company_id
  AND m.entered_unit_id IS NULL;

ALTER TABLE inventory_movements ALTER COLUMN entered_unit_id SET NOT NULL;

ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_source_bin_fk
  FOREIGN KEY (company_id, source_location_id, source_bin_id)
  REFERENCES inventory_bins(company_id, location_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_source_bin_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_destination_bin_fk
  FOREIGN KEY (company_id, destination_location_id, destination_bin_id)
  REFERENCES inventory_bins(company_id, location_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_destination_bin_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_entered_positive;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_entered_positive CHECK (entered_quantity > 0) NOT VALID;
ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_base_positive;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_base_positive CHECK (base_quantity > 0) NOT VALID;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_location_bin_shape;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_location_bin_shape CHECK (
    (source_location_id IS NULL) = (source_bin_id IS NULL)
    AND (destination_location_id IS NULL) = (destination_bin_id IS NULL)
  ) NOT VALID;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_status_shape;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_status_shape CHECK (
    (source_location_id IS NULL OR source_inventory_status IS NOT NULL)
    AND (destination_location_id IS NULL OR destination_inventory_status IS NOT NULL)
  ) NOT VALID;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_semantic_shape;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_semantic_shape CHECK (
    CASE movement_type
      WHEN 'OPENING_BALANCE' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'TRANSFER_OUT' THEN source_location_id IS NOT NULL AND destination_location_id IS NULL
      WHEN 'TRANSFER_IN' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'TRANSFER_RETURN_IN' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'SALE' THEN source_location_id IS NOT NULL AND destination_location_id IS NULL
      WHEN 'SALE_REVERSAL' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'CUSTOMER_RETURN' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'STOCK_ADJUSTMENT_IN' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'STOCK_ADJUSTMENT_OUT' THEN source_location_id IS NOT NULL AND destination_location_id IS NULL
      WHEN 'STOCK_COUNT_VARIANCE_IN' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'STOCK_COUNT_VARIANCE_OUT' THEN source_location_id IS NOT NULL AND destination_location_id IS NULL
      WHEN 'PURCHASE_RECEIPT' THEN source_location_id IS NULL AND destination_location_id IS NOT NULL
      WHEN 'EXPIRY' THEN source_location_id IS NOT NULL AND destination_location_id IS NULL
      WHEN 'TRANSFER_LOSS' THEN source_location_id IS NOT NULL AND destination_location_id IS NULL
      WHEN 'STATUS_CHANGE' THEN source_location_id IS NOT NULL AND destination_location_id IS NOT NULL
        AND source_location_id = destination_location_id
        AND source_bin_id = destination_bin_id
        AND source_inventory_status IS DISTINCT FROM destination_inventory_status
      WHEN 'DAMAGE' THEN source_location_id IS NOT NULL AND destination_location_id IS NOT NULL
        AND source_location_id = destination_location_id
        AND source_bin_id = destination_bin_id
        AND source_inventory_status = 'AVAILABLE'::inventory_status
        AND destination_inventory_status = 'DAMAGED'::inventory_status
      WHEN 'TRANSFER_REVERSAL' THEN false
      ELSE false
    END
  ) NOT VALID;

-- ---------------------------------------------------------------------------
-- 8. Canonical warehouse position views.
-- Physical on-hand is the sum of AVAILABLE + DAMAGED + BLOCKED status buckets.
-- Available-to-promise = AVAILABLE physical - active reservation remainder.
-- In-transit stays separate until received.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW inventory_location_positions
WITH (security_invoker = true)
AS
WITH physical AS (
  SELECT
    b.company_id,
    b.location_id,
    b.product_id,
    sum(b.on_hand_base_qty) AS physical_on_hand_base_qty,
    sum(b.on_hand_base_qty) FILTER (WHERE b.inventory_status = 'AVAILABLE') AS available_physical_base_qty,
    sum(b.on_hand_base_qty) FILTER (WHERE b.inventory_status = 'DAMAGED') AS damaged_base_qty,
    sum(b.on_hand_base_qty) FILTER (WHERE b.inventory_status = 'BLOCKED') AS blocked_base_qty,
    max(b.physical_status_revision) AS physical_revision
  FROM inventory_balances b
  GROUP BY b.company_id, b.location_id, b.product_id
), reservations AS (
  SELECT
    r.company_id,
    r.location_id,
    r.product_id,
    sum(r.reserved_base_qty - r.fulfilled_base_qty - r.released_base_qty)
      FILTER (WHERE r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')) AS reserved_base_qty,
    max(r.reservation_revision) AS reservation_revision
  FROM inventory_reservations r
  GROUP BY r.company_id, r.location_id, r.product_id
), transit AS (
  SELECT
    t.company_id,
    t.destination_location_id AS location_id,
    t.product_id,
    sum(t.base_quantity - t.received_base_quantity - t.lost_base_quantity)
      FILTER (WHERE t.status IN ('IN_TRANSIT', 'PARTIALLY_RECEIVED')) AS in_transit_inbound_base_qty
  FROM inventory_transit_lots t
  GROUP BY t.company_id, t.destination_location_id, t.product_id
)
SELECT
  l.company_id,
  l.id AS location_id,
  p.id AS product_id,
  p.name AS product_name,
  p.sku,
  p.base_unit_id,
  u.unit_name AS base_unit_name,
  u.unit_code AS base_unit_code,
  u.quantity_scale,
  u.quantity_step,
  COALESCE(ph.physical_on_hand_base_qty, 0) AS physical_on_hand_base_qty,
  COALESCE(ph.available_physical_base_qty, 0) AS available_physical_base_qty,
  COALESCE(ph.damaged_base_qty, 0) AS damaged_base_qty,
  COALESCE(ph.blocked_base_qty, 0) AS blocked_base_qty,
  COALESCE(rs.reserved_base_qty, 0) AS reserved_base_qty,
  COALESCE(ph.available_physical_base_qty, 0) - COALESCE(rs.reserved_base_qty, 0) AS available_to_promise_base_qty,
  COALESCE(tr.in_transit_inbound_base_qty, 0) AS in_transit_inbound_base_qty,
  COALESCE(ph.physical_revision, 0) AS physical_revision,
  COALESCE(rs.reservation_revision, 0) AS reservation_revision
FROM inventory_locations l
JOIN products p ON p.company_id = l.company_id
JOIN product_units u ON u.id = p.base_unit_id AND u.product_id = p.id AND u.company_id = p.company_id
LEFT JOIN physical ph ON ph.company_id = l.company_id AND ph.location_id = l.id AND ph.product_id = p.id
LEFT JOIN reservations rs ON rs.company_id = l.company_id AND rs.location_id = l.id AND rs.product_id = p.id
LEFT JOIN transit tr ON tr.company_id = l.company_id AND tr.location_id = l.id AND tr.product_id = p.id;

CREATE OR REPLACE VIEW inventory_bin_positions
WITH (security_invoker = true)
AS
WITH physical AS (
  SELECT
    b.company_id, b.location_id, b.bin_id, b.product_id,
    sum(b.on_hand_base_qty) AS physical_on_hand_base_qty,
    sum(b.on_hand_base_qty) FILTER (WHERE b.inventory_status = 'AVAILABLE') AS available_physical_base_qty,
    sum(b.on_hand_base_qty) FILTER (WHERE b.inventory_status = 'DAMAGED') AS damaged_base_qty,
    sum(b.on_hand_base_qty) FILTER (WHERE b.inventory_status = 'BLOCKED') AS blocked_base_qty
  FROM inventory_balances b
  GROUP BY b.company_id, b.location_id, b.bin_id, b.product_id
), reservations AS (
  SELECT
    r.company_id, r.location_id, r.bin_id, r.product_id,
    sum(r.reserved_base_qty - r.fulfilled_base_qty - r.released_base_qty)
      FILTER (WHERE r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')) AS reserved_base_qty
  FROM inventory_reservations r
  WHERE r.bin_id IS NOT NULL
  GROUP BY r.company_id, r.location_id, r.bin_id, r.product_id
), transit AS (
  SELECT
    t.company_id, t.destination_location_id AS location_id, t.destination_bin_id AS bin_id, t.product_id,
    sum(t.base_quantity - t.received_base_quantity - t.lost_base_quantity)
      FILTER (WHERE t.status IN ('IN_TRANSIT', 'PARTIALLY_RECEIVED')) AS in_transit_inbound_base_qty
  FROM inventory_transit_lots t
  WHERE t.destination_bin_id IS NOT NULL
  GROUP BY t.company_id, t.destination_location_id, t.destination_bin_id, t.product_id
), position_keys AS (
  SELECT company_id, location_id, bin_id, product_id FROM physical
  UNION
  SELECT company_id, location_id, bin_id, product_id FROM reservations
  UNION
  SELECT company_id, location_id, bin_id, product_id FROM transit
)
SELECT
  k.company_id,
  k.location_id,
  k.bin_id,
  ib.code AS bin_code,
  k.product_id,
  COALESCE(ph.physical_on_hand_base_qty, 0) AS physical_on_hand_base_qty,
  COALESCE(ph.available_physical_base_qty, 0) AS available_physical_base_qty,
  COALESCE(ph.damaged_base_qty, 0) AS damaged_base_qty,
  COALESCE(ph.blocked_base_qty, 0) AS blocked_base_qty,
  COALESCE(rs.reserved_base_qty, 0) AS reserved_base_qty,
  COALESCE(ph.available_physical_base_qty, 0) - COALESCE(rs.reserved_base_qty, 0) AS available_to_promise_base_qty,
  COALESCE(tr.in_transit_inbound_base_qty, 0) AS in_transit_inbound_base_qty
FROM position_keys k
JOIN inventory_bins ib
  ON ib.id = k.bin_id AND ib.location_id = k.location_id AND ib.company_id = k.company_id
LEFT JOIN physical ph
  ON ph.company_id = k.company_id AND ph.location_id = k.location_id AND ph.bin_id = k.bin_id AND ph.product_id = k.product_id
LEFT JOIN reservations rs
  ON rs.company_id = k.company_id AND rs.location_id = k.location_id AND rs.bin_id = k.bin_id AND rs.product_id = k.product_id
LEFT JOIN transit tr
  ON tr.company_id = k.company_id AND tr.location_id = k.location_id AND tr.bin_id = k.bin_id AND tr.product_id = k.product_id;

-- ---------------------------------------------------------------------------
-- 9. Bin/UOM-aware internal primitive. This remains internal/revoked.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_inventory_operation_v2(
  p_company_id UUID,
  p_operation_type TEXT,
  p_client_transaction_id TEXT,
  p_request_fingerprint TEXT,
  p_initiating_actor UUID,
  p_product_id UUID,
  p_movement_type movement_type,
  p_source_location_id UUID,
  p_source_bin_id UUID,
  p_destination_location_id UUID,
  p_destination_bin_id UUID,
  p_source_status inventory_status,
  p_destination_status inventory_status,
  p_entered_quantity NUMERIC,
  p_entered_unit_id UUID,
  p_reference_type TEXT,
  p_reference_id UUID,
  p_reference_number TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operation_id UUID;
  v_existing_status operation_status;
  v_existing_fingerprint TEXT;
  v_movement_id UUID;
  v_base_quantity NUMERIC;
  v_current_source NUMERIC;
  v_new_source NUMERIC;
  v_allow_negative BOOLEAN;
BEGIN
  v_base_quantity := public.convert_product_quantity(
    p_company_id, p_product_id, p_entered_unit_id, p_entered_quantity
  );

  IF p_source_location_id IS NULL AND p_destination_location_id IS NULL THEN
    RAISE EXCEPTION 'Movement must have a source or destination' USING ERRCODE = '22023';
  END IF;
  IF p_source_location_id IS NOT NULL AND p_source_bin_id IS NULL THEN
    RAISE EXCEPTION 'source_bin_id is required when source_location_id is set' USING ERRCODE = '22023';
  END IF;
  IF p_destination_location_id IS NOT NULL AND p_destination_bin_id IS NULL THEN
    RAISE EXCEPTION 'destination_bin_id is required when destination_location_id is set' USING ERRCODE = '22023';
  END IF;

  IF p_source_location_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM inventory_locations l
    JOIN inventory_bins b ON b.company_id = l.company_id AND b.location_id = l.id
    WHERE l.company_id = p_company_id
      AND l.id = p_source_location_id
      AND l.is_active
      AND b.id = p_source_bin_id
      AND b.is_active
  ) THEN
    RAISE EXCEPTION 'Source location/bin is unknown, inactive, or outside the company' USING ERRCODE = '22023';
  END IF;

  IF p_destination_location_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM inventory_locations l
    JOIN inventory_bins b ON b.company_id = l.company_id AND b.location_id = l.id
    WHERE l.company_id = p_company_id
      AND l.id = p_destination_location_id
      AND l.is_active
      AND b.id = p_destination_bin_id
      AND b.is_active
  ) THEN
    RAISE EXCEPTION 'Destination location/bin is unknown, inactive, or outside the company' USING ERRCODE = '22023';
  END IF;

  SELECT o.id, o.status, o.request_fingerprint
  INTO v_operation_id, v_existing_status, v_existing_fingerprint
  FROM inventory_operations o
  WHERE o.company_id = p_company_id
    AND o.operation_type = p_operation_type
    AND o.client_transaction_id = p_client_transaction_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_fingerprint <> p_request_fingerprint THEN
      RAISE EXCEPTION 'Idempotency conflict: same transaction ID with different payload' USING ERRCODE = '23505';
    END IF;
    IF v_existing_status = 'COMPLETED' THEN
      RETURN jsonb_build_object('success', true, 'operation_id', v_operation_id, 'status', 'ALREADY_COMPLETED');
    END IF;
  ELSE
    INSERT INTO inventory_operations (
      company_id, operation_type, client_transaction_id, request_fingerprint,
      initiating_actor, status
    ) VALUES (
      p_company_id, p_operation_type, p_client_transaction_id, p_request_fingerprint,
      p_initiating_actor, 'PROCESSING'
    )
    RETURNING id INTO v_operation_id;
  END IF;

  IF p_source_location_id IS NOT NULL THEN
    SELECT l.allow_negative_inventory INTO v_allow_negative
    FROM inventory_locations l
    WHERE l.id = p_source_location_id AND l.company_id = p_company_id;

    -- Materialize a zero row first so an initially absent balance also has a row
    -- that can be locked deterministically. This avoids an absent-row race.
    INSERT INTO inventory_balances (
      company_id, location_id, bin_id, product_id, inventory_status,
      on_hand_base_qty, reserved_base_qty, physical_status_revision
    ) VALUES (
      p_company_id, p_source_location_id, p_source_bin_id, p_product_id, p_source_status,
      0, 0, 1
    )
    ON CONFLICT (company_id, location_id, bin_id, product_id, inventory_status) DO NOTHING;

    SELECT b.on_hand_base_qty INTO v_current_source
    FROM inventory_balances b
    WHERE b.company_id = p_company_id
      AND b.location_id = p_source_location_id
      AND b.bin_id = p_source_bin_id
      AND b.product_id = p_product_id
      AND b.inventory_status = p_source_status
    FOR UPDATE;

    v_new_source := v_current_source - v_base_quantity;
    IF v_new_source < 0 AND NOT COALESCE(v_allow_negative, false) THEN
      RAISE EXCEPTION 'Insufficient stock: source balance %, requested %', v_current_source, v_base_quantity
        USING ERRCODE = '23514';
    END IF;

    UPDATE inventory_balances
    SET on_hand_base_qty = v_new_source,
        physical_status_revision = physical_status_revision + 1,
        updated_at = now()
    WHERE company_id = p_company_id
      AND location_id = p_source_location_id
      AND bin_id = p_source_bin_id
      AND product_id = p_product_id
      AND inventory_status = p_source_status;
  END IF;

  IF p_destination_location_id IS NOT NULL THEN
    INSERT INTO inventory_balances (
      company_id, location_id, bin_id, product_id, inventory_status,
      on_hand_base_qty, reserved_base_qty, physical_status_revision
    ) VALUES (
      p_company_id, p_destination_location_id, p_destination_bin_id, p_product_id, p_destination_status,
      v_base_quantity, 0, 1
    )
    ON CONFLICT (company_id, location_id, bin_id, product_id, inventory_status)
    DO UPDATE SET
      on_hand_base_qty = inventory_balances.on_hand_base_qty + EXCLUDED.on_hand_base_qty,
      physical_status_revision = inventory_balances.physical_status_revision + 1,
      updated_at = now();
  END IF;

  INSERT INTO inventory_movements (
    company_id, product_id, movement_type,
    source_location_id, source_bin_id,
    destination_location_id, destination_bin_id,
    source_inventory_status, destination_inventory_status,
    entered_quantity, entered_unit_id, base_quantity,
    reference_type, reference_id, reference_number,
    performed_by, client_transaction_id, operation_id, posted_at
  ) VALUES (
    p_company_id, p_product_id, p_movement_type,
    p_source_location_id, p_source_bin_id,
    p_destination_location_id, p_destination_bin_id,
    p_source_status, p_destination_status,
    p_entered_quantity, p_entered_unit_id, v_base_quantity,
    p_reference_type, p_reference_id, p_reference_number,
    p_initiating_actor, p_client_transaction_id, v_operation_id, now()
  ) RETURNING id INTO v_movement_id;

  UPDATE inventory_operations
  SET status = 'COMPLETED', posted_at = now()
  WHERE id = v_operation_id;

  RETURN jsonb_build_object(
    'success', true,
    'operation_id', v_operation_id,
    'movement_id', v_movement_id,
    'entered_quantity', p_entered_quantity,
    'base_quantity', v_base_quantity
  );
END;
$$;

REVOKE ALL ON FUNCTION post_inventory_operation_v2(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, movement_type,
  UUID, UUID, UUID, UUID, inventory_status, inventory_status,
  NUMERIC, UUID, TEXT, UUID, TEXT
) FROM PUBLIC, anon, authenticated;

-- Authorized compatibility wrapper upgraded to canonical bins/UOM/status semantics.
CREATE OR REPLACE FUNCTION public.post_inventory_operation(p_operation JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID;
  v_company UUID;
  v_location UUID;
  v_location_active BOOLEAN;
  v_allow_direct_sales BOOLEAN;
  v_permission TEXT;
  v_movement_type movement_type;
  v_source_loc UUID;
  v_source_bin UUID;
  v_dest_loc UUID;
  v_dest_bin UUID;
  v_source_status inventory_status := 'AVAILABLE';
  v_dest_status inventory_status := 'AVAILABLE';
  v_op_type TEXT;
  v_qty NUMERIC;
  v_product UUID;
  v_unit UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  v_actor := public.current_profile_id();
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authenticated user is not provisioned for FieldOne' USING ERRCODE = '42501';
  END IF;

  v_op_type := p_operation->>'operation_type';
  IF v_op_type = 'COUNT' THEN
    RAISE EXCEPTION 'COUNT is an observation and cannot mutate stock directly; use the count workflow command'
      USING ERRCODE = '0A000';
  END IF;
  IF v_op_type = 'ADJUSTMENT' THEN
    RAISE EXCEPTION 'Generic ADJUSTMENT is ambiguous; use ADJUSTMENT_IN or ADJUSTMENT_OUT'
      USING ERRCODE = '22023';
  END IF;
  IF v_op_type NOT IN ('RECEIPT', 'DISPATCH', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'STATUS_CHANGE', 'DAMAGE') THEN
    RAISE EXCEPTION 'Unsupported operation type: %', COALESCE(v_op_type, '<null>') USING ERRCODE = '22023';
  END IF;

  IF NULLIF(p_operation->>'location_id', '') IS NULL THEN
    RAISE EXCEPTION 'location_id is required' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(p_operation->>'product_id', '') IS NULL THEN
    RAISE EXCEPTION 'product_id is required' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(p_operation->>'qty', '') IS NULL THEN
    RAISE EXCEPTION 'qty is required' USING ERRCODE = '22023';
  END IF;

  v_location := (p_operation->>'location_id')::UUID;
  v_product := (p_operation->>'product_id')::UUID;
  v_qty := (p_operation->>'qty')::NUMERIC;

  SELECT l.company_id, l.is_active, l.allow_direct_sales
  INTO v_company, v_location_active, v_allow_direct_sales
  FROM inventory_locations l
  WHERE l.id = v_location;

  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Unknown inventory location' USING ERRCODE = '22023';
  END IF;
  IF NOT v_location_active THEN
    RAISE EXCEPTION 'Inventory location is inactive' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_company_member(v_company) THEN
    RAISE EXCEPTION 'Company membership required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(NULLIF(p_operation->>'unit_id', '')::UUID, p.base_unit_id)
  INTO v_unit
  FROM products p
  WHERE p.id = v_product AND p.company_id = v_company;

  IF v_unit IS NULL THEN
    RAISE EXCEPTION 'Product is not part of the authorized company' USING ERRCODE = '42501';
  END IF;

  v_source_status := COALESCE(NULLIF(p_operation->>'source_status', '')::inventory_status, 'AVAILABLE'::inventory_status);
  v_dest_status := COALESCE(NULLIF(p_operation->>'destination_status', '')::inventory_status, 'AVAILABLE'::inventory_status);

  IF v_op_type = 'RECEIPT' THEN
    v_permission := 'inventory.receive';
    v_movement_type := 'TRANSFER_IN';
    v_source_loc := NULL;
    v_dest_loc := v_location;
    v_dest_bin := public.resolve_inventory_bin(v_company, v_location, NULLIF(p_operation->>'bin_id', '')::UUID, p_operation->>'bin_code');
  ELSIF v_op_type = 'DISPATCH' THEN
    v_permission := 'inventory.dispatch';
    IF NOT v_allow_direct_sales THEN
      RAISE EXCEPTION 'Direct sales are not allowed from this location' USING ERRCODE = '42501';
    END IF;
    v_movement_type := 'SALE';
    v_source_loc := v_location;
    v_source_bin := public.resolve_inventory_bin(v_company, v_location, NULLIF(p_operation->>'bin_id', '')::UUID, p_operation->>'bin_code');
    v_dest_loc := NULL;
  ELSIF v_op_type = 'ADJUSTMENT_IN' THEN
    v_permission := 'inventory.adjust';
    v_movement_type := 'STOCK_ADJUSTMENT_IN';
    v_source_loc := NULL;
    v_dest_loc := v_location;
    v_dest_bin := public.resolve_inventory_bin(v_company, v_location, NULLIF(p_operation->>'bin_id', '')::UUID, p_operation->>'bin_code');
  ELSIF v_op_type = 'ADJUSTMENT_OUT' THEN
    v_permission := 'inventory.adjust';
    v_movement_type := 'STOCK_ADJUSTMENT_OUT';
    v_source_loc := v_location;
    v_source_bin := public.resolve_inventory_bin(v_company, v_location, NULLIF(p_operation->>'bin_id', '')::UUID, p_operation->>'bin_code');
    v_dest_loc := NULL;
  ELSIF v_op_type = 'DAMAGE' THEN
    v_permission := 'inventory.adjust';
    v_movement_type := 'DAMAGE';
    v_source_loc := v_location;
    v_dest_loc := v_location;
    v_source_bin := public.resolve_inventory_bin(v_company, v_location, NULLIF(p_operation->>'bin_id', '')::UUID, p_operation->>'bin_code');
    v_dest_bin := v_source_bin;
    v_source_status := 'AVAILABLE';
    v_dest_status := 'DAMAGED';
  ELSE
    v_permission := 'inventory.adjust';
    v_movement_type := 'STATUS_CHANGE';
    v_source_loc := v_location;
    v_dest_loc := v_location;
    v_source_bin := public.resolve_inventory_bin(v_company, v_location, NULLIF(p_operation->>'bin_id', '')::UUID, p_operation->>'bin_code');
    v_dest_bin := v_source_bin;
    IF v_source_status = v_dest_status THEN
      RAISE EXCEPTION 'STATUS_CHANGE requires different source and destination statuses' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF NOT public.has_warehouse_permission(v_location, v_permission) THEN
    RAISE EXCEPTION 'Warehouse permission % required', v_permission USING ERRCODE = '42501';
  END IF;

  RETURN public.post_inventory_operation_v2(
    v_company,
    v_op_type,
    p_operation->>'client_transaction_id',
    COALESCE(p_operation->>'request_fingerprint', md5(p_operation::text)),
    v_actor,
    v_product,
    v_movement_type,
    v_source_loc,
    v_source_bin,
    v_dest_loc,
    v_dest_bin,
    v_source_status,
    v_dest_status,
    v_qty,
    v_unit,
    'DOCUMENT',
    NULL,
    p_operation->>'reference'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.post_inventory_operation(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_inventory_operation(JSONB) TO authenticated;

-- The Phase 0/1 low-level primitive does not carry bin/UOM identity and must never be reused.
CREATE OR REPLACE FUNCTION public.post_inventory_operation(
    p_company_id UUID,
    p_operation_type TEXT,
    p_client_transaction_id TEXT,
    p_request_fingerprint TEXT,
    p_initiating_actor UUID,
    p_product_id UUID,
    p_movement_type movement_type,
    p_source_location_id UUID,
    p_destination_location_id UUID,
    p_source_status inventory_status,
    p_destination_status inventory_status,
    p_entered_quantity NUMERIC,
    p_base_quantity NUMERIC,
    p_reference_type TEXT,
    p_reference_id UUID,
    p_reference_number TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'Deprecated Phase 1 mutation primitive: use the authorized JSON wrapper/canonical command path'
    USING ERRCODE = '0A000';
END;
$$;

REVOKE ALL ON FUNCTION public.post_inventory_operation(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, movement_type, UUID, UUID,
  inventory_status, inventory_status, NUMERIC, NUMERIC, TEXT, UUID, TEXT
) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 10. RLS and privileges for new canonical inventory tables/views.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_bins ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_transit_lots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inventory_bins_select_authorized ON inventory_bins;
CREATE POLICY inventory_bins_select_authorized ON inventory_bins
FOR SELECT TO authenticated
USING (public.has_warehouse_permission(location_id, 'inventory.read'));

DROP POLICY IF EXISTS inventory_reservations_select_authorized ON inventory_reservations;
CREATE POLICY inventory_reservations_select_authorized ON inventory_reservations
FOR SELECT TO authenticated
USING (public.has_warehouse_permission(location_id, 'inventory.read'));

DROP POLICY IF EXISTS inventory_transit_select_authorized ON inventory_transit_lots;
CREATE POLICY inventory_transit_select_authorized ON inventory_transit_lots
FOR SELECT TO authenticated
USING (
  public.has_warehouse_permission(source_location_id, 'inventory.read')
  OR public.has_warehouse_permission(destination_location_id, 'inventory.read')
);

REVOKE ALL PRIVILEGES ON TABLE inventory_bins, inventory_reservations, inventory_transit_lots FROM anon, authenticated;
GRANT SELECT ON TABLE inventory_bins, inventory_reservations, inventory_transit_lots TO authenticated;
GRANT SELECT ON inventory_location_positions, inventory_bin_positions TO authenticated;

REVOKE ALL ON FUNCTION public.default_inventory_bin(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.convert_product_quantity(UUID, UUID, UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_inventory_bin(UUID, UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ensure_inventory_location_default_bin() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_inventory_balance_policy() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_product_unit_role() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.validate_product_uom_configuration_values(UUID, UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.validate_product_uom_configuration() FROM PUBLIC, anon, authenticated;

COMMENT ON VIEW inventory_location_positions IS
  'Phase 2 canonical warehouse stock position. physical_on_hand = AVAILABLE + DAMAGED + BLOCKED; ATP = AVAILABLE physical - active reservation remainder; inbound transit is separate.';
COMMENT ON COLUMN inventory_balances.reserved_base_qty IS
  'Deprecated in Phase 2. Must remain zero; authoritative reservations live in inventory_reservations.';
COMMENT ON FUNCTION public.post_inventory_operation(JSONB) IS
  'Phase 2 compatibility wrapper. Server-derived actor/company, authoritative bin/UOM conversion, negative-stock enforcement, explicit adjustment/status semantics. COUNT intentionally fails closed until the authoritative count workflow is implemented.';
