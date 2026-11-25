-- ============================================================================
-- ICT371 Advanced Database — Question 1: Pharmacy Stock and Daily Sales
-- Student: Chanda Mubanga | ID: 202408138
-- Note: Run CREATE EXTENSION IF NOT EXISTS pg_cron; once before part (g).
-- ============================================================================

-- (a) Database Tables and Seed Data
DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path TO q1_pharmacy, public;

CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 15.00, 50),
    ('Amoxicillin 250mg', 45.00, 14),
    ('Ibuprofen 400mg',   25.00, 30);

-- (b) Function: fn_sale_value
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive. Got: %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- (c) Procedure: pr_record_sale
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
    v_total NUMERIC(12,2);
BEGIN
    -- Validate medicine and quantity via function
    v_total := fn_sale_value(p_medicine_id, p_quantity);

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL';
    END IF;

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %. Available: %, Requested: %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger: AFTER UPDATE on medicines
CREATE OR REPLACE FUNCTION trg_fn_audit_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_stock();

-- Load six valid sales through the completed procedure (Part a)
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1, 5,  CURRENT_DATE);
CALL pr_record_sale(2, 6,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 2,  CURRENT_DATE);
CALL pr_record_sale(3, 8,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 4,  CURRENT_DATE);

-- (e) View: v_low_stock
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query the view after sales
SELECT * FROM v_low_stock;

-- (f) Index & Justification
-- Justification: A composite B-tree index on (medicine_id, sold_on) satisfies the equality predicate
-- on medicine_id first and then performs a range scan on sold_on without sorting.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_sales
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_qty INTEGER;
    v_amt NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_qty, v_amt
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_qty, v_amt)
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 00:15 for the previous day
SELECT cron.schedule(
    'q1_refresh_daily_sales',
    '15 0 * * *',
    $$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1);$$
);
