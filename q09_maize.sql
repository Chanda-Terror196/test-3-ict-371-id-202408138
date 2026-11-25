-- ============================================================================
-- ICT371 Advanced Database — Question 9: Farmer Cooperative Maize Deliveries
-- Student: Chanda Mubanga | ID: 202408138
-- Note: Run CREATE EXTENSION IF NOT EXISTS pg_cron; once before part (g).
-- ============================================================================

-- (a) Database Tables and Seed Data
DROP SCHEMA IF EXISTS q9_maize CASCADE;
CREATE SCHEMA q9_maize;
SET search_path TO q9_maize, public;

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) UNIQUE NOT NULL,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL CHECK (total_weight >= 0),
    total_value   NUMERIC(12,2) NOT NULL CHECK (total_value >= 0)
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F-202408138', 'Chanda Mubanga'),
    ('F-202408144', 'Derrick Chama'),
    ('F-202408145', 'Grace Mwila'); -- Will have no unpaid deliveries

-- (b) Function: fn_maize_rate
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL';
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Unsupported maize grade: %. Allowed: A, B, C', p_grade;
    END CASE;
END;
$$;

-- (c) Procedure: pr_receive_delivery
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     CHAR(1),
    p_weight    NUMERIC(10,2),
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    -- Trigger validates weight, derives unit_rate and sets total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, UPPER(TRIM(p_grade)), p_weight, p_date, FALSE);
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE on deliveries
CREATE OR REPLACE FUNCTION trg_fn_calc_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight must be positive. Got: %', NEW.weight_kg;
    END IF;

    NEW.grade       := UPPER(TRIM(NEW.grade));
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_calc_delivery_value();

-- Load six deliveries after installing trigger covering all grades & payment states (Part a)
CALL pr_receive_delivery(1, 'A', 500.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 400.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 250.00, CURRENT_DATE - 1);
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (3, 'A', 600.00, CURRENT_DATE - 3, TRUE),
    (3, 'B', 200.00, CURRENT_DATE - 1, TRUE);

-- (e) View: v_farmer_amount_due
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value), 0.00) AS total_unpaid_amount
FROM farmers f
LEFT JOIN deliveries d
    ON d.farmer_id = f.farmer_id
   AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index & Justification
-- Justification: A composite index on (farmer_id, delivered_on) isolates a single farmer's
-- records first and performs a range scan across delivered_on without scanning the full table.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_purchases
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12,2);
    v_value  NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(weight_kg), 0.00), COALESCE(SUM(total_value), 0.00)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;
END;
$$;

-- Schedule daily at 01:30 for the previous day
SELECT cron.schedule(
    'q9_refresh_daily_purchases',
    '30 1 * * *',
    $$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1);$$
);
