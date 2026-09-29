-- Phase 9: explicit physical/reservation revision preconditions for stock-sensitive commands.

CREATE TABLE IF NOT EXISTS inventory_document_command_stock_preconditions (
  company_id UUID NOT NULL REFERENCES companies(id),
  client_command_id UUID NOT NULL,
  command_type document_command_type NOT NULL,
  source_document_id UUID NOT NULL,
  expected_document_revision BIGINT NOT NULL CHECK (expected_document_revision > 0),
  preconditions JSONB NOT NULL CHECK (jsonb_typeof(preconditions) = 'array'),
  precondition_fingerprint TEXT NOT NULL,
  initiating_actor UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, client_command_id)
);
ALTER TABLE inventory_document_command_stock_preconditions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON inventory_document_command_stock_preconditions FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION phase9_position_lock_key(
  p_company_id UUID,
  p_location_id UUID,
  p_bin_id UUID,
  p_product_id UUID,
  p_scope TEXT
)
RETURNS BIGINT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT hashtextextended(
    concat_ws(':', p_company_id::text, p_location_id::text, COALESCE(p_bin_id::text, '*'), p_product_id::text, p_scope),
    0
  )
$$;

CREATE OR REPLACE FUNCTION phase9_lock_balance_position_trigger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_old_key BIGINT; v_new_key BIGINT;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    v_old_key := public.phase9_position_lock_key(OLD.company_id, OLD.location_id, OLD.bin_id, OLD.product_id, 'BIN');
  END IF;
  IF TG_OP <> 'DELETE' THEN
    v_new_key := public.phase9_position_lock_key(NEW.company_id, NEW.location_id, NEW.bin_id, NEW.product_id, 'BIN');
  END IF;
  IF v_old_key IS NOT NULL AND v_new_key IS NOT NULL AND v_old_key <> v_new_key THEN
    PERFORM pg_advisory_xact_lock(LEAST(v_old_key, v_new_key));
    PERFORM pg_advisory_xact_lock(GREATEST(v_old_key, v_new_key));
  ELSE
    PERFORM pg_advisory_xact_lock(COALESCE(v_new_key, v_old_key));
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_phase9_balance_position_lock ON inventory_balances;
CREATE TRIGGER trg_phase9_balance_position_lock
BEFORE INSERT OR UPDATE OR DELETE ON inventory_balances
FOR EACH ROW EXECUTE FUNCTION phase9_lock_balance_position_trigger();

CREATE OR REPLACE FUNCTION phase9_lock_reservation_position_trigger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_old_key BIGINT; v_new_key BIGINT; v_old_scope TEXT; v_new_scope TEXT;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    v_old_scope := CASE WHEN OLD.bin_id IS NULL THEN 'LOCATION' ELSE 'BIN' END;
    v_old_key := public.phase9_position_lock_key(OLD.company_id, OLD.location_id, OLD.bin_id, OLD.product_id, v_old_scope);
  END IF;
  IF TG_OP <> 'DELETE' THEN
    v_new_scope := CASE WHEN NEW.bin_id IS NULL THEN 'LOCATION' ELSE 'BIN' END;
    v_new_key := public.phase9_position_lock_key(NEW.company_id, NEW.location_id, NEW.bin_id, NEW.product_id, v_new_scope);
  END IF;
  IF v_old_key IS NOT NULL AND v_new_key IS NOT NULL AND v_old_key <> v_new_key THEN
    PERFORM pg_advisory_xact_lock(LEAST(v_old_key, v_new_key));
    PERFORM pg_advisory_xact_lock(GREATEST(v_old_key, v_new_key));
  ELSE
    PERFORM pg_advisory_xact_lock(COALESCE(v_new_key, v_old_key));
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_phase9_reservation_position_lock ON inventory_reservations;
CREATE TRIGGER trg_phase9_reservation_position_lock
BEFORE INSERT OR UPDATE OR DELETE ON inventory_reservations
FOR EACH ROW EXECUTE FUNCTION phase9_lock_reservation_position_trigger();

CREATE OR REPLACE FUNCTION phase9_required_stock_positions(
  p_command_type TEXT,
  p_document_id UUID
)
RETURNS TABLE (
  company_id UUID,
  location_id UUID,
  bin_id UUID,
  product_id UUID,
  inventory_status inventory_status
)
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_command_type = 'SALES_DISPATCH' THEN
    RETURN QUERY
    SELECT DISTINCT d.company_id, d.source_location_id, l.source_bin_id, l.product_id, 'AVAILABLE'::inventory_status
    FROM inventory_sales_orders d
    JOIN inventory_sales_order_lines l ON l.company_id = d.company_id AND l.sales_order_id = d.id
    WHERE d.id = p_document_id AND l.line_status <> 'CANCELLED';
  ELSIF p_command_type = 'TRANSFER_SHIP' THEN
    RETURN QUERY
    SELECT DISTINCT d.company_id, d.source_location_id, l.source_bin_id, l.product_id, 'AVAILABLE'::inventory_status
    FROM inventory_transfer_documents d
    JOIN inventory_transfer_lines l ON l.company_id = d.company_id AND l.transfer_id = d.id
    WHERE d.id = p_document_id AND l.line_status <> 'CANCELLED';
  ELSIF p_command_type = 'TRANSFER_RECEIVE' THEN
    RETURN QUERY
    SELECT DISTINCT q.company_id, q.location_id, q.bin_id, q.product_id, s.inventory_status
    FROM (
      SELECT d.company_id, d.destination_location_id AS location_id, l.destination_bin_id AS bin_id, l.product_id
      FROM inventory_transfer_documents d
      JOIN inventory_transfer_lines l ON l.company_id = d.company_id AND l.transfer_id = d.id
      WHERE d.id = p_document_id AND l.line_status <> 'CANCELLED'
    ) q
    CROSS JOIN (VALUES ('AVAILABLE'::inventory_status), ('DAMAGED'::inventory_status)) s(inventory_status);
  ELSIF p_command_type = 'COUNT_FINALIZE' THEN
    RETURN QUERY
    SELECT DISTINCT s.company_id, s.location_id, l.bin_id, l.product_id, 'AVAILABLE'::inventory_status
    FROM inventory_count_sessions s
    JOIN inventory_count_lines l ON l.company_id=s.company_id AND l.count_session_id=s.id
    WHERE s.id=p_document_id AND l.line_status <> 'CANCELLED';
  ELSE
    RAISE EXCEPTION 'Unsupported stock-precondition command type %', p_command_type USING ERRCODE = '22023';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION phase9_get_document_stock_preconditions(
  p_command_type TEXT,
  p_document_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE v_actor UUID := public.current_profile_id(); v_company UUID; v_location UUID; v_result JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;
  IF p_command_type = 'SALES_DISPATCH' THEN
    SELECT company_id, source_location_id INTO v_company, v_location FROM inventory_sales_orders WHERE id = p_document_id;
    IF v_company IS NULL OR NOT public.is_company_member(v_company) OR NOT public.has_warehouse_permission(v_location, 'inventory.dispatch') THEN
      RAISE EXCEPTION 'Dispatch permission required' USING ERRCODE = '42501';
    END IF;
  ELSIF p_command_type = 'TRANSFER_SHIP' THEN
    SELECT company_id, source_location_id INTO v_company, v_location FROM inventory_transfer_documents WHERE id = p_document_id;
    IF v_company IS NULL OR NOT public.is_company_member(v_company) OR NOT public.has_warehouse_permission(v_location, 'inventory.dispatch') THEN
      RAISE EXCEPTION 'Transfer dispatch permission required' USING ERRCODE = '42501';
    END IF;
  ELSIF p_command_type = 'TRANSFER_RECEIVE' THEN
    SELECT company_id, destination_location_id INTO v_company, v_location FROM inventory_transfer_documents WHERE id = p_document_id;
    IF v_company IS NULL OR NOT public.is_company_member(v_company) OR NOT public.has_warehouse_permission(v_location, 'inventory.receive') THEN
      RAISE EXCEPTION 'Receive permission required' USING ERRCODE = '42501';
    END IF;
  ELSIF p_command_type = 'COUNT_FINALIZE' THEN
    SELECT company_id, location_id INTO v_company, v_location FROM inventory_count_sessions WHERE id=p_document_id;
    IF v_company IS NULL OR NOT public.is_company_member(v_company) OR NOT public.has_warehouse_permission(v_location, 'inventory.count') THEN
      RAISE EXCEPTION 'Count permission required' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unsupported stock-precondition command type' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'locationId', p.location_id,
    'binId', p.bin_id,
    'productId', p.product_id,
    'inventoryStatus', p.inventory_status::text,
    'physicalRevision', COALESCE((
      SELECT b.physical_status_revision FROM inventory_balances b
      WHERE b.company_id = p.company_id AND b.location_id = p.location_id AND b.bin_id = p.bin_id
        AND b.product_id = p.product_id AND b.inventory_status = p.inventory_status
    ), 0),
    'binReservationRevision', COALESCE((
      SELECT sum(r.reservation_revision) FROM inventory_reservations r
      WHERE r.company_id = p.company_id AND r.location_id = p.location_id AND r.bin_id = p.bin_id
        AND r.product_id = p.product_id AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')
    ), 0),
    'locationReservationRevision', COALESCE((
      SELECT sum(r.reservation_revision) FROM inventory_reservations r
      WHERE r.company_id = p.company_id AND r.location_id = p.location_id AND r.bin_id IS NULL
        AND r.product_id = p.product_id AND r.status IN ('ACTIVE', 'PARTIALLY_FULFILLED')
    ), 0)
  ) ORDER BY p.location_id, p.bin_id, p.product_id, p.inventory_status::text), '[]'::jsonb)
  INTO v_result
  FROM public.phase9_required_stock_positions(p_command_type, p_document_id) p;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION phase9_prepare_stock_command(
  p_company_id UUID,
  p_actor UUID,
  p_command_type document_command_type,
  p_client_command_id UUID,
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_preconditions JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_fingerprint TEXT; v_existing inventory_document_command_stock_preconditions%ROWTYPE;
BEGIN
  IF p_preconditions IS NULL OR jsonb_typeof(p_preconditions) <> 'array' THEN
    RETURN jsonb_build_object('state','MISMATCH','message','Stock revision preconditions are required');
  END IF;
  v_fingerprint := md5(jsonb_build_object(
    'command_type', p_command_type::text,
    'document_id', p_document_id,
    'expected_revision', p_expected_revision,
    'preconditions', p_preconditions
  )::text);

  INSERT INTO inventory_document_command_stock_preconditions(
    company_id, client_command_id, command_type, source_document_id,
    expected_document_revision, preconditions, precondition_fingerprint, initiating_actor
  ) VALUES (
    p_company_id, p_client_command_id, p_command_type, p_document_id,
    p_expected_revision, p_preconditions, v_fingerprint, p_actor
  ) ON CONFLICT (company_id, client_command_id) DO NOTHING;

  SELECT * INTO v_existing FROM inventory_document_command_stock_preconditions
  WHERE company_id = p_company_id AND client_command_id = p_client_command_id FOR UPDATE;

  IF v_existing.precondition_fingerprint <> v_fingerprint
     OR v_existing.command_type <> p_command_type
     OR v_existing.source_document_id <> p_document_id
     OR v_existing.expected_document_revision <> p_expected_revision
     OR v_existing.initiating_actor <> p_actor THEN
    RETURN jsonb_build_object('state','MISMATCH','message','Idempotency key was already used with different stock revision preconditions');
  END IF;
  RETURN jsonb_build_object('state','MATCH','precondition_fingerprint',v_fingerprint);
END;
$$;

CREATE OR REPLACE FUNCTION phase9_validate_stock_preconditions(
  p_company_id UUID,
  p_command_type TEXT,
  p_document_id UUID,
  p_expected JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  p RECORD; e JSONB; v_required_count INT; v_expected_count INT;
  v_physical BIGINT; v_bin_res BIGINT; v_location_res BIGINT;
  v_mismatches JSONB := '[]'::jsonb;
BEGIN
  IF p_expected IS NULL OR jsonb_typeof(p_expected) <> 'array' THEN
    RETURN jsonb_build_object('ok',false,'code','STOCK_PRECONDITIONS_REQUIRED','mismatches','[]'::jsonb);
  END IF;

  SELECT count(*) INTO v_required_count FROM public.phase9_required_stock_positions(p_command_type, p_document_id);
  SELECT jsonb_array_length(p_expected) INTO v_expected_count;
  IF v_required_count <> v_expected_count THEN
    RETURN jsonb_build_object('ok',false,'code','STOCK_PRECONDITION_SET_MISMATCH','required',v_required_count,'provided',v_expected_count,'mismatches','[]'::jsonb);
  END IF;

  FOR p IN SELECT * FROM public.phase9_required_stock_positions(p_command_type, p_document_id)
           ORDER BY location_id, bin_id, product_id, inventory_status::text
  LOOP
    IF p.company_id <> p_company_id THEN
      RETURN jsonb_build_object('ok',false,'code','STOCK_PRECONDITION_TENANT_MISMATCH','mismatches','[]'::jsonb);
    END IF;

    -- These advisory locks are also acquired by balance/reservation mutation triggers.
    -- They protect absent rows and new reservation inserts from slipping through the check.
    PERFORM pg_advisory_xact_lock(public.phase9_position_lock_key(p.company_id,p.location_id,p.bin_id,p.product_id,'BIN'));
    PERFORM pg_advisory_xact_lock(public.phase9_position_lock_key(p.company_id,p.location_id,NULL,p.product_id,'LOCATION'));

    PERFORM 1 FROM inventory_balances b
      WHERE b.company_id=p.company_id AND b.location_id=p.location_id AND b.bin_id=p.bin_id
        AND b.product_id=p.product_id AND b.inventory_status=p.inventory_status FOR UPDATE;
    PERFORM 1 FROM inventory_reservations r
      WHERE r.company_id=p.company_id AND r.location_id=p.location_id AND r.product_id=p.product_id
        AND (r.bin_id=p.bin_id OR r.bin_id IS NULL) AND r.status IN ('ACTIVE','PARTIALLY_FULFILLED')
      ORDER BY r.id FOR UPDATE;

    SELECT value INTO e FROM jsonb_array_elements(p_expected) value
      WHERE value->>'locationId'=p.location_id::text
        AND value->>'binId'=p.bin_id::text
        AND value->>'productId'=p.product_id::text
        AND value->>'inventoryStatus'=p.inventory_status::text
      LIMIT 1;

    SELECT COALESCE((SELECT b.physical_status_revision FROM inventory_balances b
      WHERE b.company_id=p.company_id AND b.location_id=p.location_id AND b.bin_id=p.bin_id
        AND b.product_id=p.product_id AND b.inventory_status=p.inventory_status),0)
      INTO v_physical;
    SELECT COALESCE(sum(r.reservation_revision),0) INTO v_bin_res FROM inventory_reservations r
      WHERE r.company_id=p.company_id AND r.location_id=p.location_id AND r.bin_id=p.bin_id
        AND r.product_id=p.product_id AND r.status IN ('ACTIVE','PARTIALLY_FULFILLED');
    SELECT COALESCE(sum(r.reservation_revision),0) INTO v_location_res FROM inventory_reservations r
      WHERE r.company_id=p.company_id AND r.location_id=p.location_id AND r.bin_id IS NULL
        AND r.product_id=p.product_id AND r.status IN ('ACTIVE','PARTIALLY_FULFILLED');

    IF e IS NULL
       OR COALESCE((e->>'physicalRevision')::bigint,-1) <> v_physical
       OR COALESCE((e->>'binReservationRevision')::bigint,-1) <> v_bin_res
       OR COALESCE((e->>'locationReservationRevision')::bigint,-1) <> v_location_res THEN
      v_mismatches := v_mismatches || jsonb_build_array(jsonb_build_object(
        'locationId',p.location_id,'binId',p.bin_id,'productId',p.product_id,'inventoryStatus',p.inventory_status::text,
        'expected',e,
        'current',jsonb_build_object('physicalRevision',v_physical,'binReservationRevision',v_bin_res,'locationReservationRevision',v_location_res)
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok',jsonb_array_length(v_mismatches)=0,'code',CASE WHEN jsonb_array_length(v_mismatches)=0 THEN NULL ELSE 'STOCK_REVISION_CONFLICT' END,'mismatches',v_mismatches);
END;
$$;

CREATE OR REPLACE FUNCTION phase9_existing_terminal_command(p_company_id UUID, p_client_command_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT EXISTS(
    SELECT 1 FROM inventory_document_commands c
    WHERE c.company_id=p_company_id AND c.client_command_id=p_client_command_id
      AND c.status <> 'TRANSIENT_ERROR'
  )
$$;

CREATE OR REPLACE FUNCTION public.dispatch_sales_order_v2(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
  p_expected_stock_revisions JSONB,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_temp AS $$
DECLARE v_actor UUID:=public.current_profile_id(); v_doc inventory_sales_orders%ROWTYPE; v_prepare JSONB; v_check JSONB;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Authenticated operational profile required'); END IF;
  SELECT * INTO v_doc FROM inventory_sales_orders WHERE id=p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Sales order is not available to the authenticated company'); END IF;
  v_prepare:=public.phase9_prepare_stock_command(v_doc.company_id,v_actor,'SALES_DISPATCH',p_client_command_id,p_document_id,p_expected_revision,p_expected_stock_revisions);
  IF v_prepare->>'state'='MISMATCH' THEN RETURN jsonb_build_object('success',false,'outcome','validation_error','client_command_id',p_client_command_id,'code','STOCK_PRECONDITION_IDEMPOTENCY_MISMATCH','message',v_prepare->>'message'); END IF;
  IF public.phase9_existing_terminal_command(v_doc.company_id,p_client_command_id) THEN
    RETURN public.dispatch_sales_order(p_document_id,p_expected_revision,p_client_command_id,p_client_recorded_at);
  END IF;
  v_check:=public.phase9_validate_stock_preconditions(v_doc.company_id,'SALES_DISPATCH',p_document_id,p_expected_stock_revisions);
  IF NOT COALESCE((v_check->>'ok')::boolean,false) THEN RETURN jsonb_build_object('success',false,'outcome','conflict','client_command_id',p_client_command_id,'document_id',p_document_id,'code',v_check->>'code','message','Authoritative stock/reservation revision changed since this command was created','lines',v_check->'mismatches'); END IF;
  RETURN public.dispatch_sales_order(p_document_id,p_expected_revision,p_client_command_id,p_client_recorded_at);
END; $$;

CREATE OR REPLACE FUNCTION public.receive_transfer_document_v2(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
  p_expected_stock_revisions JSONB,
  p_allow_partial BOOLEAN DEFAULT false,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_temp AS $$
DECLARE v_actor UUID:=public.current_profile_id(); v_doc inventory_transfer_documents%ROWTYPE; v_prepare JSONB; v_check JSONB;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Authenticated operational profile required'); END IF;
  SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id=p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Transfer is not available to the authenticated company'); END IF;
  v_prepare:=public.phase9_prepare_stock_command(v_doc.company_id,v_actor,'TRANSFER_RECEIVE',p_client_command_id,p_document_id,p_expected_revision,p_expected_stock_revisions);
  IF v_prepare->>'state'='MISMATCH' THEN RETURN jsonb_build_object('success',false,'outcome','validation_error','client_command_id',p_client_command_id,'code','STOCK_PRECONDITION_IDEMPOTENCY_MISMATCH','message',v_prepare->>'message'); END IF;
  IF public.phase9_existing_terminal_command(v_doc.company_id,p_client_command_id) THEN
    RETURN public.receive_transfer_document(p_document_id,p_expected_revision,p_client_command_id,p_allow_partial,p_client_recorded_at);
  END IF;
  v_check:=public.phase9_validate_stock_preconditions(v_doc.company_id,'TRANSFER_RECEIVE',p_document_id,p_expected_stock_revisions);
  IF NOT COALESCE((v_check->>'ok')::boolean,false) THEN RETURN jsonb_build_object('success',false,'outcome','conflict','client_command_id',p_client_command_id,'document_id',p_document_id,'code',v_check->>'code','message','Authoritative stock/reservation revision changed since this command was created','lines',v_check->'mismatches'); END IF;
  RETURN public.receive_transfer_document(p_document_id,p_expected_revision,p_client_command_id,p_allow_partial,p_client_recorded_at);
END; $$;

CREATE OR REPLACE FUNCTION public.ship_transfer_document_v2(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
  p_expected_stock_revisions JSONB,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_temp AS $$
DECLARE v_actor UUID:=public.current_profile_id(); v_doc inventory_transfer_documents%ROWTYPE; v_prepare JSONB; v_check JSONB;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Authenticated operational profile required'); END IF;
  SELECT * INTO v_doc FROM inventory_transfer_documents WHERE id=p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Transfer is not available to the authenticated company'); END IF;
  v_prepare:=public.phase9_prepare_stock_command(v_doc.company_id,v_actor,'TRANSFER_SHIP',p_client_command_id,p_document_id,p_expected_revision,p_expected_stock_revisions);
  IF v_prepare->>'state'='MISMATCH' THEN RETURN jsonb_build_object('success',false,'outcome','validation_error','client_command_id',p_client_command_id,'code','STOCK_PRECONDITION_IDEMPOTENCY_MISMATCH','message',v_prepare->>'message'); END IF;
  IF public.phase9_existing_terminal_command(v_doc.company_id,p_client_command_id) THEN
    RETURN public.ship_transfer_document(p_document_id,p_expected_revision,p_client_command_id,p_client_recorded_at);
  END IF;
  v_check:=public.phase9_validate_stock_preconditions(v_doc.company_id,'TRANSFER_SHIP',p_document_id,p_expected_stock_revisions);
  IF NOT COALESCE((v_check->>'ok')::boolean,false) THEN RETURN jsonb_build_object('success',false,'outcome','conflict','client_command_id',p_client_command_id,'document_id',p_document_id,'code',v_check->>'code','message','Authoritative stock/reservation revision changed since this command was created','lines',v_check->'mismatches'); END IF;
  RETURN public.ship_transfer_document(p_document_id,p_expected_revision,p_client_command_id,p_client_recorded_at);
END; $$;

CREATE OR REPLACE FUNCTION public.finalize_count_session_v2(
  p_document_id UUID,
  p_expected_revision BIGINT,
  p_client_command_id UUID,
  p_expected_stock_revisions JSONB,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_temp AS $$
DECLARE v_actor UUID:=public.current_profile_id(); v_doc inventory_count_sessions%ROWTYPE; v_prepare JSONB; v_check JSONB;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Authenticated operational profile required'); END IF;
  SELECT * INTO v_doc FROM inventory_count_sessions WHERE id=p_document_id;
  IF NOT FOUND OR NOT public.is_company_member(v_doc.company_id) THEN RETURN jsonb_build_object('success',false,'outcome','authorization_error','code','42501','message','Count session is not available to the authenticated company'); END IF;
  v_prepare:=public.phase9_prepare_stock_command(v_doc.company_id,v_actor,'COUNT_FINALIZE',p_client_command_id,p_document_id,p_expected_revision,p_expected_stock_revisions);
  IF v_prepare->>'state'='MISMATCH' THEN RETURN jsonb_build_object('success',false,'outcome','validation_error','client_command_id',p_client_command_id,'code','STOCK_PRECONDITION_IDEMPOTENCY_MISMATCH','message',v_prepare->>'message'); END IF;
  IF public.phase9_existing_terminal_command(v_doc.company_id,p_client_command_id) THEN
    RETURN public.finalize_count_session(p_document_id,p_expected_revision,p_client_command_id,p_client_recorded_at);
  END IF;
  v_check:=public.phase9_validate_stock_preconditions(v_doc.company_id,'COUNT_FINALIZE',p_document_id,p_expected_stock_revisions);
  IF NOT COALESCE((v_check->>'ok')::boolean,false) THEN RETURN jsonb_build_object('success',false,'outcome','conflict','client_command_id',p_client_command_id,'document_id',p_document_id,'code',v_check->>'code','message','Authoritative stock/reservation revision changed since this command was created','lines',v_check->'mismatches'); END IF;
  RETURN public.finalize_count_session(p_document_id,p_expected_revision,p_client_command_id,p_client_recorded_at);
END; $$;

-- The old public stock-mutating entry points remain available only to privileged/internal callers.
REVOKE ALL ON FUNCTION public.dispatch_sales_order(UUID,BIGINT,UUID,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ship_transfer_document(UUID,BIGINT,UUID,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.receive_transfer_document(UUID,BIGINT,UUID,BOOLEAN,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_count_session(UUID,BIGINT,UUID,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.dispatch_sales_order_v2(UUID,BIGINT,UUID,JSONB,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dispatch_sales_order_v2(UUID,BIGINT,UUID,JSONB,TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.ship_transfer_document_v2(UUID,BIGINT,UUID,JSONB,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ship_transfer_document_v2(UUID,BIGINT,UUID,JSONB,TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.receive_transfer_document_v2(UUID,BIGINT,UUID,JSONB,BOOLEAN,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_transfer_document_v2(UUID,BIGINT,UUID,JSONB,BOOLEAN,TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.finalize_count_session_v2(UUID,BIGINT,UUID,JSONB,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalize_count_session_v2(UUID,BIGINT,UUID,JSONB,TIMESTAMPTZ) TO authenticated;
REVOKE ALL ON FUNCTION public.phase9_get_document_stock_preconditions(TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.phase9_get_document_stock_preconditions(TEXT,UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.phase9_required_stock_positions(TEXT,UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase9_prepare_stock_command(UUID,UUID,document_command_type,UUID,UUID,BIGINT,JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase9_validate_stock_preconditions(UUID,TEXT,UUID,JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase9_existing_terminal_command(UUID,UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phase9_position_lock_key(UUID,UUID,UUID,UUID,TEXT) FROM PUBLIC, anon, authenticated;
