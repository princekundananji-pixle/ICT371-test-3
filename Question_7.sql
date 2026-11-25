-- (a) TABLES

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month),
    CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INTEGER UNIQUE NOT NULL REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL,
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,
    CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(12,2) NOT NULL
);

INSERT INTO customers(full_name)
VALUES ('John Banda'), ('Mary Phiri'), ('Peter Zulu');

-- (b) FUNCTION

CREATE OR REPLACE FUNCTION fn_water_charge(
    p_units NUMERIC
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be NULL or negative';
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    ELSE
        RETURN ROUND((10 * 5) + ((p_units - 10) * 8), 2);
    END IF;
END;
$$;

-- (d) TRIGGER

CREATE OR REPLACE FUNCTION fn_validate_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading cannot be below previous reading';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_reading();

-- INSERT SIX READINGS

INSERT INTO readings
(customer_id, reading_month, previous_reading, current_reading)
VALUES
(1, DATE '2026-09-01', 0, 0),
(1, DATE '2026-10-01', 0, 10),
(2, DATE '2026-09-01', 20, 35),
(2, DATE '2026-10-01', 35, 45),
(3, DATE '2026-09-01', 100, 108),
(3, DATE '2026-10-01', 108, 125);

-- (c) PROCEDURE

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous NUMERIC(12,2);
    v_current NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    SELECT previous_reading, current_reading
    INTO v_previous, v_current
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reading does not exist';
    END IF;

    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    IF EXISTS (
        SELECT 1 FROM bills WHERE reading_id = p_reading_id
    ) THEN
        RAISE EXCEPTION 'Bill already exists for this reading';
    END IF;

    v_charge := fn_water_charge(v_current - v_previous);

    INSERT INTO bills(reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- GENERATE BILLS

CALL pr_generate_bill(1, CURRENT_DATE + 30);
CALL pr_generate_bill(2, CURRENT_DATE + 30);
CALL pr_generate_bill(3, CURRENT_DATE + 30);
CALL pr_generate_bill(4, CURRENT_DATE + 30);
CALL pr_generate_bill(5, CURRENT_DATE + 30);
CALL pr_generate_bill(6, CURRENT_DATE + 30);

-- (e) VIEW

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name,
    b.due_on,
    b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) INDEX

CREATE INDEX idx_bills_due_date
ON bills(due_on)
WHERE amount_paid < charge;

EXPLAIN
SELECT *
FROM bills
WHERE due_on < CURRENT_DATE
AND amount_paid < charge;

-- (g) RECEIVABLE PROCEDURE

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0)
    INTO v_total
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot
    VALUES (CURRENT_DATE, v_total)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-receivables',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);

CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;