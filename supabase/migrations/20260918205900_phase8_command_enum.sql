-- Phase 8 enum expansion isolated so PostgreSQL commits the new value before functions use it.
ALTER TYPE document_command_type ADD VALUE IF NOT EXISTS 'TRANSFER_EXCEPTION_DISPOSITION';
