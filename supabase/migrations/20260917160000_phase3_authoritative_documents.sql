-- Phase 3: authoritative warehouse documents and line lifecycle.
-- This migration records business intent/outcomes but deliberately does not mutate stock.
-- Phase 4 document commands will consume these stable documents/lines atomically.

-- ---------------------------------------------------------------------------
-- 1. Document lifecycle types.
-- ---------------------------------------------------------------------------
CREATE TYPE warehouse_document_status AS ENUM (
  'ASSIGNED', 'IN_PROGRESS', 'READY_TO_POST', 'PARTIAL', 'COMPLETED', 'CANCELLED'
);

CREATE TYPE warehouse_document_line_status AS ENUM (
  'OPEN', 'CAPTURED', 'EXCEPTION', 'READY_TO_POST', 'POSTED', 'BACKORDERED', 'CANCELLED'
);

CREATE TYPE count_session_status AS ENUM (
  'ASSIGNED', 'IN_PROGRESS', 'PENDING_APPROVAL', 'READY_TO_POST', 'COMPLETED', 'CANCELLED'
);

CREATE TYPE count_line_status AS ENUM (
  'OPEN', 'OBSERVED', 'PENDING_APPROVAL', 'APPROVED', 'REJECTED', 'RECOUNT_REQUIRED', 'READY_TO_POST', 'FINALIZED', 'CANCELLED'
);

CREATE TYPE count_approval_decision AS ENUM ('APPROVED', 'REJECTED', 'RECOUNT');
CREATE TYPE backorder_status AS ENUM ('OPEN', 'FULFILLED', 'CANCELLED');

-- ---------------------------------------------------------------------------
-- 2. Transfers / receiving documents.
-- ---------------------------------------------------------------------------
CREATE TABLE inventory_transfer_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  reference_number TEXT NOT NULL,
  source_location_id UUID NOT NULL,
  destination_location_id UUID NOT NULL,
  assigned_profile_id UUID,
  status warehouse_document_status NOT NULL DEFAULT 'ASSIGNED',
  revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
  due_at TIMESTAMPTZ,
  notes TEXT,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_transfer_reference_not_blank CHECK (btrim(reference_number) <> ''),
  CONSTRAINT inventory_transfer_locations_differ CHECK (source_location_id <> destination_location_id),
  UNIQUE (company_id, reference_number),
  UNIQUE (company_id, id),
  UNIQUE (company_id, id, source_location_id, destination_location_id)
);

ALTER TABLE inventory_transfer_documents
  ADD CONSTRAINT inventory_transfer_source_location_fk
  FOREIGN KEY (company_id, source_location_id)
  REFERENCES inventory_locations(company_id, id);
ALTER TABLE inventory_transfer_documents
  ADD CONSTRAINT inventory_transfer_destination_location_fk
  FOREIGN KEY (company_id, destination_location_id)
  REFERENCES inventory_locations(company_id, id);
ALTER TABLE inventory_transfer_documents
  ADD CONSTRAINT inventory_transfer_assignee_fk
  FOREIGN KEY (company_id, assigned_profile_id)
  REFERENCES company_memberships(company_id, profile_id);
ALTER TABLE inventory_transfer_documents
  ADD CONSTRAINT inventory_transfer_created_by_fk
  FOREIGN KEY (company_id, created_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE TABLE inventory_transfer_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  transfer_id UUID NOT NULL,
  source_location_id UUID NOT NULL,
  destination_location_id UUID NOT NULL,
  line_number INTEGER NOT NULL CHECK (line_number > 0),
  product_id UUID NOT NULL,
  entered_unit_id UUID NOT NULL,
  source_bin_id UUID NOT NULL,
  destination_bin_id UUID NOT NULL,
  expected_entered_quantity NUMERIC(28, 6) NOT NULL CHECK (expected_entered_quantity > 0),
  expected_base_quantity NUMERIC(28, 6) NOT NULL CHECK (expected_base_quantity > 0),
  captured_received_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (captured_received_base_quantity >= 0),
  posted_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (posted_base_quantity >= 0),
  remaining_expected_base_quantity NUMERIC(28, 6)
    GENERATED ALWAYS AS (GREATEST(expected_base_quantity - posted_base_quantity, 0)) STORED,
  line_status warehouse_document_line_status NOT NULL DEFAULT 'OPEN',
  exception_code TEXT,
  exception_notes TEXT,
  captured_by UUID,
  client_recorded_at TIMESTAMPTZ,
  captured_at TIMESTAMPTZ,
  revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_transfer_line_posted_within_capture CHECK (posted_base_quantity <= captured_received_base_quantity),
  CONSTRAINT inventory_transfer_line_exception_reason CHECK (line_status <> 'EXCEPTION' OR (exception_code IS NOT NULL AND btrim(exception_code) <> '')),
  UNIQUE (company_id, transfer_id, line_number),
  UNIQUE (company_id, id),
  UNIQUE (company_id, id, source_location_id, destination_location_id, product_id)
);

ALTER TABLE inventory_transfer_lines
  ADD CONSTRAINT inventory_transfer_line_parent_fk
  FOREIGN KEY (company_id, transfer_id, source_location_id, destination_location_id)
  REFERENCES inventory_transfer_documents(company_id, id, source_location_id, destination_location_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_transfer_lines
  ADD CONSTRAINT inventory_transfer_line_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id);
ALTER TABLE inventory_transfer_lines
  ADD CONSTRAINT inventory_transfer_line_unit_fk
  FOREIGN KEY (company_id, product_id, entered_unit_id)
  REFERENCES product_units(company_id, product_id, id);
ALTER TABLE inventory_transfer_lines
  ADD CONSTRAINT inventory_transfer_line_source_bin_fk
  FOREIGN KEY (company_id, source_location_id, source_bin_id)
  REFERENCES inventory_bins(company_id, location_id, id);
ALTER TABLE inventory_transfer_lines
  ADD CONSTRAINT inventory_transfer_line_destination_bin_fk
  FOREIGN KEY (company_id, destination_location_id, destination_bin_id)
  REFERENCES inventory_bins(company_id, location_id, id);
ALTER TABLE inventory_transfer_lines
  ADD CONSTRAINT inventory_transfer_line_captured_by_fk
  FOREIGN KEY (company_id, captured_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE INDEX inventory_transfer_work_idx
  ON inventory_transfer_documents (company_id, destination_location_id, status, due_at);
CREATE INDEX inventory_transfer_line_lookup_idx
  ON inventory_transfer_lines (company_id, transfer_id, line_status, line_number);

-- ---------------------------------------------------------------------------
-- 3. Sales orders / dispatch documents and backorders.
-- ---------------------------------------------------------------------------
CREATE TABLE inventory_sales_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  reference_number TEXT NOT NULL,
  source_location_id UUID NOT NULL,
  destination_location_id UUID,
  destination_name TEXT NOT NULL,
  customer_name TEXT NOT NULL,
  assigned_profile_id UUID,
  priority TEXT NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('NORMAL', 'HIGH')),
  status warehouse_document_status NOT NULL DEFAULT 'ASSIGNED',
  revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
  due_at TIMESTAMPTZ,
  notes TEXT,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_sales_order_reference_not_blank CHECK (btrim(reference_number) <> ''),
  CONSTRAINT inventory_sales_order_destination_name_not_blank CHECK (btrim(destination_name) <> ''),
  CONSTRAINT inventory_sales_order_customer_not_blank CHECK (btrim(customer_name) <> ''),
  CONSTRAINT inventory_sales_order_destination_differs CHECK (destination_location_id IS NULL OR destination_location_id <> source_location_id),
  UNIQUE (company_id, reference_number),
  UNIQUE (company_id, id),
  UNIQUE (company_id, id, source_location_id)
);

ALTER TABLE inventory_sales_orders
  ADD CONSTRAINT inventory_sales_order_source_location_fk
  FOREIGN KEY (company_id, source_location_id)
  REFERENCES inventory_locations(company_id, id);
ALTER TABLE inventory_sales_orders
  ADD CONSTRAINT inventory_sales_order_destination_location_fk
  FOREIGN KEY (company_id, destination_location_id)
  REFERENCES inventory_locations(company_id, id);
ALTER TABLE inventory_sales_orders
  ADD CONSTRAINT inventory_sales_order_assignee_fk
  FOREIGN KEY (company_id, assigned_profile_id)
  REFERENCES company_memberships(company_id, profile_id);
ALTER TABLE inventory_sales_orders
  ADD CONSTRAINT inventory_sales_order_created_by_fk
  FOREIGN KEY (company_id, created_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE TABLE inventory_sales_order_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  sales_order_id UUID NOT NULL,
  source_location_id UUID NOT NULL,
  line_number INTEGER NOT NULL CHECK (line_number > 0),
  product_id UUID NOT NULL,
  entered_unit_id UUID NOT NULL,
  source_bin_id UUID NOT NULL,
  requested_entered_quantity NUMERIC(28, 6) NOT NULL CHECK (requested_entered_quantity > 0),
  requested_base_quantity NUMERIC(28, 6) NOT NULL CHECK (requested_base_quantity > 0),
  captured_picked_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (captured_picked_base_quantity >= 0),
  posted_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (posted_base_quantity >= 0),
  backordered_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (backordered_base_quantity >= 0),
  remaining_base_quantity NUMERIC(28, 6)
    GENERATED ALWAYS AS (GREATEST(requested_base_quantity - posted_base_quantity - backordered_base_quantity, 0)) STORED,
  line_status warehouse_document_line_status NOT NULL DEFAULT 'OPEN',
  exception_code TEXT,
  exception_notes TEXT,
  captured_by UUID,
  client_recorded_at TIMESTAMPTZ,
  captured_at TIMESTAMPTZ,
  revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_sales_order_capture_within_requested CHECK (captured_picked_base_quantity <= requested_base_quantity),
  CONSTRAINT inventory_sales_order_posted_within_capture CHECK (posted_base_quantity <= captured_picked_base_quantity),
  CONSTRAINT inventory_sales_order_progress_within_requested CHECK (posted_base_quantity + backordered_base_quantity <= requested_base_quantity),
  CONSTRAINT inventory_sales_order_capture_plus_backorder_within_requested CHECK (captured_picked_base_quantity + backordered_base_quantity <= requested_base_quantity),
  CONSTRAINT inventory_sales_order_line_exception_reason CHECK (line_status <> 'EXCEPTION' OR (exception_code IS NOT NULL AND btrim(exception_code) <> '')),
  UNIQUE (company_id, sales_order_id, line_number),
  UNIQUE (company_id, id),
  UNIQUE (company_id, sales_order_id, id, source_location_id, product_id),
  UNIQUE (company_id, id, source_location_id, product_id)
);

ALTER TABLE inventory_sales_order_lines
  ADD CONSTRAINT inventory_sales_order_line_parent_fk
  FOREIGN KEY (company_id, sales_order_id, source_location_id)
  REFERENCES inventory_sales_orders(company_id, id, source_location_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_sales_order_lines
  ADD CONSTRAINT inventory_sales_order_line_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id);
ALTER TABLE inventory_sales_order_lines
  ADD CONSTRAINT inventory_sales_order_line_unit_fk
  FOREIGN KEY (company_id, product_id, entered_unit_id)
  REFERENCES product_units(company_id, product_id, id);
ALTER TABLE inventory_sales_order_lines
  ADD CONSTRAINT inventory_sales_order_line_source_bin_fk
  FOREIGN KEY (company_id, source_location_id, source_bin_id)
  REFERENCES inventory_bins(company_id, location_id, id);
ALTER TABLE inventory_sales_order_lines
  ADD CONSTRAINT inventory_sales_order_line_captured_by_fk
  FOREIGN KEY (company_id, captured_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE TABLE inventory_backorders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  sales_order_id UUID NOT NULL,
  sales_order_line_id UUID NOT NULL,
  source_location_id UUID NOT NULL,
  product_id UUID NOT NULL,
  base_quantity NUMERIC(28, 6) NOT NULL CHECK (base_quantity > 0),
  status backorder_status NOT NULL DEFAULT 'OPEN',
  reason_code TEXT NOT NULL,
  reason_text TEXT,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  fulfilled_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  CONSTRAINT inventory_backorder_reason_not_blank CHECK (btrim(reason_code) <> ''),
  UNIQUE (company_id, id)
);

ALTER TABLE inventory_backorders
  ADD CONSTRAINT inventory_backorder_order_fk
  FOREIGN KEY (company_id, sales_order_id, source_location_id)
  REFERENCES inventory_sales_orders(company_id, id, source_location_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_backorders
  ADD CONSTRAINT inventory_backorder_line_fk
  FOREIGN KEY (company_id, sales_order_id, sales_order_line_id, source_location_id, product_id)
  REFERENCES inventory_sales_order_lines(company_id, sales_order_id, id, source_location_id, product_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_backorders
  ADD CONSTRAINT inventory_backorder_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id);
ALTER TABLE inventory_backorders
  ADD CONSTRAINT inventory_backorder_created_by_fk
  FOREIGN KEY (company_id, created_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE UNIQUE INDEX inventory_backorder_one_open_per_line_idx
  ON inventory_backorders (company_id, sales_order_line_id)
  WHERE status = 'OPEN';
CREATE INDEX inventory_sales_order_work_idx
  ON inventory_sales_orders (company_id, source_location_id, status, due_at);
CREATE INDEX inventory_sales_order_line_lookup_idx
  ON inventory_sales_order_lines (company_id, sales_order_id, line_status, line_number);

-- ---------------------------------------------------------------------------
-- 4. Cycle-count sessions, immutable observations, and approval decisions.
-- ---------------------------------------------------------------------------
CREATE TABLE inventory_count_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  reference_number TEXT NOT NULL,
  location_id UUID NOT NULL,
  zone TEXT NOT NULL,
  policy TEXT NOT NULL DEFAULT 'BLIND_COUNT',
  assigned_profile_id UUID,
  status count_session_status NOT NULL DEFAULT 'ASSIGNED',
  revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
  due_at TIMESTAMPTZ,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT inventory_count_reference_not_blank CHECK (btrim(reference_number) <> ''),
  CONSTRAINT inventory_count_zone_not_blank CHECK (btrim(zone) <> ''),
  UNIQUE (company_id, reference_number),
  UNIQUE (company_id, id),
  UNIQUE (company_id, id, location_id)
);

ALTER TABLE inventory_count_sessions
  ADD CONSTRAINT inventory_count_location_fk
  FOREIGN KEY (company_id, location_id)
  REFERENCES inventory_locations(company_id, id);
ALTER TABLE inventory_count_sessions
  ADD CONSTRAINT inventory_count_assignee_fk
  FOREIGN KEY (company_id, assigned_profile_id)
  REFERENCES company_memberships(company_id, profile_id);
ALTER TABLE inventory_count_sessions
  ADD CONSTRAINT inventory_count_created_by_fk
  FOREIGN KEY (company_id, created_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE TABLE inventory_count_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  count_session_id UUID NOT NULL,
  location_id UUID NOT NULL,
  line_number INTEGER NOT NULL CHECK (line_number > 0),
  product_id UUID NOT NULL,
  bin_id UUID NOT NULL,
  base_unit_id UUID NOT NULL,
  expected_snapshot_base_quantity NUMERIC(28, 6) NOT NULL,
  expected_physical_revision BIGINT NOT NULL CHECK (expected_physical_revision > 0),
  posted_variance_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0,
  line_status count_line_status NOT NULL DEFAULT 'OPEN',
  revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, count_session_id, line_number),
  UNIQUE (company_id, id),
  UNIQUE (company_id, id, product_id),
  UNIQUE (company_id, id, count_session_id, location_id, product_id)
);

ALTER TABLE inventory_count_lines
  ADD CONSTRAINT inventory_count_line_parent_fk
  FOREIGN KEY (company_id, count_session_id, location_id)
  REFERENCES inventory_count_sessions(company_id, id, location_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_count_lines
  ADD CONSTRAINT inventory_count_line_product_fk
  FOREIGN KEY (company_id, product_id)
  REFERENCES products(company_id, id);
ALTER TABLE inventory_count_lines
  ADD CONSTRAINT inventory_count_line_bin_fk
  FOREIGN KEY (company_id, location_id, bin_id)
  REFERENCES inventory_bins(company_id, location_id, id);
ALTER TABLE inventory_count_lines
  ADD CONSTRAINT inventory_count_line_unit_fk
  FOREIGN KEY (company_id, product_id, base_unit_id)
  REFERENCES product_units(company_id, product_id, id);

CREATE TABLE inventory_count_observations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  count_session_id UUID NOT NULL,
  count_line_id UUID NOT NULL,
  location_id UUID NOT NULL,
  product_id UUID NOT NULL,
  attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
  entered_unit_id UUID NOT NULL,
  observed_entered_quantity NUMERIC(28, 6) NOT NULL CHECK (observed_entered_quantity >= 0),
  observed_base_quantity NUMERIC(28, 6) NOT NULL CHECK (observed_base_quantity >= 0),
  expected_snapshot_base_quantity NUMERIC(28, 6) NOT NULL,
  expected_physical_revision BIGINT NOT NULL CHECK (expected_physical_revision > 0),
  variance_base_quantity NUMERIC(28, 6)
    GENERATED ALWAYS AS (observed_base_quantity - expected_snapshot_base_quantity) STORED,
  reason_code TEXT,
  notes TEXT,
  observed_by UUID NOT NULL,
  client_recorded_at TIMESTAMPTZ NOT NULL,
  observed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, count_line_id, attempt_number),
  UNIQUE (company_id, id),
  UNIQUE (company_id, id, count_session_id, count_line_id, location_id)
);

ALTER TABLE inventory_count_observations
  ADD CONSTRAINT inventory_count_observation_session_fk
  FOREIGN KEY (company_id, count_session_id, location_id)
  REFERENCES inventory_count_sessions(company_id, id, location_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_count_observations
  ADD CONSTRAINT inventory_count_observation_line_fk
  FOREIGN KEY (company_id, count_line_id, count_session_id, location_id, product_id)
  REFERENCES inventory_count_lines(company_id, id, count_session_id, location_id, product_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_count_observations
  ADD CONSTRAINT inventory_count_observation_unit_fk
  FOREIGN KEY (company_id, product_id, entered_unit_id)
  REFERENCES product_units(company_id, product_id, id);
ALTER TABLE inventory_count_observations
  ADD CONSTRAINT inventory_count_observation_actor_fk
  FOREIGN KEY (company_id, observed_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE TABLE inventory_count_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  count_session_id UUID NOT NULL,
  count_line_id UUID NOT NULL,
  observation_id UUID NOT NULL,
  location_id UUID NOT NULL,
  decision count_approval_decision NOT NULL,
  decision_reason TEXT,
  decided_by UUID NOT NULL,
  decided_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, observation_id),
  UNIQUE (company_id, id)
);

ALTER TABLE inventory_count_approvals
  ADD CONSTRAINT inventory_count_approval_session_fk
  FOREIGN KEY (company_id, count_session_id, location_id)
  REFERENCES inventory_count_sessions(company_id, id, location_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_count_approvals
  ADD CONSTRAINT inventory_count_approval_line_fk
  FOREIGN KEY (company_id, count_line_id)
  REFERENCES inventory_count_lines(company_id, id)
  ON DELETE CASCADE;
ALTER TABLE inventory_count_approvals
  ADD CONSTRAINT inventory_count_approval_observation_fk
  FOREIGN KEY (company_id, observation_id, count_session_id, count_line_id, location_id)
  REFERENCES inventory_count_observations(company_id, id, count_session_id, count_line_id, location_id)
  ON DELETE CASCADE;
ALTER TABLE inventory_count_approvals
  ADD CONSTRAINT inventory_count_approval_actor_fk
  FOREIGN KEY (company_id, decided_by)
  REFERENCES company_memberships(company_id, profile_id);

CREATE INDEX inventory_count_work_idx
  ON inventory_count_sessions (company_id, location_id, status, due_at);
CREATE INDEX inventory_count_line_lookup_idx
  ON inventory_count_lines (company_id, count_session_id, line_status, line_number);
CREATE INDEX inventory_count_observation_lookup_idx
  ON inventory_count_observations (company_id, count_line_id, attempt_number DESC);

-- ---------------------------------------------------------------------------
-- 5. Attach Phase 2 reservation/transit provenance to authoritative lines.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_reservations
  ADD COLUMN IF NOT EXISTS sales_order_line_id UUID;
ALTER TABLE inventory_reservations
  ADD CONSTRAINT inventory_reservations_sales_order_line_fk
  FOREIGN KEY (company_id, sales_order_line_id, location_id, product_id)
  REFERENCES inventory_sales_order_lines(company_id, id, source_location_id, product_id)
  NOT VALID;

ALTER TABLE inventory_transit_lots
  ADD COLUMN IF NOT EXISTS transfer_line_id UUID;
ALTER TABLE inventory_transit_lots
  ADD CONSTRAINT inventory_transit_transfer_line_fk
  FOREIGN KEY (company_id, transfer_line_id, source_location_id, destination_location_id, product_id)
  REFERENCES inventory_transfer_lines(company_id, id, source_location_id, destination_location_id, product_id)
  NOT VALID;

-- Durable document links for Phase 4 operations/movements. Historical rows remain NULL.
ALTER TABLE inventory_operations
  ADD COLUMN IF NOT EXISTS source_document_line_id UUID;

ALTER TABLE inventory_movements
  ADD COLUMN IF NOT EXISTS transfer_line_id UUID,
  ADD COLUMN IF NOT EXISTS sales_order_line_id UUID,
  ADD COLUMN IF NOT EXISTS count_line_id UUID;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_transfer_line_fk
  FOREIGN KEY (company_id, transfer_line_id)
  REFERENCES inventory_transfer_lines(company_id, id)
  NOT VALID;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_sales_order_line_fk
  FOREIGN KEY (company_id, sales_order_line_id)
  REFERENCES inventory_sales_order_lines(company_id, id)
  NOT VALID;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_count_line_fk
  FOREIGN KEY (company_id, count_line_id)
  REFERENCES inventory_count_lines(company_id, id)
  NOT VALID;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_one_authoritative_line CHECK (
    num_nonnulls(transfer_line_id, sales_order_line_id, count_line_id) <= 1
  ) NOT VALID;

-- ---------------------------------------------------------------------------
-- 6. Internal lifecycle recalculation helpers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recalculate_transfer_document_status(p_transfer_id UUID)
RETURNS warehouse_document_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status warehouse_document_status;
BEGIN
  SELECT CASE
    WHEN bool_and(l.line_status = 'POSTED') THEN 'COMPLETED'::warehouse_document_status
    WHEN bool_or(l.line_status IN ('OPEN', 'CAPTURED')) THEN 'IN_PROGRESS'::warehouse_document_status
    WHEN bool_or(l.line_status = 'POSTED') THEN 'PARTIAL'::warehouse_document_status
    ELSE 'READY_TO_POST'::warehouse_document_status
  END
  INTO v_status
  FROM inventory_transfer_lines l
  WHERE l.transfer_id = p_transfer_id;

  v_status := COALESCE(v_status, 'ASSIGNED'::warehouse_document_status);
  UPDATE inventory_transfer_documents
  SET status = v_status, updated_at = now()
  WHERE id = p_transfer_id AND status <> 'CANCELLED';
  RETURN v_status;
END;
$$;

CREATE OR REPLACE FUNCTION recalculate_sales_order_status(p_sales_order_id UUID)
RETURNS warehouse_document_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status warehouse_document_status;
BEGIN
  SELECT CASE
    WHEN bool_and(l.line_status IN ('POSTED', 'BACKORDERED', 'CANCELLED')) THEN
      CASE WHEN bool_or(l.line_status = 'BACKORDERED') THEN 'PARTIAL'::warehouse_document_status ELSE 'COMPLETED'::warehouse_document_status END
    WHEN bool_or(l.line_status IN ('OPEN', 'CAPTURED')) THEN 'IN_PROGRESS'::warehouse_document_status
    WHEN bool_or(l.line_status = 'POSTED') THEN 'PARTIAL'::warehouse_document_status
    ELSE 'READY_TO_POST'::warehouse_document_status
  END
  INTO v_status
  FROM inventory_sales_order_lines l
  WHERE l.sales_order_id = p_sales_order_id;

  v_status := COALESCE(v_status, 'ASSIGNED'::warehouse_document_status);
  UPDATE inventory_sales_orders
  SET status = v_status, updated_at = now()
  WHERE id = p_sales_order_id AND status <> 'CANCELLED';
  RETURN v_status;
END;
$$;

CREATE OR REPLACE FUNCTION recalculate_count_session_status(p_count_session_id UUID)
RETURNS count_session_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status count_session_status;
BEGIN
  SELECT CASE
    WHEN bool_and(l.line_status = 'FINALIZED') THEN 'COMPLETED'::count_session_status
    WHEN bool_or(l.line_status = 'PENDING_APPROVAL') THEN 'PENDING_APPROVAL'::count_session_status
    WHEN bool_and(l.line_status IN ('READY_TO_POST', 'APPROVED')) THEN 'READY_TO_POST'::count_session_status
    WHEN bool_or(l.line_status IN ('OBSERVED', 'REJECTED', 'RECOUNT_REQUIRED', 'READY_TO_POST', 'APPROVED')) THEN 'IN_PROGRESS'::count_session_status
    ELSE 'ASSIGNED'::count_session_status
  END
  INTO v_status
  FROM inventory_count_lines l
  WHERE l.count_session_id = p_count_session_id;

  v_status := COALESCE(v_status, 'ASSIGNED'::count_session_status);
  UPDATE inventory_count_sessions
  SET status = v_status, updated_at = now()
  WHERE id = p_count_session_id AND status <> 'CANCELLED';
  RETURN v_status;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Server-authoritative capture commands. These change documents, not stock.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_transfer_receipt_line(
  p_line_id UUID,
  p_expected_document_revision BIGINT,
  p_received_entered_quantity NUMERIC,
  p_unit_id UUID,
  p_destination_bin_id UUID,
  p_exception_code TEXT DEFAULT NULL,
  p_exception_notes TEXT DEFAULT NULL,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_doc inventory_transfer_documents%ROWTYPE;
  v_line inventory_transfer_lines%ROWTYPE;
  v_base_qty NUMERIC;
  v_line_status warehouse_document_line_status;
  v_doc_status warehouse_document_status;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;
  IF p_received_entered_quantity IS NULL OR p_received_entered_quantity < 0 THEN
    RAISE EXCEPTION 'Received quantity cannot be negative' USING ERRCODE = '22023';
  END IF;

  SELECT d.* INTO v_doc
  FROM inventory_transfer_documents d
  JOIN inventory_transfer_lines l ON l.transfer_id = d.id AND l.company_id = d.company_id
  WHERE l.id = p_line_id
  FOR UPDATE OF d;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer line not found' USING ERRCODE = 'P0002'; END IF;

  SELECT * INTO v_line FROM inventory_transfer_lines WHERE id = p_line_id FOR UPDATE;
  IF v_doc.revision <> p_expected_document_revision THEN RAISE EXCEPTION 'Document revision conflict' USING ERRCODE = '40001'; END IF;
  IF v_doc.status IN ('COMPLETED', 'CANCELLED') THEN RAISE EXCEPTION 'Transfer is not editable'; END IF;
  IF v_line.line_status NOT IN ('OPEN') THEN RAISE EXCEPTION 'Transfer line is already captured and immutable' USING ERRCODE = 'P0001'; END IF;
  IF NOT public.has_warehouse_permission(v_doc.destination_location_id, 'inventory.receive') THEN RAISE EXCEPTION 'Receive permission required' USING ERRCODE = '42501'; END IF;
  IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Transfer is assigned to another user' USING ERRCODE = '42501'; END IF;
  IF p_destination_bin_id <> v_line.destination_bin_id THEN RAISE EXCEPTION 'Destination bin does not match authoritative transfer line' USING ERRCODE = '22023'; END IF;

  IF p_received_entered_quantity = 0 THEN
    v_base_qty := 0;
  ELSE
    v_base_qty := public.convert_product_quantity(v_doc.company_id, v_line.product_id, p_unit_id, p_received_entered_quantity);
  END IF;

  IF p_unit_id <> v_line.entered_unit_id THEN RAISE EXCEPTION 'Receipt unit does not match authoritative transfer line' USING ERRCODE = '22023'; END IF;
  IF v_base_qty = v_line.expected_base_quantity AND p_exception_code IS NULL THEN
    v_line_status := 'CAPTURED';
  ELSE
    IF p_exception_code IS NULL OR btrim(p_exception_code) = '' THEN
      RAISE EXCEPTION 'A structured exception reason is required when received quantity differs from expected' USING ERRCODE = '22023';
    END IF;
    v_line_status := 'EXCEPTION';
  END IF;

  UPDATE inventory_transfer_lines
  SET captured_received_base_quantity = v_base_qty,
      line_status = v_line_status,
      exception_code = NULLIF(btrim(p_exception_code), ''),
      exception_notes = p_exception_notes,
      captured_by = v_actor,
      client_recorded_at = p_client_recorded_at,
      captured_at = now(),
      revision = revision + 1,
      updated_at = now()
  WHERE id = p_line_id;

  UPDATE inventory_transfer_documents
  SET revision = revision + 1, updated_at = now()
  WHERE id = v_doc.id;
  v_doc_status := public.recalculate_transfer_document_status(v_doc.id);

  RETURN jsonb_build_object(
    'document_id', v_doc.id,
    'document_revision', v_doc.revision + 1,
    'document_status', v_doc_status,
    'line_id', p_line_id,
    'line_status', v_line_status,
    'captured_base_quantity', v_base_qty
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.record_sales_order_pick_line(
  p_line_id UUID,
  p_expected_document_revision BIGINT,
  p_picked_entered_quantity NUMERIC,
  p_unit_id UUID,
  p_source_bin_id UUID,
  p_exception_code TEXT DEFAULT NULL,
  p_exception_notes TEXT DEFAULT NULL,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_doc inventory_sales_orders%ROWTYPE;
  v_line inventory_sales_order_lines%ROWTYPE;
  v_base_qty NUMERIC;
  v_line_status warehouse_document_line_status;
  v_doc_status warehouse_document_status;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;
  IF p_picked_entered_quantity IS NULL OR p_picked_entered_quantity < 0 THEN RAISE EXCEPTION 'Picked quantity cannot be negative' USING ERRCODE = '22023'; END IF;

  SELECT d.* INTO v_doc
  FROM inventory_sales_orders d
  JOIN inventory_sales_order_lines l ON l.sales_order_id = d.id AND l.company_id = d.company_id
  WHERE l.id = p_line_id
  FOR UPDATE OF d;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sales-order line not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO v_line FROM inventory_sales_order_lines WHERE id = p_line_id FOR UPDATE;

  IF v_doc.revision <> p_expected_document_revision THEN RAISE EXCEPTION 'Document revision conflict' USING ERRCODE = '40001'; END IF;
  IF v_doc.status IN ('COMPLETED', 'CANCELLED') THEN RAISE EXCEPTION 'Sales order is not editable'; END IF;
  IF v_line.line_status NOT IN ('OPEN') THEN RAISE EXCEPTION 'Sales-order line is already captured and immutable' USING ERRCODE = 'P0001'; END IF;
  IF NOT public.has_warehouse_permission(v_doc.source_location_id, 'inventory.dispatch') THEN RAISE EXCEPTION 'Dispatch permission required' USING ERRCODE = '42501'; END IF;
  IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Sales order is assigned to another user' USING ERRCODE = '42501'; END IF;
  IF p_source_bin_id <> v_line.source_bin_id THEN RAISE EXCEPTION 'Source bin does not match authoritative sales-order line' USING ERRCODE = '22023'; END IF;

  IF p_picked_entered_quantity = 0 THEN v_base_qty := 0;
  ELSE v_base_qty := public.convert_product_quantity(v_doc.company_id, v_line.product_id, p_unit_id, p_picked_entered_quantity);
  END IF;
  IF p_unit_id <> v_line.entered_unit_id THEN RAISE EXCEPTION 'Pick unit does not match authoritative sales-order line' USING ERRCODE = '22023'; END IF;
  IF v_base_qty > v_line.requested_base_quantity THEN
    RAISE EXCEPTION 'Picked quantity exceeds authoritative requested quantity' USING ERRCODE = '22023';
  END IF;

  IF v_base_qty = v_line.requested_base_quantity AND p_exception_code IS NULL THEN v_line_status := 'CAPTURED';
  ELSE
    IF p_exception_code IS NULL OR btrim(p_exception_code) = '' THEN
      RAISE EXCEPTION 'A structured exception reason is required for a partial/zero pick' USING ERRCODE = '22023';
    END IF;
    v_line_status := 'EXCEPTION';
  END IF;

  UPDATE inventory_sales_order_lines
  SET captured_picked_base_quantity = v_base_qty,
      line_status = v_line_status,
      exception_code = NULLIF(btrim(p_exception_code), ''),
      exception_notes = p_exception_notes,
      captured_by = v_actor,
      client_recorded_at = p_client_recorded_at,
      captured_at = now(),
      revision = revision + 1,
      updated_at = now()
  WHERE id = p_line_id;

  UPDATE inventory_sales_orders SET revision = revision + 1, updated_at = now() WHERE id = v_doc.id;
  v_doc_status := public.recalculate_sales_order_status(v_doc.id);

  RETURN jsonb_build_object(
    'document_id', v_doc.id,
    'document_revision', v_doc.revision + 1,
    'document_status', v_doc_status,
    'line_id', p_line_id,
    'line_status', v_line_status,
    'captured_base_quantity', v_base_qty
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_sales_order_backorder(
  p_line_id UUID,
  p_expected_document_revision BIGINT,
  p_base_quantity NUMERIC,
  p_reason_code TEXT,
  p_reason_text TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_doc inventory_sales_orders%ROWTYPE;
  v_line inventory_sales_order_lines%ROWTYPE;
  v_existing NUMERIC;
  v_id UUID;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;
  IF p_base_quantity IS NULL OR p_base_quantity <= 0 THEN RAISE EXCEPTION 'Backorder quantity must be greater than zero' USING ERRCODE = '22023'; END IF;
  IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN RAISE EXCEPTION 'Backorder reason is required' USING ERRCODE = '22023'; END IF;

  SELECT d.* INTO v_doc
  FROM inventory_sales_orders d
  JOIN inventory_sales_order_lines l ON l.sales_order_id = d.id AND l.company_id = d.company_id
  WHERE l.id = p_line_id FOR UPDATE OF d;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sales-order line not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO v_line FROM inventory_sales_order_lines WHERE id = p_line_id FOR UPDATE;

  IF v_doc.revision <> p_expected_document_revision THEN RAISE EXCEPTION 'Document revision conflict' USING ERRCODE = '40001'; END IF;
  IF NOT public.has_warehouse_permission(v_doc.source_location_id, 'inventory.dispatch') THEN RAISE EXCEPTION 'Dispatch permission required' USING ERRCODE = '42501'; END IF;
  IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Sales order is assigned to another user' USING ERRCODE = '42501'; END IF;
  IF v_doc.status IN ('COMPLETED', 'CANCELLED') OR v_line.line_status IN ('POSTED', 'CANCELLED') THEN RAISE EXCEPTION 'Sales-order line cannot be backordered in its current state'; END IF;

  SELECT COALESCE(sum(b.base_quantity), 0) INTO v_existing
  FROM inventory_backorders b
  WHERE b.company_id = v_doc.company_id AND b.sales_order_line_id = p_line_id AND b.status = 'OPEN';

  IF v_line.captured_picked_base_quantity + v_existing + p_base_quantity > v_line.requested_base_quantity THEN
    RAISE EXCEPTION 'Backorder would exceed authoritative remaining requested quantity' USING ERRCODE = '22023';
  END IF;

  IF v_existing > 0 THEN
    UPDATE inventory_backorders
    SET base_quantity = base_quantity + p_base_quantity,
        reason_code = p_reason_code,
        reason_text = COALESCE(p_reason_text, reason_text),
        updated_at = now()
    WHERE company_id = v_doc.company_id
      AND sales_order_line_id = p_line_id
      AND status = 'OPEN'
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO inventory_backorders (
      company_id, sales_order_id, sales_order_line_id, source_location_id, product_id,
      base_quantity, reason_code, reason_text, created_by
    ) VALUES (
      v_doc.company_id, v_doc.id, v_line.id, v_doc.source_location_id, v_line.product_id,
      p_base_quantity, p_reason_code, p_reason_text, v_actor
    ) RETURNING id INTO v_id;
  END IF;

  UPDATE inventory_sales_order_lines
  SET backordered_base_quantity = backordered_base_quantity + p_base_quantity,
      line_status = CASE WHEN captured_picked_base_quantity + backordered_base_quantity + p_base_quantity >= requested_base_quantity THEN 'BACKORDERED' ELSE line_status END,
      revision = revision + 1,
      updated_at = now()
  WHERE id = p_line_id;
  UPDATE inventory_sales_orders SET revision = revision + 1, updated_at = now() WHERE id = v_doc.id;
  PERFORM public.recalculate_sales_order_status(v_doc.id);

  RETURN jsonb_build_object('backorder_id', v_id, 'document_id', v_doc.id, 'document_revision', v_doc.revision + 1);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_count_observation(
  p_count_line_id UUID,
  p_expected_session_revision BIGINT,
  p_observed_entered_quantity NUMERIC,
  p_unit_id UUID,
  p_reason_code TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_session inventory_count_sessions%ROWTYPE;
  v_line inventory_count_lines%ROWTYPE;
  v_conversion NUMERIC;
  v_scale SMALLINT;
  v_step NUMERIC;
  v_max NUMERIC;
  v_base_qty NUMERIC;
  v_variance NUMERIC;
  v_attempt INTEGER;
  v_observation_id UUID;
  v_line_status count_line_status;
  v_session_status count_session_status;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;
  IF p_observed_entered_quantity IS NULL OR p_observed_entered_quantity < 0 THEN RAISE EXCEPTION 'Count observation cannot be negative' USING ERRCODE = '22023'; END IF;

  SELECT s.* INTO v_session
  FROM inventory_count_sessions s
  JOIN inventory_count_lines l ON l.count_session_id = s.id AND l.company_id = s.company_id
  WHERE l.id = p_count_line_id FOR UPDATE OF s;
  IF NOT FOUND THEN RAISE EXCEPTION 'Count line not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO v_line FROM inventory_count_lines WHERE id = p_count_line_id FOR UPDATE;

  IF v_session.revision <> p_expected_session_revision THEN RAISE EXCEPTION 'Count session revision conflict' USING ERRCODE = '40001'; END IF;
  IF v_session.status IN ('COMPLETED', 'CANCELLED') THEN RAISE EXCEPTION 'Count session is not editable'; END IF;
  IF v_line.line_status NOT IN ('OPEN', 'RECOUNT_REQUIRED', 'REJECTED') THEN RAISE EXCEPTION 'Count line is not accepting a new observation'; END IF;
  IF NOT public.has_warehouse_permission(v_session.location_id, 'inventory.count') THEN RAISE EXCEPTION 'Count permission required' USING ERRCODE = '42501'; END IF;
  IF v_session.assigned_profile_id IS NOT NULL AND v_session.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Count session is assigned to another user' USING ERRCODE = '42501'; END IF;

  SELECT u.conversion_to_base, u.quantity_scale, u.quantity_step, u.max_transaction_quantity
  INTO v_conversion, v_scale, v_step, v_max
  FROM product_units u
  WHERE u.id = p_unit_id AND u.company_id = v_session.company_id AND u.product_id = v_line.product_id AND u.is_active;
  IF v_conversion IS NULL THEN RAISE EXCEPTION 'Unit does not belong to count product/company or is inactive' USING ERRCODE = '22023'; END IF;
  IF p_observed_entered_quantity <> round(p_observed_entered_quantity, v_scale) THEN RAISE EXCEPTION 'Count quantity exceeds allowed scale' USING ERRCODE = '22023'; END IF;
  IF p_observed_entered_quantity > 0 AND mod(p_observed_entered_quantity, v_step) <> 0 THEN RAISE EXCEPTION 'Count quantity must match unit step' USING ERRCODE = '22023'; END IF;
  IF v_max IS NOT NULL AND p_observed_entered_quantity > v_max THEN RAISE EXCEPTION 'Count quantity exceeds unit maximum' USING ERRCODE = '22023'; END IF;

  v_base_qty := p_observed_entered_quantity * v_conversion;
  v_variance := v_base_qty - v_line.expected_snapshot_base_quantity;
  IF v_variance <> 0 AND (p_reason_code IS NULL OR btrim(p_reason_code) = '') THEN
    RAISE EXCEPTION 'Variance reason is required' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(max(o.attempt_number), 0) + 1 INTO v_attempt
  FROM inventory_count_observations o
  WHERE o.company_id = v_session.company_id AND o.count_line_id = p_count_line_id;

  INSERT INTO inventory_count_observations (
    company_id, count_session_id, count_line_id, location_id, product_id, attempt_number,
    entered_unit_id, observed_entered_quantity, observed_base_quantity,
    expected_snapshot_base_quantity, expected_physical_revision,
    reason_code, notes, observed_by, client_recorded_at
  ) VALUES (
    v_session.company_id, v_session.id, v_line.id, v_session.location_id, v_line.product_id, v_attempt,
    p_unit_id, p_observed_entered_quantity, v_base_qty,
    v_line.expected_snapshot_base_quantity, v_line.expected_physical_revision,
    NULLIF(btrim(p_reason_code), ''), p_notes, v_actor, p_client_recorded_at
  ) RETURNING id INTO v_observation_id;

  v_line_status := CASE WHEN v_variance = 0 THEN 'READY_TO_POST'::count_line_status ELSE 'PENDING_APPROVAL'::count_line_status END;
  UPDATE inventory_count_lines
  SET line_status = v_line_status, revision = revision + 1, updated_at = now()
  WHERE id = v_line.id;
  UPDATE inventory_count_sessions SET revision = revision + 1, updated_at = now() WHERE id = v_session.id;
  v_session_status := public.recalculate_count_session_status(v_session.id);

  RETURN jsonb_build_object(
    'session_id', v_session.id,
    'session_revision', v_session.revision + 1,
    'session_status', v_session_status,
    'line_id', v_line.id,
    'line_status', v_line_status,
    'observation_id', v_observation_id,
    'observed_base_quantity', v_base_qty,
    'variance_base_quantity', v_variance
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.decide_count_variance(
  p_observation_id UUID,
  p_expected_session_revision BIGINT,
  p_decision count_approval_decision,
  p_decision_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_observation inventory_count_observations%ROWTYPE;
  v_line inventory_count_lines%ROWTYPE;
  v_session inventory_count_sessions%ROWTYPE;
  v_line_status count_line_status;
  v_session_status count_session_status;
  v_approval_id UUID;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;

  SELECT * INTO v_observation FROM inventory_count_observations WHERE id = p_observation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Count observation not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO v_session FROM inventory_count_sessions WHERE id = v_observation.count_session_id FOR UPDATE;
  SELECT * INTO v_line FROM inventory_count_lines WHERE id = v_observation.count_line_id FOR UPDATE;

  IF v_session.revision <> p_expected_session_revision THEN RAISE EXCEPTION 'Count session revision conflict' USING ERRCODE = '40001'; END IF;
  IF v_line.line_status <> 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'Count line is not awaiting approval'; END IF;
  IF NOT public.has_warehouse_permission(v_session.location_id, 'inventory.count.approve') THEN RAISE EXCEPTION 'Count approval permission required' USING ERRCODE = '42501'; END IF;
  IF EXISTS (SELECT 1 FROM inventory_count_approvals a WHERE a.company_id = v_session.company_id AND a.observation_id = p_observation_id) THEN
    RAISE EXCEPTION 'Count observation already has a decision';
  END IF;

  INSERT INTO inventory_count_approvals (
    company_id, count_session_id, count_line_id, observation_id, location_id,
    decision, decision_reason, decided_by
  ) VALUES (
    v_session.company_id, v_session.id, v_line.id, v_observation.id, v_session.location_id,
    p_decision, p_decision_reason, v_actor
  ) RETURNING id INTO v_approval_id;

  v_line_status := CASE p_decision
    WHEN 'APPROVED' THEN 'APPROVED'::count_line_status
    WHEN 'REJECTED' THEN 'REJECTED'::count_line_status
    WHEN 'RECOUNT' THEN 'RECOUNT_REQUIRED'::count_line_status
  END;
  UPDATE inventory_count_lines SET line_status = v_line_status, revision = revision + 1, updated_at = now() WHERE id = v_line.id;
  UPDATE inventory_count_sessions SET revision = revision + 1, updated_at = now() WHERE id = v_session.id;
  v_session_status := public.recalculate_count_session_status(v_session.id);

  RETURN jsonb_build_object(
    'approval_id', v_approval_id,
    'session_id', v_session.id,
    'session_revision', v_session.revision + 1,
    'session_status', v_session_status,
    'line_id', v_line.id,
    'line_status', v_line_status,
    'decision', p_decision
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Read RPCs. Base document tables are not directly exposed to app roles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_my_warehouse_work(p_location_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_result JSONB;
BEGIN
  IF v_actor IS NULL OR NOT public.has_warehouse_permission(p_location_id, 'inventory.read') THEN
    RAISE EXCEPTION 'Warehouse read permission required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(x.item ORDER BY x.due_at NULLS LAST, x.reference_number), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT d.due_at, d.reference_number,
      jsonb_build_object(
        'id', d.id, 'kind', 'receive', 'ref', d.reference_number, 'title', 'Receive Transfer',
        'where', sl.name || ' -> ' || dl.name, 'due_at', d.due_at, 'priority', 'normal',
        'status', d.status, 'revision', d.revision,
        'done', count(*) FILTER (WHERE l.line_status NOT IN ('OPEN', 'CAPTURED')),
        'total', count(*)
      ) AS item
    FROM inventory_transfer_documents d
    JOIN inventory_transfer_lines l ON l.transfer_id = d.id AND l.company_id = d.company_id
    JOIN inventory_locations sl ON sl.id = d.source_location_id
    JOIN inventory_locations dl ON dl.id = d.destination_location_id
    WHERE d.destination_location_id = p_location_id
      AND d.status <> 'CANCELLED'
      AND (d.assigned_profile_id IS NULL OR d.assigned_profile_id = v_actor)
      AND public.has_warehouse_permission(d.destination_location_id, 'inventory.receive')
    GROUP BY d.id, sl.name, dl.name

    UNION ALL

    SELECT d.due_at, d.reference_number,
      jsonb_build_object(
        'id', d.id, 'kind', 'dispatch', 'ref', d.reference_number, 'title', 'Dispatch Order',
        'where', '-> ' || d.destination_name, 'due_at', d.due_at, 'priority', lower(d.priority),
        'status', d.status, 'revision', d.revision,
        'done', count(*) FILTER (WHERE l.line_status NOT IN ('OPEN', 'CAPTURED')),
        'total', count(*)
      ) AS item
    FROM inventory_sales_orders d
    JOIN inventory_sales_order_lines l ON l.sales_order_id = d.id AND l.company_id = d.company_id
    WHERE d.source_location_id = p_location_id
      AND d.status <> 'CANCELLED'
      AND (d.assigned_profile_id IS NULL OR d.assigned_profile_id = v_actor)
      AND public.has_warehouse_permission(d.source_location_id, 'inventory.dispatch')
    GROUP BY d.id

    UNION ALL

    SELECT d.due_at, d.reference_number,
      jsonb_build_object(
        'id', d.id, 'kind', 'count', 'ref', d.reference_number, 'title', 'Cycle Count',
        'where', d.zone, 'due_at', d.due_at, 'priority', 'normal',
        'status', d.status, 'revision', d.revision,
        'done', count(*) FILTER (WHERE l.line_status NOT IN ('OPEN', 'RECOUNT_REQUIRED')),
        'total', count(*)
      ) AS item
    FROM inventory_count_sessions d
    JOIN inventory_count_lines l ON l.count_session_id = d.id AND l.company_id = d.company_id
    WHERE d.location_id = p_location_id
      AND d.status <> 'CANCELLED'
      AND (d.assigned_profile_id IS NULL OR d.assigned_profile_id = v_actor)
      AND public.has_warehouse_permission(d.location_id, 'inventory.count')
    GROUP BY d.id
  ) x;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_transfer_document(p_document_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE v_doc inventory_transfer_documents%ROWTYPE; v_actor UUID := public.current_profile_id(); v_result JSONB;
BEGIN
  SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id = p_document_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_actor IS NULL OR NOT public.has_warehouse_permission(v_doc.destination_location_id, 'inventory.receive') THEN RAISE EXCEPTION 'Receive permission required' USING ERRCODE = '42501'; END IF;
  IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Transfer is assigned to another user' USING ERRCODE = '42501'; END IF;

  SELECT jsonb_build_object(
    'id', d.id, 'ref', d.reference_number, 'status', d.status, 'revision', d.revision,
    'source_location_id', d.source_location_id, 'source_name', sl.name,
    'destination_location_id', d.destination_location_id, 'destination_name', dl.name,
    'due_at', d.due_at,
    'lines', COALESCE(jsonb_agg(jsonb_build_object(
      'id', l.id, 'line_number', l.line_number, 'product_id', l.product_id, 'product_name', p.name, 'sku', p.sku,
      'unit_id', l.entered_unit_id, 'unit_code', u.unit_code,
      'source_bin_id', l.source_bin_id, 'source_bin_code', sb.code,
      'destination_bin_id', l.destination_bin_id, 'destination_bin_code', db.code,
      'expected_base_quantity', l.expected_base_quantity,
      'captured_received_base_quantity', l.captured_received_base_quantity,
      'posted_base_quantity', l.posted_base_quantity,
      'remaining_expected_base_quantity', l.remaining_expected_base_quantity,
      'line_status', l.line_status, 'exception_code', l.exception_code, 'exception_notes', l.exception_notes,
      'revision', l.revision, 'client_recorded_at', l.client_recorded_at
    ) ORDER BY l.line_number) FILTER (WHERE l.id IS NOT NULL), '[]'::jsonb)
  ) INTO v_result
  FROM inventory_transfer_documents d
  JOIN inventory_locations sl ON sl.id = d.source_location_id
  JOIN inventory_locations dl ON dl.id = d.destination_location_id
  LEFT JOIN inventory_transfer_lines l ON l.transfer_id = d.id AND l.company_id = d.company_id
  LEFT JOIN products p ON p.id = l.product_id
  LEFT JOIN product_units u ON u.id = l.entered_unit_id
  LEFT JOIN inventory_bins sb ON sb.id = l.source_bin_id
  LEFT JOIN inventory_bins db ON db.id = l.destination_bin_id
  WHERE d.id = p_document_id
  GROUP BY d.id, sl.name, dl.name;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_sales_order_document(p_document_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE v_doc inventory_sales_orders%ROWTYPE; v_actor UUID := public.current_profile_id(); v_result JSONB;
BEGIN
  SELECT * INTO v_doc FROM inventory_sales_orders WHERE id = p_document_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_actor IS NULL OR NOT public.has_warehouse_permission(v_doc.source_location_id, 'inventory.dispatch') THEN RAISE EXCEPTION 'Dispatch permission required' USING ERRCODE = '42501'; END IF;
  IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Sales order is assigned to another user' USING ERRCODE = '42501'; END IF;

  SELECT jsonb_build_object(
    'id', d.id, 'ref', d.reference_number, 'status', d.status, 'revision', d.revision,
    'source_location_id', d.source_location_id, 'source_name', sl.name,
    'destination_location_id', d.destination_location_id, 'destination_name', d.destination_name,
    'customer_name', d.customer_name, 'priority', d.priority, 'due_at', d.due_at,
    'lines', COALESCE(jsonb_agg(jsonb_build_object(
      'id', l.id, 'line_number', l.line_number, 'product_id', l.product_id, 'product_name', p.name, 'sku', p.sku,
      'unit_id', l.entered_unit_id, 'unit_code', u.unit_code,
      'source_bin_id', l.source_bin_id, 'source_bin_code', sb.code,
      'requested_base_quantity', l.requested_base_quantity,
      'captured_picked_base_quantity', l.captured_picked_base_quantity,
      'posted_base_quantity', l.posted_base_quantity,
      'backordered_base_quantity', l.backordered_base_quantity,
      'remaining_base_quantity', l.remaining_base_quantity,
      'line_status', l.line_status, 'exception_code', l.exception_code, 'exception_notes', l.exception_notes,
      'revision', l.revision, 'client_recorded_at', l.client_recorded_at
    ) ORDER BY l.line_number) FILTER (WHERE l.id IS NOT NULL), '[]'::jsonb)
  ) INTO v_result
  FROM inventory_sales_orders d
  JOIN inventory_locations sl ON sl.id = d.source_location_id
  LEFT JOIN inventory_sales_order_lines l ON l.sales_order_id = d.id AND l.company_id = d.company_id
  LEFT JOIN products p ON p.id = l.product_id
  LEFT JOIN product_units u ON u.id = l.entered_unit_id
  LEFT JOIN inventory_bins sb ON sb.id = l.source_bin_id
  WHERE d.id = p_document_id
  GROUP BY d.id, sl.name;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_count_session_document(p_document_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE v_doc inventory_count_sessions%ROWTYPE; v_actor UUID := public.current_profile_id(); v_result JSONB; v_can_approve BOOLEAN;
BEGIN
  SELECT * INTO v_doc FROM inventory_count_sessions WHERE id = p_document_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_actor IS NULL OR NOT public.has_warehouse_permission(v_doc.location_id, 'inventory.count') THEN RAISE EXCEPTION 'Count permission required' USING ERRCODE = '42501'; END IF;
  IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Count session is assigned to another user' USING ERRCODE = '42501'; END IF;
  v_can_approve := public.has_warehouse_permission(v_doc.location_id, 'inventory.count.approve');

  SELECT jsonb_build_object(
    'id', d.id, 'ref', d.reference_number, 'status', d.status, 'revision', d.revision,
    'location_id', d.location_id, 'location_name', loc.name, 'zone', d.zone, 'policy', d.policy, 'due_at', d.due_at,
    'lines', COALESCE(jsonb_agg(jsonb_build_object(
      'id', l.id, 'line_number', l.line_number, 'product_id', l.product_id, 'product_name', p.name, 'sku', p.sku,
      'bin_id', l.bin_id, 'bin_code', b.code, 'unit_id', l.base_unit_id, 'unit_code', u.unit_code,
      -- Blind-count guarantee: expected quantity/revision are hidden until an observation exists, unless the actor can approve.
      'expected_base_quantity', CASE WHEN v_can_approve OR obs.id IS NOT NULL THEN l.expected_snapshot_base_quantity ELSE NULL END,
      'expected_physical_revision', CASE WHEN v_can_approve OR obs.id IS NOT NULL THEN l.expected_physical_revision ELSE NULL END,
      'line_status', l.line_status, 'revision', l.revision,
      'latest_observation_id', obs.id, 'observed_base_quantity', obs.observed_base_quantity,
      'variance_base_quantity', obs.variance_base_quantity, 'reason_code', obs.reason_code,
      'approval_decision', appr.decision
    ) ORDER BY l.line_number) FILTER (WHERE l.id IS NOT NULL), '[]'::jsonb)
  ) INTO v_result
  FROM inventory_count_sessions d
  JOIN inventory_locations loc ON loc.id = d.location_id
  LEFT JOIN inventory_count_lines l ON l.count_session_id = d.id AND l.company_id = d.company_id
  LEFT JOIN products p ON p.id = l.product_id
  LEFT JOIN inventory_bins b ON b.id = l.bin_id
  LEFT JOIN product_units u ON u.id = l.base_unit_id
  LEFT JOIN LATERAL (
    SELECT o.* FROM inventory_count_observations o
    WHERE o.company_id = l.company_id AND o.count_line_id = l.id
    ORDER BY o.attempt_number DESC LIMIT 1
  ) obs ON true
  LEFT JOIN inventory_count_approvals appr ON appr.company_id = d.company_id AND appr.observation_id = obs.id
  WHERE d.id = p_document_id
  GROUP BY d.id, loc.name;
  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. RLS defense-in-depth and app privilege boundary.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_transfer_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_transfer_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_sales_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_sales_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_backorders ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_count_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_count_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_count_observations ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_count_approvals ENABLE ROW LEVEL SECURITY;

CREATE POLICY inventory_transfer_documents_authorized_read ON inventory_transfer_documents
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(destination_location_id, 'inventory.receive'));
CREATE POLICY inventory_transfer_lines_authorized_read ON inventory_transfer_lines
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(destination_location_id, 'inventory.receive'));
CREATE POLICY inventory_sales_orders_authorized_read ON inventory_sales_orders
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(source_location_id, 'inventory.dispatch'));
CREATE POLICY inventory_sales_order_lines_authorized_read ON inventory_sales_order_lines
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(source_location_id, 'inventory.dispatch'));
CREATE POLICY inventory_backorders_authorized_read ON inventory_backorders
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(source_location_id, 'inventory.dispatch'));
CREATE POLICY inventory_count_sessions_authorized_read ON inventory_count_sessions
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(location_id, 'inventory.count'));
CREATE POLICY inventory_count_lines_authorized_read ON inventory_count_lines
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(location_id, 'inventory.count'));
CREATE POLICY inventory_count_observations_authorized_read ON inventory_count_observations
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(location_id, 'inventory.count'));
CREATE POLICY inventory_count_approvals_authorized_read ON inventory_count_approvals
  FOR SELECT TO authenticated USING (is_company_member(company_id) AND has_warehouse_permission(location_id, 'inventory.count'));

-- Document base tables remain command-only. Read through RPCs so blind-count columns cannot be queried directly.
REVOKE ALL PRIVILEGES ON TABLE
  inventory_transfer_documents, inventory_transfer_lines,
  inventory_sales_orders, inventory_sales_order_lines, inventory_backorders,
  inventory_count_sessions, inventory_count_lines, inventory_count_observations, inventory_count_approvals
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION recalculate_transfer_document_status(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION recalculate_sales_order_status(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION recalculate_count_session_status(UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.record_transfer_receipt_line(UUID, BIGINT, NUMERIC, UUID, UUID, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_transfer_receipt_line(UUID, BIGINT, NUMERIC, UUID, UUID, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.record_sales_order_pick_line(UUID, BIGINT, NUMERIC, UUID, UUID, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sales_order_pick_line(UUID, BIGINT, NUMERIC, UUID, UUID, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.create_sales_order_backorder(UUID, BIGINT, NUMERIC, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_order_backorder(UUID, BIGINT, NUMERIC, TEXT, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.record_count_observation(UUID, BIGINT, NUMERIC, UUID, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_count_observation(UUID, BIGINT, NUMERIC, UUID, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.decide_count_variance(UUID, BIGINT, count_approval_decision, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_count_variance(UUID, BIGINT, count_approval_decision, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.list_my_warehouse_work(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_warehouse_work(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.get_transfer_document(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_transfer_document(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.get_sales_order_document(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_sales_order_document(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.get_count_session_document(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_count_session_document(UUID) TO authenticated;
