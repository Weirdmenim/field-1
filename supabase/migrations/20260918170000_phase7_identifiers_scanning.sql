-- Phase 7: production identifiers/scanning and durable unknown-scan reporting.
-- Preserves Phase 1-6 authority boundaries: identifier work never mutates stock.

CREATE OR REPLACE FUNCTION public.normalize_inventory_identifier(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT lower(regexp_replace(btrim(COALESCE(p_value, '')), '\\s+', '', 'g'))
$$;

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS normalized_sku TEXT
  GENERATED ALWAYS AS (public.normalize_inventory_identifier(sku)) STORED;

ALTER TABLE products
  DROP CONSTRAINT IF EXISTS products_sku_not_blank;
ALTER TABLE products
  ADD CONSTRAINT products_sku_not_blank CHECK (public.normalize_inventory_identifier(sku) <> '');

CREATE UNIQUE INDEX IF NOT EXISTS products_company_normalized_sku_unique_idx
  ON products(company_id, normalized_sku);

CREATE TABLE IF NOT EXISTS product_identifiers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  product_id UUID NOT NULL,
  identifier_type TEXT NOT NULL CHECK (identifier_type IN ('BARCODE','GTIN','ALIAS')),
  identifier_value TEXT NOT NULL,
  normalized_value TEXT GENERATED ALWAYS AS (public.normalize_inventory_identifier(identifier_value)) STORED,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT product_identifiers_value_not_blank CHECK (public.normalize_inventory_identifier(identifier_value) <> ''),
  UNIQUE(company_id, id),
  FOREIGN KEY(company_id, product_id) REFERENCES products(company_id, id),
  FOREIGN KEY(company_id, created_by) REFERENCES company_memberships(company_id, profile_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS product_identifiers_company_normalized_unique_idx
  ON product_identifiers(company_id, normalized_value);
CREATE INDEX IF NOT EXISTS product_identifiers_product_idx
  ON product_identifiers(company_id, product_id, is_active);

CREATE OR REPLACE FUNCTION public.phase7_guard_identifier_namespace()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path=public,pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM products p
    WHERE p.company_id=NEW.company_id AND p.normalized_sku=public.normalize_inventory_identifier(NEW.identifier_value) AND p.id<>NEW.product_id
  ) THEN RAISE EXCEPTION 'Identifier collides with another product SKU' USING ERRCODE='23505'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_phase7_identifier_namespace ON product_identifiers;
CREATE TRIGGER trg_phase7_identifier_namespace BEFORE INSERT OR UPDATE OF company_id,product_id,identifier_value,is_active ON product_identifiers
FOR EACH ROW WHEN (NEW.is_active) EXECUTE FUNCTION public.phase7_guard_identifier_namespace();

CREATE OR REPLACE FUNCTION public.phase7_guard_sku_namespace()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path=public,pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM product_identifiers i
    WHERE i.company_id=NEW.company_id AND i.normalized_value=public.normalize_inventory_identifier(NEW.sku) AND i.product_id<>NEW.id AND i.is_active
  ) THEN RAISE EXCEPTION 'SKU collides with another product identifier' USING ERRCODE='23505'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_phase7_sku_namespace ON products;
CREATE TRIGGER trg_phase7_sku_namespace BEFORE INSERT OR UPDATE OF company_id,sku ON products
FOR EACH ROW EXECUTE FUNCTION public.phase7_guard_sku_namespace();

CREATE TABLE IF NOT EXISTS inventory_unknown_scan_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  client_event_id UUID NOT NULL,
  location_id UUID NOT NULL,
  actor_id UUID NOT NULL,
  raw_code TEXT NOT NULL,
  normalized_code TEXT NOT NULL,
  scan_context TEXT NOT NULL CHECK (scan_context IN ('browse','receive','dispatch')),
  document_type TEXT CHECK (document_type IS NULL OR document_type IN ('TRANSFER','SALES_ORDER')),
  document_id UUID,
  client_recorded_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unknown_scan_code_not_blank CHECK (normalized_code <> ''),
  CONSTRAINT unknown_scan_document_pair CHECK ((document_type IS NULL) = (document_id IS NULL)),
  UNIQUE(company_id, client_event_id),
  FOREIGN KEY(company_id, location_id) REFERENCES inventory_locations(company_id, id),
  FOREIGN KEY(company_id, actor_id) REFERENCES company_memberships(company_id, profile_id)
);
CREATE INDEX IF NOT EXISTS inventory_unknown_scan_events_context_idx
  ON inventory_unknown_scan_events(company_id, location_id, created_at DESC);

ALTER TABLE product_identifiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_unknown_scan_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY product_identifiers_member_read ON product_identifiers
  FOR SELECT TO authenticated USING (public.is_company_member(company_id));
CREATE POLICY unknown_scan_events_actor_read ON inventory_unknown_scan_events
  FOR SELECT TO authenticated USING (
    actor_id = public.current_profile_id()
    AND public.has_warehouse_permission(location_id, 'inventory.read')
  );
REVOKE ALL PRIVILEGES ON TABLE product_identifiers, inventory_unknown_scan_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON product_identifiers, inventory_unknown_scan_events TO authenticated;

CREATE OR REPLACE FUNCTION public.resolve_inventory_identifier(
  p_location_id UUID,
  p_code TEXT,
  p_context TEXT DEFAULT 'browse',
  p_document_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor UUID := public.current_profile_id();
  v_company UUID;
  v_norm TEXT := public.normalize_inventory_identifier(p_code);
  v_product products%ROWTYPE;
  v_match_type TEXT;
  v_candidates JSONB := '[]'::jsonb;
  v_count INTEGER := 0;
  v_permission TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE='42501'; END IF;
  IF v_norm = '' THEN RETURN jsonb_build_object('status','invalid','code',v_norm,'candidates','[]'::jsonb); END IF;
  IF p_context NOT IN ('browse','receive','dispatch') THEN RAISE EXCEPTION 'Unsupported scan context' USING ERRCODE='22023'; END IF;
  v_permission := CASE p_context WHEN 'receive' THEN 'inventory.receive' WHEN 'dispatch' THEN 'inventory.dispatch' ELSE 'inventory.read' END;
  IF NOT public.has_warehouse_permission(p_location_id, v_permission) THEN RAISE EXCEPTION 'Warehouse permission required' USING ERRCODE='42501'; END IF;
  SELECT company_id INTO v_company FROM inventory_locations WHERE id=p_location_id;
  IF v_company IS NULL OR NOT public.is_company_member(v_company) THEN RAISE EXCEPTION 'Company membership required' USING ERRCODE='42501'; END IF;

  SELECT p.* INTO v_product
  FROM product_identifiers i JOIN products p ON p.company_id=i.company_id AND p.id=i.product_id
  WHERE i.company_id=v_company AND i.normalized_value=v_norm AND i.is_active
  LIMIT 1;
  IF FOUND THEN v_match_type := 'IDENTIFIER'; END IF;
  IF v_product.id IS NULL THEN
    SELECT p.* INTO v_product FROM products p WHERE p.company_id=v_company AND p.normalized_sku=v_norm LIMIT 1;
    IF FOUND THEN v_match_type := 'SKU'; END IF;
  END IF;
  IF v_product.id IS NULL THEN
    RETURN jsonb_build_object('status','unknown','normalized_code',v_norm,'candidates','[]'::jsonb);
  END IF;

  IF p_context='browse' THEN
    RETURN jsonb_build_object('status','resolved','normalized_code',v_norm,'match_type',v_match_type,
      'product_id',v_product.id,'product_name',v_product.name,'sku',v_product.sku,'candidates','[]'::jsonb);
  END IF;
  IF p_document_id IS NULL THEN RAISE EXCEPTION 'Transactional scan requires document id' USING ERRCODE='22023'; END IF;

  IF p_context='receive' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'line_id',l.id,'line_number',l.line_number,'product_id',l.product_id,'product_name',p.name,'sku',p.sku,
      'bin_id',l.destination_bin_id,'bin_code',b.code,'line_status',l.line_status
    ) ORDER BY l.line_number),'[]'::jsonb), count(*)
    INTO v_candidates,v_count
    FROM inventory_transfer_lines l
    JOIN inventory_transfer_documents d ON d.company_id=l.company_id AND d.id=l.transfer_id
    JOIN products p ON p.id=l.product_id AND p.company_id=l.company_id
    JOIN inventory_bins b ON b.id=l.destination_bin_id AND b.company_id=l.company_id
    WHERE l.company_id=v_company AND l.transfer_id=p_document_id AND l.product_id=v_product.id
      AND d.destination_location_id=p_location_id
      AND l.line_status IN ('OPEN','CAPTURED','EXCEPTION','READY_TO_POST');
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'line_id',l.id,'line_number',l.line_number,'product_id',l.product_id,'product_name',p.name,'sku',p.sku,
      'bin_id',l.source_bin_id,'bin_code',b.code,'line_status',l.line_status
    ) ORDER BY l.line_number),'[]'::jsonb), count(*)
    INTO v_candidates,v_count
    FROM inventory_sales_order_lines l
    JOIN inventory_sales_orders d ON d.company_id=l.company_id AND d.id=l.sales_order_id
    JOIN products p ON p.id=l.product_id AND p.company_id=l.company_id
    JOIN inventory_bins b ON b.id=l.source_bin_id AND b.company_id=l.company_id
    WHERE l.company_id=v_company AND l.sales_order_id=p_document_id AND l.product_id=v_product.id
      AND d.source_location_id=p_location_id
      AND l.line_status IN ('OPEN','CAPTURED','EXCEPTION','READY_TO_POST');
  END IF;

  RETURN jsonb_build_object(
    'status',CASE WHEN v_count=0 THEN 'non_actionable' WHEN v_count=1 THEN 'resolved' ELSE 'ambiguous' END,
    'normalized_code',v_norm,'match_type',v_match_type,'product_id',v_product.id,'product_name',v_product.name,'sku',v_product.sku,
    'candidates',v_candidates
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.report_unknown_inventory_scan(
  p_client_event_id UUID,
  p_location_id UUID,
  p_raw_code TEXT,
  p_context TEXT,
  p_document_type TEXT DEFAULT NULL,
  p_document_id UUID DEFAULT NULL,
  p_client_recorded_at TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,auth,pg_temp
AS $$
DECLARE v_actor UUID:=public.current_profile_id(); v_company UUID; v_id UUID; v_norm TEXT:=public.normalize_inventory_identifier(p_raw_code);
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authenticated operational profile required' USING ERRCODE='42501'; END IF;
  IF p_client_event_id IS NULL OR v_norm='' OR p_client_recorded_at IS NULL THEN RAISE EXCEPTION 'Event id, code and timestamp are required' USING ERRCODE='22023'; END IF;
  IF p_context NOT IN ('browse','receive','dispatch') THEN RAISE EXCEPTION 'Invalid scan context' USING ERRCODE='22023'; END IF;
  IF NOT public.has_warehouse_permission(p_location_id,'inventory.read') THEN RAISE EXCEPTION 'Warehouse read permission required' USING ERRCODE='42501'; END IF;
  SELECT company_id INTO v_company FROM inventory_locations WHERE id=p_location_id;
  INSERT INTO inventory_unknown_scan_events(company_id,client_event_id,location_id,actor_id,raw_code,normalized_code,scan_context,document_type,document_id,client_recorded_at)
  VALUES(v_company,p_client_event_id,p_location_id,v_actor,p_raw_code,v_norm,p_context,p_document_type,p_document_id,p_client_recorded_at)
  ON CONFLICT(company_id,client_event_id) DO UPDATE SET client_event_id=EXCLUDED.client_event_id
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('success',true,'event_id',v_id,'client_event_id',p_client_event_id);
END;
$$;

REVOKE ALL ON FUNCTION public.normalize_inventory_identifier(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.normalize_inventory_identifier(TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.resolve_inventory_identifier(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_inventory_identifier(UUID,TEXT,TEXT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.report_unknown_inventory_scan(UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_unknown_inventory_scan(UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) TO authenticated;

COMMENT ON TABLE product_identifiers IS 'Tenant-scoped exact product identifiers. SKU remains on products; BARCODE/GTIN/ALIAS values live here and never use substring matching for transactional resolution.';
COMMENT ON TABLE inventory_unknown_scan_events IS 'Durable audit trail of unknown scanner codes, including offline-replayed client event ids and task context.';
