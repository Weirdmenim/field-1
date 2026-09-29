-- Phase 8: remaining production-hardening closure.
-- Preserves all Phase 1-7 trust, stock, document, command, ledger, offline, and scanner invariants.

-- ---------------------------------------------------------------------------
-- 1. Authoritative receipt exception disposition.
-- ---------------------------------------------------------------------------
CREATE TYPE transfer_receipt_disposition_type AS ENUM (
  'ACCEPT_DAMAGED',
  'REJECT_WRONG_ITEM',
  'REJECT_UNEXPECTED',
  'ACCEPT_EXPECTED_REJECT_OVERAGE'
);

CREATE TABLE inventory_transfer_receipt_dispositions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  transfer_id UUID NOT NULL,
  transfer_line_id UUID NOT NULL,
  disposition transfer_receipt_disposition_type NOT NULL,
  captured_base_quantity NUMERIC(28, 6) NOT NULL CHECK (captured_base_quantity >= 0),
  accepted_available_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (accepted_available_base_quantity >= 0),
  accepted_damaged_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (accepted_damaged_base_quantity >= 0),
  rejected_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (rejected_base_quantity >= 0),
  transit_lost_base_quantity NUMERIC(28, 6) NOT NULL DEFAULT 0 CHECK (transit_lost_base_quantity >= 0),
  reason_text TEXT NOT NULL CHECK (btrim(reason_text) <> ''),
  resolved_by UUID NOT NULL,
  client_command_id UUID NOT NULL,
  client_recorded_at TIMESTAMPTZ NOT NULL,
  applied_at TIMESTAMPTZ,
  applied_document_command_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT transfer_receipt_disposition_quantity_partition CHECK (
    accepted_available_base_quantity + accepted_damaged_base_quantity + rejected_base_quantity = captured_base_quantity
  ),
  -- Custody loss is finalized against the authoritative transit lot when the
  -- disposition is applied; it is not necessarily a subset of rejected physical goods.
  UNIQUE (company_id, transfer_line_id),
  UNIQUE (company_id, client_command_id),
  UNIQUE (company_id, id)
);

ALTER TABLE inventory_transfer_receipt_dispositions
  ADD CONSTRAINT transfer_receipt_disposition_line_fk
  FOREIGN KEY (company_id, transfer_line_id)
  REFERENCES inventory_transfer_lines(company_id, id)
  ON DELETE CASCADE;
ALTER TABLE inventory_transfer_receipt_dispositions
  ADD CONSTRAINT transfer_receipt_disposition_actor_fk
  FOREIGN KEY (company_id, resolved_by)
  REFERENCES company_memberships(company_id, profile_id);
ALTER TABLE inventory_transfer_receipt_dispositions
  ADD CONSTRAINT transfer_receipt_disposition_applied_command_fk
  FOREIGN KEY (company_id, applied_document_command_id)
  REFERENCES inventory_document_commands(company_id, id);

ALTER TABLE inventory_transfer_receipt_dispositions ENABLE ROW LEVEL SECURITY;
CREATE POLICY inventory_transfer_receipt_dispositions_select_authorized
  ON inventory_transfer_receipt_dispositions
  FOR SELECT TO authenticated
  USING (public.is_company_member(company_id));
REVOKE ALL PRIVILEGES ON TABLE inventory_transfer_receipt_dispositions FROM anon, authenticated;
GRANT SELECT ON TABLE inventory_transfer_receipt_dispositions TO authenticated;

CREATE OR REPLACE FUNCTION public.resolve_transfer_receipt_exception(
  p_line_id UUID,
  p_expected_document_revision BIGINT,
  p_client_command_id UUID,
  p_disposition transfer_receipt_disposition_type,
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
  v_doc inventory_transfer_documents%ROWTYPE;
  v_line inventory_transfer_lines%ROWTYPE;
  v_begin JSONB;
  v_server_command_id UUID;
  v_result JSONB;
  v_code TEXT;
  v_available NUMERIC := 0;
  v_damaged NUMERIC := 0;
  v_rejected NUMERIC := 0;
  v_lost NUMERIC := 0;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Authenticated operational profile required');
  END IF;
  IF p_reason_text IS NULL OR btrim(p_reason_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'validation_error', 'code', '22023', 'message', 'Disposition reason is required');
  END IF;

  SELECT d.* INTO v_doc
  FROM inventory_transfer_documents d
  JOIN inventory_transfer_lines l ON l.transfer_id = d.id AND l.company_id = d.company_id
  WHERE l.id = p_line_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN
    RETURN jsonb_build_object('success', false, 'outcome', 'authorization_error', 'code', '42501', 'message', 'Transfer line is not available to the authenticated company');
  END IF;

  v_begin := public.phase4_begin_document_command(
    v_doc.company_id, v_actor, 'TRANSFER_EXCEPTION_DISPOSITION', p_client_command_id,
    v_doc.id, p_expected_document_revision,
    jsonb_build_object('line_id', p_line_id, 'disposition', p_disposition::text, 'reason_text', btrim(p_reason_text)),
    p_client_recorded_at
  );
  IF v_begin->>'state' <> 'NEW' THEN
    RETURN public.phase4_duplicate_result(v_begin, p_client_command_id);
  END IF;
  v_server_command_id := (v_begin->>'server_command_id')::uuid;

  BEGIN
    SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id = v_doc.id FOR UPDATE;
    SELECT * INTO v_line FROM inventory_transfer_lines WHERE id = p_line_id FOR UPDATE;
    IF v_doc.revision <> p_expected_document_revision THEN RAISE EXCEPTION 'Transfer revision conflict' USING ERRCODE = '40001'; END IF;
    IF v_doc.status IN ('COMPLETED', 'CANCELLED') THEN RAISE EXCEPTION 'Transfer is not editable' USING ERRCODE = '22023'; END IF;
    IF NOT public.has_warehouse_permission(v_doc.destination_location_id, 'inventory.receive') THEN RAISE EXCEPTION 'Receive permission required' USING ERRCODE = '42501'; END IF;
    IF v_doc.assigned_profile_id IS NOT NULL AND v_doc.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Transfer is assigned to another user' USING ERRCODE = '42501'; END IF;
    IF v_line.line_status <> 'EXCEPTION' OR v_line.exception_code IS NULL THEN RAISE EXCEPTION 'Transfer line does not have a resolvable exception' USING ERRCODE = '22023'; END IF;
    IF upper(v_line.exception_code) IN ('SHORTAGE', 'SHORT_RECEIPT') THEN RAISE EXCEPTION 'Shortage is already an explicit terminal receipt outcome and does not require a separate disposition' USING ERRCODE = '22023'; END IF;
    IF EXISTS (SELECT 1 FROM inventory_transfer_receipt_dispositions x WHERE x.company_id = v_doc.company_id AND x.transfer_line_id = v_line.id) THEN
      RAISE EXCEPTION 'Transfer exception already has an immutable disposition' USING ERRCODE = '23505';
    END IF;

    v_code := upper(replace(btrim(v_line.exception_code), ' ', '_'));
    CASE p_disposition
      WHEN 'ACCEPT_DAMAGED' THEN
        IF v_code <> 'DAMAGED' THEN RAISE EXCEPTION 'ACCEPT_DAMAGED requires a DAMAGED exception' USING ERRCODE = '22023'; END IF;
        v_damaged := v_line.captured_received_base_quantity;
      WHEN 'REJECT_WRONG_ITEM' THEN
        IF v_code NOT IN ('WRONG_ITEM', 'WRONG') THEN RAISE EXCEPTION 'REJECT_WRONG_ITEM requires a wrong-item exception' USING ERRCODE = '22023'; END IF;
        v_rejected := v_line.captured_received_base_quantity;
      WHEN 'REJECT_UNEXPECTED' THEN
        IF v_code NOT IN ('EXTRA_/_UNEXPECTED', 'EXTRA_UNEXPECTED', 'UNEXPECTED') THEN RAISE EXCEPTION 'REJECT_UNEXPECTED requires an unexpected-item exception' USING ERRCODE = '22023'; END IF;
        v_rejected := v_line.captured_received_base_quantity;
      WHEN 'ACCEPT_EXPECTED_REJECT_OVERAGE' THEN
        IF v_code <> 'OVERAGE' THEN RAISE EXCEPTION 'Overage disposition requires an OVERAGE exception' USING ERRCODE = '22023'; END IF;
        v_available := LEAST(v_line.captured_received_base_quantity, v_line.expected_base_quantity);
        v_rejected := GREATEST(v_line.captured_received_base_quantity - v_available, 0);
      ELSE
        RAISE EXCEPTION 'Unsupported receipt disposition' USING ERRCODE = '22023';
    END CASE;

    INSERT INTO inventory_transfer_receipt_dispositions (
      company_id, transfer_id, transfer_line_id, disposition, captured_base_quantity,
      accepted_available_base_quantity, accepted_damaged_base_quantity, rejected_base_quantity,
      transit_lost_base_quantity, reason_text, resolved_by, client_command_id, client_recorded_at
    ) VALUES (
      v_doc.company_id, v_doc.id, v_line.id, p_disposition, v_line.captured_received_base_quantity,
      v_available, v_damaged, v_rejected, v_lost, btrim(p_reason_text), v_actor, p_client_command_id, p_client_recorded_at
    );

    UPDATE inventory_transfer_documents SET revision = revision + 1, updated_at = now() WHERE id = v_doc.id;
    v_result := jsonb_build_object(
      'success', true, 'outcome', 'accepted', 'client_command_id', p_client_command_id,
      'server_command_id', v_server_command_id, 'document_id', v_doc.id,
      'document_revision', v_doc.revision + 1, 'line_id', v_line.id,
      'disposition', p_disposition::text
    );
    PERFORM public.phase4_store_command_result(v_server_command_id, 'COMPLETED', v_result, NULL, NULL, NULL);
    RETURN v_result;
  EXCEPTION WHEN OTHERS THEN
    v_result := public.phase4_error_outcome(SQLSTATE, SQLERRM, v_server_command_id, p_client_command_id);
    PERFORM public.phase4_store_command_result(v_server_command_id, public.phase4_error_status(SQLSTATE), v_result, SQLSTATE, SQLERRM, NULL);
    RETURN v_result;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_transfer_receipt_exception(UUID, BIGINT, UUID, transfer_receipt_disposition_type, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_transfer_receipt_exception(UUID, BIGINT, UUID, transfer_receipt_disposition_type, TEXT, TIMESTAMPTZ) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Retire the legacy client-callable generic operation/idempotency path.
-- Current document/reversal commands use UUID command IDs and server fingerprints.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.post_inventory_operation(JSONB) FROM PUBLIC, anon, authenticated;

ALTER TABLE inventory_operations
  ADD CONSTRAINT inventory_operations_new_transaction_id_uuid
  CHECK (client_transaction_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') NOT VALID;
ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_new_transaction_id_uuid
  CHECK (client_transaction_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') NOT VALID;

-- All new canonical IDs are UUID shaped. Existing pre-remediation text IDs remain historical.
CREATE UNIQUE INDEX inventory_operations_canonical_transaction_identity_idx
  ON inventory_operations(company_id, client_transaction_id)
  WHERE client_transaction_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';

CREATE OR REPLACE FUNCTION public.guard_inventory_operation_identity_immutability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.company_id IS DISTINCT FROM OLD.company_id
     OR NEW.operation_type IS DISTINCT FROM OLD.operation_type
     OR NEW.client_transaction_id IS DISTINCT FROM OLD.client_transaction_id
     OR NEW.request_fingerprint IS DISTINCT FROM OLD.request_fingerprint
     OR NEW.initiating_actor IS DISTINCT FROM OLD.initiating_actor THEN
    RAISE EXCEPTION 'Inventory operation identity and server fingerprint are immutable' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS inventory_operations_identity_immutable ON inventory_operations;
CREATE TRIGGER inventory_operations_identity_immutable
BEFORE UPDATE ON inventory_operations
FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_operation_identity_immutability();

REVOKE ALL ON FUNCTION public.guard_inventory_operation_identity_immutability() FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE inventory_operations IS
  'Internal successful-operation audit rows only. Client-callable legacy idempotency/failure handling is retired in Phase 8; durable failures live in document/ledger command ledgers.';

-- ---------------------------------------------------------------------------
-- 3. Cross-table reservation/physical invariant checked at transaction end.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_inventory_reservation_integrity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_company UUID;
  v_location UUID;
  v_product UUID;
  v_available NUMERIC;
  v_reserved NUMERIC;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_company := OLD.company_id;
    v_location := OLD.location_id;
    v_product := OLD.product_id;
  ELSE
    v_company := NEW.company_id;
    v_location := NEW.location_id;
    v_product := NEW.product_id;
  END IF;
  SELECT COALESCE(sum(on_hand_base_qty), 0) INTO v_available
  FROM inventory_balances
  WHERE company_id = v_company AND location_id = v_location AND product_id = v_product
    AND inventory_status = 'AVAILABLE';

  SELECT COALESCE(sum(reserved_base_qty - fulfilled_base_qty - released_base_qty), 0) INTO v_reserved
  FROM inventory_reservations
  WHERE company_id = v_company AND location_id = v_location AND product_id = v_product
    AND status IN ('ACTIVE', 'PARTIALLY_FULFILLED');

  IF v_reserved < 0 OR v_reserved > v_available THEN
    RAISE EXCEPTION 'Active reservation remainder % exceeds available physical % for company %, location %, product %',
      v_reserved, v_available, v_company, v_location, v_product USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS inventory_reservation_integrity_reservation ON inventory_reservations;
CREATE CONSTRAINT TRIGGER inventory_reservation_integrity_reservation
AFTER INSERT OR UPDATE OR DELETE ON inventory_reservations
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.assert_inventory_reservation_integrity();
DROP TRIGGER IF EXISTS inventory_reservation_integrity_balance ON inventory_balances;
CREATE CONSTRAINT TRIGGER inventory_reservation_integrity_balance
AFTER INSERT OR UPDATE OR DELETE ON inventory_balances
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.assert_inventory_reservation_integrity();
REVOKE ALL ON FUNCTION public.assert_inventory_reservation_integrity() FROM PUBLIC, anon, authenticated;


-- Phase 8 replacement of destination receipt finalization.
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
  v_disposition inventory_transfer_receipt_dispositions%ROWTYPE;
  v_available_delta NUMERIC;
  v_damaged_delta NUMERIC;
  v_rejected_delta NUMERIC;
  v_lost_delta NUMERIC;
  v_transit_consumed NUMERIC;
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
      IF v_delta = 0 AND v_line.line_status = 'POSTED' THEN CONTINUE; END IF;

      v_available_delta := GREATEST(v_delta, 0);
      v_damaged_delta := 0;
      v_rejected_delta := 0;
      v_lost_delta := 0;

      IF v_line.exception_code IS NOT NULL
         AND upper(v_line.exception_code) NOT IN ('SHORTAGE', 'SHORT_RECEIPT') THEN
        SELECT * INTO v_disposition
        FROM inventory_transfer_receipt_dispositions
        WHERE company_id = v_doc.company_id AND transfer_line_id = v_line.id
        FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Transfer exception % requires an authoritative disposition before stock posting', v_line.exception_code USING ERRCODE = '22023';
        END IF;
        IF v_disposition.applied_at IS NOT NULL THEN CONTINUE; END IF;
        v_available_delta := v_disposition.accepted_available_base_quantity;
        v_damaged_delta := v_disposition.accepted_damaged_base_quantity;
        v_rejected_delta := v_disposition.rejected_base_quantity;
        v_lost_delta := v_disposition.transit_lost_base_quantity;
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

      -- A resolved exception is terminal custody accounting. Accepted stock consumes
      -- transit as AVAILABLE/DAMAGED and any unaccounted transfer custody is explicitly
      -- closed as lost/short. Rejected wrong/unexpected physical goods do not become stock.
      IF v_line.exception_code IS NOT NULL THEN
        v_lost_delta := GREATEST(v_transit_remaining - v_available_delta - v_damaged_delta, 0);
      END IF;

      v_transit_consumed := v_available_delta + v_damaged_delta + v_lost_delta;
      IF v_transit_consumed > v_transit_remaining THEN
        RAISE EXCEPTION 'Receipt disposition exceeds authoritative in-transit custody for transfer line %', v_line.id USING ERRCODE = '23514';
      END IF;

      v_movement_id := NULL;
      IF v_available_delta > 0 THEN
        v_movement_id := public.phase4_apply_document_movement(
          v_doc.company_id, v_actor, v_operation_id, v_server_command_id, p_client_command_id,
          v_line.product_id, 'TRANSFER_IN', NULL, NULL,
          v_doc.destination_location_id, v_line.destination_bin_id, NULL, 'AVAILABLE',
          v_available_delta, v_line.entered_unit_id, 'TRANSFER', v_doc.id, v_doc.reference_number,
          v_line.id, NULL, NULL, COALESCE(v_line.client_recorded_at, p_client_recorded_at),
          v_line.exception_code, v_line.exception_notes, NULL
        );
      END IF;
      IF v_damaged_delta > 0 THEN
        PERFORM public.phase4_apply_document_movement(
          v_doc.company_id, v_actor, v_operation_id, v_server_command_id, p_client_command_id,
          v_line.product_id, 'TRANSFER_IN', NULL, NULL,
          v_doc.destination_location_id, v_line.destination_bin_id, NULL, 'DAMAGED',
          v_damaged_delta, v_line.entered_unit_id, 'TRANSFER', v_doc.id, v_doc.reference_number,
          v_line.id, NULL, NULL, COALESCE(v_line.client_recorded_at, p_client_recorded_at),
          v_line.exception_code, COALESCE(v_disposition.reason_text, v_line.exception_notes), NULL
        );
      END IF;

      v_new_received := v_transit.received_base_quantity + v_available_delta + v_damaged_delta;
      UPDATE inventory_transit_lots
      SET received_base_quantity = v_new_received,
          lost_base_quantity = lost_base_quantity + v_lost_delta,
          status = CASE
            WHEN v_new_received + lost_base_quantity + v_lost_delta >= base_quantity THEN 'RECEIVED'::transit_status
            ELSE 'PARTIALLY_RECEIVED'::transit_status
          END,
          transit_revision = transit_revision + 1,
          completed_at = CASE WHEN v_new_received + lost_base_quantity + v_lost_delta >= base_quantity THEN now() ELSE completed_at END,
          updated_at = now()
      WHERE id = v_transit.id;

      UPDATE inventory_transfer_lines
      SET posted_base_quantity = posted_base_quantity + v_available_delta + v_damaged_delta,
          line_status = 'POSTED'::warehouse_document_line_status,
          revision = revision + 1,
          updated_at = now()
      WHERE id = v_line.id;

      IF v_line.exception_code IS NOT NULL AND upper(v_line.exception_code) NOT IN ('SHORTAGE', 'SHORT_RECEIPT') THEN
        UPDATE inventory_transfer_receipt_dispositions
        SET transit_lost_base_quantity = v_lost_delta,
            applied_at = now(), applied_document_command_id = v_server_command_id, updated_at = now()
        WHERE company_id = v_doc.company_id AND transfer_line_id = v_line.id;
      END IF;

      v_line_results := v_line_results || jsonb_build_array(jsonb_build_object(
        'line_id', v_line.id,
        'received_available_base_quantity', v_available_delta,
        'received_damaged_base_quantity', v_damaged_delta,
        'rejected_base_quantity', v_rejected_delta,
        'transit_lost_base_quantity', v_lost_delta,
        'movement_id', v_movement_id,
        'transit_lot_id', v_transit.id
      ));
    END LOOP;

    SELECT EXISTS (
      SELECT 1 FROM inventory_transfer_lines
      WHERE company_id = v_doc.company_id AND transfer_id = v_doc.id
        AND line_status NOT IN ('POSTED', 'CANCELLED')
    ) INTO v_has_unresolved;

    IF jsonb_array_length(v_line_results) = 0 AND v_has_unresolved THEN
      RAISE EXCEPTION 'Transfer has no newly postable captured receipt quantity' USING ERRCODE = '22023';
    END IF;

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
-- 4. Tighten receipt-disposition visibility and warehouse-work progress.
-- Unresolved exception lines must not count as completed work merely because a
-- capture row exists; the business exception itself must be dispositioned.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS inventory_transfer_receipt_dispositions_select_authorized
  ON inventory_transfer_receipt_dispositions;
CREATE POLICY inventory_transfer_receipt_dispositions_select_authorized
  ON inventory_transfer_receipt_dispositions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM inventory_transfer_documents d
      WHERE d.company_id = inventory_transfer_receipt_dispositions.company_id
        AND d.id = inventory_transfer_receipt_dispositions.transfer_id
        AND public.has_warehouse_permission(d.destination_location_id, 'inventory.receive')
        AND (d.assigned_profile_id IS NULL OR d.assigned_profile_id = public.current_profile_id())
    )
  );

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
        'done', count(*) FILTER (
          WHERE l.line_status IN ('CAPTURED', 'POSTED', 'CANCELLED')
             OR (
               l.line_status = 'EXCEPTION'
               AND (
                 upper(COALESCE(l.exception_code, '')) IN ('SHORTAGE', 'SHORT_RECEIPT')
                 OR rd.id IS NOT NULL
               )
             )
        ),
        'total', count(*)
      ) AS item
    FROM inventory_transfer_documents d
    JOIN inventory_transfer_lines l ON l.transfer_id = d.id AND l.company_id = d.company_id
    LEFT JOIN inventory_transfer_receipt_dispositions rd
      ON rd.company_id = l.company_id AND rd.transfer_line_id = l.id
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
REVOKE ALL ON FUNCTION public.list_my_warehouse_work(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_warehouse_work(UUID) TO authenticated;

-- Negative AVAILABLE stock can be permitted by warehouse policy, but active
-- reservation remainder may never exceed non-negative available physical stock.
CREATE OR REPLACE FUNCTION public.assert_inventory_reservation_integrity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_company UUID;
  v_location UUID;
  v_product UUID;
  v_available NUMERIC;
  v_reserved NUMERIC;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_company := OLD.company_id;
    v_location := OLD.location_id;
    v_product := OLD.product_id;
  ELSE
    v_company := NEW.company_id;
    v_location := NEW.location_id;
    v_product := NEW.product_id;
  END IF;

  SELECT COALESCE(sum(on_hand_base_qty), 0) INTO v_available
  FROM inventory_balances
  WHERE company_id = v_company AND location_id = v_location AND product_id = v_product
    AND inventory_status = 'AVAILABLE';

  SELECT COALESCE(sum(reserved_base_qty - fulfilled_base_qty - released_base_qty), 0) INTO v_reserved
  FROM inventory_reservations
  WHERE company_id = v_company AND location_id = v_location AND product_id = v_product
    AND status IN ('ACTIVE', 'PARTIALLY_FULFILLED');

  IF v_reserved < 0 OR v_reserved > GREATEST(v_available, 0) THEN
    RAISE EXCEPTION 'Active reservation remainder % exceeds available physical % for company %, location %, product %',
      v_reserved, v_available, v_company, v_location, v_product USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.assert_inventory_reservation_integrity() FROM PUBLIC, anon, authenticated;
