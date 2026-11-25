-- (a) TABLES

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (
        average_mark BETWEEN 0 AND 100
    ),
    submitted_on DATE NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INTEGER REFERENCES applications(application_id),
    old_status VARCHAR(10),
    new_status VARCHAR(10),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- SEED STUDENTS

INSERT INTO students(student_number, full_name)
VALUES
('S001', 'John Banda'),
('S002', 'Mary Phiri'),
('S003', 'Peter Zulu');

-- (b) FUNCTION

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INTEGER,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'All application details are required';
    END IF;

    IF p_age <= 0 OR p_income < 0
       OR p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid application details';
    END IF;

    RETURN (
        p_age BETWEEN 18 AND 25
        AND p_income <= 3000
        AND p_mark >= 70
    );
END;
$$;

-- (d) TRIGGER

CREATE OR REPLACE FUNCTION fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit
        (application_id, old_status, new_status, changed_at)
        VALUES
        (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_decision_audit();

-- (a) INSERT SIX PENDING APPLICATIONS

INSERT INTO applications
(student_id, age_at_application, monthly_income,
 average_mark, submitted_on, status)
VALUES
(1, 20, 2500, 80, CURRENT_DATE, 'PENDING'),
(1, 17, 2000, 75, CURRENT_DATE, 'PENDING'),
(2, 25, 3000, 70, CURRENT_DATE, 'PENDING'),
(2, 26, 2500, 85, CURRENT_DATE, 'PENDING'),
(3, 22, 3500, 90, CURRENT_DATE, 'PENDING'),
(3, 19, 2000, 65, CURRENT_DATE, 'PENDING');

-- (c) PROCEDURE

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age INTEGER;
    v_income NUMERIC(12,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(10);
    v_eligible BOOLEAN;
BEGIN
    SELECT
        age_at_application,
        monthly_income,
        average_mark,
        status
    INTO
        v_age,
        v_income,
        v_mark,
        v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application does not exist';
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application has already been assessed';
    END IF;

    v_eligible := fn_scholarship_eligible(
        v_age, v_income, v_mark
    );

    IF v_eligible THEN
        UPDATE applications
        SET status = 'APPROVED'
        WHERE application_id = p_application_id;
    ELSE
        UPDATE applications
        SET status = 'REJECTED'
        WHERE application_id = p_application_id;
    END IF;
END;
$$;

-- ASSESS APPLICATIONS

CALL pr_assess_application(1);
CALL pr_assess_application(2);
CALL pr_assess_application(3);
CALL pr_assess_application(4);
CALL pr_assess_application(5);
CALL pr_assess_application(6);

-- (e) VIEW

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- (f) INDEX

CREATE INDEX idx_applications_status_date
ON applications(status, submitted_on);

EXPLAIN
SELECT *
FROM applications
WHERE status = 'PENDING'
AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) PROCEDURE TO ASSESS ALL PENDING APPLICATIONS

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    app RECORD;
BEGIN
    FOR app IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(app.application_id);
    END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'assess-pending-applications',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);

CALL pr_assess_pending();

-- VERIFY RESULTS

SELECT * FROM applications;
SELECT * FROM decision_audit;
SELECT * FROM v_approved_applica