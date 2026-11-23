-- ============================================================================
-- File:    09_export.sql
-- Purpose: Publish the reporting layer. Each mart.pbi_* view is exactly one
--          table in the Power BI model; the \copy lines write them to
--          data/mart/*.csv, which is what the report reads.
--
-- Run with psql from the project root (\copy is a psql command):
--     psql -d clv_banking -f sql/09_export.sql
-- To point Power BI at PostgreSQL directly instead, connect it to these same
-- views -- the column names and types are identical.
-- ============================================================================

CREATE OR REPLACE VIEW mart.pbi_dim_customer AS
SELECT
    c.customer_id,
    CASE c.gender WHEN 'F' THEN 'Female' ELSE 'Male' END        AS gender,
    c.age_1998                                                  AS age,
    b.age_band,
    b.age_band_id,
    c.region,
    c.district_name                                             AS district,
    c.district_avg_salary,
    c.open_date,
    c.open_year,
    c.tenure_years,
    INITCAP(REPLACE(c.statement_frequency, '_', ' '))           AS statement_frequency,
    CASE WHEN c.has_disponent THEN 'Yes' ELSE 'No' END          AS has_second_user,
    c.n_standing_orders                                         AS standing_orders,
    CASE WHEN c.ever_had_loan THEN 'Yes' ELSE 'No' END          AS has_loan,
    COALESCE(INITCAP(REPLACE(c.loan_status, '_', ' ')), 'No loan') AS loan_status,
    COALESCE(INITCAP(c.card_type), 'No card')                   AS card,
    CASE
        WHEN c.ever_had_loan AND c.card_type IS NOT NULL THEN 'Account + loan + card'
        WHEN c.ever_had_loan                             THEN 'Account + loan'
        WHEN c.card_type IS NOT NULL                     THEN 'Account + card'
        ELSE 'Account only'
    END                                                         AS product_holding,
    s.state                                                     AS current_state,
    s.state_id                                                  AS current_state_id,
    c.avg_balance_1998                                          AS current_balance,
    c.value_1998                                                AS current_value,
    c.clv_5y_base,
    c.survival_5y_base,
    c.clv_decile,
    c.current_value_decile,
    -- the customers a current-profit ranking would miss, or over-rate
    CASE
        WHEN c.clv_decile <= 2 AND c.current_value_decile > 2 THEN 'Under-rated today'
        WHEN c.clv_decile > 2 AND c.current_value_decile <= 2 THEN 'Over-rated today'
        WHEN c.clv_decile <= 2                                THEN 'Top tier on both'
        ELSE 'Rest of base'
    END                                                         AS ranking_gap
FROM mart.dim_customer c
JOIN mart.dim_state s    ON s.state_id = c.state_id_1998
JOIN mart.dim_age_band b ON b.age_band_id = c.age_band_id;

CREATE OR REPLACE VIEW mart.pbi_fact_customer_year AS
SELECT
    f.customer_id,
    f.year,
    s.state_id,
    f.days_open,
    ROUND(f.avg_balance, 2)              AS avg_balance,
    f.n_customer_txn                     AS customer_transactions,
    ROUND(f.avg_loan_outstanding, 2)     AS avg_loan_outstanding,
    ROUND(f.annual_value, 2)             AS annual_value,
    ROUND(f.annualised_value, 2)         AS annualised_value
FROM mart.fact_customer_year f
JOIN mart.customer_year_state s USING (customer_id, year);

CREATE OR REPLACE VIEW mart.pbi_fact_value_component AS
SELECT f.customer_id, f.year, v.component, v.component_sort, ROUND(v.amount, 2) AS amount
FROM mart.fact_customer_year f
CROSS JOIN LATERAL (VALUES
    ('Deposit margin', 1, f.deposit_margin),
    ('Loan margin',    2, f.loan_margin),
    ('Fee income',     3, f.fee_income),
    ('Card income',    4, f.card_income),
    ('Cost to serve',  5, f.cost_to_serve)
) AS v(component, component_sort, amount);

CREATE OR REPLACE VIEW mart.pbi_fact_clv_projection AS
SELECT scenario_id, customer_id, horizon_year,
       ROUND(expected_value::NUMERIC, 2)       AS expected_value,
       ROUND(survival_probability::NUMERIC, 5) AS survival_probability
FROM mart.fact_clv_projection;

CREATE OR REPLACE VIEW mart.pbi_fact_state_projection AS
SELECT scenario_id, customer_id, horizon_year, state_id,
       ROUND(probability::NUMERIC, 5) AS probability
FROM mart.fact_state_projection
WHERE probability >= 0.000005;

CREATE OR REPLACE VIEW mart.pbi_transition_matrix AS
SELECT
    m.scenario_id,
    m.age_band_id,
    COALESCE(b.age_band, 'All ages')   AS age_band,
    m.state_from                       AS from_state_id,
    f.state                            AS from_state,
    m.state_to                         AS to_state_id,
    t.state                            AS to_state,
    ROUND(m.probability, 5)            AS probability,
    o.n_from                           AS observed_transitions_from,
    CASE WHEN o.is_fallback THEN 'Pooled fallback' ELSE 'Own data' END AS estimate_source
FROM mart.transition_matrix m
JOIN mart.transition_matrix_observed o USING (age_band_id, state_from, state_to)
JOIN mart.dim_state f ON f.state_id = m.state_from
JOIN mart.dim_state t ON t.state_id = m.state_to
LEFT JOIN mart.dim_age_band b ON b.age_band_id = m.age_band_id
WHERE m.state_from <> 5;

CREATE OR REPLACE VIEW mart.pbi_dim_state AS
SELECT state_id, state, state_group, definition FROM mart.dim_state;

CREATE OR REPLACE VIEW mart.pbi_dim_scenario AS
SELECT scenario_id, scenario, base_attrition, note FROM mart.dim_scenario;

CREATE OR REPLACE VIEW mart.pbi_dim_year AS
SELECT year FROM mart.dim_year;

CREATE OR REPLACE VIEW mart.pbi_assumption AS
SELECT label AS assumption, value, unit,
       CASE source_type WHEN 'assumed' THEN 'Assumed' ELSE 'Calibrated from data' END AS source, basis
FROM mart.assumption
UNION ALL
SELECT 'Value persistence (rho)', ROUND(value::NUMERIC, 4), 'share p.a.', 'Calibrated from data', meaning
FROM mart.model_parameter
WHERE parameter = 'persistence_rho';

CREATE OR REPLACE VIEW mart.pbi_backtest_metric AS
SELECT model, horizon_year, 1996 + horizon_year AS predicted_year, customers,
       median_abs_error, mean_abs_error, top_decile_precision, separation_czk, portfolio_error_pct
FROM mart.backtest_metric;

CREATE OR REPLACE VIEW mart.pbi_backtest_state AS
SELECT b.chain, b.year, d.state_id, d.state, b.predicted_customers, b.actual_customers
FROM mart.backtest_state_distribution b
JOIN mart.dim_state d USING (state_id);

CREATE OR REPLACE VIEW mart.pbi_stationarity AS
SELECT f.state_id AS from_state_id, f.state AS from_state, t.state_id AS to_state_id, t.state AS to_state,
       s.n_early, s.n_late, s.p_early, s.p_late, s.p_shift, s.chi_square_contribution
FROM mart.stationarity_check s
JOIN mart.dim_state f ON f.state_id = s.state_from
JOIN mart.dim_state t ON t.state_id = s.state_to;

CREATE OR REPLACE VIEW mart.pbi_test_result AS
SELECT test_id, INITCAP(layer) AS layer, test, failures,
       CASE WHEN passed THEN 'Pass' ELSE 'Fail' END AS result
FROM mart.test_result;

\copy (SELECT * FROM mart.pbi_dim_customer ORDER BY customer_id)                         TO 'data/mart/dim_customer.csv'          WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_dim_state ORDER BY state_id)                               TO 'data/mart/dim_state.csv'             WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_dim_scenario ORDER BY scenario_id)                         TO 'data/mart/dim_scenario.csv'          WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_dim_year ORDER BY year)                                    TO 'data/mart/dim_year.csv'              WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_fact_customer_year ORDER BY customer_id, year)             TO 'data/mart/fact_customer_year.csv'    WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_fact_value_component ORDER BY customer_id, year, component_sort) TO 'data/mart/fact_value_component.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_fact_clv_projection ORDER BY scenario_id, customer_id, horizon_year) TO 'data/mart/fact_clv_projection.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_fact_state_projection ORDER BY scenario_id, customer_id, horizon_year, state_id) TO 'data/mart/fact_state_projection.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_transition_matrix ORDER BY scenario_id, age_band_id, from_state_id, to_state_id) TO 'data/mart/transition_matrix.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_assumption ORDER BY source, assumption)                                                TO 'data/mart/assumption.csv'            WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_backtest_metric ORDER BY horizon_year, model)              TO 'data/mart/backtest_metric.csv'       WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_backtest_state ORDER BY chain, year, state_id)             TO 'data/mart/backtest_state.csv'        WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_stationarity ORDER BY from_state_id, to_state_id)          TO 'data/mart/stationarity.csv'          WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM mart.pbi_test_result ORDER BY test_id)                              TO 'data/mart/test_result.csv'           WITH (FORMAT csv, HEADER)
