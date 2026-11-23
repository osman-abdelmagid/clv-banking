-- ============================================================================
-- File:    08_tests.sql
-- Purpose: Assertions the pipeline must satisfy. Each test writes one row to
--          mart.test_result; the script then fails loudly if any test failed.
--          Run after 07_validation.sql.
-- ============================================================================

DROP TABLE IF EXISTS mart.test_result CASCADE;

CREATE TABLE mart.test_result (
    test_id  INT PRIMARY KEY,
    layer    TEXT NOT NULL,
    test     TEXT NOT NULL,
    failures BIGINT NOT NULL,          -- number of offending rows; 0 = pass
    passed   BOOLEAN GENERATED ALWAYS AS (failures = 0) STORED
);

-- 1. Raw row counts match the published PKDD'99 figures
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 1, 'raw', 'Row counts match the PKDD''99 documentation (8 tables)',
       (SELECT COUNT(*) FROM (VALUES
            ((SELECT COUNT(*) FROM raw.account),  4500),
            ((SELECT COUNT(*) FROM raw.client),   5369),
            ((SELECT COUNT(*) FROM raw.disp),     5369),
            ((SELECT COUNT(*) FROM raw.trans), 1056320),
            ((SELECT COUNT(*) FROM raw.loan),      682),
            ((SELECT COUNT(*) FROM raw.card),      892),
            ((SELECT COUNT(*) FROM raw.orders),   6471),
            ((SELECT COUNT(*) FROM raw.district),   77)
        ) AS t(actual, expected) WHERE actual <> expected);

-- 2. Keys are unique in staging
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 2, 'staging', 'Primary keys are unique (account, client, disp, trans, loan, card)',
       (SELECT COUNT(*) - COUNT(DISTINCT account_id) FROM staging.account)
     + (SELECT COUNT(*) - COUNT(DISTINCT client_id)  FROM staging.client)
     + (SELECT COUNT(*) - COUNT(DISTINCT disp_id)    FROM staging.disp)
     + (SELECT COUNT(*) - COUNT(DISTINCT trans_id)   FROM staging.trans)
     + (SELECT COUNT(*) - COUNT(DISTINCT loan_id)    FROM staging.loan)
     + (SELECT COUNT(*) - COUNT(DISTINCT card_id)    FROM staging.card);

-- 3. No date failed to parse and no transaction falls outside 1993-1998
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 3, 'staging', 'All transaction dates parse and fall in 1993-1998',
       (SELECT COUNT(*) FROM staging.trans
        WHERE trans_date IS NULL OR trans_date < DATE '1993-01-01' OR trans_date > DATE '1998-12-31');

-- 4. Every account has exactly one owner
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 4, 'staging', 'Every account has exactly one owner',
       (SELECT COUNT(*) FROM (
            SELECT a.account_id
            FROM staging.account a
            LEFT JOIN staging.disp d ON d.account_id = a.account_id AND d.role = 'owner'
            GROUP BY a.account_id
            HAVING COUNT(d.disp_id) <> 1) x);

-- 5. Rebuilt end-of-day balances reconcile to a reported balance within 3 CZK
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 5, 'mart', 'Rebuilt end-of-day balance reconciles to the source within 3 CZK on every account-day',
       (SELECT COUNT(*)
        FROM mart.account_day_balance b
        WHERE NOT EXISTS (
            SELECT 1 FROM staging.trans t
            WHERE t.account_id = b.account_id
              AND t.trans_date = b.bal_date
              AND ABS(t.balance - b.eod_balance) <= 3));

-- 6. The panel has one row per account for every year from opening to 1998
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 6, 'mart', 'Customer-year panel is complete from opening year to 1998',
       (SELECT COUNT(*) FROM (
            SELECT a.account_id
            FROM staging.account a
            LEFT JOIN mart.fact_customer_year f ON f.customer_id = a.account_id
            GROUP BY a.account_id, a.open_date
            HAVING COUNT(f.year) <> 1998 - EXTRACT(YEAR FROM a.open_date) + 1) x);

-- 7. Value components add up to annual value
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 7, 'mart', 'Value components sum to annual value',
       (SELECT COUNT(*) FROM mart.fact_customer_year
        WHERE ABS(deposit_margin + loan_margin + fee_income + card_income + cost_to_serve - annual_value) > 0.01);

-- 8. Every transition-matrix row is a probability distribution
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 8, 'model', 'Every transition-matrix row sums to 1 with no negative cell',
       (SELECT COUNT(*) FROM (
            SELECT 1 FROM mart.transition_matrix
            GROUP BY scenario_id, age_band_id, state_from
            HAVING ABS(SUM(probability) - 1) > 1e-9 OR MIN(probability) < 0) x);

-- 9. Projected state probabilities sum to 1 for every customer, year and scenario
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 9, 'model', 'Projected state probabilities sum to 1 per customer, year and scenario',
       (SELECT COUNT(*) FROM (
            SELECT 1 FROM mart.fact_state_projection
            GROUP BY scenario_id, customer_id, horizon_year
            HAVING ABS(SUM(probability) - 1) > 1e-9) x);

-- 10. Survival never rises over the horizon (Churned is absorbing)
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 10, 'model', 'Survival probability never increases from one year to the next',
       (SELECT COUNT(*) FROM (
            SELECT survival_probability
                   - LAG(survival_probability) OVER (PARTITION BY scenario_id, customer_id ORDER BY horizon_year) AS change
            FROM mart.fact_clv_projection) x
        WHERE change > 1e-9);

-- 11. More attrition never produces more portfolio value
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 11, 'model', 'Portfolio CLV falls as the attrition scenario gets harsher',
       (SELECT COUNT(*) FROM (
            SELECT SUM(p.expected_value)
                   - LAG(SUM(p.expected_value)) OVER (ORDER BY s.base_attrition) AS change
            FROM mart.fact_clv_projection p
            JOIN mart.dim_scenario s USING (scenario_id)
            GROUP BY s.scenario_id, s.base_attrition) x
        WHERE change > 0);

-- 12. Every customer with a 1998 state has a full five-year projection
INSERT INTO mart.test_result (test_id, layer, test, failures)
SELECT 12, 'model', 'Every customer has a projection for each of the 5 years in each of the 4 scenarios',
       (SELECT COUNT(*) FROM (
            SELECT c.customer_id
            FROM mart.dim_customer c
            LEFT JOIN mart.fact_clv_projection p USING (customer_id)
            GROUP BY c.customer_id
            HAVING COUNT(p.horizon_year) <> 20) x);

SELECT test_id, layer, test, failures, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM mart.test_result
ORDER BY test_id;

DO $$
DECLARE n_failed INT;
BEGIN
    SELECT COUNT(*) INTO n_failed FROM mart.test_result WHERE NOT passed;
    IF n_failed > 0 THEN
        RAISE EXCEPTION '% pipeline test(s) failed -- see mart.test_result', n_failed;
    END IF;
END $$;
