-- ============================================================================
-- ICT371 Advanced Database — Question 6: Monthly Payroll Processing
-- Student: Chanda Mubanga | ID: 202408138
-- Note: Run CREATE EXTENSION IF NOT EXISTS pg_cron; once before part (g).
-- ============================================================================

-- (a) Database Tables and Seed Data
DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path TO q6_payroll, public;

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mubanga',  15000.00, 3000.00, 2200.00, TRUE),
    ('Taonga Nyirenda', 12000.00, 2000.00, 1800.00, TRUE),
    ('Mubita Sililo',   10000.00, 1500.00, 1200.00, FALSE); -- Inactive employee

-- Seed historical payroll across two months (including employee 3 when active)
INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay) VALUES
    (1, '2026-09-01', 18000.00, 15800.00),
    (2, '2026-09-01', 14000.00, 12200.00),
    (3, '2026-09-01', 11500.00, 10300.00),
    (1, '2026-10-01', 18000.00, 15800.00),
    (2, '2026-10-01', 14000.00, 12200.00);

-- (b) Function: fn_net_pay
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net       NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allowance) - v_deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) computed for employee_id %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure: pr_process_payroll
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec     RECORD;
    v_gross NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month. Got: %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
    LOOP
        v_net   := fn_net_pay(rec.employee_id);
        v_gross := rec.basic_salary + rec.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Trigger: AFTER UPDATE on employees
CREATE OR REPLACE FUNCTION trg_fn_audit_salary()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_salary();

-- (e) View: v_payroll_report
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name AS employee_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index & Justification
-- Justification: The existing UNIQUE (employee_id, pay_month) index has employee_id as its leading
-- column, making it inefficient for queries filtering solely by pay_month across all staff.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = '2026-10-01';

-- (g) Scheduled Job & Inspection
-- Schedule at 02:00 on the 1st of every month for the first date of the previous month
SELECT cron.schedule(
    'q6_monthly_payroll',
    '0 2 1 * *',
    $$CALL q6_payroll.pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$$
);

-- Inspect configured job and execution run history
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_monthly_payroll';

SELECT runid, jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_monthly_payroll')
ORDER BY start_time DESC;
