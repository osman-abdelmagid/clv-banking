-- ============================================================================
-- File:    06_mart_clv.sql
-- Purpose: Project every customer five years forward and value the result.
--
--   state probabilities   p_k = p_(k-1) x P            (Markov projection)
--   expected value        EV_k = sum_j p_k(j) * mu(j)   (state mean value)
--                              + rho^k * d * survival_k (customer-specific part)
--   CLV                   sum_k EV_k / (1 + r)^k        (k = 1..5)
--
-- Two refinements over a plain state-mean Markov model:
--   * the matrix used in year k is the one for the customer's age band IN
--     THAT YEAR, so a 58-year-old moves onto the 60-plus matrix after two
--     years (ABN AMRO use one matrix per age for the same reason);
--   * customers keep a decaying share (rho^k) of the gap between their own
--     value and their state's average, so two "High value" customers are not
--     given the same CLV. rho is estimated from the data, not assumed.
--     This plays the role of the customer-level "value assigner" in Cowan et
--     al. (2023), at a complexity that fits 4,500 customers.
--
-- All three building blocks take a training cut-off so that 07_validation.sql
-- can refit them on early years only and test on later ones.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- State mean value, per state and age band, from customer-years up to max_year.
-- Cells with fewer than 150 customer-years fall back to the state's pooled mean.
-- age_band_id = 0 is the pooled (all ages) figure.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mart.state_value(max_year INT)
RETURNS TABLE (age_band_id INT, state_id INT, mean_value DOUBLE PRECISION, n_customer_years BIGINT)
LANGUAGE sql STABLE AS $$
    WITH pooled AS (
        SELECT state_id, AVG(annualised_value)::FLOAT8 AS mean_value, COUNT(*) AS n
        FROM mart.customer_year_state
        WHERE year <= max_year AND state_id BETWEEN 1 AND 4
        GROUP BY state_id
    ),
    banded AS (
        SELECT age_band_id, state_id, AVG(annualised_value)::FLOAT8 AS mean_value, COUNT(*) AS n
        FROM mart.customer_year_state
        WHERE year <= max_year AND state_id BETWEEN 1 AND 4
        GROUP BY age_band_id, state_id
    )
    SELECT 0, state_id, mean_value, n FROM pooled
    UNION ALL
    SELECT b.age_band_id, p.state_id,
           CASE WHEN COALESCE(x.n, 0) >= 150 THEN x.mean_value ELSE p.mean_value END,
           COALESCE(x.n, 0)
    FROM mart.dim_age_band b
    CROSS JOIN pooled p
    LEFT JOIN banded x ON x.age_band_id = b.age_band_id AND x.state_id = p.state_id
    UNION ALL
    SELECT b.age_band_id, 5, 0, 0          -- a churned customer is worth nothing
    FROM (SELECT 0 AS age_band_id UNION ALL SELECT age_band_id FROM mart.dim_age_band) b
$$;

-- ----------------------------------------------------------------------------
-- Persistence (rho): how much of a customer's gap to their state average
-- survives one year. Least-squares slope through the origin of next year's
-- gap on this year's gap, over transitions that start by train_through.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mart.persistence(train_through INT)
RETURNS DOUBLE PRECISION
LANGUAGE sql STABLE AS $$
    WITH v AS (SELECT * FROM mart.state_value(train_through + 1)),
    gaps AS (
        SELECT
            (a.annualised_value - va.mean_value)::FLOAT8 AS gap_now,
            (b.annualised_value - vb.mean_value)::FLOAT8 AS gap_next
        FROM mart.customer_year_state a
        JOIN mart.customer_year_state b ON b.customer_id = a.customer_id AND b.year = a.year + 1
        JOIN v va ON va.age_band_id = a.age_band_id AND va.state_id = a.state_id
        JOIN v vb ON vb.age_band_id = b.age_band_id AND vb.state_id = b.state_id
        WHERE a.year <= train_through
          AND a.state_id BETWEEN 1 AND 4
          AND b.state_id BETWEEN 1 AND 4
    )
    SELECT SUM(gap_now * gap_next) / SUM(gap_now * gap_now) FROM gaps
$$;

-- ----------------------------------------------------------------------------
-- Markov projection.
--   p_start_year    : year whose observed state is the starting point
--   p_train_through : last transition start-year used to estimate the matrices
--   p_horizon       : number of years to project
--   p_banded        : TRUE = age-band matrices, FALSE = one pooled matrix
--   p_scenarios     : which attrition scenarios to run
-- Returns one row per scenario, customer, projected year and state.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mart.project_states(
    p_start_year INT, p_train_through INT, p_horizon INT, p_banded BOOLEAN, p_scenarios INT[])
RETURNS TABLE (scenario_id INT, customer_id INT, horizon_year INT, state_id INT, probability DOUBLE PRECISION)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
BEGIN
    DROP TABLE IF EXISTS _matrix;
    CREATE TEMP TABLE _matrix AS
    SELECT scenario_id, age_band_id, state_from, state_to, probability::FLOAT8 AS probability
    FROM mart.apply_attrition(p_train_through)
    WHERE scenario_id = ANY (p_scenarios);

    DROP TABLE IF EXISTS _proj;
    CREATE TEMP TABLE _proj (
        scenario_id INT, customer_id INT, horizon_year INT, state_id INT, probability FLOAT8);

    -- year 0: everyone is in their observed state with certainty
    INSERT INTO _proj
    SELECT s.scenario_id, c.customer_id, 0, c.state_id, 1.0
    FROM mart.customer_year_state c
    CROSS JOIN UNNEST(p_scenarios) AS s(scenario_id)
    WHERE c.year = p_start_year
      AND c.state_id IS NOT NULL;

    FOR k IN 1..p_horizon LOOP
        INSERT INTO _proj
        SELECT p.scenario_id, p.customer_id, k, m.state_to, SUM(p.probability * m.probability)
        FROM _proj p
        JOIN mart.customer_year_state c
          ON c.customer_id = p.customer_id AND c.year = p_start_year
        -- the customer's age band at the START of projected year k
        JOIN mart.dim_age_band b
          ON c.age + k - 1 BETWEEN b.age_from AND b.age_to
        JOIN _matrix m
          ON m.scenario_id = p.scenario_id
         AND m.age_band_id = CASE WHEN p_banded THEN b.age_band_id ELSE 0 END
         AND m.state_from  = p.state_id
        WHERE p.horizon_year = k - 1
        GROUP BY p.scenario_id, p.customer_id, m.state_to;
        ANALYZE _proj;
    END LOOP;

    RETURN QUERY SELECT * FROM _proj;
END $$;

-- ----------------------------------------------------------------------------
-- Expected value per projected year.
--   p_banded      : passed through to the projection and the state means
--   p_persistence : TRUE adds the customer-specific rho^k term
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mart.project_value(
    p_start_year INT, p_train_through INT, p_horizon INT,
    p_banded BOOLEAN, p_persistence BOOLEAN, p_scenarios INT[])
RETURNS TABLE (scenario_id INT, customer_id INT, horizon_year INT,
               expected_value DOUBLE PRECISION, survival_probability DOUBLE PRECISION)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_rho FLOAT8 := CASE WHEN p_persistence THEN mart.persistence(p_train_through) ELSE 0 END;
BEGIN
    -- state means, fitted on data available at the training cut-off
    DROP TABLE IF EXISTS _value;
    CREATE TEMP TABLE _value AS SELECT * FROM mart.state_value(p_train_through + 1);

    -- each customer's starting gap: own value minus their state's average
    DROP TABLE IF EXISTS _start;
    CREATE TEMP TABLE _start AS
    SELECT c.customer_id, c.age,
           (c.annualised_value - sv.mean_value)::FLOAT8 AS gap
    FROM mart.customer_year_state c
    JOIN _value sv ON sv.state_id = c.state_id
                  AND sv.age_band_id = CASE WHEN p_banded THEN c.age_band_id ELSE 0 END
    WHERE c.year = p_start_year AND c.state_id IS NOT NULL;

    DROP TABLE IF EXISTS _states;
    CREATE TEMP TABLE _states AS
    SELECT * FROM mart.project_states(p_start_year, p_train_through, p_horizon, p_banded, p_scenarios)
    WHERE horizon_year >= 1;

    ANALYZE _value; ANALYZE _start; ANALYZE _states;

    RETURN QUERY
    SELECT
        p.scenario_id,
        p.customer_id,
        p.horizon_year,
        SUM(p.probability * sv.mean_value)
            + POWER(v_rho, p.horizon_year) * s.gap
              * (1 - COALESCE(SUM(p.probability) FILTER (WHERE p.state_id = 5), 0)),
        1 - COALESCE(SUM(p.probability) FILTER (WHERE p.state_id = 5), 0)
    FROM _states p
    JOIN _start s USING (customer_id)
    -- value in year k uses the state mean for the customer's age band in that year
    JOIN mart.dim_age_band b ON s.age + p.horizon_year BETWEEN b.age_from AND b.age_to
    JOIN _value sv ON sv.state_id = p.state_id
                  AND sv.age_band_id = CASE WHEN p_banded THEN b.age_band_id ELSE 0 END
    GROUP BY p.scenario_id, p.customer_id, p.horizon_year, s.gap;
END $$;

-- ============================================================================
-- Production run: start from 1998, use every observed transition, 5 years,
-- age-banded matrices with persistence, all four attrition scenarios.
-- ============================================================================

DROP TABLE IF EXISTS mart.state_value_current CASCADE;
CREATE TABLE mart.state_value_current AS SELECT * FROM mart.state_value(1998);

DROP TABLE IF EXISTS mart.model_parameter CASCADE;
CREATE TABLE mart.model_parameter AS
SELECT 'persistence_rho' AS parameter, mart.persistence(1997) AS value,
       'Share of a customer''s gap to their state average that survives one year (estimated).' AS meaning;

DROP TABLE IF EXISTS mart.fact_state_projection CASCADE;
CREATE TABLE mart.fact_state_projection AS
SELECT * FROM mart.project_states(1998, 1997, mart.a('horizon_years')::INT, TRUE, ARRAY[1, 2, 3, 4]);

DROP TABLE IF EXISTS mart.fact_clv_projection CASCADE;
CREATE TABLE mart.fact_clv_projection AS
SELECT * FROM mart.project_value(1998, 1997, mart.a('horizon_years')::INT, TRUE, TRUE, ARRAY[1, 2, 3, 4]);

ALTER TABLE mart.fact_clv_projection ADD PRIMARY KEY (scenario_id, customer_id, horizon_year);

-- ----------------------------------------------------------------------------
-- MART.DIM_CUSTOMER
-- One row per customer with everything the report slices by, plus the
-- base-case CLV at the default discount rate for convenience.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.dim_customer CASCADE;

CREATE TABLE mart.dim_customer AS
WITH clv AS (
    SELECT
        customer_id,
        SUM(expected_value / POWER(1 + mart.a('discount_rate')::FLOAT8, horizon_year)) AS clv_5y,
        SUM(expected_value)                                                           AS undiscounted_5y,
        MAX(survival_probability) FILTER (WHERE horizon_year = 5)                      AS survival_5y
    FROM mart.fact_clv_projection
    WHERE scenario_id = (SELECT scenario_id FROM mart.dim_scenario WHERE is_default)
    GROUP BY customer_id
),
standing AS (
    SELECT account_id, COUNT(*) AS n_standing_orders FROM staging.orders GROUP BY account_id
)
SELECT
    a.account_id                                   AS customer_id,
    cl.client_id                                   AS owner_client_id,
    cl.gender,
    cl.birth_date,
    s.age                                          AS age_1998,
    s.age_band_id,
    di.district_name,
    di.region,
    di.avg_salary                                  AS district_avg_salary,
    a.open_date,
    EXTRACT(YEAR FROM a.open_date)::INT            AS open_year,
    ROUND((DATE '1998-12-31' - a.open_date) / 365.25, 1) AS tenure_years,
    a.statement_frequency,
    EXISTS (SELECT 1 FROM staging.disp x
            WHERE x.account_id = a.account_id AND x.role = 'disponent') AS has_disponent,
    COALESCE(st.n_standing_orders, 0)              AS n_standing_orders,
    l.loan_id IS NOT NULL                          AS ever_had_loan,
    l.status                                       AS loan_status,
    COALESCE(l.is_default, FALSE)                  AS loan_in_default,
    c.card_type,
    s.state_id                                     AS state_id_1998,
    ROUND(f.avg_balance::NUMERIC, 2)               AS avg_balance_1998,
    ROUND(f.annual_value::NUMERIC, 2)              AS value_1998,
    ROUND(clv.clv_5y::NUMERIC, 2)                  AS clv_5y_base,
    ROUND(clv.survival_5y::NUMERIC, 4)             AS survival_5y_base,
    -- rank and decile on CLV, and on today's value, to show how the two orderings differ
    NTILE(10) OVER (ORDER BY clv.clv_5y DESC NULLS LAST, a.account_id)      AS clv_decile,
    NTILE(10) OVER (ORDER BY f.annual_value DESC NULLS LAST, a.account_id)  AS current_value_decile
FROM staging.account a
JOIN staging.disp d               ON d.account_id = a.account_id AND d.role = 'owner'
JOIN staging.client cl            ON cl.client_id = d.client_id
JOIN staging.district di          ON di.district_id = cl.district_id
JOIN mart.customer_year_state s   ON s.customer_id = a.account_id AND s.year = 1998
JOIN mart.fact_customer_year f    ON f.customer_id = a.account_id AND f.year = 1998
LEFT JOIN standing st             ON st.account_id = a.account_id
LEFT JOIN staging.loan l          ON l.account_id = a.account_id
LEFT JOIN staging.card c          ON c.disp_id = d.disp_id
LEFT JOIN clv                     ON clv.customer_id = a.account_id;

ALTER TABLE mart.dim_customer ADD PRIMARY KEY (customer_id);

-- ----------------------------------------------------------------------------
-- Headline results
-- ----------------------------------------------------------------------------

SELECT parameter, ROUND(value::NUMERIC, 3) AS value FROM mart.model_parameter;

SELECT
    sc.scenario,
    ROUND(SUM(p.expected_value / POWER(1.10, p.horizon_year))::NUMERIC / 1e6, 2) AS portfolio_clv_czk_m,
    ROUND(SUM(p.expected_value / POWER(1.10, p.horizon_year))::NUMERIC
          / COUNT(DISTINCT p.customer_id))                                        AS avg_clv_czk,
    ROUND(100 * AVG(p.survival_probability) FILTER (WHERE p.horizon_year = 5)::NUMERIC, 1) AS retained_after_5y_pct
FROM mart.fact_clv_projection p
JOIN mart.dim_scenario sc USING (scenario_id)
GROUP BY sc.scenario_id, sc.scenario
ORDER BY sc.scenario_id;

SELECT
    st.state                           AS state_1998,
    COUNT(*)                           AS customers,
    ROUND(AVG(c.value_1998))           AS avg_value_1998,
    ROUND(AVG(c.clv_5y_base))          AS avg_clv_5y,
    ROUND(SUM(c.clv_5y_base) / 1e6, 2) AS total_clv_czk_m
FROM mart.dim_customer c
JOIN mart.dim_state st ON st.state_id = c.state_id_1998
GROUP BY st.state_id, st.state
ORDER BY st.state_id;
