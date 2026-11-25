-- QUESTION 2: UNIVERSITY FEE PAYMENTS

-- (a) CREATE TABLES

CREATE TABLE Students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE Payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES Students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES Payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES Students(student_id),
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);


-- INSERT THREE STUDENTS

INSERT INTO Students (student_number, full_name, fee_due)
VALUES
('S001', 'John Banda', 5000),
('S002', 'Mary Phiri', 7500),
('S003', 'Peter Zulu', 6000);


-- (b) CREATE FEE BALANCE FUNCTION

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due
    INTO v_fee
    FROM Students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student does not exist';
    END IF;

    SELECT COALESCE(SUM(amount), 0)
    INTO v_paid
    FROM Payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;


-- (d) CREATE PAYMENT AUDIT TRIGGER

CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON Payments
FOR EACH ROW
EXECUTE FUNCTION fn_payment_audit();


-- (c) CREATE PAYMENT PROCEDURE

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC(12,2),
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment exceeds outstanding balance';
    END IF;

    INSERT INTO Payments (
        student_id,
        amount,
        paid_on
    )
    VALUES (
        p_student_id,
        p_amount,
        p_paid_on
    );
END;
$$;


-- INSERT AT LEAST SIX PAYMENTS THROUGH THE PROCEDURE
-- STUDENT 3 INITIALLY HAS NO PAYMENTS

CALL pr_receive_payment(1, 1000, CURRENT_DATE);
CALL pr_receive_payment(1, 500, CURRENT_DATE);
CALL pr_receive_payment(2, 2000, CURRENT_DATE);
CALL pr_receive_payment(2, 1500, CURRENT_DATE);
CALL pr_receive_payment(1, 750, CURRENT_DATE);
CALL pr_receive_payment(2, 1000, CURRENT_DATE);


-- (e) CREATE OUTSTANDING FEE VIEW

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM Students s
WHERE fn_fee_balance(s.student_id) > 0;

-- QUERY THE VIEW

SELECT * FROM v_fee_balances;


-- (f) CREATE COMPOSITE INDEX

CREATE INDEX idx_payments_student_date
ON Payments (student_id, paid_on);

-- DISPLAY QUERY PLAN

EXPLAIN
SELECT *
FROM Payments
WHERE student_id = 1
AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- (g) CREATE DAILY COLLECTIONS PROCEDURE

CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_total NUMERIC(12,2);
BEGIN
    SELECT
        COUNT(*),
        COALESCE(SUM(amount), 0)
    INTO
        v_count,
        v_total
    FROM Payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (
        collection_date,
        payment_count,
        total_amount
    )
    VALUES (
        p_day,
        v_count,
        v_total
    )
    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;


-- SCHEDULE DAILY AT 01:00 FOR THE PREVIOUS DAY

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1);$$
);


-- TEST PROCEDURE

CALL pr_refresh_collections(CURRENT_DATE);

SELECT * FROM daily_collections;

-- VERIFY RESULTS

SELECT * FROM Students;
SELECT * FROM Payments;
SELECT * FROM payment_audit;
SELECT * FROM v_fee_balances;