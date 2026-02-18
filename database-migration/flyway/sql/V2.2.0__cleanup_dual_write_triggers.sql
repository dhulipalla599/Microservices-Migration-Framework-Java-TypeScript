-- V2.2.0__cleanup_dual_write_triggers.sql
-- Run this AFTER validating new document-service in production
-- This removes the temporary dual-write triggers

-- Drop triggers
DROP TRIGGER IF EXISTS sync_documents_trigger ON shared.documents;
DROP TRIGGER IF EXISTS sync_metadata_trigger ON shared.document_metadata;

-- Drop trigger functions
DROP FUNCTION IF EXISTS sync_documents_to_new_schema();
DROP FUNCTION IF EXISTS sync_metadata_to_new_schema();

-- Optional: Archive or drop old tables
-- CAUTION: Only do this after confirming all services use new schema

-- Archive old data (recommended)
CREATE TABLE IF NOT EXISTS shared.documents_archived AS
SELECT * FROM shared.documents;

CREATE TABLE IF NOT EXISTS shared.document_metadata_archived AS
SELECT * FROM shared.document_metadata;

-- Then drop original tables
-- DROP TABLE shared.document_metadata;
-- DROP TABLE shared.documents;

COMMENT ON SCHEMA document_service IS 
'Document service isolated schema. Dual-write triggers removed in V2.2.0. Legacy tables archived.';
