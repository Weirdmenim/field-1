-- Stubs for dependencies not in the inventory module
CREATE TABLE IF NOT EXISTS companies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  full_name TEXT NOT NULL,
  role TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  name TEXT NOT NULL,
  sku TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Inventory Enums
CREATE TYPE location_type AS ENUM (
  'CENTRAL_WAREHOUSE', 'REGIONAL_WAREHOUSE', 'BRANCH_DEPOT', 'REP_STORE', 'VAN_STORE', 'OTHER_INTERNAL'
);

CREATE TYPE inventory_status AS ENUM (
  'AVAILABLE', 'DAMAGED', 'BLOCKED'
);

CREATE TYPE movement_type AS ENUM (
  'OPENING_BALANCE', 'TRANSFER_OUT', 'TRANSFER_IN', 'TRANSFER_RETURN_IN', 'SALE', 'SALE_REVERSAL', 'CUSTOMER_RETURN', 
  'STOCK_ADJUSTMENT_IN', 'STOCK_ADJUSTMENT_OUT', 'STATUS_CHANGE', 'DAMAGE', 'STOCK_COUNT_VARIANCE_IN', 
  'STOCK_COUNT_VARIANCE_OUT', 'TRANSFER_REVERSAL', 'TRANSFER_LOSS', 'EXPIRY', 'PURCHASE_RECEIPT'
);

CREATE TYPE operation_status AS ENUM (
  'PENDING', 'PROCESSING', 'COMPLETED', 'FAILED'
);

-- Inventory Core Tables
CREATE TABLE inventory_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  name TEXT NOT NULL,
  code TEXT NOT NULL,
  location_type location_type NOT NULL,
  region_id UUID,
  territory_id UUID,
  responsible_user_id UUID REFERENCES profiles(id),
  address TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  allow_direct_sales BOOLEAN NOT NULL DEFAULT false,
  allow_negative_inventory BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, code)
);

CREATE TABLE product_units (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  product_id UUID NOT NULL REFERENCES products(id),
  unit_name TEXT NOT NULL,
  unit_code TEXT NOT NULL,
  conversion_to_base NUMERIC NOT NULL CHECK (conversion_to_base > 0),
  is_base_unit BOOLEAN NOT NULL DEFAULT false,
  is_default_sale_unit BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true
);

-- Ensure only one base unit and default sale unit per product (simplified with a unique index where true)
CREATE UNIQUE INDEX product_units_base_idx ON product_units (product_id) WHERE is_base_unit = true;
CREATE UNIQUE INDEX product_units_default_sale_idx ON product_units (product_id) WHERE is_default_sale_unit = true;

CREATE TABLE inventory_balances (
  company_id UUID NOT NULL REFERENCES companies(id),
  location_id UUID NOT NULL REFERENCES inventory_locations(id),
  product_id UUID NOT NULL REFERENCES products(id),
  inventory_status inventory_status NOT NULL,
  on_hand_base_qty NUMERIC NOT NULL DEFAULT 0,
  reserved_base_qty NUMERIC NOT NULL DEFAULT 0,
  physical_status_revision BIGINT NOT NULL DEFAULT 1,
  reservation_revision BIGINT NOT NULL DEFAULT 1,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, location_id, product_id, inventory_status)
);

CREATE TABLE inventory_operations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  operation_type TEXT NOT NULL,
  client_transaction_id TEXT NOT NULL,
  request_fingerprint TEXT NOT NULL,
  source_document_type TEXT,
  source_document_id UUID,
  initiating_actor UUID REFERENCES profiles(id),
  status operation_status NOT NULL DEFAULT 'PENDING',
  posted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (company_id, operation_type, client_transaction_id)
);

CREATE TABLE inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id),
  product_id UUID NOT NULL REFERENCES products(id),
  movement_type movement_type NOT NULL,
  source_location_id UUID REFERENCES inventory_locations(id),
  destination_location_id UUID REFERENCES inventory_locations(id),
  source_inventory_status inventory_status,
  destination_inventory_status inventory_status,
  entered_quantity NUMERIC NOT NULL CHECK (entered_quantity >= 0),
  entered_unit_id UUID REFERENCES product_units(id),
  base_quantity NUMERIC NOT NULL CHECK (base_quantity >= 0),
  direction TEXT,
  client_recorded_at TIMESTAMPTZ,
  server_received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  reference_type TEXT,
  reference_id UUID,
  reference_number TEXT,
  reason_code TEXT,
  reason_text TEXT,
  performed_by UUID REFERENCES profiles(id),
  approved_by UUID REFERENCES profiles(id),
  client_transaction_id TEXT NOT NULL,
  operation_id UUID REFERENCES inventory_operations(id),
  reversal_of_movement_id UUID,
  posted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create basic views or RPCs placeholders for atomic updates later
