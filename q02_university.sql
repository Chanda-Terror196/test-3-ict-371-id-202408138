-- ============================================================================
-- ICT371 Advanced Database — Question 2: University Fee Payments
-- Student: Chanda Mubanga | ID: 202408138
-- Note: Run CREATE EXTENSION IF NOT EXISTS pg_cron; once before part (g).
-- ============================================================================

-- (a) Database Tables and Seed Data
DROP SCHEMA IF EXISTS q2_university CASCADE;
CREATE SCHEMA q2_university;
SET search_path TO q2_university, public;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(120) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL CHECK (payment_count >= 0),
    total_amount    NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202408138', 'Chanda Mubanga', 12000.00),
    ('202408139', 'Mutale Banda',    9500.00),
    ('202408140', 'Thabo Phiri',    11000.00); -- Initially has no payments

-- (b) Function: fn_fee_balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_paid    NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_paid;
END;
$$;

-- (c) Procedure: pr_receive_payment
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC(12,2),
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero. Got: %', p_amount;
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL';
    END IF;

    -- Lock student row to prevent concurrent overpayment
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Overpayment rejected. Amount: %, Outstanding balance: %', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger: AFTER INSERT on payments
CREATE OR REPLACE FUNCTION trg_fn_log_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_log_payment();

-- Seed six payments across two students (Student 3 remains with zero payments)
CALL pr_receive_payment(1, 3000.00, CURRENT_DATE - 10);
CALL pr_receive_payment(1, 4000.00, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 5000.00, CURRENT_DATE - 1); -- Student 1 fully settled
CALL pr_receive_payment(2, 2000.00, CURRENT_DATE - 8);
CALL pr_receive_payment(2, 2500.00, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 1);

-- (e) View: v_fee_balances
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

-- (f) Index & Justification
-- Justification: A composite index on (student_id, paid_on) allows PostgreSQL to jump directly
-- to a specific student's entries and scan the contiguous date range without reading other students.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_collections
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_total NUMERIC(12,2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(amount), 0.00)
    INTO v_count, v_total
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_total)
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 01:00 for the previous day
SELECT cron.schedule(
    'q2_refresh_daily_collections',
    '0 1 * * *',
    $$CALL q2_university.pr_refresh_collections(CURRENT_DATE - 1);$$
);
