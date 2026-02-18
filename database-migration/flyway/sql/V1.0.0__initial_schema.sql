-- V1.0.0__initial_schema.sql
-- Legacy monolith shared schema

CREATE SCHEMA IF NOT EXISTS shared;

-- Users table
CREATE TABLE shared.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    username VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL DEFAULT 'user',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_users_email ON shared.users(email);

-- Documents table (to be extracted later)
CREATE TABLE shared.documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(255) NOT NULL,
    content_type VARCHAR(100) NOT NULL,
    file_size BIGINT NOT NULL,
    storage_path VARCHAR(500) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    created_by UUID REFERENCES shared.users(id),
    version INT NOT NULL DEFAULT 1,
    status VARCHAR(50) NOT NULL DEFAULT 'active'
);

CREATE INDEX idx_documents_created_by ON shared.documents(created_by);
CREATE INDEX idx_documents_status ON shared.documents(status);

-- Document metadata (to be extracted later)
CREATE TABLE shared.document_metadata (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES shared.documents(id) ON DELETE CASCADE,
    key VARCHAR(100) NOT NULL,
    value TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    UNIQUE(document_id, key)
);

-- Pricing table
CREATE TABLE shared.pricing_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_code VARCHAR(100) UNIQUE NOT NULL,
    base_price DECIMAL(10, 2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'USD',
    effective_date DATE NOT NULL,
    expiry_date DATE,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_pricing_product ON shared.pricing_rules(product_code);
CREATE INDEX idx_pricing_dates ON shared.pricing_rules(effective_date, expiry_date);

-- Insert sample data
INSERT INTO shared.users (email, username, password_hash, role) VALUES
('admin@example.com', 'admin', '$2a$10$rO5Z8qKZHKZQxKZHKZHKZeJ5Y8qKZHKZQxKZHKZHKZHKZQ', 'admin'),
('user@example.com', 'user', '$2a$10$rO5Z8qKZHKZQxKZHKZHKZeJ5Y8qKZHKZQxKZHKZHKZHKZQ', 'user');

INSERT INTO shared.pricing_rules (product_code, base_price, effective_date) VALUES
('PROD-001', 99.99, '2024-01-01'),
('PROD-002', 149.99, '2024-01-01'),
('PROD-003', 199.99, '2024-01-01');
