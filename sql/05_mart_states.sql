-- ============================================================================
-- File:    05_mart_states.sql
-- Purpose: Turn the customer-year panel into a Markov chain:
--            1. give every customer-year a STATE
--            2. record every observed year-to-year TRANSITION
--            3. estimate TRANSITION MATRICES (pooled, and per age band)
--            4. overlay explicit ATTRITION SCENARIOS
--
-- Method: first-order Markov chain with annual periods, after Pfeifer &
-- Carraway (2000) and Haenlein et al. (2007). Age-specific matrices with a
-- sparse-cell fallback follow the ABN AMRO write-up (Hoogendoorn, 2023).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- DIMENSIONS
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.dim_state CASCADE;

CREATE TABLE mart.dim_state (
    state_id    INT PRIMARY KEY,
    state       TEXT NOT NULL,
    state_group TEXT NOT NULL,
    definition  TEXT NOT NULL
);

INSERT INTO mart.dim_state VALUES
(1, 'High value', 'Active',  'Engaged account with annualised value of 750 CZK or more'),
(2, 'Mid value',  'Active',  'Engaged account with annualised value from 250 up to 750 CZK'),
(3, 'Low value',  'Active',  'Engaged account with annualised value below 250 CZK (includes loss-making)'),
(4, 'Passive',    'Active',  'Fewer than one discretionary transaction a month, whatever the balance'),
(5, 'Churned',    'Churned', 'Relationship ended. Absorbing state');

DROP TABLE IF EXISTS mart.dim_age_band CASCADE;

CREATE TABLE mart.dim_age_band (
    age_band_id INT PRIMARY KEY,
    age_band    TEXT NOT NULL,
    age_from    INT  NOT NULL,
    age_to      INT  NOT NULL
);

INSERT INTO mart.dim_age_band VALUES
(1, 'Under 30', 0,  29),
(2, '30 to 59', 30, 59),
(3, '60 plus',  60, 200);

-- ----------------------------------------------------------------------------
-- MART.CUSTOMER_YEAR_STATE
-- State rule, applied in this order:
--   Churned  : the account has no postings of any kind in the year
--   (none)   : open for fewer than 180 days in the year -- too short to judge
--   Passive  : fewer than 1 discretionary transaction per month
--   High/Mid/Low : by annualised value against fixed CZK thresholds
--
-- Thresholds are fixed amounts, not per-year quantiles. Per-year terciles
-- would force a third of customers into each tier every year and hide any
-- real drift in the customer base.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.customer_year_state CASCADE;

CREATE TABLE mart.customer_year_state AS
SELECT
    f.customer_id,
    f.year,
    CASE
        WHEN f.no_postings_in_year                                   THEN 5
        WHEN f.days_open < mart.a('min_days_for_state')              THEN NULL
        WHEN f.discretionary_txn_per_month < mart.a('passive_txn_per_month') THEN 4
        WHEN f.annualised_value >= mart.a('tier_high_floor')         THEN 1
        WHEN f.annualised_value >= mart.a('tier_mid_floor')          THEN 2
        ELSE 3
    END                                                              AS state_id,
    b.age_band_id,
    f.age,
    f.annualised_value
FROM mart.fact_customer_year f
JOIN mart.dim_age_band b ON f.age BETWEEN b.age_from AND b.age_to;

ALTER TABLE mart.customer_year_state ADD PRIMARY KEY (customer_id, year);

-- State mix by year
SELECT s.year, d.state, COUNT(*) AS customers
FROM mart.customer_year_state s
JOIN mart.dim_state d USING (state_id)
GROUP BY s.year, d.state_id, d.state
ORDER BY s.year, d.state_id;

-- ----------------------------------------------------------------------------
-- MART.FACT_TRANSITION
-- One row per customer per pair of consecutive years where both years have
-- a state. Churned is absorbing, so transitions OUT of Churned are excluded.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.fact_transition CASCADE;

CREATE TABLE mart.fact_transition AS
SELECT
    a.customer_id,
    a.year        AS year_from,
    b.year        AS year_to,
    a.state_id    AS state_from,
    b.state_id    AS state_to,
    a.age_band_id AS age_band_id      -- band at the start of the transition
FROM mart.customer_year_state a
JOIN mart.customer_year_state b
  ON b.customer_id = a.customer_id
 AND b.year = a.year + 1
WHERE a.state_id IS NOT NULL
  AND b.state_id IS NOT NULL
  AND a.state_id <> 5;

-- ----------------------------------------------------------------------------
-- MART.TRANSITION_MATRIX_OBSERVED
-- Maximum-likelihood estimate: P(i -> j) = n(i -> j) / n(i -> anything).
--
-- age_band_id = 0 is the pooled matrix (all ages).
-- For age-band matrices, any origin row with fewer than 150 observations is
-- replaced by the pooled row (is_fallback = TRUE) -- the same small-sample
-- fallback ABN AMRO describe.
--
-- train_through lets the same function serve the backtest: pass 1995 to
-- estimate only on transitions that START in 1995 or earlier.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mart.estimate_matrix(train_through INT)
RETURNS TABLE (
    age_band_id  INT,
    state_from   INT,
    state_to     INT,
    n_transitions BIGINT,
    n_from       BIGINT,
    probability  NUMERIC,
    is_fallback  BOOLEAN
)
LANGUAGE sql STABLE AS $$
    WITH grid AS (          -- every origin/destination pair, so zero cells exist
        SELECT bands.age_band_id, f.state_id AS state_from, t.state_id AS state_to
        FROM (SELECT 0 AS age_band_id UNION ALL SELECT age_band_id FROM mart.dim_age_band) bands
        CROSS JOIN mart.dim_state f
        CROSS JOIN mart.dim_state t
        WHERE f.state_id <> 5
    ),
    counts AS (
        SELECT 0 AS age_band_id, state_from, state_to, COUNT(*) AS n
        FROM mart.fact_transition
        WHERE year_from <= train_through
        GROUP BY state_from, state_to
        UNION ALL
        SELECT age_band_id, state_from, state_to, COUNT(*)
        FROM mart.fact_transition
        WHERE year_from <= train_through
        GROUP BY age_band_id, state_from, state_to
    ),
    raw AS (
        SELECT
            g.age_band_id, g.state_from, g.state_to,
            COALESCE(c.n, 0)                                                        AS n,
            SUM(COALESCE(c.n, 0)) OVER (PARTITION BY g.age_band_id, g.state_from)   AS n_from
        FROM grid g
        LEFT JOIN counts c USING (age_band_id, state_from, state_to)
    ),
    pooled AS (
        SELECT state_from, state_to, n::NUMERIC / n_from AS p
        FROM raw
        WHERE age_band_id = 0
    )
    SELECT
        r.age_band_id,
        r.state_from,
        r.state_to,
        r.n::BIGINT,
        r.n_from::BIGINT,
        CASE WHEN r.age_band_id <> 0 AND r.n_from < 150 THEN p.p
             ELSE r.n::NUMERIC / r.n_from END,
        (r.age_band_id <> 0 AND r.n_from < 150)
    FROM raw r
    JOIN pooled p USING (state_from, state_to)
    UNION ALL
    -- Churned is absorbing
    SELECT b.age_band_id, 5, t.state_id, 0, 0, (t.state_id = 5)::INT::NUMERIC, FALSE
    FROM (SELECT 0 AS age_band_id UNION ALL SELECT age_band_id FROM mart.dim_age_band) b
    CROSS JOIN mart.dim_state t
$$;

DROP TABLE IF EXISTS mart.transition_matrix_observed CASCADE;

CREATE TABLE mart.transition_matrix_observed AS
SELECT * FROM mart.estimate_matrix(1997);     -- all observed transitions

-- The pooled matrix, as a grid
SELECT
    f.state AS "from \ to",
    ROUND(100 * MAX(m.probability) FILTER (WHERE m.state_to = 1), 1) AS high,
    ROUND(100 * MAX(m.probability) FILTER (WHERE m.state_to = 2), 1) AS mid,
    ROUND(100 * MAX(m.probability) FILTER (WHERE m.state_to = 3), 1) AS low,
    ROUND(100 * MAX(m.probability) FILTER (WHERE m.state_to = 4), 1) AS passive,
    ROUND(100 * MAX(m.probability) FILTER (WHERE m.state_to = 5), 2) AS churned,
    MAX(m.n_from)                                                    AS n
FROM mart.transition_matrix_observed m
JOIN mart.dim_state f ON f.state_id = m.state_from
WHERE m.age_band_id = 0
GROUP BY f.state_id, f.state
ORDER BY f.state_id;

-- ----------------------------------------------------------------------------
-- ATTRITION SCENARIOS
--
-- Berka is a sample of surviving accounts: 4,480 of 4,500 accounts are still
-- posting in the last two months of the data, and only 9 ever go silent for
-- a full year. An observed closure rate near 0.1% a year is not a credible
-- basis for a lifetime-value projection, and it cannot be fixed by redefining
-- churn -- the leavers are simply not in the data.
--
-- So attrition is modelled as an explicit, labelled scenario instead of being
-- inferred. Each scenario sets a base annual attrition rate; state multipliers
-- make disengaged customers more likely to leave than engaged ones.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.dim_scenario CASCADE;

CREATE TABLE mart.dim_scenario (
    scenario_id    INT PRIMARY KEY,
    scenario       TEXT NOT NULL,
    base_attrition NUMERIC NOT NULL,
    is_default     BOOLEAN NOT NULL,
    note           TEXT NOT NULL
);

INSERT INTO mart.dim_scenario VALUES
(1, 'Observed only', 0.00, FALSE, 'No attrition beyond the handful of closures in the data. An upper bound, not a forecast.'),
(2, 'Low attrition', 0.03, FALSE, '3% base annual attrition.'),
(3, 'Base case',     0.06, TRUE,  '6% base annual attrition. Used for all headline figures.'),
(4, 'High attrition', 0.10, FALSE, '10% base annual attrition.');

DROP TABLE IF EXISTS mart.attrition_multiplier CASCADE;

CREATE TABLE mart.attrition_multiplier (
    state_id   INT PRIMARY KEY REFERENCES mart.dim_state,
    multiplier NUMERIC NOT NULL
);

INSERT INTO mart.attrition_multiplier VALUES
(1, 0.50),   -- High value: half the base rate
(2, 0.80),
(3, 1.20),
(4, 2.50);   -- Passive: two and a half times the base rate

-- ----------------------------------------------------------------------------
-- MART.TRANSITION_MATRIX
-- The matrices actually used for projection: observed behaviour, scaled down
-- by (1 - attrition), with the attrition mass moved into Churned.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mart.apply_attrition(train_through INT)
RETURNS TABLE (scenario_id INT, age_band_id INT, state_from INT, state_to INT, probability NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT
        s.scenario_id,
        m.age_band_id,
        m.state_from,
        m.state_to,
        CASE
            WHEN m.state_from = 5 THEN m.probability
            WHEN m.state_to   = 5 THEN m.probability * (1 - s.base_attrition * a.multiplier)
                                       + s.base_attrition * a.multiplier
            ELSE m.probability * (1 - s.base_attrition * a.multiplier)
        END
    FROM mart.estimate_matrix(train_through) m
    CROSS JOIN mart.dim_scenario s
    LEFT JOIN mart.attrition_multiplier a ON a.state_id = m.state_from
$$;

DROP TABLE IF EXISTS mart.transition_matrix CASCADE;

CREATE TABLE mart.transition_matrix AS
SELECT * FROM mart.apply_attrition(1997);

ALTER TABLE mart.transition_matrix ADD PRIMARY KEY (scenario_id, age_band_id, state_from, state_to);
