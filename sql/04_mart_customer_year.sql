-- ============================================================================
-- File:    04_mart_customer_year.sql
-- Purpose: Build the customer-year panel that everything downstream runs on:
--          one row per customer per calendar year, with balances, activity,
--          product holdings and an annual VALUE (profit proxy) broken into
--          its components.
--
-- Unit of analysis: the ACCOUNT, represented by its owner. Every account has
-- exactly one owner (4,500 accounts = 4,500 owners), so customer_id = account_id.
-- Disponents (869 secondary users) are an attribute of the account, not
-- separate customers.
--
-- Value definition follows Cowan, Mercuri & Khraishi (2023), eq. for product
-- value:  value = revenue - cost, summed across the customer's products.
-- Berka has no profit data, so revenue and cost are built from observed
-- postings where they exist and from explicit assumptions where they don't.
-- Every assumption lives in mart.assumption -- nothing is hard-coded below.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- MART.ASSUMPTION
-- The single place where modelling assumptions are declared.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.assumption CASCADE;

CREATE TABLE mart.assumption (
    assumption_key TEXT PRIMARY KEY,
    value          NUMERIC NOT NULL,
    unit           TEXT    NOT NULL,
    label          TEXT    NOT NULL,
    basis          TEXT    NOT NULL,   -- why this number
    source_type    TEXT    NOT NULL    -- 'assumed' or 'calibrated from data'
);

INSERT INTO mart.assumption VALUES
('ftp_rate',              0.075, 'rate p.a.',  'Funds transfer price on deposits',
 'Rate the bank earns on customer deposits when lent on internally. Set 2.6pp above the 4.9% the bank is observed paying depositors.', 'assumed'),
('loan_gross_spread',     0.060, 'rate p.a.',  'Loan spread over funding cost',
 'The loan table stores principal only (payments x duration = amount for all 682 loans), so interest income is not observable. A 6pp consumer-lending spread is assumed.', 'assumed'),
('loss_given_default',    0.450, 'share',      'Loss given default on loans in arrears',
 'Applied to the outstanding balance of loans with status D (running, in debt). Finished-and-unpaid loans (status B) are taken at their observed unpaid balance.', 'assumed'),
('card_fee_junior',         100, 'CZK p.a.',   'Annual fee: junior card',  'Card fees are not itemised in the transactions.', 'assumed'),
('card_fee_classic',        300, 'CZK p.a.',   'Annual fee: classic card', 'Card fees are not itemised in the transactions.', 'assumed'),
('card_fee_gold',          1000, 'CZK p.a.',   'Annual fee: gold card',    'Card fees are not itemised in the transactions.', 'assumed'),
('card_interchange_rate', 0.010, 'share',      'Interchange on card withdrawals', 'Applied to observed card withdrawal volume.', 'assumed'),
('cost_fixed',              500, 'CZK p.a.',   'Fixed cost to serve an account', 'Statements, compliance, platform cost allocated per account.', 'assumed'),
('cost_per_transaction',    3.0, 'CZK',        'Variable cost per customer transaction', 'Applied to customer-initiated transactions only (bank postings excluded).', 'assumed'),
('passive_txn_per_month',   1.0, 'txn/month',  'Passive threshold', 'Fewer than one discretionary transaction a month marks an account as Passive.', 'assumed'),
('tier_mid_floor',          250, 'CZK p.a.',   'Mid-value floor',  'Annualised value at or above this is Mid value. Close to the pooled 33rd percentile (221), rounded so the rule is explainable.', 'assumed'),
('tier_high_floor',         750, 'CZK p.a.',   'High-value floor', 'Annualised value at or above this is High value. Close to the pooled 67th percentile (728), rounded.', 'assumed'),
('min_days_for_state',      180, 'days',       'Minimum days open in a year to be given a state', 'Shorter first years are too noisy to annualise.', 'assumed'),
('discount_rate',         0.100, 'rate p.a.',  'Discount rate (cost of capital)', 'Default for exported CLV. The Power BI report overrides it with a what-if parameter.', 'assumed'),
('horizon_years',             5, 'years',      'Projection horizon', 'Same horizon as Cowan et al. (2023); typical for current-account, card and consumer-loan relationships.', 'assumed');

-- Convenience accessor: mart.a('ftp_rate')
CREATE OR REPLACE FUNCTION mart.a(k TEXT) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$ SELECT value FROM mart.assumption WHERE assumption_key = k $$;

-- ----------------------------------------------------------------------------
-- MART.DIM_YEAR
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.dim_year CASCADE;

CREATE TABLE mart.dim_year AS
SELECT
    y                         AS year,
    MAKE_DATE(y, 1, 1)        AS year_start,
    MAKE_DATE(y, 12, 31)      AS year_end
FROM GENERATE_SERIES(1993, 1998) AS y;

-- ----------------------------------------------------------------------------
-- MART.ACCOUNT_DAY_BALANCE
-- End-of-day balance per account, for every day the account moved.
--
-- Why rebuild it: within a day the source gives no reliable transaction order
-- (trans_id is not chronological), so "the last balance of the day" cannot be
-- read off the rows. The running sum of signed amounts does not depend on
-- intra-day order, and it reconciles to a reported balance on every
-- account-day to within 3 CZK of source rounding (asserted in 08_tests.sql).
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.account_day_balance CASCADE;

CREATE TABLE mart.account_day_balance AS
WITH daily AS (
    SELECT account_id, trans_date AS bal_date, SUM(amount_signed) AS net_flow
    FROM staging.trans
    GROUP BY account_id, trans_date
),
running AS (
    SELECT
        account_id,
        bal_date,
        SUM(net_flow) OVER (PARTITION BY account_id ORDER BY bal_date) AS eod_balance
    FROM daily
)
SELECT
    account_id,
    bal_date,
    eod_balance,
    -- the balance stands until the next movement (or the end of the data window)
    COALESCE(LEAD(bal_date) OVER (PARTITION BY account_id ORDER BY bal_date),
             DATE '1999-01-01') AS next_date
FROM running;

CREATE INDEX idx_adb_acct ON mart.account_day_balance (account_id, bal_date);

-- ----------------------------------------------------------------------------
-- MART.LOAN_YEAR
-- Average scheduled principal outstanding per loan per year (straight-line
-- amortisation, which is exactly how the source schedules repayments).
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.loan_year CASCADE;

CREATE TABLE mart.loan_year AS
WITH schedule AS (
    SELECT
        l.loan_id,
        l.account_id,
        (DATE_TRUNC('month', l.grant_date) + (m || ' month')::INTERVAL)::DATE AS month_start,
        l.principal - m * l.monthly_payment                                   AS outstanding
    FROM staging.loan l
    CROSS JOIN LATERAL GENERATE_SERIES(0, l.duration_months - 1) AS m
)
SELECT
    account_id,
    EXTRACT(YEAR FROM month_start)::INT AS year,
    SUM(outstanding) / 12.0             AS avg_loan_outstanding,   -- zero months count as zero
    COUNT(*)                            AS loan_months
FROM schedule
WHERE month_start <= DATE '1998-12-31'
GROUP BY account_id, EXTRACT(YEAR FROM month_start);

-- Expected-loss rate, calibrated from what the data shows about defaults:
--   observed unpaid balance on finished-defaulted loans (status B)
-- + LGD x remaining balance on loans running in arrears (status D)
-- divided by total principal-years outstanding across the whole book.
INSERT INTO mart.assumption
WITH paid AS (
    SELECT account_id, SUM(amount) AS paid
    FROM staging.trans
    WHERE category = 'loan_payment'
    GROUP BY account_id
),
loss AS (
    SELECT SUM(CASE l.status_code
                   WHEN 'B' THEN GREATEST(l.principal - COALESCE(p.paid, 0), 0)
                   WHEN 'D' THEN GREATEST(l.principal - COALESCE(p.paid, 0), 0) * mart.a('loss_given_default')
                   ELSE 0
               END) AS expected_loss
    FROM staging.loan l
    LEFT JOIN paid p USING (account_id)
)
SELECT
    'loan_expected_loss_rate',
    ROUND(loss.expected_loss / (SELECT SUM(avg_loan_outstanding) FROM mart.loan_year), 4),
    'rate p.a.',
    'Expected credit loss on loans outstanding',
    'Unpaid balance on status-B loans plus LGD x remaining balance on status-D loans, divided by principal-years outstanding 1993-1998.',
    'calibrated from data'
FROM loss;

-- ----------------------------------------------------------------------------
-- MART.CARD_YEAR
-- Share of each year a card was held, per account, with its annual fee.
-- No account holds more than one card.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.card_year CASCADE;

CREATE TABLE mart.card_year AS
SELECT
    d.account_id,
    y.year,
    c.card_type,
    (y.year_end - GREATEST(c.issue_date, y.year_start) + 1) / 365.0 AS share_of_year_held,
    mart.a('card_fee_' || c.card_type)                              AS annual_fee
FROM staging.card c
JOIN staging.disp d USING (disp_id)
JOIN mart.dim_year y ON c.issue_date <= y.year_end;

-- ----------------------------------------------------------------------------
-- MART.FACT_CUSTOMER_YEAR
-- The panel. One row per customer per calendar year the account was open.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.fact_customer_year CASCADE;

CREATE TABLE mart.fact_customer_year AS
WITH balance AS (
    -- time-weighted average daily balance: each end-of-day balance is weighted
    -- by the number of days it stood, clipped to the calendar year
    SELECT
        b.account_id,
        y.year,
        SUM(LEAST(b.next_date, y.year_end + 1) - GREATEST(b.bal_date, y.year_start)) AS days_open,
        SUM(b.eod_balance
            * (LEAST(b.next_date, y.year_end + 1) - GREATEST(b.bal_date, y.year_start))) AS balance_days,
        SUM(GREATEST(b.eod_balance, 0)
            * (LEAST(b.next_date, y.year_end + 1) - GREATEST(b.bal_date, y.year_start))) AS credit_balance_days,
        SUM(CASE WHEN b.eod_balance < 0
                 THEN LEAST(b.next_date, y.year_end + 1) - GREATEST(b.bal_date, y.year_start)
                 ELSE 0 END)                                                             AS days_overdrawn
    FROM mart.account_day_balance b
    JOIN mart.dim_year y
      ON b.bal_date <= y.year_end
     AND b.next_date > y.year_start
    GROUP BY b.account_id, y.year
),
activity AS (
    SELECT
        account_id,
        trans_year AS year,
        COUNT(*) FILTER (WHERE is_customer_activity)                       AS n_customer_txn,
        -- discretionary = the customer chose to do it: excludes bank postings
        -- AND excludes automated standing categories (household, insurance,
        -- loan instalments, pension credits)
        COUNT(*) FILTER (WHERE is_customer_activity AND category = 'none')  AS n_discretionary_txn,
        COALESCE(SUM(amount) FILTER (WHERE category = 'interest_credited'), 0) AS interest_paid,
        COALESCE(SUM(amount) FILTER (WHERE category = 'statement_fee'), 0)     AS statement_fees,
        COALESCE(SUM(amount) FILTER (WHERE category = 'penalty_interest'), 0)  AS penalty_interest,
        COALESCE(SUM(amount) FILTER (WHERE operation = 'card_withdrawal'), 0)  AS card_volume,
        COALESCE(SUM(amount) FILTER (WHERE direction = 'credit' AND is_customer_activity), 0) AS inflow
    FROM staging.trans
    GROUP BY account_id, trans_year
),
joined AS (
    SELECT
        b.account_id                                   AS customer_id,
        b.year,
        b.days_open,
        b.days_open >= 365                             AS is_full_year,
        b.balance_days / b.days_open                   AS avg_balance,
        b.days_overdrawn,
        a.account_id IS NULL                           AS no_postings_in_year,   -- nothing at all, not even interest
        COALESCE(a.n_customer_txn, 0)                  AS n_customer_txn,
        COALESCE(a.n_discretionary_txn, 0)             AS n_discretionary_txn,
        COALESCE(a.n_discretionary_txn, 0) / (b.days_open / 30.4375) AS discretionary_txn_per_month,
        COALESCE(a.inflow, 0)                          AS inflow,
        COALESCE(l.avg_loan_outstanding, 0)            AS avg_loan_outstanding,
        l.account_id IS NOT NULL                       AS has_loan,
        c.account_id IS NOT NULL                       AS has_card,
        c.card_type,

        -- ---- value components (CZK, actual for the part of the year open) ----
        b.credit_balance_days / 365.0 * mart.a('ftp_rate') - COALESCE(a.interest_paid, 0)         AS deposit_margin,
        COALESCE(l.avg_loan_outstanding, 0)
            * (mart.a('loan_gross_spread') - mart.a('loan_expected_loss_rate'))        AS loan_margin,
        COALESCE(a.statement_fees, 0) + COALESCE(a.penalty_interest, 0)                                     AS fee_income,
        COALESCE(c.annual_fee * c.share_of_year_held, 0)
            + COALESCE(a.card_volume, 0) * mart.a('card_interchange_rate')                         AS card_income,
        -(mart.a('cost_fixed') * b.days_open / 365.0
          + mart.a('cost_per_transaction') * COALESCE(a.n_customer_txn, 0))                        AS cost_to_serve
    FROM balance b
    -- LEFT JOIN: a handful of accounts stop posting entirely; they must stay in the panel
    LEFT JOIN activity a       ON a.account_id = b.account_id AND a.year = b.year
    LEFT JOIN mart.loan_year l ON l.account_id = b.account_id AND l.year = b.year
    LEFT JOIN mart.card_year c ON c.account_id = b.account_id AND c.year = b.year
)
SELECT
    j.*,
    j.deposit_margin + j.loan_margin + j.fee_income + j.card_income + j.cost_to_serve AS annual_value,
    -- scaled to a 12-month equivalent so part-years are comparable
    (j.deposit_margin + j.loan_margin + j.fee_income + j.card_income + j.cost_to_serve)
        * 365.0 / j.days_open                                                         AS annualised_value,
    (j.year - EXTRACT(YEAR FROM cl.birth_date))::INT                                  AS age
FROM joined j
JOIN staging.disp   d  ON d.account_id = j.customer_id AND d.role = 'owner'
JOIN staging.client cl ON cl.client_id = d.client_id;

ALTER TABLE mart.fact_customer_year ADD PRIMARY KEY (customer_id, year);

-- Sanity view of the panel
SELECT
    year,
    COUNT(*)                              AS customers,
    ROUND(AVG(avg_balance))               AS avg_balance,
    ROUND(SUM(deposit_margin))            AS deposit_margin,
    ROUND(SUM(loan_margin))               AS loan_margin,
    ROUND(SUM(fee_income))                AS fee_income,
    ROUND(SUM(card_income))               AS card_income,
    ROUND(SUM(cost_to_serve))             AS cost_to_serve,
    ROUND(SUM(annual_value))              AS annual_value
FROM mart.fact_customer_year
GROUP BY year
ORDER BY year;
