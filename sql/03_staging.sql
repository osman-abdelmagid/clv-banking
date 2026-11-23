-- ============================================================================
-- File:    03_staging.sql
-- Purpose: Build cleaned, typed, corrected versions of every raw table.
--          This is the "staging" layer of the medallion architecture --
--          nothing here is analysis yet, it's just making the data trustworthy.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- STAGING.ACCOUNT
-- Source quirks handled:
--   1. "date" arrives as an integer like 930101 (YYMMDD) -- needs real parsing.
--   2. "frequency" arrives as a Czech phrase -- mapped to plain English.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.account CASCADE;

CREATE TABLE staging.account AS
SELECT
    account_id::INT AS account_id,
    district_id::INT AS district_id,

    CASE frequency
        WHEN 'POPLATEK MESICNE'   THEN 'monthly_statement'
        WHEN 'POPLATEK TYDNE'     THEN 'weekly_statement'
        WHEN 'POPLATEK PO OBRATU' THEN 'per_transaction_statement'
    END AS statement_frequency,

    TO_DATE(date, 'YYMMDD') AS open_date

FROM raw.account;

SELECT * FROM staging.account LIMIT 5;

-- ----------------------------------------------------------------------------
-- STAGING.CLIENT
-- Source quirk: "birth_number" encodes BOTH date of birth AND gender in one
-- field. Format is YYMMDD normally -- but for women, 50 is added to the
-- month. So month 15 = January, male. Month 65 = January, female (65-50=15).
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.client CASCADE;

CREATE TABLE staging.client AS
SELECT
    client_id::INT AS client_id,
    district_id::INT AS district_id,

    CASE
        WHEN SUBSTRING(birth_number, 3, 2)::INT > 50 THEN 'F'
        ELSE 'M'
    END AS gender,

    MAKE_DATE(
        1900 + SUBSTRING(birth_number, 1, 2)::INT,
        CASE
            WHEN SUBSTRING(birth_number, 3, 2)::INT > 50
                THEN SUBSTRING(birth_number, 3, 2)::INT - 50
            ELSE SUBSTRING(birth_number, 3, 2)::INT
        END,
        SUBSTRING(birth_number, 5, 2)::INT
    ) AS birth_date

FROM raw.client;

SELECT * FROM staging.client LIMIT 5;

-- ----------------------------------------------------------------------------
-- STAGING.DISP
-- Bridge table linking clients to accounts. "type" tells us whether this
-- client is the account OWNER or a DISPONENT (secondary, shared access).
-- We standardize the values to lowercase for easier filtering later.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.disp CASCADE;

CREATE TABLE staging.disp AS
SELECT
    disp_id::INT AS disp_id,
    client_id::INT AS client_id,
    account_id::INT AS account_id,
    LOWER(TRIM(type)) AS role   -- 'owner' or 'disponent'
FROM raw.disp;

SELECT role, COUNT(*) FROM staging.disp GROUP BY role;

-- ----------------------------------------------------------------------------
-- STAGING.TRANS
-- The core transaction table (1,056,320 rows). Audit-driven corrections:
--   1. "type" has an undocumented 3rd value (VYBER) that also means debit.
--   2. "k_symbol" contains both '' and ' ' (a single space) meaning "none" --
--      TRIM handles both the same way.
--   3. "amount" is always stored positive; direction lives in "type" --
--      we sign it here so sums are meaningful.
--   4. is_customer_activity flags rows the CUSTOMER generated, excluding
--      bank-generated postings (interest, penalties, fees). This protects
--      churn detection later -- a dormant account shouldn't look "active"
--      just because the bank auto-posted interest to it.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.trans CASCADE;

CREATE TABLE staging.trans AS
SELECT
    trans_id::BIGINT AS trans_id,
    account_id::INT AS account_id,

    TO_DATE(date, 'YYMMDD') AS trans_date,
    EXTRACT(YEAR FROM TO_DATE(date, 'YYMMDD'))::INT AS trans_year,

    CASE TRIM(type)
        WHEN 'PRIJEM' THEN 'credit'
        ELSE 'debit'          -- covers both VYDAJ and the VYBER quirk
    END AS direction,

    CASE TRIM(COALESCE(operation, ''))
        WHEN 'VKLAD'          THEN 'cash_deposit'
        WHEN 'VYBER'          THEN 'cash_withdrawal'
        WHEN 'VYBER KARTOU'   THEN 'card_withdrawal'
        WHEN 'PREVOD Z UCTU'  THEN 'inbound_transfer'
        WHEN 'PREVOD NA UCET' THEN 'outbound_transfer'
        ELSE 'none'
    END AS operation,

    CASE TRIM(COALESCE(k_symbol, ''))
        WHEN 'UROK'        THEN 'interest_credited'
        WHEN 'SANKC. UROK' THEN 'penalty_interest'
        WHEN 'SLUZBY'      THEN 'statement_fee'
        WHEN 'POJISTNE'    THEN 'insurance_payment'
        WHEN 'SIPO'        THEN 'household_payment'
        WHEN 'DUCHOD'      THEN 'pension_credit'
        WHEN 'UVER'        THEN 'loan_payment'
        ELSE 'none'
    END AS category,

    amount::NUMERIC AS amount,

    CASE
        WHEN TRIM(type) = 'PRIJEM' THEN amount::NUMERIC
        ELSE -amount::NUMERIC
    END AS amount_signed,

    balance::NUMERIC AS balance,

    TRIM(COALESCE(k_symbol, '')) NOT IN ('UROK', 'SANKC. UROK', 'SLUZBY') AS is_customer_activity

FROM raw.trans;

-- Indexes speed up the joins and groupings we'll do in the next step
CREATE INDEX idx_trans_acct_date ON staging.trans (account_id, trans_date);
CREATE INDEX idx_trans_acct_year ON staging.trans (account_id, trans_year);

-- Check 1: no debit rows accidentally left with a positive signed amount
SELECT COUNT(*) FROM staging.trans WHERE direction = 'debit' AND amount_signed > 0;

-- Check 2: no dates failed to parse
SELECT COUNT(*) FROM staging.trans WHERE trans_date IS NULL;

-- Check 3: how much of the data is actually customer activity vs bank-generated?
SELECT is_customer_activity, COUNT(*) FROM staging.trans GROUP BY is_customer_activity;

-- ----------------------------------------------------------------------------
-- STAGING.LOAN
-- Source quirks handled:
--   1. "date" is YYMMDD, same as account.
--   2. "status" is a one-letter code. A/C = performing, B/D = in default.
--   3. payments * duration = amount exactly for all 682 loans, i.e. the table
--      stores principal only and carries NO interest. Loan revenue therefore
--      cannot be read from the data and is modelled in the mart from an
--      explicit spread assumption (see mart.assumption).
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.loan CASCADE;

CREATE TABLE staging.loan AS
SELECT
    loan_id::INT              AS loan_id,
    account_id::INT           AS account_id,
    TO_DATE(date, 'YYMMDD')   AS grant_date,
    amount::NUMERIC           AS principal,
    duration::INT             AS duration_months,
    payments::NUMERIC         AS monthly_payment,
    TRIM(status)              AS status_code,
    CASE TRIM(status)
        WHEN 'A' THEN 'finished_repaid'
        WHEN 'B' THEN 'finished_defaulted'
        WHEN 'C' THEN 'running_ok'
        WHEN 'D' THEN 'running_in_debt'
    END                       AS status,
    TRIM(status) IN ('B', 'D') AS is_default
FROM raw.loan;

-- Check: the "no interest in the loan table" quirk holds for every row
SELECT COUNT(*) AS loans_where_payments_x_duration_differs
FROM staging.loan
WHERE ABS(principal - monthly_payment * duration_months) > 1;

-- ----------------------------------------------------------------------------
-- STAGING.CARD
-- "issued" arrives as 'YYMMDD 00:00:00' -- only the first 6 characters matter.
-- Cards hang off a disposition (disp_id), not directly off an account.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.card CASCADE;

CREATE TABLE staging.card AS
SELECT
    card_id::INT                          AS card_id,
    disp_id::INT                          AS disp_id,
    LOWER(TRIM(type))                     AS card_type,   -- junior / classic / gold
    TO_DATE(SUBSTRING(issued, 1, 6), 'YYMMDD') AS issue_date
FROM raw.card;

SELECT card_type, COUNT(*) FROM staging.card GROUP BY card_type;

-- ----------------------------------------------------------------------------
-- STAGING.ORDERS
-- Standing (permanent) payment orders. No dates in the source, so this table
-- describes the account's standing commitments, not a time series.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.orders CASCADE;

CREATE TABLE staging.orders AS
SELECT
    order_id::INT    AS order_id,
    account_id::INT  AS account_id,
    amount::NUMERIC  AS amount,
    CASE TRIM(COALESCE(k_symbol, ''))
        WHEN 'POJISTNE' THEN 'insurance_payment'
        WHEN 'SIPO'     THEN 'household_payment'
        WHEN 'LEASING'  THEN 'leasing_payment'
        WHEN 'UVER'     THEN 'loan_payment'
        ELSE 'other'
    END              AS category
FROM raw.orders;

-- ----------------------------------------------------------------------------
-- STAGING.DISTRICT
-- Columns arrive as A1..A16. Renamed from the PKDD'99 data dictionary.
-- '?' is the source's missing-value marker (one district, 1995 figures).
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.district CASCADE;

CREATE TABLE staging.district AS
SELECT
    a1::INT                        AS district_id,
    TRIM(a2)                       AS district_name,
    INITCAP(TRIM(a3))              AS region,
    a4::INT                        AS population,
    a10::NUMERIC                   AS urban_ratio_pct,
    a11::INT                       AS avg_salary,
    NULLIF(TRIM(a12), '?')::NUMERIC AS unemployment_1995_pct,
    a13::NUMERIC                   AS unemployment_1996_pct,
    a14::INT                       AS entrepreneurs_per_1000,
    NULLIF(TRIM(a15), '?')::INT    AS crimes_1995,
    a16::INT                       AS crimes_1996
FROM raw.district;

SELECT region, COUNT(*) AS districts FROM staging.district GROUP BY region ORDER BY region;
