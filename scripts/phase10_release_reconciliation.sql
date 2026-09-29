\set ON_ERROR_STOP on
-- Phase 10 release reconciliation. Every SELECT below must return zero rows/count zero.
DO $$
DECLARE v_count bigint;
BEGIN
  SELECT count(*) INTO v_count FROM inventory_balances WHERE reserved_base_qty <> 0;
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % balance rows still use deprecated reserved_base_qty',v_count; END IF;

  SELECT count(*) INTO v_count
  FROM inventory_balances b JOIN inventory_locations l ON l.company_id=b.company_id AND l.id=b.location_id
  WHERE b.on_hand_base_qty < 0 AND (b.inventory_status <> 'AVAILABLE' OR NOT l.allow_negative_inventory);
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % policy-invalid negative balance rows',v_count; END IF;

  SELECT count(*) INTO v_count FROM inventory_reservations
  WHERE reserved_base_qty <= 0 OR fulfilled_base_qty < 0 OR released_base_qty < 0
     OR fulfilled_base_qty + released_base_qty > reserved_base_qty;
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % invalid reservation progress rows',v_count; END IF;

  SELECT count(*) INTO v_count FROM (
    SELECT r.company_id,r.location_id,r.product_id,
      sum(r.reserved_base_qty-r.fulfilled_base_qty-r.released_base_qty) reserved,
      COALESCE((SELECT sum(b.on_hand_base_qty) FROM inventory_balances b WHERE b.company_id=r.company_id AND b.location_id=r.location_id AND b.product_id=r.product_id AND b.inventory_status='AVAILABLE'),0) available
    FROM inventory_reservations r WHERE r.status IN ('ACTIVE','PARTIALLY_FULFILLED')
    GROUP BY r.company_id,r.location_id,r.product_id
  ) x WHERE x.reserved < 0 OR x.reserved > GREATEST(x.available,0);
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % reservation groups exceed available physical stock',v_count; END IF;

  SELECT count(*) INTO v_count FROM inventory_transit_lots
  WHERE received_base_quantity < 0 OR lost_base_quantity < 0 OR received_base_quantity + lost_base_quantity > base_quantity;
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % invalid transit progress rows',v_count; END IF;

  SELECT count(*) INTO v_count FROM inventory_sales_order_lines
  WHERE posted_base_quantity > captured_picked_base_quantity
     OR posted_base_quantity + backordered_base_quantity > requested_base_quantity
     OR captured_picked_base_quantity + backordered_base_quantity > requested_base_quantity;
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % invalid sales-order line progress rows',v_count; END IF;

  SELECT count(*) INTO v_count FROM inventory_transfer_lines
  WHERE captured_received_base_quantity > expected_base_quantity OR posted_base_quantity > expected_base_quantity;
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % invalid transfer line progress rows',v_count; END IF;

  SELECT count(*) INTO v_count FROM inventory_document_commands
  WHERE status='COMPLETED' AND (completed_at IS NULL OR COALESCE((result_payload->>'success')::boolean,false)=false);
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % completed document commands lack successful terminal result',v_count; END IF;

  SELECT count(*) INTO v_count FROM inventory_document_commands
  WHERE status='PROCESSING' AND created_at < now()-interval '10 minutes';
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % document commands are stale in PROCESSING',v_count; END IF;

  SELECT count(*) INTO v_count FROM inventory_sales_orders d
  WHERE d.status='COMPLETED' AND EXISTS(
    SELECT 1 FROM inventory_sales_order_lines l WHERE l.company_id=d.company_id AND l.sales_order_id=d.id
      AND l.line_status<>'CANCELLED' AND l.posted_base_quantity+l.backordered_base_quantity<>l.requested_base_quantity
  );
  IF v_count <> 0 THEN RAISE EXCEPTION 'Reconciliation failed: % completed sales orders contain unresolved requested quantity',v_count; END IF;
END $$;

SELECT jsonb_build_object(
  'balances',(SELECT count(*) FROM inventory_balances),
  'movements',(SELECT count(*) FROM inventory_movements),
  'reservations',(SELECT count(*) FROM inventory_reservations),
  'transitLots',(SELECT count(*) FROM inventory_transit_lots),
  'documentCommands',(SELECT count(*) FROM inventory_document_commands),
  'salesOrders',(SELECT count(*) FROM inventory_sales_orders),
  'transfers',(SELECT count(*) FROM inventory_transfer_documents),
  'countSessions',(SELECT count(*) FROM inventory_count_sessions),
  'checkedAt',clock_timestamp()
) AS reconciliation_summary;
