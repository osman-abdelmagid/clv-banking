-- ============================================================================
-- File:    07_validation.sql
-- Purpose: Test the model against data it has not seen, and test the
--          assumption the whole method rests on.
--
--   A. OUT-OF-TIME BACKTEST
--      Refit everything on transitions that start in 1995 or earlier, start
--      customers from their 1996 state, predict 1997 (1 year ahead) and 1998
--      (2 years ahead), and compare with what actually happened.
--      Four models are compared so each refinement has to earn its place:
--        M0  Naive        : next year's value = this year's value
--        M1  Baseline     : pooled Markov, state-mean value (Haenlein et al. 2007;
--                           the baseline used by Cowan et al. 2023)
--        M2  Age-banded   : age-band matrices and state means
--        M3  Final        : M2 plus customer-level persistence
--      Metrics follow Cowan et al. (2023): median absolute error for value,
--      top-decile precision and separation for ranking, state accuracy for needs.
--
--   B. STATIONARITY
--      A Markov projection assumes next year's transition probabilities look
--      like past years'. Compare the matrix from early transitions with the
--      matrix from late ones (the check ABN AMRO describe).
--
-- Attrition scenarios are NOT validated here -- they are assumptions, and the
-- data contains no leavers to test them against. The backtest runs on the
-- "Observed only" scenario.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A. Backtest predictions
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.backtest_prediction CASCADE;

CREATE TABLE mart.backtest_prediction AS
WITH actual AS (
    SELECT s.customer_id, s.year - 1996 AS horizon_year, s.state_id AS actual_state,
           s.annualised_value::FLOAT8 AS actual_value
    FROM mart.customer_year_state s
    WHERE s.year IN (1997, 1998) AND s.state_id IS NOT NULL
),
start AS (
    SELECT customer_id, annualised_value::FLOAT8 AS start_value
    FROM mart.customer_year_state
    WHERE year = 1996 AND state_id BETWEEN 1 AND 4
),
models AS (
    SELECT 'M1 Baseline Markov' AS model, customer_id, horizon_year, expected_value
    FROM mart.project_value(1996, 1995, 2, FALSE, FALSE, ARRAY[1])
    UNION ALL
    SELECT 'M2 Age-banded Markov', customer_id, horizon_year, expected_value
    FROM mart.project_value(1996, 1995, 2, TRUE, FALSE, ARRAY[1])
    UNION ALL
    SELECT 'M3 Final model', customer_id, horizon_year, expected_value
    FROM mart.project_value(1996, 1995, 2, TRUE, TRUE, ARRAY[1])
    UNION ALL
    SELECT 'M0 Naive carry-forward', s.customer_id, h, s.start_value
    FROM start s CROSS JOIN GENERATE_SERIES(1, 2) AS h
)
SELECT m.model, m.customer_id, m.horizon_year, m.expected_value AS predicted_value,
       a.actual_value, a.actual_state
FROM models m
JOIN start s  USING (customer_id)
JOIN actual a USING (customer_id, horizon_year);

-- ----------------------------------------------------------------------------
-- Backtest metrics, one row per model and horizon
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.backtest_metric CASCADE;

CREATE TABLE mart.backtest_metric AS
WITH ranked AS (
    SELECT *,
           NTILE(10) OVER (PARTITION BY model, horizon_year ORDER BY ROUND(predicted_value::NUMERIC, 4) DESC, customer_id) AS predicted_decile,
           NTILE(10) OVER (PARTITION BY model, horizon_year ORDER BY actual_value DESC, customer_id)    AS actual_decile
    FROM mart.backtest_prediction
)
SELECT
    model,
    horizon_year,
    COUNT(*)                                                                        AS customers,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(predicted_value - actual_value)))::NUMERIC, 1)
                                                                                    AS median_abs_error,
    ROUND(AVG(ABS(predicted_value - actual_value))::NUMERIC, 1)                     AS mean_abs_error,
    -- of the customers the model put in its top 10%, how many really were top 10%?
    ROUND((AVG((actual_decile = 1)::INT) FILTER (WHERE predicted_decile = 1))::NUMERIC, 3)
                                                                                    AS top_decile_precision,
    -- average ACTUAL value of the model's top 10% minus that of its bottom 10%
    ROUND((AVG(actual_value) FILTER (WHERE predicted_decile = 1)
         - AVG(actual_value) FILTER (WHERE predicted_decile = 10))::NUMERIC)        AS separation_czk,
    -- predicted portfolio total against actual
    ROUND((100 * (SUM(predicted_value) / SUM(actual_value) - 1))::NUMERIC, 1)       AS portfolio_error_pct
FROM ranked
GROUP BY model, horizon_year;

SELECT * FROM mart.backtest_metric ORDER BY horizon_year, model;

-- ----------------------------------------------------------------------------
-- Backtest of the state distribution: expected customers per state against
-- actual, for the final (age-banded) chain and the pooled baseline.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.backtest_state_distribution CASCADE;

CREATE TABLE mart.backtest_state_distribution AS
WITH predicted AS (
    SELECT 'Age-banded' AS chain, horizon_year, state_id, SUM(probability) AS predicted_customers
    FROM mart.project_states(1996, 1995, 2, TRUE, ARRAY[1])
    WHERE horizon_year >= 1
    GROUP BY horizon_year, state_id
    UNION ALL
    SELECT 'Pooled', horizon_year, state_id, SUM(probability)
    FROM mart.project_states(1996, 1995, 2, FALSE, ARRAY[1])
    WHERE horizon_year >= 1
    GROUP BY horizon_year, state_id
),
actual AS (
    SELECT s.year - 1996 AS horizon_year, s.state_id, COUNT(*) AS actual_customers
    FROM mart.customer_year_state s
    JOIN mart.customer_year_state s0
      ON s0.customer_id = s.customer_id AND s0.year = 1996 AND s0.state_id BETWEEN 1 AND 4
    WHERE s.year IN (1997, 1998) AND s.state_id IS NOT NULL
    GROUP BY s.year, s.state_id
)
SELECT
    p.chain,
    p.horizon_year,
    1996 + p.horizon_year                     AS year,
    p.state_id,
    ROUND(p.predicted_customers::NUMERIC, 1)  AS predicted_customers,
    COALESCE(a.actual_customers, 0)           AS actual_customers
FROM predicted p
LEFT JOIN actual a USING (horizon_year, state_id);

SELECT chain, year, d.state, predicted_customers, actual_customers
FROM mart.backtest_state_distribution b
JOIN mart.dim_state d USING (state_id)
ORDER BY chain, year, state_id;

-- State accuracy: is the customer's actual state the one the chain rated most likely?
DROP TABLE IF EXISTS mart.backtest_state_accuracy CASCADE;

CREATE TABLE mart.backtest_state_accuracy AS
WITH proj AS (
    SELECT 'Age-banded' AS chain, * FROM mart.project_states(1996, 1995, 2, TRUE, ARRAY[1]) WHERE horizon_year >= 1
),
best AS (
    SELECT DISTINCT ON (chain, customer_id, horizon_year)
           chain, customer_id, horizon_year, state_id AS predicted_state
    FROM proj
    ORDER BY chain, customer_id, horizon_year, probability DESC
)
SELECT
    b.chain,
    b.horizon_year,
    COUNT(*)                                                   AS customers,
    ROUND(AVG((b.predicted_state = s.state_id)::INT)::NUMERIC, 3) AS state_accuracy
FROM best b
JOIN mart.customer_year_state s
  ON s.customer_id = b.customer_id AND s.year = 1996 + b.horizon_year AND s.state_id IS NOT NULL
GROUP BY b.chain, b.horizon_year;

SELECT * FROM mart.backtest_state_accuracy ORDER BY horizon_year;

-- ----------------------------------------------------------------------------
-- B. Stationarity: early matrix (transitions starting 1993-1995) against
--    late matrix (transitions starting 1996-1997), pooled across ages.
--    chi_square is the test of homogeneity for each origin row; with four
--    destination states the 5% critical value is 7.81 (3 d.f.).
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.stationarity_check CASCADE;

CREATE TABLE mart.stationarity_check AS
WITH counts AS (
    SELECT
        CASE WHEN year_from <= 1995 THEN 'early' ELSE 'late' END AS period,
        state_from, state_to, COUNT(*) AS n
    FROM mart.fact_transition
    WHERE state_to <> 5
    GROUP BY 1, 2, 3
),
grid AS (
    SELECT p.period, f.state_id AS state_from, t.state_id AS state_to
    FROM (VALUES ('early'), ('late')) AS p(period)
    CROSS JOIN mart.dim_state f
    CROSS JOIN mart.dim_state t
    WHERE f.state_id <= 4 AND t.state_id <= 4
),
filled AS (
    SELECT g.period, g.state_from, g.state_to, COALESCE(c.n, 0) AS n
    FROM grid g LEFT JOIN counts c USING (period, state_from, state_to)
),
totals AS (
    SELECT *,
           SUM(n) OVER (PARTITION BY period, state_from)   AS row_n,      -- origin total in this period
           SUM(n) OVER (PARTITION BY state_from, state_to) AS cell_n,     -- cell total across periods
           SUM(n) OVER (PARTITION BY state_from)           AS origin_n    -- origin total across periods
    FROM filled
)
SELECT
    state_from,
    state_to,
    MAX(n) FILTER (WHERE period = 'early')                              AS n_early,
    MAX(n) FILTER (WHERE period = 'late')                               AS n_late,
    ROUND(MAX(n::NUMERIC / row_n) FILTER (WHERE period = 'early'), 4)   AS p_early,
    ROUND(MAX(n::NUMERIC / row_n) FILTER (WHERE period = 'late'), 4)    AS p_late,
    ROUND(MAX(n::NUMERIC / row_n) FILTER (WHERE period = 'late')
        - MAX(n::NUMERIC / row_n) FILTER (WHERE period = 'early'), 4)   AS p_shift,
    -- this cell's contribution to the row's chi-square statistic
    ROUND(SUM(POWER(n - row_n * cell_n::NUMERIC / origin_n, 2)
              / NULLIF(row_n * cell_n::NUMERIC / origin_n, 0)), 2)      AS chi_square_contribution
FROM totals
GROUP BY state_from, state_to;

SELECT
    d.state                                   AS origin_state,
    ROUND(SUM(chi_square_contribution), 1)    AS chi_square,
    ROUND(100 * MAX(ABS(p_shift)), 1)         AS largest_shift_pp
FROM mart.stationarity_check s
JOIN mart.dim_state d ON d.state_id = s.state_from
GROUP BY d.state_id, d.state
ORDER BY d.state_id;
