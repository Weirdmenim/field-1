-- FieldOne Phase 6: offline workflow support for genuinely blind count observations.
-- No stock mutation is introduced here. Phase 4 remains the only count finalization path.

CREATE OR REPLACE FUNCTION public.set_count_variance_reason(
  p_observation_id UUID,
  p_expected_session_revision BIGINT,
  p_reason_code TEXT,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_observation inventory_count_observations%ROWTYPE;
  v_session inventory_count_sessions%ROWTYPE;
  v_line inventory_count_lines%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE = '42501'; END IF;
  IF p_reason_code IS NULL OR btrim(p_reason_code) = '' OR upper(btrim(p_reason_code)) = 'PENDING_REASON' THEN
    RAISE EXCEPTION 'A final variance reason is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_observation FROM inventory_count_observations WHERE id = p_observation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Count observation not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO v_session FROM inventory_count_sessions WHERE id = v_observation.count_session_id FOR UPDATE;
  SELECT * INTO v_line FROM inventory_count_lines WHERE id = v_observation.count_line_id FOR UPDATE;

  IF v_session.revision <> p_expected_session_revision THEN RAISE EXCEPTION 'Count session revision conflict' USING ERRCODE = '40001'; END IF;
  IF v_line.line_status <> 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'Count line is not awaiting a variance reason' USING ERRCODE = '22023'; END IF;
  IF v_observation.variance_base_quantity = 0 THEN RAISE EXCEPTION 'Matching count does not require a variance reason' USING ERRCODE = '22023'; END IF;
  IF NOT public.has_warehouse_permission(v_session.location_id, 'inventory.count') THEN RAISE EXCEPTION 'Count permission required' USING ERRCODE = '42501'; END IF;
  IF v_session.assigned_profile_id IS NOT NULL AND v_session.assigned_profile_id <> v_actor THEN RAISE EXCEPTION 'Count session is assigned to another user' USING ERRCODE = '42501'; END IF;
  IF v_observation.observed_by <> v_actor AND NOT public.has_warehouse_permission(v_session.location_id, 'inventory.count.approve') THEN
    RAISE EXCEPTION 'Only the observing user or a count approver may classify this variance' USING ERRCODE = '42501';
  END IF;

  UPDATE inventory_count_observations
  SET reason_code = btrim(p_reason_code), notes = COALESCE(p_notes, notes)
  WHERE id = v_observation.id;

  UPDATE inventory_count_sessions SET revision = revision + 1, updated_at = now() WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'observation_id', v_observation.id,
    'session_id', v_session.id,
    'session_revision', v_session.revision + 1,
    'line_id', v_line.id,
    'reason_code', btrim(p_reason_code)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.phase6_require_final_count_reason()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_observation inventory_count_observations%ROWTYPE;
BEGIN
  SELECT * INTO v_observation
  FROM inventory_count_observations
  WHERE company_id = NEW.company_id AND id = NEW.observation_id;

  IF v_observation.variance_base_quantity <> 0 AND (
    v_observation.reason_code IS NULL OR btrim(v_observation.reason_code) = '' OR upper(btrim(v_observation.reason_code)) = 'PENDING_REASON'
  ) THEN
    RAISE EXCEPTION 'Count variance requires a final operator reason before approval' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_phase6_count_approval_reason ON inventory_count_approvals;
CREATE TRIGGER trg_phase6_count_approval_reason
BEFORE INSERT ON inventory_count_approvals
FOR EACH ROW EXECUTE FUNCTION public.phase6_require_final_count_reason();

REVOKE ALL ON FUNCTION public.set_count_variance_reason(UUID, BIGINT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_count_variance_reason(UUID, BIGINT, TEXT, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.phase6_require_final_count_reason() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.set_count_variance_reason(UUID, BIGINT, TEXT, TEXT) IS
  'Phase 6 follow-up for blind counts: records the real reason after server variance is revealed; stock remains unchanged.';
