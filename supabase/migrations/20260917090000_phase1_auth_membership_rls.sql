-- Phase 1: authenticated actor binding, tenant isolation, warehouse authorization,
-- RLS, tenant-safe foreign keys, and restricted inventory mutation entrypoints.
-- This migration is intentionally additive: legacy profile/company columns remain
-- in place until later phases complete their data-model migrations.

-- ---------------------------------------------------------------------------
-- 1. Bind operational profiles to Supabase Auth and introduce memberships.
-- ---------------------------------------------------------------------------
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS profiles_auth_user_id_unique_idx
  ON profiles (auth_user_id)
  WHERE auth_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS company_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'SUSPENDED', 'REVOKED')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, profile_id)
);

CREATE TABLE IF NOT EXISTS warehouse_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  location_id UUID NOT NULL REFERENCES inventory_locations(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'SUSPENDED', 'REVOKED')),
  can_read_inventory BOOLEAN NOT NULL DEFAULT true,
  can_receive BOOLEAN NOT NULL DEFAULT false,
  can_dispatch BOOLEAN NOT NULL DEFAULT false,
  can_count BOOLEAN NOT NULL DEFAULT false,
  can_approve_counts BOOLEAN NOT NULL DEFAULT false,
  can_adjust BOOLEAN NOT NULL DEFAULT false,
  can_reverse BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, location_id, profile_id),
  FOREIGN KEY (company_id, profile_id)
    REFERENCES company_memberships(company_id, profile_id)
    ON DELETE CASCADE
);

-- Existing profiles are preserved and receive a legacy-company membership.
-- auth_user_id remains NULL until an administrator explicitly binds the profile
-- to an authenticated Supabase user. This deliberately fails closed.
INSERT INTO company_memberships (company_id, profile_id, role, status)
SELECT p.company_id, p.id, p.role, 'ACTIVE'
FROM profiles p
ON CONFLICT (company_id, profile_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Tenant-safe relational constraints.
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS products_company_id_id_unique_idx
  ON products (company_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS inventory_locations_company_id_id_unique_idx
  ON inventory_locations (company_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS product_units_company_product_id_id_unique_idx
  ON product_units (company_id, product_id, id);

ALTER TABLE warehouse_memberships
  DROP CONSTRAINT IF EXISTS warehouse_memberships_company_location_fk;
ALTER TABLE warehouse_memberships
  ADD CONSTRAINT warehouse_memberships_company_location_fk
  FOREIGN KEY (company_id, location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE warehouse_memberships VALIDATE CONSTRAINT warehouse_memberships_company_location_fk;

ALTER TABLE product_units
  DROP CONSTRAINT IF EXISTS product_units_company_product_fk;
ALTER TABLE product_units
  ADD CONSTRAINT product_units_company_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id)
  NOT VALID;
ALTER TABLE product_units VALIDATE CONSTRAINT product_units_company_product_fk;

ALTER TABLE inventory_balances
  DROP CONSTRAINT IF EXISTS inventory_balances_company_location_fk;
ALTER TABLE inventory_balances
  ADD CONSTRAINT inventory_balances_company_location_fk
  FOREIGN KEY (company_id, location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE inventory_balances VALIDATE CONSTRAINT inventory_balances_company_location_fk;

ALTER TABLE inventory_balances
  DROP CONSTRAINT IF EXISTS inventory_balances_company_product_fk;
ALTER TABLE inventory_balances
  ADD CONSTRAINT inventory_balances_company_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id)
  NOT VALID;
ALTER TABLE inventory_balances VALIDATE CONSTRAINT inventory_balances_company_product_fk;

ALTER TABLE inventory_locations
  DROP CONSTRAINT IF EXISTS inventory_locations_company_responsible_user_fk;
ALTER TABLE inventory_locations
  ADD CONSTRAINT inventory_locations_company_responsible_user_fk
  FOREIGN KEY (company_id, responsible_user_id)
  REFERENCES company_memberships(company_id, profile_id)
  NOT VALID;
ALTER TABLE inventory_locations VALIDATE CONSTRAINT inventory_locations_company_responsible_user_fk;

ALTER TABLE inventory_operations
  DROP CONSTRAINT IF EXISTS inventory_operations_company_actor_fk;
ALTER TABLE inventory_operations
  ADD CONSTRAINT inventory_operations_company_actor_fk
  FOREIGN KEY (company_id, initiating_actor)
  REFERENCES company_memberships(company_id, profile_id)
  NOT VALID;
ALTER TABLE inventory_operations VALIDATE CONSTRAINT inventory_operations_company_actor_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_company_product_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_company_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_company_product_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_company_source_location_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_company_source_location_fk
  FOREIGN KEY (company_id, source_location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_company_source_location_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_company_destination_location_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_company_destination_location_fk
  FOREIGN KEY (company_id, destination_location_id)
  REFERENCES inventory_locations(company_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_company_destination_location_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_company_performed_by_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_company_performed_by_fk
  FOREIGN KEY (company_id, performed_by)
  REFERENCES company_memberships(company_id, profile_id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_company_performed_by_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_company_approved_by_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_company_approved_by_fk
  FOREIGN KEY (company_id, approved_by)
  REFERENCES company_memberships(company_id, profile_id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_company_approved_by_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_company_product_unit_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_company_product_unit_fk
  FOREIGN KEY (company_id, product_id, entered_unit_id)
  REFERENCES product_units(company_id, product_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_company_product_unit_fk;

-- Existing history is preserved, but every new balance-changing operation and
-- movement must have an actor. NOT VALID avoids destroying/mutating any legacy
-- unattributed rows while still enforcing the constraint for new writes.
ALTER TABLE inventory_operations
  DROP CONSTRAINT IF EXISTS inventory_operations_actor_required;
ALTER TABLE inventory_operations
  ADD CONSTRAINT inventory_operations_actor_required
  CHECK (initiating_actor IS NOT NULL) NOT VALID;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_actor_required;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_actor_required
  CHECK (performed_by IS NOT NULL) NOT VALID;

-- ---------------------------------------------------------------------------
-- 3. Auth-derived helper functions used by RLS and RPC authorization.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_profile_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  SELECT p.id
  FROM public.profiles p
  WHERE p.auth_user_id = auth.uid()
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION is_company_member(p_company_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.company_memberships cm
    JOIN public.profiles p ON p.id = cm.profile_id
    WHERE p.auth_user_id = auth.uid()
      AND cm.company_id = p_company_id
      AND cm.status = 'ACTIVE'
  )
$$;

CREATE OR REPLACE FUNCTION has_warehouse_permission(
  p_location_id UUID,
  p_permission TEXT DEFAULT 'inventory.read'
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.warehouse_memberships wm
    JOIN public.company_memberships cm
      ON cm.company_id = wm.company_id
     AND cm.profile_id = wm.profile_id
    JOIN public.profiles p ON p.id = wm.profile_id
    JOIN public.inventory_locations l
      ON l.id = wm.location_id
     AND l.company_id = wm.company_id
    WHERE p.auth_user_id = auth.uid()
      AND wm.location_id = p_location_id
      AND wm.status = 'ACTIVE'
      AND cm.status = 'ACTIVE'
      AND l.is_active = true
      AND CASE p_permission
        WHEN 'inventory.read' THEN wm.can_read_inventory
        WHEN 'inventory.receive' THEN wm.can_receive
        WHEN 'inventory.dispatch' THEN wm.can_dispatch
        WHEN 'inventory.count' THEN wm.can_count
        WHEN 'inventory.count.approve' THEN wm.can_approve_counts
        WHEN 'inventory.adjust' THEN wm.can_adjust
        WHEN 'inventory.reverse' THEN wm.can_reverse
        ELSE false
      END
  )
$$;

CREATE OR REPLACE FUNCTION get_my_operational_context()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_profile_id UUID;
  v_context JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object(
      'profile', NULL,
      'companies', '[]'::jsonb,
      'warehouses', '[]'::jsonb
    );
  END IF;

  v_profile_id := public.current_profile_id();

  IF v_profile_id IS NULL THEN
    RETURN jsonb_build_object(
      'profile', NULL,
      'companies', '[]'::jsonb,
      'warehouses', '[]'::jsonb
    );
  END IF;

  SELECT jsonb_build_object(
    'profile', jsonb_build_object(
      'id', p.id,
      'auth_user_id', p.auth_user_id,
      'full_name', p.full_name
    ),
    'companies', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', c.id,
          'name', c.name,
          'role', cm.role
        ) ORDER BY c.name
      )
      FROM public.company_memberships cm
      JOIN public.companies c ON c.id = cm.company_id
      WHERE cm.profile_id = v_profile_id
        AND cm.status = 'ACTIVE'
    ), '[]'::jsonb),
    'warehouses', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', l.id,
          'company_id', l.company_id,
          'name', l.name,
          'code', l.code,
          'location_type', l.location_type,
          'is_active', l.is_active,
          'allow_direct_sales', l.allow_direct_sales,
          'permissions', jsonb_build_object(
            'inventory.read', wm.can_read_inventory,
            'inventory.receive', wm.can_receive,
            'inventory.dispatch', wm.can_dispatch,
            'inventory.count', wm.can_count,
            'inventory.count.approve', wm.can_approve_counts,
            'inventory.adjust', wm.can_adjust,
            'inventory.reverse', wm.can_reverse
          )
        ) ORDER BY l.name
      )
      FROM public.warehouse_memberships wm
      JOIN public.company_memberships cm
        ON cm.company_id = wm.company_id
       AND cm.profile_id = wm.profile_id
      JOIN public.inventory_locations l
        ON l.id = wm.location_id
       AND l.company_id = wm.company_id
      WHERE wm.profile_id = v_profile_id
        AND wm.status = 'ACTIVE'
        AND cm.status = 'ACTIVE'
        AND l.is_active = true
    ), '[]'::jsonb)
  )
  INTO v_context
  FROM public.profiles p
  WHERE p.id = v_profile_id;

  RETURN v_context;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Enable RLS and make application table access read-only by default.
-- ---------------------------------------------------------------------------
ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE company_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS companies_select_member ON companies;
CREATE POLICY companies_select_member ON companies
FOR SELECT TO authenticated
USING (public.is_company_member(id));

DROP POLICY IF EXISTS profiles_select_self ON profiles;
CREATE POLICY profiles_select_self ON profiles
FOR SELECT TO authenticated
USING (auth_user_id = auth.uid());

DROP POLICY IF EXISTS company_memberships_select_self ON company_memberships;
CREATE POLICY company_memberships_select_self ON company_memberships
FOR SELECT TO authenticated
USING (profile_id = public.current_profile_id());

DROP POLICY IF EXISTS warehouse_memberships_select_self ON warehouse_memberships;
CREATE POLICY warehouse_memberships_select_self ON warehouse_memberships
FOR SELECT TO authenticated
USING (profile_id = public.current_profile_id());

DROP POLICY IF EXISTS products_select_company_member ON products;
CREATE POLICY products_select_company_member ON products
FOR SELECT TO authenticated
USING (public.is_company_member(company_id));

DROP POLICY IF EXISTS product_units_select_company_member ON product_units;
CREATE POLICY product_units_select_company_member ON product_units
FOR SELECT TO authenticated
USING (public.is_company_member(company_id));

DROP POLICY IF EXISTS inventory_locations_select_authorized ON inventory_locations;
CREATE POLICY inventory_locations_select_authorized ON inventory_locations
FOR SELECT TO authenticated
USING (public.has_warehouse_permission(id, 'inventory.read'));

DROP POLICY IF EXISTS inventory_balances_select_authorized ON inventory_balances;
CREATE POLICY inventory_balances_select_authorized ON inventory_balances
FOR SELECT TO authenticated
USING (public.has_warehouse_permission(location_id, 'inventory.read'));

DROP POLICY IF EXISTS inventory_operations_select_own ON inventory_operations;
CREATE POLICY inventory_operations_select_own ON inventory_operations
FOR SELECT TO authenticated
USING (
  public.is_company_member(company_id)
  AND initiating_actor = public.current_profile_id()
);

DROP POLICY IF EXISTS inventory_movements_select_authorized ON inventory_movements;
CREATE POLICY inventory_movements_select_authorized ON inventory_movements
FOR SELECT TO authenticated
USING (
  public.is_company_member(company_id)
  AND (
    (source_location_id IS NOT NULL AND public.has_warehouse_permission(source_location_id, 'inventory.read'))
    OR
    (destination_location_id IS NOT NULL AND public.has_warehouse_permission(destination_location_id, 'inventory.read'))
  )
);

-- Supabase commonly grants broad privileges to authenticated/anon on public
-- tables. Explicitly reduce these inventory tables to SELECT-only for the app.
REVOKE ALL PRIVILEGES ON TABLE
  companies,
  profiles,
  company_memberships,
  warehouse_memberships,
  products,
  product_units,
  inventory_locations,
  inventory_balances,
  inventory_operations,
  inventory_movements
FROM anon, authenticated;

GRANT SELECT ON TABLE
  companies,
  profiles,
  company_memberships,
  warehouse_memberships,
  products,
  product_units,
  inventory_locations,
  inventory_balances,
  inventory_operations,
  inventory_movements
TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Restrict the low-level mutation primitive and authorize the JSON wrapper.
-- ---------------------------------------------------------------------------
ALTER FUNCTION public.post_inventory_operation(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, movement_type, UUID, UUID,
  inventory_status, inventory_status, NUMERIC, NUMERIC, TEXT, UUID, TEXT
) SECURITY DEFINER;

ALTER FUNCTION public.post_inventory_operation(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, movement_type, UUID, UUID,
  inventory_status, inventory_status, NUMERIC, NUMERIC, TEXT, UUID, TEXT
) SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION public.post_inventory_operation(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, movement_type, UUID, UUID,
  inventory_status, inventory_status, NUMERIC, NUMERIC, TEXT, UUID, TEXT
) FROM PUBLIC, anon, authenticated;

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
  v_dest_loc UUID;
  v_op_type TEXT;
  v_qty NUMERIC;
  v_product UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  v_actor := public.current_profile_id();
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authenticated user is not provisioned for FieldOne' USING ERRCODE = '42501';
  END IF;

  v_op_type := p_operation->>'operation_type';
  IF v_op_type NOT IN ('RECEIPT', 'DISPATCH', 'COUNT', 'ADJUSTMENT') THEN
    RAISE EXCEPTION 'Unsupported operation type: %', COALESCE(v_op_type, '<null>') USING ERRCODE = '22023';
  END IF;

  IF NULLIF(p_operation->>'location_id', '') IS NULL THEN
    RAISE EXCEPTION 'location_id is required' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(p_operation->>'product_id', '') IS NULL THEN
    RAISE EXCEPTION 'product_id is required' USING ERRCODE = '22023';
  END IF;

  v_location := (p_operation->>'location_id')::UUID;
  v_product := (p_operation->>'product_id')::UUID;
  v_qty := COALESCE((p_operation->>'qty')::NUMERIC, 0);

  SELECT l.company_id, l.is_active, l.allow_direct_sales
  INTO v_company, v_location_active, v_allow_direct_sales
  FROM public.inventory_locations l
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.products p
    WHERE p.id = v_product
      AND p.company_id = v_company
  ) THEN
    RAISE EXCEPTION 'Product is not part of the authorized company' USING ERRCODE = '42501';
  END IF;

  IF v_op_type = 'RECEIPT' THEN
    v_permission := 'inventory.receive';
    v_movement_type := 'TRANSFER_IN';
    v_source_loc := NULL;
    v_dest_loc := v_location;
  ELSIF v_op_type = 'DISPATCH' THEN
    v_permission := 'inventory.dispatch';
    IF NOT v_allow_direct_sales THEN
      RAISE EXCEPTION 'Direct sales are not allowed from this location' USING ERRCODE = '42501';
    END IF;
    v_movement_type := 'TRANSFER_OUT';
    v_source_loc := v_location;
    v_dest_loc := NULL;
  ELSIF v_op_type = 'COUNT' THEN
    v_permission := 'inventory.count';
    v_movement_type := 'STOCK_ADJUSTMENT_IN';
    v_source_loc := NULL;
    v_dest_loc := v_location;
  ELSE
    v_permission := 'inventory.adjust';
    v_movement_type := 'STOCK_ADJUSTMENT_IN';
    v_source_loc := NULL;
    v_dest_loc := v_location;
  END IF;

  IF NOT public.has_warehouse_permission(v_location, v_permission) THEN
    RAISE EXCEPTION 'Warehouse permission % required', v_permission USING ERRCODE = '42501';
  END IF;

  RETURN public.post_inventory_operation(
    v_company,
    v_op_type,
    p_operation->>'client_transaction_id',
    COALESCE(p_operation->>'request_fingerprint', md5(p_operation::text)),
    v_actor,
    v_product,
    v_movement_type,
    v_source_loc,
    v_dest_loc,
    'AVAILABLE'::inventory_status,
    'AVAILABLE'::inventory_status,
    v_qty,
    v_qty,
    'DOCUMENT',
    NULL,
    p_operation->>'reference'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.post_inventory_operation(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_inventory_operation(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION public.current_profile_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_company_member(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.has_warehouse_permission(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_operational_context() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_profile_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_company_member(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_warehouse_permission(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_operational_context() TO authenticated;

COMMENT ON FUNCTION public.post_inventory_operation(JSONB) IS
  'Phase 1 authorized wrapper. Actor/company are derived server-side from auth.uid() and the authorized location; client user_id/company_id are ignored.';
