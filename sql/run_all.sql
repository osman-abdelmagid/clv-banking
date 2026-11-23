-- ============================================================================
-- File:    run_all.sql
-- Purpose: Rebuild the whole project from the raw CSVs in one command.
--
--   createdb clv_banking
--   psql -d clv_banking -v ON_ERROR_STOP=1 -f sql/run_all.sql      (from the project root)
--
-- Takes about a minute. Safe to re-run: every script drops what it creates.
-- ============================================================================

\echo '== 00 schemas'
\i sql/00_schemas.sql

\echo '== 01 raw tables'
\i sql/01_create_raw.sql

\echo '== load raw CSVs'
\copy raw.account  FROM 'data/raw/account.csv'  WITH (FORMAT csv, HEADER, DELIMITER ';')
\copy raw.client   FROM 'data/raw/client.csv'   WITH (FORMAT csv, HEADER, DELIMITER ';')
\copy raw.disp     FROM 'data/raw/disp.csv'     WITH (FORMAT csv, HEADER, DELIMITER ';')
\copy raw.trans    FROM 'data/raw/trans.csv'    WITH (FORMAT csv, HEADER, DELIMITER ';')
\copy raw.loan     FROM 'data/raw/loan.csv'     WITH (FORMAT csv, HEADER, DELIMITER ';')
\copy raw.card     FROM 'data/raw/card.csv'     WITH (FORMAT csv, HEADER, DELIMITER ';')
\copy raw.orders   FROM 'data/raw/order.csv'    WITH (FORMAT csv, HEADER, DELIMITER ';')
\copy raw.district FROM 'data/raw/district.csv' WITH (FORMAT csv, HEADER, DELIMITER ';')

\echo '== 02 verify load'
\i sql/02_load_raw.sql

\echo '== 03 staging'
\i sql/03_staging.sql

\echo '== 04 customer-year panel'
\i sql/04_mart_customer_year.sql

\echo '== 05 states and transition matrices'
\i sql/05_mart_states.sql

\echo '== 06 CLV projection'
\i sql/06_mart_clv.sql

\echo '== 07 validation'
\i sql/07_validation.sql

\echo '== 08 tests'
\i sql/08_tests.sql

\echo '== 09 export for Power BI'
\i sql/09_export.sql

\echo '== done'
