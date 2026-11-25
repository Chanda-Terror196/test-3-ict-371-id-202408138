-- ============================================================================
-- ICT371 Advanced Database — Question 10: Scholarship Application Assessment
-- Student: Chanda Mubanga | ID: 202408138
-- Note: Run CREATE EXTENSION IF NOT EXISTS pg_cron; once before part (g).
-- ============================================================================

-- (a) Database Tables and Seed Data
DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path TO q10_scholarship, public;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(15) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('202408138', 'Chanda Mubanga'),
    ('202408146', 'Kondwani Phiri'),
    ('202408147', 'Lillian Banda');

-- Six PENDING applications: qualifying, non-qualifying, and exact boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 21, 1800.00, 84.50, CURRENT_DATE - 5, 'PENDING'), -- Qualifying
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 4, 'PENDING'), -- Exact lower/upper boundary (Qualifying)
    (2, 25, 2950.00, 72.00, CURRENT_DATE - 3, 'PENDING'), -- Upper age boundary (Qualifying)
    (2, 17, 1500.00, 88.00, CURRENT_DATE - 2, 'PENDING'), -- Fails age (< 18)
    (3, 22, 3001.00, 79.00, CURRENT_DATE - 2, 'PENDING'), -- Fails income (> K3,000)
    (3, 20, 2200.00, 69.99, CURRENT_DATE - 1, 'PENDING'); -- Fails mark (< 70)

-- (b) Function: fn_scholarship_eligible
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Eligibility inputs (age, income, mark) must not be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive. Got: %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative. Got: %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100. Got: %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;

-- (c) Procedure: pr_assess_application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC(12,2);
    v_mark     NUMERIC(5,2);
    v_status   VARCHAR(15);
    v_eligible BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (current status: %)',
            p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger: AFTER UPDATE on applications
CREATE OR REPLACE FUNCTION trg_fn_audit_decision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_decision();

-- (e) View: v_approved_applicants
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index & Justification
-- Justification: A composite index on (status, submitted_on) groups records by decision status
-- first and then performs an efficient range scan over submitted_on dates.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

EXPLAIN
SELECT application_id, student_id, average_mark, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_assess_pending
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- Schedule every Monday at 08:00
SELECT cron.schedule(
    'q10_assess_pending_scholarships',
    '0 8 * * 1',
    $$CALL q10_scholarship.pr_assess_pending();$$
);
