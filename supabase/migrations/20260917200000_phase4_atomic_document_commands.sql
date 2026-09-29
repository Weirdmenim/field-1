-- Phase 4: atomic authoritative document commands, idempotency, and server deltas.
-- Preserves Phase 1 trust boundaries, Phase 2 stock invariants, and Phase 3 document immutability.

-- ---------------------------------------------------------------------------
-- 1. Document-command ledger and typed outcomes.
-- ---------------------------------------------------------------------------
CREATE TYPE document_command_type AS ENUM (
  'TRANSFER_SHIP', 'TRANSFER_RECEIVE', 'SALES_DISPATCH', 'COUNT_FINALIZE'
);

CREATE TYPE document_command_status AS ENUM (
  'PROCESSING', 'COMPLETED', 'VALIDATION_ERROR', 'CONFLICT',
  'AUTHORIZATION_ERROR', 'TRANSIENT_ERROR'
);

CREATE TABLE inventory_document_commands (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  client_command_id UUID NOT NULL,
  command_type document_command_type NOT NULL,
  source_document_id UUID NOT NULL,
  expected_document_revision BIGINT NOT NULL CHECK (expected_document_revision > 0),
  request_fingerprint TEXT NOT NULL,
  initiating_actor UUID NOT NULL,
  status document_command_status NOT NULL DEFAULT 'PROCESSING',
  operation_id UUID REFERENCES inventory_operations(id),
  result_payload JSONB,
  error_code TEXT,
  error_message TEXT,
  client_recorded_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, client_command_id),
  UNIQUE (company_id, id)
);

ALTER TABLE inventory_document_commands
  ADD CONSTRAINT inventory_document_commands_actor_fk
  FOREIGN KEY (company_id, initiating_actor)
  REFERENCES company_memberships(company_id, profile_id);

CREATE INDEX inventory_document_commands_document_idx
  ON inventory_document_commands (company_id, source_document_id, command_type, created_at DESC);

-- Link movements to the one authoritative document command that created them.
ALTER TABLE inventory_movements
  ADD COLUMN IF NOT EXISTS document_command_id UUID;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_document_command_fk
  FOREIGN KEY (company_id, document_command_id)
  REFERENCES inventory_document_commands(company_id, id)
  NOT VALID;

CREATE INDEX inventory_movements_document_command_idx
  ON inventory_movements (company_id, document_command_id, posted_at);

-- Transfers need explicit source-custody progress separate from destination receipt progress.
ALTER TABLE inventory_transfer_lines
  ADD COLUMN IF NOT EXISTS shipped_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0;
ALTER TABLE inventory_transfer_lines
  ADD CONSTRAINT inventory_transfer_line_shipped_within_expected
  CHECK (shipped_base_quantity >= 0 AND shipped_base_quantity <= expected_base_quantity) NOT VALID;

-- Preserve truthful existing transit provenance by backfilling only lines already linked to transit.
UPDATE inventory_transfer_lines l
SET shipped_base_quantity = LEAST(
  l.expected_base_quantity,
  COALESCE((
    SELECT sum(t.base_quantity)
    FROM inventory_transit_lots t
    WHERE t.company_id = l.company_id
      AND t.transfer_line_id = l.id
      AND t.status <> 'CANCELLED'
  ), 0)
)
WHERE EXISTS (
  SELECT 1 FROM inventory_transit_lots t
  WHERE t.company_id = l.company_id
    AND t.transfer_line_id = l.id
    AND t.status <> 'CANCELLED'
);

CREATE UNIQUE INDEX inventory_transit_one_active_lot_per_transfer_line_idx
  ON inventory_transit_lots (company_id, transfer_line_id)
  WHERE transfer_line_id IS NOT NULL AND status <> 'CANCELLED';

-- ---------------------------------------------------------------------------
-- 2. Internal idempotency helpers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION phase4_command_fingerprint(
  p_command_type document_command_type,
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_options JSONB DEFAULT '{}'::JSONB
)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT md5(jsonb_build_object(
    'command_type', p_command_type::text,
    'document_id', p_document_id::text,
    'expected_revision', p_expected_revision,
    'options', COALESCE(p_options, '{}'::jsonb)
  )::text)
$$;

CREATE OR REPLACE FUNCTION phase4_begin_document_command(
  p_company_id UUID,
  p_actor UUID,
  p_command_type document_command_type,
  p_client_command_id UUID,
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_options JSONB DEFAULT '{}'::JSONB,
  p_client_recorded_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_fingerprint TEXT;
  v_id UUID;
  v_existing inventory_document_commands%ROWTYPE;
BEGIN
  IF p_client_command_id IS NULL THEN
    RAISE EXCEPTION 'client command id is required' USING ERRCODE = '22023';
  END IF;
  IF p_expected_revision IS NULL OR p_expected_revision <= 0 THEN
    RAISE EXCEPTION 'expected document revision must be positive' USING ERRCODE = '22023';
  END IF;

  IF p_client_recorded_at IS NULL THEN
    RAISE EXCEPTION 'client recorded timestamp is required' USING ERRCODE = '22023';
  END IF;

  -- The physical-action timestamp is immutable command content. Binding it into the
  -- server fingerprint prevents a retry from silently rewriting audit chronology.
  v_fingerprint := public.phase4_command_fingerprint(
    p_command_type,
    p_document_id,
    p_expected_revision,
    COALESCE(p_options, '{}'::jsonb) || jsonb_build_object('client_recorded_at', p_client_recorded_at)
  );

  INSERT INTO inventory_document_commands (
    company_id, client_command_id, command_type, source_document_id,
    expected_document_revision, request_fingerprint, initiating_actor,
    client_recorded_at
  ) VALUES (
    p_company_id, p_client_command_id, p_command_type, p_document_id,
    p_expected_revision, v_fingerprint, p_actor, p_client_recorded_at
  )
  ON CONFLICT (company_id, client_command_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'state', 'NEW',
      'server_command_id', v_id,
      'request_fingerprint', v_fingerprint
    );
  END IF;

  SELECT * INTO v_existing
  FROM inventory_document_commands
  WHERE company_id = p_company_id
    AND client_command_id = p_client_command_id
  FOR UPDATE;

  IF v_existing.request_fingerprint <> v_fingerprint
     OR v_existing.command_type <> p_command_type
     OR v_existing.source_document_id <> p_document_id
     OR v_existing.initiating_actor <> p_actor THEN
    RETURN jsonb_build_object(
      'state', 'MISMATCH',
      'server_command_id', v_existing.id,
      'message', 'Idempotency key was already used for a different command'
    );
  END IF;

  -- A transient outcome is retryable with the same stable command identity.
  IF v_existing.status = 'TRANSIENT_ERROR' THEN
    UPDATE inventory_document_commands
    SET status = 'PROCESSING',
        result_payload = NULL,
        error_code = NULL,
        error_message = NULL,
        completed_at = NULL,
        updated_at = now()
    WHERE id = v_existing.id;
    RETURN jsonb_build_object(
      'state', 'NEW',
      'server_command_id', v_existing.id,
      'request_fingerprint', v_fingerprint,
      'retrying_transient', true
    );
  END IF;

  RETURN jsonb_build_object(
    'state', 'EXISTING',
    'server_command_id', v_existing.id,
    'status', v_existing.status::text,
    'result_payload', v_existing.result_payload,
    'error_code', v_existing.error_code,
    'error_message', v_existing.error_message
  );
END;
$$;

CREATE OR REPLACE FUNCTION phase4_duplicate_result(p_begin JSONB, p_client_command_id UUID)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_begin->>'state' = 'MISMATCH' THEN
      jsonb_build_object(
        'success', false,
        'outcome', 'validation_error',
        'client_command_id', p_client_command_id,
        'server_command_id', p_begin->>'server_command_id',
        'code', 'IDEMPOTENCY_KEY_REUSED',
        'message', p_begin->>'message'
      )
    ELSE
      jsonb_build_object(
        'success', COALESCE((p_begin->'result_payload'->>'success')::boolean, false),
        'outcome', 'duplicate',
        'original_outcome', COALESCE(p_begin->'result_payload'->>'outcome', lower(p_begin->>'status')),
        'client_command_id', p_client_command_id,
        'server_command_id', p_begin->>'server_command_id',
        'result', p_begin->'result_payload',
        'code', p_begin->>'error_code',
        'message', p_begin->>'error_message'
      )
  END
$$;

CREATE OR REPLACE FUNCTION phase4_store_command_result(
  p_server_command_id UUID,
  p_status document_command_status,
  p_result JSONB,
  p_error_code TEXT DEFAULT NULL,
  p_error_message TEXT DEFAULT NULL,
  p_operation_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE inventory_document_commands
  SET status = p_status,
      result_payload = p_result,
      error_code = p_error_code,
      error_message = p_error_message,
      operation_id = COALESCE(p_operation_id, operation_id),
      completed_at = CASE WHEN p_status <> 'PROCESSING' THEN now() ELSE NULL END,
      updated_at = now()
  WHERE id = p_server_command_id;
END;
$$;

CREATE OR REPLACE FUNCTION phase4_error_outcome(
  p_sqlstate TEXT,
  p_message TEXT,
  p_server_command_id UUID,
  p_client_command_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_outcome TEXT;
BEGIN
  v_outcome := CASE
    WHEN p_sqlstate = '42501' THEN 'authorization_error'
    WHEN p_sqlstate = '40001' THEN 'conflict'
    WHEN p_sqlstate IN ('22023', '23514', 'P0002', '0A000') THEN 'validation_error'
    ELSE 'transient_error'
  END;
  RETURN jsonb_build_object(
    'success', false,
    'outcome', v_outcome,
    'client_command_id', p_client_command_id,
    'server_command_id', p_server_command_id,
    'code', p_sqlstate,
    'message', p_message
  );
END;
$$;

CREATE OR REPLACE FUNCTION phase4_error_status(p_sqlstate TEXT)
RETURNS document_command_status
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_sqlstate = '42501' THEN 'AUTHORIZATION_ERROR'::document_command_status
    WHEN p_sqlstate = '40001' THEN 'CONFLICT'::document_command_status
    WHEN p_sqlstate IN ('22023', '23514', 'P0002', '0A000') THEN 'VALIDATION_ERROR'::document_command_status
    ELSE 'TRANSIENT_ERROR'::document_command_status
  END
$$;

-- ---------------------------------------------------------------------------
-- 3. Internal operation + movement helpers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION phase4_create_operation(
  p_company_id UUID,
  p_actor UUID,
  p_command_type document_command_type,
  p_client_command_id UUID,
  p_fingerprint TEXT,
  p_document_type TEXT,
  p_document_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operation_id UUID;
BEGIN
  INSERT INTO inventory_operations (
    company_id, operation_type, client_transaction_id, request_fingerprint,
    source_document_type, source_document_id, initiating_actor, status
  ) VALUES (
    p_company_id, p_command_type::text, p_client_command_id::text, p_fingerprint,
    p_document_type, p_document_id, p_actor, 'PROCESSING'
  ) RETURNING id INTO v_operation_id;
  RETURN v_operation_id;
END;
$$;

CREATE OR REPLACE FUNCTION phase4_apply_document_movement(
  p_company_id UUID,
  p_actor UUID,
  p_operation_id UUID,
  p_document_command_id UUID,
  p_client_command_id UUID,
  p_product_id UUID,
  p_movement_type movement_type,
  p_source_location_id UUID,
  p_source_bin_id UUID,
  p_destination_location_id UUID,
  p_destination_bin_id UUID,
  p_source_status inventory_status,
  p_destination_status inventory_status,
  p_base_quantity NUMERIC,
  p_unit_id UUID,
  p_reference_type TEXT,
  p_reference_id UUID,
  p_reference_number TEXT,
  p_transfer_line_id UUID DEFAULT NULL,
  p_sales_order_line_id UUID DEFAULT NULL,
  p_count_line_id UUID DEFAULT NULL,
  p_client_recorded_at TIMESTAMPTZ DEFAULT NULL,
  p_reason_code TEXT DEFAULT NULL,
  p_reason_text TEXT DEFAULT NULL,
  p_approved_by UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_conversion NUMERIC;
  v_entered_quantity NUMERIC;
  v_current_source NUMERIC;
  v_new_source NUMERIC;
  v_allow_negative BOOLEAN := false;
  v_movement_id UUID;
BEGIN
  IF p_base_quantity IS NULL OR p_base_quantity <= 0 THEN
    RAISE EXCEPTION 'Document movement quantity must be greater than zero' USING ERRCODE = '22023';
  END IF;

  SELECT u.conversion_to_base INTO v_conversion
  FROM product_units u
  WHERE u.company_id = p_company_id
    AND u.product_id = p_product_id
    AND u.id = p_unit_id
    AND u.is_active;
  IF v_conversion IS NULL OR v_conversion <= 0 THEN
    RAISE EXCEPTION 'Movement unit is not active for the authoritative product' USING ERRCODE = '22023';
  END IF;
  v_entered_quantity := p_base_quantity / v_conversion;

  IF p_source_location_id IS NOT NULL THEN
    SELECT l.allow_negative_inventory INTO v_allow_negative
    FROM inventory_locations l
    JOIN inventory_bins bin
      ON bin.company_id = l.company_id AND bin.location_id = l.id AND bin.id = p_source_bin_id
    WHERE l.company_id = p_company_id AND l.id = p_source_location_id
      AND l.is_active AND bin.is_active;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Source warehouse/bin is inactive or no longer valid' USING ERRCODE = '42501';
    END IF;

    INSERT INTO inventory_balances (
      company_id, location_id, bin_id, product_id, inventory_status,
      on_hand_base_qty, reserved_base_qty, physical_status_revision
    ) VALUES (
      p_company_id, p_source_location_id, p_source_bin_id, p_product_id, p_source_status,
      0, 0, 1
    )
    ON CONFLICT (company_id, location_id, bin_id, product_id, inventory_status) DO NOTHING;

    SELECT b.on_hand_base_qty
    INTO v_current_source
    FROM inventory_balances b
    WHERE b.company_id = p_company_id
      AND b.location_id = p_source_location_id
      AND b.bin_id = p_source_bin_id
      AND b.product_id = p_product_id
      AND b.inventory_status = p_source_status
    FOR UPDATE OF b;

    v_new_source := v_current_source - p_base_quantity;
    IF v_new_source < 0 AND (p_source_status <> 'AVAILABLE' OR NOT COALESCE(v_allow_negative, false)) THEN
      RAISE EXCEPTION 'Insufficient source stock for authoritative document command' USING ERRCODE = '23514';
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
    PERFORM 1
    FROM inventory_locations l
    JOIN inventory_bins bin
      ON bin.company_id = l.company_id AND bin.location_id = l.id AND bin.id = p_destination_bin_id
    WHERE l.company_id = p_company_id AND l.id = p_destination_location_id
      AND l.is_active AND bin.is_active;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Destination warehouse/bin is inactive or no longer valid' USING ERRCODE = '42501';
    END IF;

    INSERT INTO inventory_balances (
      company_id, location_id, bin_id, product_id, inventory_status,
      on_hand_base_qty, reserved_base_qty, physical_status_revision
    ) VALUES (
      p_company_id, p_destination_location_id, p_destination_bin_id, p_product_id, p_destination_status,
      p_base_quantity, 0, 1
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
    direction, client_recorded_at,
    reference_type, reference_id, reference_number,
    reason_code, reason_text,
    performed_by, approved_by,
    client_transaction_id, operation_id, document_command_id,
    transfer_line_id, sales_order_line_id, count_line_id, posted_at
  ) VALUES (
    p_company_id, p_product_id, p_movement_type,
    p_source_location_id, p_source_bin_id,
    p_destination_location_id, p_destination_bin_id,
    p_source_status, p_destination_status,
    v_entered_quantity, p_unit_id, p_base_quantity,
    CASE WHEN p_source_location_id IS NULL THEN 'IN' WHEN p_destination_location_id IS NULL THEN 'OUT' ELSE 'INTERNAL' END,
    p_client_recorded_at,
    p_reference_type, p_reference_id, p_reference_number,
    p_reason_code, p_reason_text,
    p_actor, p_approved_by,
    p_client_command_id::text, p_operation_id, p_document_command_id,
    p_transfer_line_id, p_sales_order_line_id, p_count_line_id, now()
  ) RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Atomic transfer shipment command: on-hand -> transit.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ship_transfer_document(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
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
  v_begin JSONB;
  v_server_command_id UUID;
  v_fingerprint TEXT;
  v_operation_id UUID;
  v_delta NUMERIC;
  v_current NUMERIC;
  v_total_reserved NUMERIC;
  v_movement_id UUID;
  v_transit_id UUID;
  v_line_results JSONB := '[]'::jsonb;
  v_result JSONB;
  v_state TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Authenticated operational profile required');
  END IF;

  SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Transfer is not available to the authenticated company');
  END IF;

  v_begin := public.phase4_begin_document_command(
    v_doc.company_id, v_actor, 'TRANSFER_SHIP', p_client_command_id,
    p_document_id, p_expected_revision, '{}'::jsonb, p_client_recorded_at
  );
  v_state := v_begin->>'state';
  IF v_state <> 'NEW' THEN RETURN public.phase4_duplicate_result(v_begin, p_client_command_id); END IF;
  v_server_command_id := (v_begin->>'server_command_id')::uuid;
  v_fingerprint := v_begin->>'request_fingerprint';

  BEGIN
    SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id = p_document_id FOR UPDATE;
    IF v_doc.revision <> p_expected_revision THEN RAISE EXCEPTION 'Transfer revision conflict' USING ERRCODE = '40001'; END IF;
    IF v_doc.status IN ('COMPLETED', 'CANCELLED') THEN RAISE EXCEPTION 'Transfer is not shippable in its current state' USING ERRCODE = '22023'; END IF;
    IF NOT public.has_warehouse_permission(v_doc.source_location_id, 'inventory.dispatch') THEN RAISE EXCEPTION 'Transfer ship permission required' USING ERRCODE = '42501'; END IF;
    IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Transfer is assigned to another user' USING ERRCODE = '42501'; END IF;

    v_operation_id := public.phase4_create_operation(
      v_doc.company_id, v_actor, 'TRANSFER_SHIP', p_client_command_id, v_fingerprint,
      'TRANSFER', v_doc.id
    );

    FOR v_line IN
      SELECT * FROM inventory_transfer_lines
      WHERE company_id = v_doc.company_id AND transfer_id = v_doc.id AND line_status <> 'CANCELLED'
      ORDER BY line_number FOR UPDATE
    LOOP
      v_delta := v_line.expected_base_quantity - v_line.shipped_base_quantity;
      IF v_delta < 0 THEN RAISE EXCEPTION 'Transfer line shipped quantity exceeds authoritative expected quantity' USING ERRCODE = '23514'; END IF;
      IF v_delta = 0 THEN CONTINUE; END IF;

      -- Protect active reservations from transfer shipment.
      PERFORM 1 FROM inventory_reservations r
      WHERE r.company_id = v_doc.company_id
        AND r.location_id = v_doc.source_location_id
        AND (r.bin_id = v_line.source_bin_id OR r.bin_id IS NULL)
        AND r.product_id = v_line.product_id
        AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')
      ORDER BY r.id FOR UPDATE;

      SELECT COALESCE(sum(r.reserved_base_qty - r.fulfilled_base_qty - r.released_base_qty), 0)
      INTO v_total_reserved
      FROM inventory_reservations r
      WHERE r.company_id = v_doc.company_id
        AND r.location_id = v_doc.source_location_id
        AND (r.bin_id = v_line.source_bin_id OR r.bin_id IS NULL)
        AND r.product_id = v_line.product_id
        AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED');

      INSERT INTO inventory_balances (
        company_id, location_id, bin_id, product_id, inventory_status,
        on_hand_base_qty, reserved_base_qty, physical_status_revision
      ) VALUES (
        v_doc.company_id, v_doc.source_location_id, v_line.source_bin_id, v_line.product_id, 'AVAILABLE', 0, 0, 1
      ) ON CONFLICT (company_id, location_id, bin_id, product_id, inventory_status) DO NOTHING;

      SELECT on_hand_base_qty INTO v_current
      FROM inventory_balances
      WHERE company_id = v_doc.company_id AND location_id = v_doc.source_location_id
        AND bin_id = v_line.source_bin_id AND product_id = v_line.product_id
        AND inventory_status = 'AVAILABLE'
      FOR UPDATE;

      IF v_current - v_delta < v_total_reserved THEN
        RAISE EXCEPTION 'Transfer shipment would consume stock reserved for another document' USING ERRCODE = '23514';
      END IF;

      v_movement_id := public.phase4_apply_document_movement(
        v_doc.company_id, v_actor, v_operation_id, v_server_command_id, p_client_command_id,
        v_line.product_id, 'TRANSFER_OUT',
        v_doc.source_location_id, v_line.source_bin_id,
        NULL, NULL, 'AVAILABLE', NULL,
        v_delta, v_line.entered_unit_id,
        'TRANSFER', v_doc.id, v_doc.reference_number,
        v_line.id, NULL, NULL,
        COALESCE(p_client_recorded_at, now()), NULL, NULL, NULL
      );

      v_transit_id := NULL;
      SELECT id INTO v_transit_id
      FROM inventory_transit_lots
      WHERE company_id = v_doc.company_id
        AND transfer_line_id = v_line.id
        AND status <> 'CANCELLED'
      FOR UPDATE;

      IF v_transit_id IS NULL THEN
        INSERT INTO inventory_transit_lots (
          company_id, product_id, source_location_id, source_bin_id,
          destination_location_id, destination_bin_id, base_quantity,
          status, source_reference_type, source_reference_key, source_document_id,
          transfer_line_id, dispatched_at
        ) VALUES (
          v_doc.company_id, v_line.product_id, v_doc.source_location_id, v_line.source_bin_id,
          v_doc.destination_location_id, v_line.destination_bin_id, v_delta,
          'IN_TRANSIT', 'TRANSFER', v_doc.reference_number || ':' || v_line.id::text,
          v_doc.id, v_line.id, COALESCE(p_client_recorded_at, now())
        ) RETURNING id INTO v_transit_id;
      ELSE
        UPDATE inventory_transit_lots
        SET base_quantity = base_quantity + v_delta,
            status = 'IN_TRANSIT',
            transit_revision = transit_revision + 1,
            updated_at = now()
        WHERE id = v_transit_id;
      END IF;

      UPDATE inventory_transfer_lines
      SET shipped_base_quantity = shipped_base_quantity + v_delta,
          revision = revision + 1,
          updated_at = now()
      WHERE id = v_line.id;

      v_line_results := v_line_results || jsonb_build_array(jsonb_build_object(
        'line_id', v_line.id,
        'shipped_base_quantity', v_delta,
        'movement_id', v_movement_id,
        'transit_lot_id', v_transit_id
      ));
    END LOOP;

    IF jsonb_array_length(v_line_results) = 0 THEN
      RAISE EXCEPTION 'Transfer has no unshipped quantity' USING ERRCODE = '22023';
    END IF;

    UPDATE inventory_transfer_documents
    SET status = 'IN_PROGRESS', revision = revision + 1, updated_at = now()
    WHERE id = v_doc.id;

    UPDATE inventory_operations SET status = 'COMPLETED', posted_at = now() WHERE id = v_operation_id;

    v_result := jsonb_build_object(
      'success', true,
      'outcome', 'accepted',
      'client_command_id', p_client_command_id,
      'server_command_id', v_server_command_id,
      'operation_id', v_operation_id,
      'document_id', v_doc.id,
      'document_revision', v_doc.revision + 1,
      'document_status', 'IN_PROGRESS',
      'lines', v_line_results
    );
    PERFORM public.phase4_store_command_result(v_server_command_id, 'COMPLETED', v_result, NULL, NULL, v_operation_id);
    RETURN v_result;
  EXCEPTION WHEN OTHERS THEN
    v_result := public.phase4_error_outcome(SQLSTATE, SQLERRM, v_server_command_id, p_client_command_id);
    PERFORM public.phase4_store_command_result(
      v_server_command_id, public.phase4_error_status(SQLSTATE), v_result, SQLSTATE, SQLERRM, NULL
    );
    RETURN v_result;
  END;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Atomic transfer receipt command: transit -> destination on-hand.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_transfer_document(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
  p_allow_partial BOOLEAN DEFAULT false,
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
  v_transit inventory_transit_lots%ROWTYPE;
  v_begin JSONB;
  v_server_command_id UUID;
  v_fingerprint TEXT;
  v_operation_id UUID;
  v_delta NUMERIC;
  v_transit_remaining NUMERIC;
  v_new_received NUMERIC;
  v_movement_id UUID;
  v_line_results JSONB := '[]'::jsonb;
  v_result JSONB;
  v_state TEXT;
  v_has_unresolved BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Authenticated operational profile required');
  END IF;

  SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Transfer is not available to the authenticated company');
  END IF;

  v_begin := public.phase4_begin_document_command(
    v_doc.company_id, v_actor, 'TRANSFER_RECEIVE', p_client_command_id,
    p_document_id, p_expected_revision,
    jsonb_build_object('allow_partial', p_allow_partial), p_client_recorded_at
  );
  v_state := v_begin->>'state';
  IF v_state <> 'NEW' THEN RETURN public.phase4_duplicate_result(v_begin, p_client_command_id); END IF;
  v_server_command_id := (v_begin->>'server_command_id')::uuid;
  v_fingerprint := v_begin->>'request_fingerprint';

  BEGIN
    SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id = p_document_id FOR UPDATE;
    IF v_doc.revision <> p_expected_revision THEN RAISE EXCEPTION 'Transfer revision conflict' USING ERRCODE = '40001'; END IF;
    IF v_doc.status = 'CANCELLED' THEN RAISE EXCEPTION 'Cancelled transfer cannot be received' USING ERRCODE = '22023'; END IF;
    IF NOT public.has_warehouse_permission(v_doc.destination_location_id, 'inventory.receive') THEN RAISE EXCEPTION 'Receive permission required' USING ERRCODE = '42501'; END IF;
    IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Transfer is assigned to another user' USING ERRCODE = '42501'; END IF;

    SELECT EXISTS (
      SELECT 1 FROM inventory_transfer_lines
      WHERE company_id = v_doc.company_id AND transfer_id = v_doc.id
        AND line_status = 'OPEN'
    ) INTO v_has_unresolved;
    IF v_has_unresolved AND NOT p_allow_partial THEN
      RAISE EXCEPTION 'Transfer still contains uncaptured required lines' USING ERRCODE = '22023';
    END IF;

    v_operation_id := public.phase4_create_operation(
      v_doc.company_id, v_actor, 'TRANSFER_RECEIVE', p_client_command_id, v_fingerprint,
      'TRANSFER', v_doc.id
    );

    FOR v_line IN
      SELECT * FROM inventory_transfer_lines
      WHERE company_id = v_doc.company_id AND transfer_id = v_doc.id
        AND line_status <> 'CANCELLED'
      ORDER BY line_number FOR UPDATE
    LOOP
      IF v_line.line_status = 'OPEN' THEN CONTINUE; END IF;
      v_delta := v_line.captured_received_base_quantity - v_line.posted_base_quantity;
      IF v_delta < 0 THEN RAISE EXCEPTION 'Transfer line posted quantity exceeds captured quantity' USING ERRCODE = '23514'; END IF;
      IF v_delta = 0 THEN CONTINUE; END IF;

      -- Condition/identity exceptions cannot safely be posted without a disposition quantity model.
      IF v_line.exception_code IS NOT NULL
         AND upper(v_line.exception_code) NOT IN ('SHORTAGE', 'SHORT_RECEIPT') THEN
        RAISE EXCEPTION 'Transfer exception % requires explicit disposition before stock posting', v_line.exception_code USING ERRCODE = '22023';
      END IF;

      SELECT * INTO v_transit
      FROM inventory_transit_lots
      WHERE company_id = v_doc.company_id
        AND transfer_line_id = v_line.id
        AND status IN ('IN_TRANSIT', 'PARTIALLY_RECEIVED')
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'No authoritative in-transit custody exists for transfer line %', v_line.id USING ERRCODE = '22023';
      END IF;

      v_transit_remaining := v_transit.base_quantity - v_transit.received_base_quantity - v_transit.lost_base_quantity;
      IF v_delta > v_transit_remaining THEN
        RAISE EXCEPTION 'Receipt exceeds authoritative in-transit quantity for transfer line %', v_line.id USING ERRCODE = '23514';
      END IF;

      v_movement_id := public.phase4_apply_document_movement(
        v_doc.company_id, v_actor, v_operation_id, v_server_command_id, p_client_command_id,
        v_line.product_id, 'TRANSFER_IN',
        NULL, NULL,
        v_doc.destination_location_id, v_line.destination_bin_id,
        NULL, 'AVAILABLE',
        v_delta, v_line.entered_unit_id,
        'TRANSFER', v_doc.id, v_doc.reference_number,
        v_line.id, NULL, NULL,
        COALESCE(v_line.client_recorded_at, p_client_recorded_at),
        v_line.exception_code, v_line.exception_notes, NULL
      );

      v_new_received := v_transit.received_base_quantity + v_delta;
      UPDATE inventory_transit_lots
      SET received_base_quantity = v_new_received,
          status = CASE
            WHEN v_new_received + lost_base_quantity >= base_quantity THEN 'RECEIVED'::transit_status
            ELSE 'PARTIALLY_RECEIVED'::transit_status
          END,
          transit_revision = transit_revision + 1,
          completed_at = CASE WHEN v_new_received + lost_base_quantity >= base_quantity THEN now() ELSE completed_at END,
          updated_at = now()
      WHERE id = v_transit.id;

      UPDATE inventory_transfer_lines
      SET posted_base_quantity = posted_base_quantity + v_delta,
          line_status = CASE
            WHEN posted_base_quantity + v_delta >= expected_base_quantity AND exception_code IS NULL THEN 'POSTED'::warehouse_document_line_status
            ELSE line_status
          END,
          revision = revision + 1,
          updated_at = now()
      WHERE id = v_line.id;

      v_line_results := v_line_results || jsonb_build_array(jsonb_build_object(
        'line_id', v_line.id,
        'received_base_quantity', v_delta,
        'movement_id', v_movement_id,
        'transit_lot_id', v_transit.id
      ));
    END LOOP;

    IF jsonb_array_length(v_line_results) = 0 THEN
      RAISE EXCEPTION 'Transfer has no unposted captured receipt quantity' USING ERRCODE = '22023';
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM inventory_transfer_lines
      WHERE company_id = v_doc.company_id AND transfer_id = v_doc.id
        AND line_status <> 'CANCELLED'
        AND (posted_base_quantity < expected_base_quantity OR exception_code IS NOT NULL)
    ) INTO v_has_unresolved;

    UPDATE inventory_transfer_documents
    SET status = CASE WHEN v_has_unresolved THEN 'PARTIAL'::warehouse_document_status ELSE 'COMPLETED'::warehouse_document_status END,
        revision = revision + 1,
        updated_at = now()
    WHERE id = v_doc.id;

    UPDATE inventory_operations SET status = 'COMPLETED', posted_at = now() WHERE id = v_operation_id;

    v_result := jsonb_build_object(
      'success', true,
      'outcome', 'accepted',
      'client_command_id', p_client_command_id,
      'server_command_id', v_server_command_id,
      'operation_id', v_operation_id,
      'document_id', v_doc.id,
      'document_revision', v_doc.revision + 1,
      'document_status', CASE WHEN v_has_unresolved THEN 'PARTIAL' ELSE 'COMPLETED' END,
      'lines', v_line_results
    );
    PERFORM public.phase4_store_command_result(v_server_command_id, 'COMPLETED', v_result, NULL, NULL, v_operation_id);
    RETURN v_result;
  EXCEPTION WHEN OTHERS THEN
    v_result := public.phase4_error_outcome(SQLSTATE, SQLERRM, v_server_command_id, p_client_command_id);
    PERFORM public.phase4_store_command_result(
      v_server_command_id, public.phase4_error_status(SQLSTATE), v_result, SQLSTATE, SQLERRM, NULL
    );
    RETURN v_result;
  END;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Atomic sales dispatch: reservation + stock + movements + document state.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_sales_order(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
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
  v_res inventory_reservations%ROWTYPE;
  v_begin JSONB;
  v_server_command_id UUID;
  v_fingerprint TEXT;
  v_operation_id UUID;
  v_delta NUMERIC;
  v_current NUMERIC;
  v_total_reserved NUMERIC;
  v_own_reserved NUMERIC;
  v_to_fulfill NUMERIC;
  v_take NUMERIC;
  v_remaining_res NUMERIC;
  v_movement_id UUID;
  v_line_results JSONB := '[]'::jsonb;
  v_result JSONB;
  v_state TEXT;
  v_has_backorder BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Authenticated operational profile required');
  END IF;

  SELECT * INTO v_doc FROM inventory_sales_orders WHERE id = p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Sales order is not available to the authenticated company');
  END IF;

  v_begin := public.phase4_begin_document_command(
    v_doc.company_id, v_actor, 'SALES_DISPATCH', p_client_command_id,
    p_document_id, p_expected_revision, '{}'::jsonb, p_client_recorded_at
  );
  v_state := v_begin->>'state';
  IF v_state <> 'NEW' THEN RETURN public.phase4_duplicate_result(v_begin, p_client_command_id); END IF;
  v_server_command_id := (v_begin->>'server_command_id')::uuid;
  v_fingerprint := v_begin->>'request_fingerprint';

  BEGIN
    SELECT * INTO v_doc FROM inventory_sales_orders WHERE id = p_document_id FOR UPDATE;
    IF v_doc.revision <> p_expected_revision THEN RAISE EXCEPTION 'Sales-order revision conflict' USING ERRCODE = '40001'; END IF;
    IF v_doc.status IN ('COMPLETED', 'CANCELLED') THEN RAISE EXCEPTION 'Sales order is not dispatchable in its current state' USING ERRCODE = '22023'; END IF;
    IF NOT public.has_warehouse_permission(v_doc.source_location_id, 'inventory.dispatch') THEN RAISE EXCEPTION 'Dispatch permission required' USING ERRCODE = '42501'; END IF;
    IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Sales order is assigned to another user' USING ERRCODE = '42501'; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM inventory_locations l
      WHERE l.company_id = v_doc.company_id AND l.id = v_doc.source_location_id
        AND l.is_active AND l.allow_direct_sales
    ) THEN RAISE EXCEPTION 'Sales dispatch is not allowed from this warehouse' USING ERRCODE = '42501'; END IF;

    -- Final dispatch requires every non-cancelled line to account for its full request.
    IF EXISTS (
      SELECT 1 FROM inventory_sales_order_lines l
      WHERE l.company_id = v_doc.company_id AND l.sales_order_id = v_doc.id
        AND l.line_status <> 'CANCELLED'
        AND l.captured_picked_base_quantity + l.backordered_base_quantity <> l.requested_base_quantity
    ) THEN
      RAISE EXCEPTION 'Sales order contains unresolved requested quantity; capture or backorder every line before dispatch' USING ERRCODE = '22023';
    END IF;

    v_operation_id := public.phase4_create_operation(
      v_doc.company_id, v_actor, 'SALES_DISPATCH', p_client_command_id, v_fingerprint,
      'SALES_ORDER', v_doc.id
    );

    FOR v_line IN
      SELECT * FROM inventory_sales_order_lines
      WHERE company_id = v_doc.company_id AND sales_order_id = v_doc.id
        AND line_status <> 'CANCELLED'
      ORDER BY line_number FOR UPDATE
    LOOP
      v_delta := v_line.captured_picked_base_quantity - v_line.posted_base_quantity;
      IF v_delta < 0 THEN RAISE EXCEPTION 'Sales-order posted quantity exceeds captured quantity' USING ERRCODE = '23514'; END IF;

      -- A reservation linked to this authoritative line may be warehouse-level
      -- (bin_id NULL) or belong to the line's authoritative source bin. Anything
      -- else is contradictory provenance and must fail closed before fulfillment.
      IF EXISTS (
        SELECT 1 FROM inventory_reservations r
        WHERE r.company_id = v_doc.company_id
          AND r.sales_order_line_id = v_line.id
          AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')
          AND r.bin_id IS NOT NULL
          AND r.bin_id <> v_line.source_bin_id
      ) THEN
        RAISE EXCEPTION 'Reservation bin does not match authoritative sales-order line' USING ERRCODE = '23514';
      END IF;

      -- Lock all reservations touching this physical position, then protect other documents' reservations.
      PERFORM 1 FROM inventory_reservations r
      WHERE r.company_id = v_doc.company_id
        AND r.location_id = v_doc.source_location_id
        AND (r.bin_id = v_line.source_bin_id OR r.bin_id IS NULL)
        AND r.product_id = v_line.product_id
        AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')
      ORDER BY r.id FOR UPDATE;

      SELECT
        COALESCE(sum(r.reserved_base_qty - r.fulfilled_base_qty - r.released_base_qty), 0),
        COALESCE(sum(r.reserved_base_qty - r.fulfilled_base_qty - r.released_base_qty)
          FILTER (WHERE r.sales_order_line_id = v_line.id), 0)
      INTO v_total_reserved, v_own_reserved
      FROM inventory_reservations r
      WHERE r.company_id = v_doc.company_id
        AND r.location_id = v_doc.source_location_id
        AND (r.bin_id = v_line.source_bin_id OR r.bin_id IS NULL)
        AND r.product_id = v_line.product_id
        AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED');

      IF v_delta > 0 THEN
        INSERT INTO inventory_balances (
          company_id, location_id, bin_id, product_id, inventory_status,
          on_hand_base_qty, reserved_base_qty, physical_status_revision
        ) VALUES (
          v_doc.company_id, v_doc.source_location_id, v_line.source_bin_id, v_line.product_id, 'AVAILABLE', 0, 0, 1
        ) ON CONFLICT (company_id, location_id, bin_id, product_id, inventory_status) DO NOTHING;

        SELECT on_hand_base_qty INTO v_current
        FROM inventory_balances
        WHERE company_id = v_doc.company_id AND location_id = v_doc.source_location_id
          AND bin_id = v_line.source_bin_id AND product_id = v_line.product_id
          AND inventory_status = 'AVAILABLE'
        FOR UPDATE;

        IF v_current - v_delta < GREATEST(v_total_reserved - v_own_reserved, 0) THEN
          RAISE EXCEPTION 'Dispatch would consume inventory reserved for another order' USING ERRCODE = '23514';
        END IF;

        v_movement_id := public.phase4_apply_document_movement(
          v_doc.company_id, v_actor, v_operation_id, v_server_command_id, p_client_command_id,
          v_line.product_id, 'SALE',
          v_doc.source_location_id, v_line.source_bin_id,
          NULL, NULL, 'AVAILABLE', NULL,
          v_delta, v_line.entered_unit_id,
          'SALES_ORDER', v_doc.id, v_doc.reference_number,
          NULL, v_line.id, NULL,
          COALESCE(v_line.client_recorded_at, p_client_recorded_at),
          v_line.exception_code, v_line.exception_notes, NULL
        );

        -- Fulfill this line's reservations deterministically.
        v_to_fulfill := v_delta;
        FOR v_res IN
          SELECT * FROM inventory_reservations r
          WHERE r.company_id = v_doc.company_id
            AND r.sales_order_line_id = v_line.id
            AND (r.bin_id = v_line.source_bin_id OR r.bin_id IS NULL)
            AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')
          ORDER BY r.created_at, r.id FOR UPDATE
        LOOP
          EXIT WHEN v_to_fulfill <= 0;
          v_remaining_res := v_res.reserved_base_qty - v_res.fulfilled_base_qty - v_res.released_base_qty;
          v_take := LEAST(v_to_fulfill, v_remaining_res);
          UPDATE inventory_reservations
          SET fulfilled_base_qty = fulfilled_base_qty + v_take,
              status = CASE
                WHEN fulfilled_base_qty + released_base_qty + v_take >= reserved_base_qty THEN 'FULFILLED'::reservation_status
                ELSE 'PARTIALLY_FULFILLED'::reservation_status
              END,
              reservation_revision = reservation_revision + 1,
              updated_at = now()
          WHERE id = v_res.id;
          v_to_fulfill := v_to_fulfill - v_take;
        END LOOP;
      ELSE
        v_movement_id := NULL;
      END IF;

      UPDATE inventory_sales_order_lines
      SET posted_base_quantity = posted_base_quantity + v_delta,
          line_status = CASE
            WHEN posted_base_quantity + v_delta + backordered_base_quantity >= requested_base_quantity
              THEN CASE WHEN backordered_base_quantity > 0 THEN 'BACKORDERED'::warehouse_document_line_status ELSE 'POSTED'::warehouse_document_line_status END
            ELSE line_status
          END,
          revision = revision + 1,
          updated_at = now()
      WHERE id = v_line.id;

      -- Once the line is fully accounted for, release any reservation remainder.
      IF v_line.posted_base_quantity + v_delta + v_line.backordered_base_quantity >= v_line.requested_base_quantity THEN
        UPDATE inventory_reservations r
        SET released_base_qty = released_base_qty + (reserved_base_qty - fulfilled_base_qty - released_base_qty),
            status = CASE
              WHEN fulfilled_base_qty >= reserved_base_qty THEN 'FULFILLED'::reservation_status
              ELSE 'RELEASED'::reservation_status
            END,
            reservation_revision = reservation_revision + 1,
            updated_at = now()
        WHERE r.company_id = v_doc.company_id
          AND r.sales_order_line_id = v_line.id
          AND (r.bin_id = v_line.source_bin_id OR r.bin_id IS NULL)
          AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')
          AND reserved_base_qty - fulfilled_base_qty - released_base_qty > 0;
      END IF;

      v_line_results := v_line_results || jsonb_build_array(jsonb_build_object(
        'line_id', v_line.id,
        'dispatched_base_quantity', v_delta,
        'movement_id', v_movement_id,
        'backordered_base_quantity', v_line.backordered_base_quantity
      ));
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_line_results) e WHERE COALESCE((e->>'dispatched_base_quantity')::numeric, 0) > 0)
       AND NOT EXISTS (
         SELECT 1 FROM inventory_sales_order_lines l
         WHERE l.company_id = v_doc.company_id AND l.sales_order_id = v_doc.id AND l.backordered_base_quantity > 0
       ) THEN
      RAISE EXCEPTION 'Sales order has no unposted dispatch or backorder outcome' USING ERRCODE = '22023';
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM inventory_sales_order_lines l
      WHERE l.company_id = v_doc.company_id AND l.sales_order_id = v_doc.id
        AND l.backordered_base_quantity > 0
    ) INTO v_has_backorder;

    UPDATE inventory_sales_orders
    SET status = CASE WHEN v_has_backorder THEN 'PARTIAL'::warehouse_document_status ELSE 'COMPLETED'::warehouse_document_status END,
        revision = revision + 1,
        updated_at = now()
    WHERE id = v_doc.id;

    UPDATE inventory_operations SET status = 'COMPLETED', posted_at = now() WHERE id = v_operation_id;

    v_result := jsonb_build_object(
      'success', true,
      'outcome', 'accepted',
      'client_command_id', p_client_command_id,
      'server_command_id', v_server_command_id,
      'operation_id', v_operation_id,
      'document_id', v_doc.id,
      'document_revision', v_doc.revision + 1,
      'document_status', CASE WHEN v_has_backorder THEN 'PARTIAL' ELSE 'COMPLETED' END,
      'lines', v_line_results
    );
    PERFORM public.phase4_store_command_result(v_server_command_id, 'COMPLETED', v_result, NULL, NULL, v_operation_id);
    RETURN v_result;
  EXCEPTION WHEN OTHERS THEN
    v_result := public.phase4_error_outcome(SQLSTATE, SQLERRM, v_server_command_id, p_client_command_id);
    PERFORM public.phase4_store_command_result(
      v_server_command_id, public.phase4_error_status(SQLSTATE), v_result, SQLSTATE, SQLERRM, NULL
    );
    RETURN v_result;
  END;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Atomic count finalization: approved observation -> explicit variance movement.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finalize_count_session(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
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
  v_obs inventory_count_observations%ROWTYPE;
  v_approval inventory_count_approvals%ROWTYPE;
  v_begin JSONB;
  v_server_command_id UUID;
  v_fingerprint TEXT;
  v_operation_id UUID;
  v_current_physical NUMERIC;
  v_current_revision BIGINT;
  v_variance NUMERIC;
  v_movement_id UUID;
  v_line_results JSONB := '[]'::jsonb;
  v_result JSONB;
  v_state TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Authenticated operational profile required');
  END IF;

  SELECT * INTO v_session FROM inventory_count_sessions WHERE id = p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_session.company_id) THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Count session is not available to the authenticated company');
  END IF;

  v_begin := public.phase4_begin_document_command(
    v_session.company_id, v_actor, 'COUNT_FINALIZE', p_client_command_id,
    p_document_id, p_expected_revision, '{}'::jsonb, p_client_recorded_at
  );
  v_state := v_begin->>'state';
  IF v_state <> 'NEW' THEN RETURN public.phase4_duplicate_result(v_begin, p_client_command_id); END IF;
  v_server_command_id := (v_begin->>'server_command_id')::uuid;
  v_fingerprint := v_begin->>'request_fingerprint';

  BEGIN
    SELECT * INTO v_session FROM inventory_count_sessions WHERE id = p_document_id FOR UPDATE;
    IF v_session.revision <> p_expected_revision THEN RAISE EXCEPTION 'Count-session revision conflict' USING ERRCODE = '40001'; END IF;
    IF v_session.status IN ('COMPLETED', 'CANCELLED') THEN RAISE EXCEPTION 'Count session is not finalizable in its current state' USING ERRCODE = '22023'; END IF;
    IF NOT public.has_warehouse_permission(v_session.location_id, 'inventory.count') THEN RAISE EXCEPTION 'Count permission required' USING ERRCODE = '42501'; END IF;
    IF v_session.assigned_profile_id IS NOT NULL AND v_session.assigned_profile_id <> v_actor
       AND NOT public.has_warehouse_permission(v_session.location_id, 'inventory.count.approve') THEN
      RAISE EXCEPTION 'Count session is assigned to another user' USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
      SELECT 1 FROM inventory_count_lines l
      WHERE l.company_id = v_session.company_id AND l.count_session_id = v_session.id
        AND l.line_status NOT IN ('READY_TO_POST', 'APPROVED', 'FINALIZED', 'CANCELLED')
    ) THEN
      RAISE EXCEPTION 'Count session contains unresolved or unapproved lines' USING ERRCODE = '22023';
    END IF;

    v_operation_id := public.phase4_create_operation(
      v_session.company_id, v_actor, 'COUNT_FINALIZE', p_client_command_id, v_fingerprint,
      'COUNT_SESSION', v_session.id
    );

    FOR v_line IN
      SELECT * FROM inventory_count_lines
      WHERE company_id = v_session.company_id AND count_session_id = v_session.id
        AND line_status NOT IN ('FINALIZED', 'CANCELLED')
      ORDER BY line_number FOR UPDATE
    LOOP
      SELECT * INTO v_obs
      FROM inventory_count_observations o
      WHERE o.company_id = v_session.company_id AND o.count_line_id = v_line.id
      ORDER BY o.attempt_number DESC LIMIT 1;
      IF NOT FOUND THEN RAISE EXCEPTION 'Count line has no authoritative observation' USING ERRCODE = '22023'; END IF;

      v_variance := v_obs.variance_base_quantity;
      IF v_variance <> 0 THEN
        SELECT * INTO v_approval
        FROM inventory_count_approvals a
        WHERE a.company_id = v_session.company_id AND a.observation_id = v_obs.id;
        IF NOT FOUND OR v_approval.decision <> 'APPROVED' THEN
          RAISE EXCEPTION 'Count variance has not been approved' USING ERRCODE = '22023';
        END IF;
      ELSE
        v_approval.id := NULL;
        v_approval.decided_by := NULL;
      END IF;

      -- Lock all status buckets and verify the physical snapshot did not move since observation assignment.
      PERFORM 1 FROM inventory_balances b
      WHERE b.company_id = v_session.company_id
        AND b.location_id = v_session.location_id
        AND b.bin_id = v_line.bin_id
        AND b.product_id = v_line.product_id
      ORDER BY b.inventory_status FOR UPDATE;

      SELECT COALESCE(sum(b.on_hand_base_qty), 0), COALESCE(max(b.physical_status_revision), 1)
      INTO v_current_physical, v_current_revision
      FROM inventory_balances b
      WHERE b.company_id = v_session.company_id
        AND b.location_id = v_session.location_id
        AND b.bin_id = v_line.bin_id
        AND b.product_id = v_line.product_id;

      IF v_current_physical <> v_obs.expected_snapshot_base_quantity
         OR v_current_revision <> v_obs.expected_physical_revision THEN
        RAISE EXCEPTION 'Count physical snapshot changed after assignment; recount required' USING ERRCODE = '40001';
      END IF;

      v_movement_id := NULL;
      IF v_variance > 0 THEN
        v_movement_id := public.phase4_apply_document_movement(
          v_session.company_id, v_actor, v_operation_id, v_server_command_id, p_client_command_id,
          v_line.product_id, 'STOCK_COUNT_VARIANCE_IN',
          NULL, NULL, v_session.location_id, v_line.bin_id,
          NULL, 'AVAILABLE', v_variance, v_line.base_unit_id,
          'COUNT_SESSION', v_session.id, v_session.reference_number,
          NULL, NULL, v_line.id,
          v_obs.client_recorded_at, v_obs.reason_code, v_obs.notes, v_approval.decided_by
        );
      ELSIF v_variance < 0 THEN
        v_movement_id := public.phase4_apply_document_movement(
          v_session.company_id, v_actor, v_operation_id, v_server_command_id, p_client_command_id,
          v_line.product_id, 'STOCK_COUNT_VARIANCE_OUT',
          v_session.location_id, v_line.bin_id, NULL, NULL,
          'AVAILABLE', NULL, abs(v_variance), v_line.base_unit_id,
          'COUNT_SESSION', v_session.id, v_session.reference_number,
          NULL, NULL, v_line.id,
          v_obs.client_recorded_at, v_obs.reason_code, v_obs.notes, v_approval.decided_by
        );
      END IF;

      UPDATE inventory_count_lines
      SET posted_variance_base_quantity = v_variance,
          line_status = 'FINALIZED',
          revision = revision + 1,
          updated_at = now()
      WHERE id = v_line.id;

      v_line_results := v_line_results || jsonb_build_array(jsonb_build_object(
        'line_id', v_line.id,
        'observation_id', v_obs.id,
        'variance_base_quantity', v_variance,
        'movement_id', v_movement_id
      ));
    END LOOP;

    IF jsonb_array_length(v_line_results) = 0 THEN
      RAISE EXCEPTION 'Count session has no unfinalized lines' USING ERRCODE = '22023';
    END IF;

    UPDATE inventory_count_sessions
    SET status = 'COMPLETED', revision = revision + 1, updated_at = now()
    WHERE id = v_session.id;

    UPDATE inventory_operations SET status = 'COMPLETED', posted_at = now() WHERE id = v_operation_id;

    v_result := jsonb_build_object(
      'success', true,
      'outcome', 'accepted',
      'client_command_id', p_client_command_id,
      'server_command_id', v_server_command_id,
      'operation_id', v_operation_id,
      'document_id', v_session.id,
      'document_revision', v_session.revision + 1,
      'document_status', 'COMPLETED',
      'lines', v_line_results
    );
    PERFORM public.phase4_store_command_result(v_server_command_id, 'COMPLETED', v_result, NULL, NULL, v_operation_id);
    RETURN v_result;
  EXCEPTION WHEN OTHERS THEN
    v_result := public.phase4_error_outcome(SQLSTATE, SQLERRM, v_server_command_id, p_client_command_id);
    PERFORM public.phase4_store_command_result(
      v_server_command_id, public.phase4_error_status(SQLSTATE), v_result, SQLSTATE, SQLERRM, NULL
    );
    RETURN v_result;
  END;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Disable generic document stock posting; preserve only non-document adjustments.
-- ---------------------------------------------------------------------------
ALTER FUNCTION public.post_inventory_operation(JSONB)
  RENAME TO post_inventory_operation_phase2_compat;

REVOKE ALL ON FUNCTION public.post_inventory_operation_phase2_compat(JSONB) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.post_inventory_operation(p_operation JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_type TEXT := p_operation->>'operation_type';
BEGIN
  IF v_type IN ('RECEIPT', 'DISPATCH', 'COUNT') THEN
    RAISE EXCEPTION 'Document workflow % must use the Phase 4 authoritative document command', v_type
      USING ERRCODE = '0A000';
  END IF;
  RETURN public.post_inventory_operation_phase2_compat(p_operation);
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. RLS / privileges and internal helper lockdown.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_document_commands ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS inventory_document_commands_select_authorized ON inventory_document_commands;
CREATE POLICY inventory_document_commands_select_authorized ON inventory_document_commands
FOR SELECT TO authenticated
USING (
  public.is_company_member(company_id)
  AND initiating_actor = public.current_profile_id()
);

REVOKE ALL PRIVILEGES ON TABLE inventory_document_commands FROM anon, authenticated;
GRANT SELECT ON TABLE inventory_document_commands TO authenticated;

REVOKE ALL ON FUNCTION public.phase4_command_fingerprint(document_command_type, UUID, BIGINT, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase4_begin_document_command(UUID, UUID, document_command_type, UUID, UUID, BIGINT, JSONB, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase4_duplicate_result(JSONB, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase4_store_command_result(UUID, document_command_status, JSONB, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase4_error_outcome(TEXT, TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase4_error_status(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase4_create_operation(UUID, UUID, document_command_type, UUID, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase4_apply_document_movement(UUID, UUID, UUID, UUID, UUID, UUID, movement_type, UUID, UUID, UUID, UUID, inventory_status, inventory_status, NUMERIC, UUID, TEXT, UUID, TEXT, UUID, UUID, UUID, TIMESTAMPTZ, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.post_inventory_operation_phase2_compat(JSONB) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.ship_transfer_document(UUID, BIGINT, UUID, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ship_transfer_document(UUID, BIGINT, UUID, TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.receive_transfer_document(UUID, BIGINT, UUID, BOOLEAN, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_transfer_document(UUID, BIGINT, UUID, BOOLEAN, TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.dispatch_sales_order(UUID, BIGINT, UUID, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dispatch_sales_order(UUID, BIGINT, UUID, TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.finalize_count_session(UUID, BIGINT, UUID, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalize_count_session(UUID, BIGINT, UUID, TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.post_inventory_operation(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_inventory_operation(JSONB) TO authenticated;

COMMENT ON TABLE inventory_document_commands IS
  'Phase 4 stable document-command/idempotency ledger. Unique company+client_command_id is the authoritative retry boundary.';
COMMENT ON FUNCTION public.dispatch_sales_order(UUID, BIGINT, UUID, TIMESTAMPTZ) IS
  'Atomically posts all authoritative captured/backordered sales-order lines, protects other reservations, fulfills/releases own reservations, appends SALE movements, and advances document state.';
COMMENT ON FUNCTION public.receive_transfer_document(UUID, BIGINT, UUID, BOOLEAN, TIMESTAMPTZ) IS
  'Atomically converts authoritative transit custody into destination on-hand using only unposted captured receipt deltas.';
COMMENT ON FUNCTION public.finalize_count_session(UUID, BIGINT, UUID, TIMESTAMPTZ) IS
  'Atomically applies only approved/revision-safe count variance and finalizes authoritative count lines.';

-- Application-facing command status lookup for durable retry/sync reconciliation.
CREATE OR REPLACE FUNCTION public.get_document_command_result(
  p_company_id UUID,
  p_client_command_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_command inventory_document_commands%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.is_company_member(p_company_id) THEN
    RAISE EXCEPTION 'Authenticated company membership required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_command
  FROM inventory_document_commands c
  WHERE c.company_id = p_company_id
    AND c.client_command_id = p_client_command_id
    AND c.initiating_actor = v_actor
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'client_command_id', v_command.client_command_id,
    'server_command_id', v_command.id,
    'command_type', v_command.command_type,
    'document_id', v_command.source_document_id,
    'status', v_command.status,
    'result', v_command.result_payload,
    'error_code', v_command.error_code,
    'error_message', v_command.error_message,
    'created_at', v_command.created_at,
    'completed_at', v_command.completed_at
  );
END;
$$;

-- Phase 4 transfer read adds explicit shipped progress and allows either source-dispatch
-- or destination-receive operators to inspect the authoritative transfer.
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
  IF v_actor IS NULL OR NOT (
    public.has_warehouse_permission(v_doc.destination_location_id, 'inventory.receive')
    OR public.has_warehouse_permission(v_doc.source_location_id, 'inventory.dispatch')
  ) THEN RAISE EXCEPTION 'Transfer warehouse permission required' USING ERRCODE = '42501'; END IF;
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
      'shipped_base_quantity', l.shipped_base_quantity,
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

REVOKE ALL ON FUNCTION public.get_document_command_result(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_document_command_result(UUID, UUID) TO authenticated;
-- get_transfer_document was already app-facing in Phase 3; reassert its grant after replacement.
REVOKE ALL ON FUNCTION public.get_transfer_document(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_transfer_document(UUID) TO authenticated;
