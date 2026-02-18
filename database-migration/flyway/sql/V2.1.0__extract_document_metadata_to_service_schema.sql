-- V2.1.0__extract_document_metadata_to_service_schema.sql
-- Migration: Extract document metadata from shared schema to document-service schema
-- Strategy: Non-destructive dual-write with triggers during migration window

-- =====================================================================
-- STEP 1: Create new schema owned by document-service
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS document_service;

-- =====================================================================
-- STEP 2: Create new tables in document_service schema
-- =====================================================================

-- Documents table
CREATE TABLE document_service.documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(255) NOT NULL,
    content_type VARCHAR(100) NOT NULL,
    file_size BIGINT NOT NULL,
    storage_path VARCHAR(500) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    created_by UUID NOT NULL,
    version INT NOT NULL DEFAULT 1,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    
    -- Indexes
    CONSTRAINT documents_status_check CHECK (status IN ('active', 'archived', 'deleted'))
);

CREATE INDEX idx_documents_created_by ON document_service.documents(created_by);
CREATE INDEX idx_documents_status ON document_service.documents(status);
CREATE INDEX idx_documents_created_at ON document_service.documents(created_at DESC);

-- Document metadata table
CREATE TABLE document_service.metadata (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL,
    key VARCHAR(100) NOT NULL,
    value TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    -- Foreign key to documents
    CONSTRAINT fk_metadata_document 
        FOREIGN KEY (document_id) 
        REFERENCES document_service.documents(id) 
        ON DELETE CASCADE,
    
    -- Unique constraint on document_id + key
    CONSTRAINT uq_metadata_document_key UNIQUE (document_id, key)
);

CREATE INDEX idx_metadata_document_id ON document_service.metadata(document_id);
CREATE INDEX idx_metadata_key ON document_service.metadata(key);

-- =====================================================================
-- STEP 3: Copy existing data (non-destructive)
-- =====================================================================

-- Copy documents from shared schema
INSERT INTO document_service.documents (
    id, title, content_type, file_size, storage_path, 
    created_at, updated_at, created_by, version, status
)
SELECT 
    id, title, content_type, file_size, storage_path,
    created_at, updated_at, created_by, version, status
FROM shared.documents
WHERE NOT EXISTS (
    SELECT 1 FROM document_service.documents ds WHERE ds.id = shared.documents.id
);

-- Copy metadata from shared schema
INSERT INTO document_service.metadata (
    id, document_id, key, value, created_at
)
SELECT 
    id, document_id, key, value, created_at
FROM shared.document_metadata
WHERE NOT EXISTS (
    SELECT 1 FROM document_service.metadata dm WHERE dm.id = shared.document_metadata.id
);

-- =====================================================================
-- STEP 4: Create dual-write triggers (temporary during migration)
-- =====================================================================

-- Trigger function: Sync documents table changes to new schema
CREATE OR REPLACE FUNCTION sync_documents_to_new_schema()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO document_service.documents 
            (id, title, content_type, file_size, storage_path, created_at, updated_at, created_by, version, status)
        VALUES 
            (NEW.id, NEW.title, NEW.content_type, NEW.file_size, NEW.storage_path, 
             NEW.created_at, NEW.updated_at, NEW.created_by, NEW.version, NEW.status)
        ON CONFLICT (id) DO UPDATE SET
            title = EXCLUDED.title,
            content_type = EXCLUDED.content_type,
            file_size = EXCLUDED.file_size,
            storage_path = EXCLUDED.storage_path,
            updated_at = EXCLUDED.updated_at,
            version = EXCLUDED.version,
            status = EXCLUDED.status;
            
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE document_service.documents SET
            title = NEW.title,
            content_type = NEW.content_type,
            file_size = NEW.file_size,
            storage_path = NEW.storage_path,
            updated_at = NEW.updated_at,
            version = NEW.version,
            status = NEW.status
        WHERE id = NEW.id;
        
    ELSIF TG_OP = 'DELETE' THEN
        DELETE FROM document_service.documents WHERE id = OLD.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger to shared.documents
CREATE TRIGGER sync_documents_trigger
AFTER INSERT OR UPDATE OR DELETE ON shared.documents
FOR EACH ROW EXECUTE FUNCTION sync_documents_to_new_schema();

-- Trigger function: Sync metadata table changes to new schema
CREATE OR REPLACE FUNCTION sync_metadata_to_new_schema()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO document_service.metadata 
            (id, document_id, key, value, created_at)
        VALUES 
            (NEW.id, NEW.document_id, NEW.key, NEW.value, NEW.created_at)
        ON CONFLICT (document_id, key) DO UPDATE SET
            value = EXCLUDED.value;
            
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE document_service.metadata SET
            value = NEW.value
        WHERE id = NEW.id;
        
    ELSIF TG_OP = 'DELETE' THEN
        DELETE FROM document_service.metadata WHERE id = OLD.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger to shared.document_metadata
CREATE TRIGGER sync_metadata_trigger
AFTER INSERT OR UPDATE OR DELETE ON shared.document_metadata
FOR EACH ROW EXECUTE FUNCTION sync_metadata_to_new_schema();

-- =====================================================================
-- STEP 5: Create service-specific database user and permissions
-- =====================================================================

-- Create dedicated user for document-service
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = 'document_service_user') THEN
        CREATE USER document_service_user WITH PASSWORD 'CHANGE_ME_IN_PRODUCTION';
    END IF;
END
$$;

-- Grant permissions
GRANT USAGE ON SCHEMA document_service TO document_service_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA document_service TO document_service_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA document_service TO document_service_user;

-- Ensure future tables also get permissions
ALTER DEFAULT PRIVILEGES IN SCHEMA document_service
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO document_service_user;

-- =====================================================================
-- STEP 6: Add audit columns and updated_at trigger
-- =====================================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER documents_updated_at
BEFORE UPDATE ON document_service.documents
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =====================================================================
-- NOTES FOR CUTOVER
-- =====================================================================

-- When ready to complete migration (after validating new service):
-- 1. Deploy document-service pointing to document_service schema
-- 2. Update strangler proxy to route 100% traffic to new service
-- 3. Monitor for 24-48 hours
-- 4. Run V2.2.0__cleanup_dual_write_triggers.sql to remove triggers
-- 5. Optionally drop shared.documents and shared.document_metadata tables

COMMENT ON SCHEMA document_service IS 
'Document service isolated schema. Dual-write triggers active until migration V2.2.0.';
