-- ============================================================================
-- File:    00_schemas.sql
-- Purpose: Create the three-layer (medallion) schema structure for the
--          CLV banking project
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS mart;
