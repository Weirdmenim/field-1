CREATE OR REPLACE FUNCTION post_inventory_operation(
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
AS $$
DECLARE
    v_operation_id UUID;
    v_existing_status operation_status;
    v_existing_fingerprint TEXT;
    v_movement_id UUID;
    v_source_balance NUMERIC;
BEGIN
    -- 1. Idempotency Check
    SELECT id, status, request_fingerprint 
    INTO v_operation_id, v_existing_status, v_existing_fingerprint
    FROM inventory_operations
    WHERE company_id = p_company_id 
      AND operation_type = p_operation_type 
      AND client_transaction_id = p_client_transaction_id
    FOR UPDATE;

    IF FOUND THEN
        IF v_existing_status = 'COMPLETED' THEN
            IF v_existing_fingerprint = p_request_fingerprint THEN
                -- Already processed successfully, return success safely
                RETURN jsonb_build_object('success', true, 'operation_id', v_operation_id, 'status', 'ALREADY_COMPLETED');
            ELSE
                RAISE EXCEPTION 'Idempotency conflict: Same transaction ID with different payload.';
            END IF;
        END IF;
    ELSE
        -- Insert new operation
        INSERT INTO inventory_operations(
            company_id, operation_type, client_transaction_id, request_fingerprint, initiating_actor, status
        )
        VALUES (
            p_company_id, p_operation_type, p_client_transaction_id, p_request_fingerprint, p_initiating_actor, 'PROCESSING'
        )
        RETURNING id INTO v_operation_id;
    END IF;

    -- 2. Process Source Location (Deduction)
    IF p_source_location_id IS NOT NULL THEN
        -- Upsert balance safely
        INSERT INTO inventory_balances (company_id, location_id, product_id, inventory_status, on_hand_base_qty, physical_status_revision)
        VALUES (p_company_id, p_source_location_id, p_product_id, p_source_status, -p_base_quantity, 1)
        ON CONFLICT (company_id, location_id, product_id, inventory_status) 
        DO UPDATE SET 
            on_hand_base_qty = inventory_balances.on_hand_base_qty - p_base_quantity,
            physical_status_revision = inventory_balances.physical_status_revision + 1,
            updated_at = now()
        RETURNING on_hand_base_qty INTO v_source_balance;
    END IF;

    -- 3. Process Destination Location (Addition)
    IF p_destination_location_id IS NOT NULL THEN
        INSERT INTO inventory_balances (company_id, location_id, product_id, inventory_status, on_hand_base_qty, physical_status_revision)
        VALUES (p_company_id, p_destination_location_id, p_product_id, p_destination_status, p_base_quantity, 1)
        ON CONFLICT (company_id, location_id, product_id, inventory_status) 
        DO UPDATE SET 
            on_hand_base_qty = inventory_balances.on_hand_base_qty + p_base_quantity,
            physical_status_revision = inventory_balances.physical_status_revision + 1,
            updated_at = now();
    END IF;

    -- 4. Record Movement
    INSERT INTO inventory_movements (
        company_id, product_id, movement_type, 
        source_location_id, destination_location_id, 
        source_inventory_status, destination_inventory_status, 
        entered_quantity, base_quantity, 
        reference_type, reference_id, reference_number, 
        performed_by, client_transaction_id, operation_id, posted_at
    )
    VALUES (
        p_company_id, p_product_id, p_movement_type,
        p_source_location_id, p_destination_location_id,
        p_source_status, p_destination_status,
        p_entered_quantity, p_base_quantity,
        p_reference_type, p_reference_id, p_reference_number,
        p_initiating_actor, p_client_transaction_id, v_operation_id, now()
    ) RETURNING id INTO v_movement_id;

    -- 5. Mark operation complete
    UPDATE inventory_operations 
    SET status = 'COMPLETED', posted_at = now() 
    WHERE id = v_operation_id;

    RETURN jsonb_build_object('success', true, 'operation_id', v_operation_id, 'movement_id', v_movement_id);
END;
$$;

-- JSONB wrapper overload to support single payload RPC calls from client
CREATE OR REPLACE FUNCTION post_inventory_operation(p_operation JSONB)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_movement_type movement_type;
    v_source_loc UUID;
    v_dest_loc UUID;
    v_op_type TEXT;
    v_qty NUMERIC;
BEGIN
    v_op_type := p_operation->>'operation_type';
    v_qty := COALESCE((p_operation->>'qty')::NUMERIC, 0);

    IF v_op_type = 'RECEIPT' THEN
        v_movement_type := 'TRANSFER_IN';
        v_source_loc := NULL;
        v_dest_loc := (p_operation->>'location_id')::UUID;
    ELSIF v_op_type = 'DISPATCH' THEN
        v_movement_type := 'TRANSFER_OUT';
        v_source_loc := (p_operation->>'location_id')::UUID;
        v_dest_loc := NULL;
    ELSIF v_op_type = 'COUNT' THEN
        v_movement_type := 'STOCK_ADJUSTMENT_IN';
        v_source_loc := NULL;
        v_dest_loc := (p_operation->>'location_id')::UUID;
    ELSE
        v_movement_type := 'STOCK_ADJUSTMENT_IN';
        v_source_loc := NULL;
        v_dest_loc := (p_operation->>'location_id')::UUID;
    END IF;

    RETURN post_inventory_operation(
        (p_operation->>'company_id')::UUID,
        v_op_type,
        p_operation->>'client_transaction_id',
        COALESCE(p_operation->>'request_fingerprint', md5(p_operation::text)),
        (p_operation->>'user_id')::UUID,
        (p_operation->>'product_id')::UUID,
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

