-- Phase 5: append-only ledger, validated partial/full reversals, and controlled corrections.
-- Preserves Phase 1-4 trust, stock, document, and atomic-command invariants.

-- ---------------------------------------------------------------------------
-- 1. Separate correction-command ledger using Phase 4 typed command statuses.
-- ---------------------------------------------------------------------------
CREATE TABLE inventory_ledger_commands (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  client_command_id UUID NOT NULL,
  command_type TEXT NOT NULL DEFAULT 'MOVEMENT_REVERSAL'
    CHECK (command_type = 'MOVEMENT_REVERSAL'),
  source_movement_id UUID NOT NULL,
  requested_base_quantity NUMERIC(28, 6) NOT NULL CHECK (requested_base_quantity > 0),
  request_fingerprint TEXT NOT NULL,
  initiating_actor UUID NOT NULL,
  reason_code TEXT NOT NULL CHECK (btrim(reason_code) <> ''),
  reason_text TEXT NOT NULL CHECK (btrim(reason_text) <> ''),
  status document_command_status NOT NULL DEFAULT 'PROCESSING',
  operation_id UUID REFERENCES inventory_operations(id),
  result_payload JSONB,
  error_code TEXT,
  error_message TEXT,
  client_recorded_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, client_command_id),
  UNIQUE (company_id, id)
);

ALTER TABLE inventory_ledger_commands
  ADD CONSTRAINT inventory_ledger_commands_actor_fk
  FOREIGN KEY (company_id, initiating_actor)
  REFERENCES company_memberships(company_id, profile_id);

CREATE UNIQUE INDEX IF NOT EXISTS inventory_movements_company_movement_unique_idx
  ON inventory_movements(company_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS inventory_movements_company_product_movement_unique_idx
  ON inventory_movements(company_id, product_id, id);

ALTER TABLE inventory_ledger_commands
  ADD CONSTRAINT inventory_ledger_commands_source_movement_fk
  FOREIGN KEY (company_id, source_movement_id)
  REFERENCES inventory_movements(company_id, id);

CREATE INDEX inventory_ledger_commands_source_idx
  ON inventory_ledger_commands(company_id, source_movement_id, created_at DESC);

-- Every reversal movement points to the correction command that authorized it.
ALTER TABLE inventory_movements
  ADD COLUMN IF NOT EXISTS ledger_command_id UUID;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_ledger_command_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_ledger_command_fk
  FOREIGN KEY (company_id, ledger_command_id)
  REFERENCES inventory_ledger_commands(company_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_ledger_command_fk;

-- Replace the legacy unvalidated UUID reference with a tenant+product-safe relationship.
ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_reversal_original_fk;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_reversal_original_fk
  FOREIGN KEY (company_id, product_id, reversal_of_movement_id)
  REFERENCES inventory_movements(company_id, product_id, id)
  NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_reversal_original_fk;

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_reversal_not_self;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_reversal_not_self
  CHECK (reversal_of_movement_id IS NULL OR reversal_of_movement_id <> id) NOT VALID;
ALTER TABLE inventory_movements VALIDATE CONSTRAINT inventory_movements_reversal_not_self;

CREATE INDEX IF NOT EXISTS inventory_movements_reversal_lookup_idx
  ON inventory_movements(company_id, reversal_of_movement_id, posted_at)
  WHERE reversal_of_movement_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Append-only ledger enforcement. Historical movement rows are never edited.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.inventory_movement_append_only_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'inventory_movements is append-only; use an authorized correction/reversal command'
    USING ERRCODE = '0A000';
END;
$$;

DROP TRIGGER IF EXISTS inventory_movements_append_only_trigger ON inventory_movements;
CREATE TRIGGER inventory_movements_append_only_trigger
BEFORE UPDATE OR DELETE ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION public.inventory_movement_append_only_guard();

-- ---------------------------------------------------------------------------
-- 3. Structural reversal helpers and downstream-activity rule.
-- A generic movement reversal is intentionally forbidden for document-linked
-- movements; those require document-specific correction semantics so document
-- state, reservations/transit/count evidence cannot diverge from the ledger.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.phase5_expected_reversal_type(p_original movement_type)
RETURNS movement_type
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN CASE p_original
    WHEN 'SALE' THEN 'SALE_REVERSAL'::movement_type
    WHEN 'STOCK_ADJUSTMENT_IN' THEN 'STOCK_ADJUSTMENT_OUT'::movement_type
    WHEN 'STOCK_ADJUSTMENT_OUT' THEN 'STOCK_ADJUSTMENT_IN'::movement_type
    WHEN 'STOCK_COUNT_VARIANCE_IN' THEN 'STOCK_COUNT_VARIANCE_OUT'::movement_type
    WHEN 'STOCK_COUNT_VARIANCE_OUT' THEN 'STOCK_COUNT_VARIANCE_IN'::movement_type
    WHEN 'CUSTOMER_RETURN' THEN 'STOCK_ADJUSTMENT_OUT'::movement_type
    WHEN 'PURCHASE_RECEIPT' THEN 'STOCK_ADJUSTMENT_OUT'::movement_type
    WHEN 'OPENING_BALANCE' THEN 'STOCK_ADJUSTMENT_OUT'::movement_type
    WHEN 'EXPIRY' THEN 'STOCK_ADJUSTMENT_IN'::movement_type
    WHEN 'DAMAGE' THEN 'STATUS_CHANGE'::movement_type
    WHEN 'STATUS_CHANGE' THEN 'STATUS_CHANGE'::movement_type
    ELSE NULL
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.phase5_has_downstream_activity(p_original_movement_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_original inventory_movements%ROWTYPE;
BEGIN
  SELECT * INTO v_original FROM inventory_movements WHERE id = p_original_movement_id;
  IF NOT FOUND THEN RETURN false; END IF;

  RETURN EXISTS (
    SELECT 1
    FROM inventory_movements later
    WHERE later.company_id = v_original.company_id
      AND later.product_id = v_original.product_id
      AND later.id <> v_original.id
      AND later.reversal_of_movement_id IS DISTINCT FROM v_original.id
      AND (later.created_at > v_original.created_at OR later.posted_at > v_original.posted_at)
      AND (
        (
          v_original.source_location_id IS NOT NULL
          AND (
            (later.source_location_id = v_original.source_location_id
             AND later.source_bin_id = v_original.source_bin_id
             AND later.source_inventory_status = v_original.source_inventory_status)
            OR
            (later.destination_location_id = v_original.source_location_id
             AND later.destination_bin_id = v_original.source_bin_id
             AND later.destination_inventory_status = v_original.source_inventory_status)
          )
        )
        OR
        (
          v_original.destination_location_id IS NOT NULL
          AND (
            (later.source_location_id = v_original.destination_location_id
             AND later.source_bin_id = v_original.destination_bin_id
             AND later.source_inventory_status = v_original.destination_inventory_status)
            OR
            (later.destination_location_id = v_original.destination_location_id
             AND later.destination_bin_id = v_original.destination_bin_id
             AND later.destination_inventory_status = v_original.destination_inventory_status)
          )
        )
      )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.phase5_validate_reversal_row()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_original inventory_movements%ROWTYPE;
  v_expected_type movement_type;
  v_reversed NUMERIC;
BEGIN
  IF NEW.reversal_of_movement_id IS NULL THEN RETURN NEW; END IF;

  SELECT * INTO v_original
  FROM inventory_movements
  WHERE id = NEW.reversal_of_movement_id
  FOR SHARE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Original movement does not exist' USING ERRCODE = '23503'; END IF;
  IF v_original.reversal_of_movement_id IS NOT NULL THEN
    RAISE EXCEPTION 'A reversal movement cannot itself be reversed by the generic reversal command' USING ERRCODE = '0A000';
  END IF;
  IF v_original.company_id <> NEW.company_id OR v_original.product_id <> NEW.product_id THEN
    RAISE EXCEPTION 'Reversal must remain in the original tenant and product' USING ERRCODE = '23514';
  END IF;
  IF NEW.ledger_command_id IS NULL THEN
    RAISE EXCEPTION 'A reversal movement requires an authoritative ledger command' USING ERRCODE = '23514';
  END IF;
  IF NEW.document_command_id IS NOT NULL OR NEW.transfer_line_id IS NOT NULL OR NEW.sales_order_line_id IS NOT NULL OR NEW.count_line_id IS NOT NULL THEN
    RAISE EXCEPTION 'Generic reversal rows cannot claim authoritative document-line provenance' USING ERRCODE = '23514';
  END IF;
  IF v_original.document_command_id IS NOT NULL OR v_original.transfer_line_id IS NOT NULL OR v_original.sales_order_line_id IS NOT NULL OR v_original.count_line_id IS NOT NULL THEN
    RAISE EXCEPTION 'Document-linked movement requires a document-specific correction command' USING ERRCODE = '0A000';
  END IF;

  v_expected_type := public.phase5_expected_reversal_type(v_original.movement_type);
  IF v_expected_type IS NULL OR NEW.movement_type <> v_expected_type THEN
    RAISE EXCEPTION 'Movement type is not safely reversible by the generic reversal command' USING ERRCODE = '0A000';
  END IF;

  IF public.phase5_has_downstream_activity(v_original.id) THEN
    RAISE EXCEPTION 'Movement has downstream activity on an affected inventory position' USING ERRCODE = '40001';
  END IF;

  SELECT COALESCE(sum(m.base_quantity), 0) INTO v_reversed
  FROM inventory_movements m
  WHERE m.company_id = v_original.company_id
    AND m.reversal_of_movement_id = v_original.id;
  IF v_reversed + NEW.base_quantity > v_original.base_quantity THEN
    RAISE EXCEPTION 'Reversal quantity exceeds remaining reversible quantity' USING ERRCODE = '23514';
  END IF;

  -- Exact inverse physical shape.
  IF v_original.source_location_id IS NOT NULL AND v_original.destination_location_id IS NULL THEN
    IF NEW.source_location_id IS NOT NULL
       OR NEW.destination_location_id IS DISTINCT FROM v_original.source_location_id
       OR NEW.destination_bin_id IS DISTINCT FROM v_original.source_bin_id
       OR NEW.destination_inventory_status IS DISTINCT FROM v_original.source_inventory_status THEN
      RAISE EXCEPTION 'Outbound reversal must return stock to the exact original source position' USING ERRCODE = '23514';
    END IF;
  ELSIF v_original.source_location_id IS NULL AND v_original.destination_location_id IS NOT NULL THEN
    IF NEW.destination_location_id IS NOT NULL
       OR NEW.source_location_id IS DISTINCT FROM v_original.destination_location_id
       OR NEW.source_bin_id IS DISTINCT FROM v_original.destination_bin_id
       OR NEW.source_inventory_status IS DISTINCT FROM v_original.destination_inventory_status THEN
      RAISE EXCEPTION 'Inbound reversal must remove stock from the exact original destination position' USING ERRCODE = '23514';
    END IF;
  ELSIF v_original.source_location_id IS NOT NULL AND v_original.destination_location_id IS NOT NULL THEN
    IF NEW.source_location_id IS DISTINCT FROM v_original.destination_location_id
       OR NEW.source_bin_id IS DISTINCT FROM v_original.destination_bin_id
       OR NEW.destination_location_id IS DISTINCT FROM v_original.source_location_id
       OR NEW.destination_bin_id IS DISTINCT FROM v_original.source_bin_id
       OR NEW.source_inventory_status IS DISTINCT FROM v_original.destination_inventory_status
       OR NEW.destination_inventory_status IS DISTINCT FROM v_original.source_inventory_status THEN
      RAISE EXCEPTION 'Internal/status reversal must exactly invert the original positions and statuses' USING ERRCODE = '23514';
    END IF;
  ELSE
    RAISE EXCEPTION 'Movement has no reversible physical shape' USING ERRCODE = '0A000';
  END IF;

  IF NEW.reason_code <> 'REVERSAL' OR NEW.reason_text IS NULL OR btrim(NEW.reason_text) = '' THEN
    RAISE EXCEPTION 'Reversal movement requires an explicit reason' USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_movements_reversal_validation_trigger ON inventory_movements;
CREATE TRIGGER inventory_movements_reversal_validation_trigger
BEFORE INSERT ON inventory_movements
FOR EACH ROW WHEN (NEW.reversal_of_movement_id IS NOT NULL)
EXECUTE FUNCTION public.phase5_validate_reversal_row();

-- ---------------------------------------------------------------------------
-- 4. Idempotent ledger-command helpers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.phase5_reversal_fingerprint(
  p_movement_id UUID,
  p_base_quantity NUMERIC,
  p_reason_text TEXT,
  p_client_recorded_at TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT md5(jsonb_build_object(
    'command_type', 'MOVEMENT_REVERSAL',
    'movement_id', p_movement_id::text,
    'base_quantity', trim_scale(p_base_quantity),
    'reason_text', btrim(COALESCE(p_reason_text, '')),
    'client_recorded_at', p_client_recorded_at
  )::text)
$$;

CREATE OR REPLACE FUNCTION public.phase5_begin_ledger_command(
  p_company_id UUID,
  p_actor UUID,
  p_client_command_id UUID,
  p_movement_id UUID,
  p_base_quantity NUMERIC,
  p_reason_text TEXT,
  p_client_recorded_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_fingerprint TEXT;
  v_id UUID;
  v_existing inventory_ledger_commands%ROWTYPE;
BEGIN
  IF p_client_command_id IS NULL OR p_movement_id IS NULL OR p_base_quantity IS NULL OR p_base_quantity <= 0 THEN
    RAISE EXCEPTION 'client command id, movement id, and positive reversal quantity are required' USING ERRCODE = '22023';
  END IF;
  IF p_client_recorded_at IS NULL THEN
    RAISE EXCEPTION 'client recorded timestamp is required' USING ERRCODE = '22023';
  END IF;
  IF p_reason_text IS NULL OR btrim(p_reason_text) = '' THEN
    RAISE EXCEPTION 'reversal reason is required' USING ERRCODE = '22023';
  END IF;

  v_fingerprint := public.phase5_reversal_fingerprint(p_movement_id, p_base_quantity, p_reason_text, p_client_recorded_at);

  INSERT INTO inventory_ledger_commands (
    company_id, client_command_id, source_movement_id, requested_base_quantity,
    request_fingerprint, initiating_actor, reason_code, reason_text, client_recorded_at
  ) VALUES (
    p_company_id, p_client_command_id, p_movement_id, p_base_quantity,
    v_fingerprint, p_actor, 'REVERSAL', btrim(p_reason_text), p_client_recorded_at
  )
  ON CONFLICT (company_id, client_command_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('state','NEW','server_command_id',v_id,'request_fingerprint',v_fingerprint);
  END IF;

  SELECT * INTO v_existing
  FROM inventory_ledger_commands
  WHERE company_id = p_company_id AND client_command_id = p_client_command_id
  FOR UPDATE;

  IF v_existing.request_fingerprint <> v_fingerprint
     OR v_existing.source_movement_id <> p_movement_id
     OR v_existing.initiating_actor <> p_actor THEN
    RETURN jsonb_build_object(
      'state','MISMATCH','server_command_id',v_existing.id,'status',v_existing.status,
      'error_code','IDEMPOTENCY_KEY_REUSED','error_message','client command id was already used for different immutable reversal content'
    );
  END IF;

  -- Match the Phase 4 idempotency contract: transient failures retry with the
  -- same stable command identity rather than generating a fresh correction.
  IF v_existing.status = 'TRANSIENT_ERROR' THEN
    UPDATE inventory_ledger_commands
    SET status='PROCESSING', result_payload=NULL, error_code=NULL, error_message=NULL,
        completed_at=NULL, updated_at=now()
    WHERE id=v_existing.id;
    RETURN jsonb_build_object(
      'state','NEW','server_command_id',v_existing.id,'request_fingerprint',v_fingerprint,
      'retrying_transient',true
    );
  END IF;

  RETURN jsonb_build_object(
    'state','EXISTING','server_command_id',v_existing.id,'status',v_existing.status,
    'result_payload',v_existing.result_payload,'error_code',v_existing.error_code,'error_message',v_existing.error_message
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.phase5_store_ledger_result(
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
  UPDATE inventory_ledger_commands
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

-- ---------------------------------------------------------------------------
-- 5. Public validated reversal command.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_inventory_movement(
  p_movement_id UUID,
  p_base_quantity NUMERIC,
  p_client_command_id UUID,
  p_reason_text TEXT,
  p_client_recorded_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_original inventory_movements%ROWTYPE;
  v_begin JSONB;
  v_server_command_id UUID;
  v_operation_id UUID;
  v_result JSONB;
  v_reversed NUMERIC;
  v_remaining NUMERIC;
  v_expected_type movement_type;
  v_source_location UUID;
  v_source_bin UUID;
  v_dest_location UUID;
  v_dest_bin UUID;
  v_source_status inventory_status;
  v_dest_status inventory_status;
  v_current NUMERIC;
  v_reserved NUMERIC := 0;
  v_base_unit UUID;
  v_reversal_id UUID;
  v_fingerprint TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;

  SELECT * INTO v_original FROM inventory_movements WHERE id = p_movement_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Movement not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT public.is_company_member(v_original.company_id) THEN RAISE EXCEPTION 'Company membership required' USING ERRCODE = '42501'; END IF;

  -- Require reversal permission at every physical position affected by the original.
  IF v_original.source_location_id IS NOT NULL AND NOT public.has_warehouse_permission(v_original.source_location_id, 'inventory.reverse') THEN
    RAISE EXCEPTION 'Reverse permission required at source warehouse' USING ERRCODE = '42501';
  END IF;
  IF v_original.destination_location_id IS NOT NULL AND NOT public.has_warehouse_permission(v_original.destination_location_id, 'inventory.reverse') THEN
    RAISE EXCEPTION 'Reverse permission required at destination warehouse' USING ERRCODE = '42501';
  END IF;

  v_begin := public.phase5_begin_ledger_command(
    v_original.company_id, v_actor, p_client_command_id, p_movement_id,
    p_base_quantity, p_reason_text, p_client_recorded_at
  );

  IF v_begin->>'state' = 'MISMATCH' THEN
    RETURN jsonb_build_object(
      'success',false,'outcome','validation_error','client_command_id',p_client_command_id,
      'server_command_id',v_begin->>'server_command_id','code','IDEMPOTENCY_KEY_REUSED',
      'message',v_begin->>'error_message'
    );
  END IF;
  IF v_begin->>'state' = 'EXISTING' THEN
    IF v_begin->>'status' = 'PROCESSING' THEN
      RETURN jsonb_build_object(
        'success',false,'outcome','processing','client_command_id',p_client_command_id,
        'server_command_id',v_begin->>'server_command_id','result',NULL,'code',NULL,
        'message','The matching reversal command is still being processed'
      );
    END IF;
    RETURN jsonb_build_object(
      'success',COALESCE((v_begin->'result_payload'->>'success')::boolean,false),
      'outcome','duplicate','original_outcome',COALESCE(v_begin->'result_payload'->>'outcome',lower(v_begin->>'status')),
      'client_command_id',p_client_command_id,'server_command_id',v_begin->>'server_command_id',
      'result',v_begin->'result_payload','code',v_begin->>'error_code','message',v_begin->>'error_message'
    );
  END IF;

  v_server_command_id := (v_begin->>'server_command_id')::uuid;
  v_fingerprint := v_begin->>'request_fingerprint';

  BEGIN
    -- Serialize every full/partial reversal against the immutable original movement.
    SELECT * INTO v_original FROM inventory_movements WHERE id = p_movement_id FOR UPDATE;

    IF v_original.reversal_of_movement_id IS NOT NULL THEN
      RAISE EXCEPTION 'A reversal movement cannot itself be reversed by this command' USING ERRCODE = '0A000';
    END IF;
    IF v_original.document_command_id IS NOT NULL OR v_original.transfer_line_id IS NOT NULL OR v_original.sales_order_line_id IS NOT NULL OR v_original.count_line_id IS NOT NULL THEN
      RAISE EXCEPTION 'DOCUMENT_CORRECTION_REQUIRED: movement belongs to an authoritative warehouse document' USING ERRCODE = '0A000';
    END IF;

    v_expected_type := public.phase5_expected_reversal_type(v_original.movement_type);
    IF v_expected_type IS NULL THEN
      RAISE EXCEPTION 'Movement type is not eligible for generic reversal' USING ERRCODE = '0A000';
    END IF;
    IF public.phase5_has_downstream_activity(v_original.id) THEN
      RAISE EXCEPTION 'Movement has downstream activity on an affected inventory position' USING ERRCODE = '40001';
    END IF;

    SELECT COALESCE(sum(m.base_quantity),0) INTO v_reversed
    FROM inventory_movements m
    WHERE m.company_id = v_original.company_id AND m.reversal_of_movement_id = v_original.id;
    v_remaining := v_original.base_quantity - v_reversed;
    IF p_base_quantity > v_remaining THEN
      RAISE EXCEPTION 'Requested reversal exceeds remaining reversible quantity' USING ERRCODE = '23514';
    END IF;

    -- Invert the original physical shape exactly.
    IF v_original.source_location_id IS NOT NULL AND v_original.destination_location_id IS NULL THEN
      v_dest_location := v_original.source_location_id;
      v_dest_bin := v_original.source_bin_id;
      v_dest_status := v_original.source_inventory_status;
    ELSIF v_original.source_location_id IS NULL AND v_original.destination_location_id IS NOT NULL THEN
      v_source_location := v_original.destination_location_id;
      v_source_bin := v_original.destination_bin_id;
      v_source_status := v_original.destination_inventory_status;
    ELSIF v_original.source_location_id IS NOT NULL AND v_original.destination_location_id IS NOT NULL THEN
      v_source_location := v_original.destination_location_id;
      v_source_bin := v_original.destination_bin_id;
      v_source_status := v_original.destination_inventory_status;
      v_dest_location := v_original.source_location_id;
      v_dest_bin := v_original.source_bin_id;
      v_dest_status := v_original.source_inventory_status;
    ELSE
      RAISE EXCEPTION 'Movement has no reversible physical shape' USING ERRCODE = '0A000';
    END IF;

    SELECT p.base_unit_id INTO v_base_unit
    FROM products p WHERE p.company_id = v_original.company_id AND p.id = v_original.product_id;
    IF v_base_unit IS NULL THEN RAISE EXCEPTION 'Product has no authoritative base unit' USING ERRCODE = '23514'; END IF;

    -- If reversal removes stock, require sufficient physical stock and preserve all active reservations.
    IF v_source_location IS NOT NULL THEN
      PERFORM 1 FROM inventory_locations l
      JOIN inventory_bins b ON b.company_id=l.company_id AND b.location_id=l.id AND b.id=v_source_bin
      WHERE l.company_id=v_original.company_id AND l.id=v_source_location AND l.is_active AND b.is_active;
      IF NOT FOUND THEN RAISE EXCEPTION 'Reversal source warehouse/bin is inactive' USING ERRCODE = '42501'; END IF;

      INSERT INTO inventory_balances(company_id,location_id,bin_id,product_id,inventory_status,on_hand_base_qty,reserved_base_qty,physical_status_revision)
      VALUES(v_original.company_id,v_source_location,v_source_bin,v_original.product_id,v_source_status,0,0,1)
      ON CONFLICT (company_id,location_id,bin_id,product_id,inventory_status) DO NOTHING;

      SELECT b.on_hand_base_qty INTO v_current
      FROM inventory_balances b
      WHERE b.company_id=v_original.company_id AND b.location_id=v_source_location AND b.bin_id=v_source_bin
        AND b.product_id=v_original.product_id AND b.inventory_status=v_source_status
      FOR UPDATE;

      IF v_current < p_base_quantity THEN
        RAISE EXCEPTION 'Insufficient current stock to reverse the original inbound movement' USING ERRCODE = '23514';
      END IF;

      IF v_source_status = 'AVAILABLE' THEN
        PERFORM 1 FROM inventory_reservations r
        WHERE r.company_id=v_original.company_id AND r.location_id=v_source_location
          AND (r.bin_id=v_source_bin OR r.bin_id IS NULL) AND r.product_id=v_original.product_id
          AND r.status IN ('ACTIVE','PARTIALLY_FULFILLED')
        ORDER BY r.id FOR UPDATE;

        SELECT COALESCE(sum(r.reserved_base_qty-r.fulfilled_base_qty-r.released_base_qty),0)
        INTO v_reserved FROM inventory_reservations r
        WHERE r.company_id=v_original.company_id AND r.location_id=v_source_location
          AND (r.bin_id=v_source_bin OR r.bin_id IS NULL) AND r.product_id=v_original.product_id
          AND r.status IN ('ACTIVE','PARTIALLY_FULFILLED');
        IF v_current - p_base_quantity < v_reserved THEN
          RAISE EXCEPTION 'Reversal would consume inventory reserved for active work' USING ERRCODE = '23514';
        END IF;
      END IF;

      UPDATE inventory_balances
      SET on_hand_base_qty=on_hand_base_qty-p_base_quantity,
          physical_status_revision=physical_status_revision+1,updated_at=now()
      WHERE company_id=v_original.company_id AND location_id=v_source_location AND bin_id=v_source_bin
        AND product_id=v_original.product_id AND inventory_status=v_source_status;
    END IF;

    IF v_dest_location IS NOT NULL THEN
      PERFORM 1 FROM inventory_locations l
      JOIN inventory_bins b ON b.company_id=l.company_id AND b.location_id=l.id AND b.id=v_dest_bin
      WHERE l.company_id=v_original.company_id AND l.id=v_dest_location AND l.is_active AND b.is_active;
      IF NOT FOUND THEN RAISE EXCEPTION 'Reversal destination warehouse/bin is inactive' USING ERRCODE = '42501'; END IF;

      INSERT INTO inventory_balances(company_id,location_id,bin_id,product_id,inventory_status,on_hand_base_qty,reserved_base_qty,physical_status_revision)
      VALUES(v_original.company_id,v_dest_location,v_dest_bin,v_original.product_id,v_dest_status,p_base_quantity,0,1)
      ON CONFLICT (company_id,location_id,bin_id,product_id,inventory_status)
      DO UPDATE SET on_hand_base_qty=inventory_balances.on_hand_base_qty+EXCLUDED.on_hand_base_qty,
                    physical_status_revision=inventory_balances.physical_status_revision+1,updated_at=now();
    END IF;

    INSERT INTO inventory_operations(
      company_id,operation_type,client_transaction_id,request_fingerprint,source_document_type,source_document_id,
      initiating_actor,status,posted_at
    ) VALUES(
      v_original.company_id,'MOVEMENT_REVERSAL',p_client_command_id::text,v_fingerprint,'MOVEMENT',v_original.id,
      v_actor,'COMPLETED',now()
    ) RETURNING id INTO v_operation_id;

    INSERT INTO inventory_movements(
      company_id,product_id,movement_type,
      source_location_id,source_bin_id,destination_location_id,destination_bin_id,
      source_inventory_status,destination_inventory_status,
      entered_quantity,entered_unit_id,base_quantity,direction,
      client_recorded_at,reference_type,reference_id,reference_number,
      reason_code,reason_text,performed_by,approved_by,client_transaction_id,
      operation_id,ledger_command_id,reversal_of_movement_id,posted_at
    ) VALUES(
      v_original.company_id,v_original.product_id,v_expected_type,
      v_source_location,v_source_bin,v_dest_location,v_dest_bin,
      v_source_status,v_dest_status,
      p_base_quantity,v_base_unit,p_base_quantity,
      CASE WHEN v_source_location IS NULL THEN 'IN' WHEN v_dest_location IS NULL THEN 'OUT' ELSE 'INTERNAL' END,
      p_client_recorded_at,'MOVEMENT_REVERSAL',v_original.id,v_original.reference_number,
      'REVERSAL',btrim(p_reason_text),v_actor,v_actor,p_client_command_id::text,
      v_operation_id,v_server_command_id,v_original.id,now()
    ) RETURNING id INTO v_reversal_id;

    v_remaining := v_remaining - p_base_quantity;
    v_result := jsonb_build_object(
      'success',true,'outcome','accepted','client_command_id',p_client_command_id,
      'server_command_id',v_server_command_id,'operation_id',v_operation_id,
      'original_movement_id',v_original.id,'reversal_movement_id',v_reversal_id,
      'reversed_base_quantity',p_base_quantity,'remaining_reversible_base_quantity',v_remaining,
      'reversal_status',CASE WHEN v_remaining=0 THEN 'FULL' ELSE 'PARTIAL' END
    );
    PERFORM public.phase5_store_ledger_result(v_server_command_id,'COMPLETED',v_result,NULL,NULL,v_operation_id);
    RETURN v_result;
  EXCEPTION WHEN OTHERS THEN
    v_result := public.phase4_error_outcome(SQLSTATE,SQLERRM,v_server_command_id,p_client_command_id);
    IF position('DOCUMENT_CORRECTION_REQUIRED' in SQLERRM) > 0 THEN
      v_result := v_result || jsonb_build_object('code','DOCUMENT_CORRECTION_REQUIRED');
    END IF;
    PERFORM public.phase5_store_ledger_result(
      v_server_command_id,public.phase4_error_status(SQLSTATE),v_result,
      CASE WHEN position('DOCUMENT_CORRECTION_REQUIRED' in SQLERRM)>0 THEN 'DOCUMENT_CORRECTION_REQUIRED' ELSE SQLSTATE END,
      SQLERRM,NULL
    );
    RETURN v_result;
  END;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Read-only reversal eligibility / command status APIs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_movement_reversal_state(p_movement_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_original inventory_movements%ROWTYPE;
  v_reversed NUMERIC;
  v_eligible BOOLEAN := true;
  v_reason TEXT;
BEGIN
  SELECT * INTO v_original FROM inventory_movements WHERE id=p_movement_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_actor IS NULL OR NOT public.is_company_member(v_original.company_id) THEN
    RAISE EXCEPTION 'Company membership required' USING ERRCODE='42501';
  END IF;
  IF v_original.source_location_id IS NOT NULL AND NOT public.has_warehouse_permission(v_original.source_location_id,'inventory.reverse') THEN v_eligible:=false; v_reason:='MISSING_SOURCE_REVERSE_PERMISSION'; END IF;
  IF v_original.destination_location_id IS NOT NULL AND NOT public.has_warehouse_permission(v_original.destination_location_id,'inventory.reverse') THEN v_eligible:=false; v_reason:=COALESCE(v_reason,'MISSING_DESTINATION_REVERSE_PERMISSION'); END IF;
  IF v_original.reversal_of_movement_id IS NOT NULL THEN v_eligible:=false; v_reason:='REVERSAL_OF_REVERSAL_NOT_ALLOWED'; END IF;
  IF v_original.document_command_id IS NOT NULL OR v_original.transfer_line_id IS NOT NULL OR v_original.sales_order_line_id IS NOT NULL OR v_original.count_line_id IS NOT NULL THEN v_eligible:=false; v_reason:='DOCUMENT_CORRECTION_REQUIRED'; END IF;
  IF public.phase5_expected_reversal_type(v_original.movement_type) IS NULL THEN v_eligible:=false; v_reason:='MOVEMENT_TYPE_NOT_REVERSIBLE'; END IF;
  IF public.phase5_has_downstream_activity(v_original.id) THEN v_eligible:=false; v_reason:='DOWNSTREAM_ACTIVITY'; END IF;

  SELECT COALESCE(sum(base_quantity),0) INTO v_reversed
  FROM inventory_movements WHERE company_id=v_original.company_id AND reversal_of_movement_id=v_original.id;
  IF v_reversed >= v_original.base_quantity THEN v_eligible:=false; v_reason:='FULLY_REVERSED'; END IF;

  RETURN jsonb_build_object(
    'movement_id',v_original.id,'company_id',v_original.company_id,'product_id',v_original.product_id,
    'movement_type',v_original.movement_type,'original_base_quantity',v_original.base_quantity,
    'reversed_base_quantity',v_reversed,'remaining_reversible_base_quantity',GREATEST(v_original.base_quantity-v_reversed,0),
    'eligible',v_eligible,'reason',v_reason
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_ledger_command_result(p_company_id UUID,p_client_command_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_cmd inventory_ledger_commands%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.is_company_member(p_company_id) THEN RAISE EXCEPTION 'Company membership required' USING ERRCODE='42501'; END IF;
  SELECT * INTO v_cmd FROM inventory_ledger_commands c
  WHERE c.company_id=p_company_id AND c.client_command_id=p_client_command_id AND c.initiating_actor=v_actor LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'client_command_id',v_cmd.client_command_id,'server_command_id',v_cmd.id,'command_type',v_cmd.command_type,
    'source_movement_id',v_cmd.source_movement_id,'status',v_cmd.status,'result',v_cmd.result_payload,
    'error_code',v_cmd.error_code,'error_message',v_cmd.error_message,'created_at',v_cmd.created_at,'completed_at',v_cmd.completed_at
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. RLS/privileges: command-only correction boundary.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_ledger_commands ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS inventory_ledger_commands_select_self ON inventory_ledger_commands;
CREATE POLICY inventory_ledger_commands_select_self ON inventory_ledger_commands
FOR SELECT TO authenticated
USING (public.is_company_member(company_id) AND initiating_actor=public.current_profile_id());

REVOKE ALL PRIVILEGES ON TABLE inventory_ledger_commands FROM anon, authenticated;
GRANT SELECT ON TABLE inventory_ledger_commands TO authenticated;

-- Movement history remains readable through RLS, but no application/service role may insert,
-- update, delete, or truncate it directly. SECURITY DEFINER command functions own writes.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE inventory_movements FROM PUBLIC, anon, authenticated;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
    EXECUTE 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.inventory_movements FROM service_role';
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.inventory_movement_append_only_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase5_expected_reversal_type(movement_type) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase5_has_downstream_activity(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase5_validate_reversal_row() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase5_reversal_fingerprint(UUID,NUMERIC,TEXT,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase5_begin_ledger_command(UUID,UUID,UUID,UUID,NUMERIC,TEXT,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase5_store_ledger_result(UUID,document_command_status,JSONB,TEXT,TEXT,UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.reverse_inventory_movement(UUID,NUMERIC,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_inventory_movement(UUID,NUMERIC,UUID,TEXT,TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.get_movement_reversal_state(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_movement_reversal_state(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.get_ledger_command_result(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_ledger_command_result(UUID,UUID) TO authenticated;

COMMENT ON TABLE inventory_ledger_commands IS
  'Phase 5 idempotent correction-command ledger. Generic movement reversals are allowed only for structurally safe, non-document-linked movements.';
COMMENT ON FUNCTION public.reverse_inventory_movement(UUID,NUMERIC,UUID,TEXT,TIMESTAMPTZ) IS
  'Appends a validated full/partial compensating movement without editing history. Locks the original, prevents over/double reversal, protects reservations, rejects downstream activity, and fails closed for authoritative document movements.';
