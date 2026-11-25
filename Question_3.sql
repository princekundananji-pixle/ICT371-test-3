-- (a) TABLES

CREATE TABLE Books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE Loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES Books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(10,2) DEFAULT 0,
    CHECK (due_on >= borrowed_on),
    CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INTEGER REFERENCES Loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL,
    total_fine NUMERIC(12,2) NOT NULL
);

INSERT INTO Books(title)
VALUES ('Database Systems'), ('Computer Networks'), ('Cyber Security');

-- (b) FUNCTION

CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of DATE
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due DATE;
    v_returned DATE;
    v_end DATE;
BEGIN
    SELECT due_on, returned_on
    INTO v_due, v_returned
    FROM Loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan does not exist';
    END IF;

    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Date is required';
    END IF;

    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN GREATEST(v_end - v_due, 0) * 2.00;
END;
$$;

-- (d) TRIGGER

CREATE OR REPLACE FUNCTION fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit
        (loan_id, old_returned_on, new_returned_on)
        VALUES
        (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON Loans
FOR EACH ROW
EXECUTE FUNCTION fn_loan_audit();

-- (c) PROCEDURE

CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    SELECT borrowed_on, returned_on
    INTO v_borrowed, v_returned
    FROM Loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan does not exist';
    END IF;

    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan has already been returned';
    END IF;

    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Invalid return date';
    END IF;

    UPDATE Loans
    SET returned_on = p_returned_on,
        fine_amount = GREATEST(p_returned_on - due_on, 0) * 2.00
    WHERE loan_id = p_loan_id;
END;
$$;

-- (a) SEED DATA: SIX LOANS

INSERT INTO Loans
(book_id, borrower_name, borrowed_on, due_on, returned_on)
VALUES
(1, 'John Banda', CURRENT_DATE - 20, CURRENT_DATE - 10, NULL),
(2, 'Mary Phiri', CURRENT_DATE - 10, CURRENT_DATE + 5, NULL),
(3, 'Peter Zulu', CURRENT_DATE - 15, CURRENT_DATE - 5, CURRENT_DATE - 5),
(1, 'James Mwila', CURRENT_DATE - 12, CURRENT_DATE - 2, NULL),
(2, 'Grace Tembo', CURRENT_DATE - 8, CURRENT_DATE + 2, NULL),
(3, 'Brian Chanda', CURRENT_DATE - 20, CURRENT_DATE - 10, CURRENT_DATE - 8);

-- (e) VIEW

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine
FROM Loans l
JOIN Books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) INDEX

CREATE INDEX idx_loans_book_unreturned
ON Loans(book_id)
WHERE returned_on IS NULL;

EXPLAIN
SELECT *
FROM Loans
WHERE book_id = 1
AND returned_on IS NULL;

-- (g) SUMMARY PROCEDURE

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_total NUMERIC(12,2);
BEGIN
    SELECT COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    INTO v_count, v_total
    FROM Loans
    WHERE returned_on IS NULL
    AND due_on < p_as_of;

    INSERT INTO overdue_summary
    VALUES (p_as_of, v_count, v_total)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-overdue',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);

CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;