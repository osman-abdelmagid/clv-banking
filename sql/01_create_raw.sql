-- ============================================================================
-- File:    01_create_raw.sql
-- Purpose: Define the 8 raw tables from the data source
-- Note: every column is TEXT at this stage, with no transforms
-- Typing, parsing, and cleaning will happen later in staging (03_staging.sql)
-- ============================================================================

DROP TABLE IF EXISTS raw.account CASCADE;
CREATE TABLE raw.account (
    account_id  TEXT,
    district_id TEXT,
    frequency   TEXT,
    date        TEXT
);

DROP TABLE IF EXISTS raw.client CASCADE;
CREATE TABLE raw.client (
    client_id    TEXT,
    birth_number TEXT,
    district_id  TEXT
);

DROP TABLE IF EXISTS raw.disp CASCADE;
CREATE TABLE raw.disp (
    disp_id    TEXT,
    client_id  TEXT,
    account_id TEXT,
    type       TEXT
);

DROP TABLE IF EXISTS raw.trans CASCADE;
CREATE TABLE raw.trans (
    trans_id   TEXT,
    account_id TEXT,
    date       TEXT,
    type       TEXT,
    operation  TEXT,
    amount     TEXT,
    balance    TEXT,
    k_symbol   TEXT,
    bank       TEXT,
    account    TEXT
);

DROP TABLE IF EXISTS raw.loan CASCADE;
CREATE TABLE raw.loan (
    loan_id    TEXT,
    account_id TEXT,
    date       TEXT,
    amount     TEXT,
    duration   TEXT,
    payments   TEXT,
    status     TEXT
);

DROP TABLE IF EXISTS raw.card CASCADE;
CREATE TABLE raw.card (
    card_id TEXT,
    disp_id TEXT,
    type    TEXT,
    issued  TEXT
);


DROP TABLE IF EXISTS raw.orders CASCADE;
CREATE TABLE raw.orders (
    order_id   TEXT,
    account_id TEXT,
    bank_to    TEXT,
    account_to TEXT,
    amount     TEXT,
    k_symbol   TEXT
);

DROP TABLE IF EXISTS raw.district CASCADE;
CREATE TABLE raw.district (
    a1  TEXT, a2  TEXT, a3  TEXT, a4  TEXT,
    a5  TEXT, a6  TEXT, a7  TEXT, a8  TEXT,
    a9  TEXT, a10 TEXT, a11 TEXT, a12 TEXT,
    a13 TEXT, a14 TEXT, a15 TEXT, a16 TEXT
);