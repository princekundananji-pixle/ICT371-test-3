-- QUESTION 1: PHARMACY STOCK AND DAILY SALES

-- (a) CREATE DATABASE TABLES

CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);


-- (b) CREATE FUNCTION

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine does not exist';
    END IF;

    RETURN v_price * p_quantity;
END;
$$;


-- (d) CREATE STOCK AUDIT TRIGGER

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (
            medicine_id, old_qty, new_qty
        )
        VALUES (
            NEW.medicine_id,
            OLD.stock_qty,
            NEW.stock_qty
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_stock_audit();


-- (c) CREATE PROCEDURE

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine does not exist';
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock available';
    END IF;

    INSERT INTO sales (
        medicine_id, quantity, unit_price, sold_on
    )
    VALUES (
        p_medicine_id, p_quantity, v_price, p_sold_on
    );

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;

END;
$$;


-- (a) INSERT MEDICINES

INSERT INTO medicines (medicine_name, unit_price, stock_qty)
VALUES
('Paracetamol', 5.00, 100),
('Amoxicillin', 12.00, 80),
('Ibuprofen', 8.00, 60);


-- LOAD SIX VALID SALES THROUGH THE PROCEDURE

CALL pr_record_sale(1, 5, CURRENT_DATE);
CALL pr_record_sale(2, 3, CURRENT_DATE);
CALL pr_record_sale(3, 4, CURRENT_DATE);
CALL pr_record_sale(1, 6, CURRENT_DATE);
CALL pr_record_sale(2, 2, CURRENT_DATE);
CALL pr_record_sale(3, 5, CURRENT_DATE);


-- (e) CREATE LOW STOCK VIEW

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- QUERY THE VIEW

SELECT * FROM v_low_stock;


-- (f) CREATE INDEX

CREATE INDEX idx_sales_medicine_date
ON sales (medicine_id, sold_on);

-- MATCHING QUERY

EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- (g) CREATE DAILY SALES REFRESH PROCEDURE

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty INTEGER;
    v_total_amount NUMERIC(12,2);
BEGIN
    SELECT
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    INTO
        v_total_qty,
        v_total_amount
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (
        sales_date, total_qty, total_amount
    )
    VALUES (
        p_day, v_total_qty, v_total_amount
    )
    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;


-- SCHEDULE DAILY AT 00:15 FOR THE PREVIOUS DAY

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1);$$
);


-- TEST DAILY SALES PROCEDURE

CALL pr_refresh_sales(CURRENT_DATE);

SELECT * FROM daily_sales;

-- VERIFY SALES AND STOCK

SELECT * FROM medicines;
SELECT * FROM sales;
SELECT * FROM stock_audit;