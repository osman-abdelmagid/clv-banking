-- ============================================================================
-- File:    02_load_raw.sql
-- Purpose: Verify that all 8 raw tables were loaded correctly
-- The verification numbers come from official documentation
-- ============================================================================

SELECT
    'account' AS table_name,
    COUNT(*) AS row_count,
    4500 AS expected
FROM raw.account

UNION ALL

SELECT 'client', COUNT(*), 5369 FROM raw.client

UNION ALL

SELECT 'disp', COUNT(*), 5369 FROM raw.disp

UNION ALL

SELECT 'trans', COUNT(*), 1056320 FROM raw.trans

UNION ALL

SELECT 'loan', COUNT(*), 682 FROM raw.loan

UNION ALL

SELECT 'card', COUNT(*), 892 FROM raw.card

UNION ALL

SELECT 'orders', COUNT(*), 6471 FROM raw.orders

UNION ALL

SELECT 'district', COUNT(*), 77 FROM raw.district

ORDER BY table_name;