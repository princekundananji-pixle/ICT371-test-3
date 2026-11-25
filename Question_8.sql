-- (a) TABLES

CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(30) UNIQUE NOT NULL,
    current_odometer NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12,2) NOT NULL CHECK (
        last_service_odometer >= 0
        AND last_service_odometer <= current_odometer
    )
);

CREATE TABLE trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer NUMERIC(12,2) NOT NULL,
    end_odometer NUMERIC(12,2) NOT NULL,
    CHECK (start_odometer >= 0),
    CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,2) NOT NULL,
    flagged_on DATE NOT NULL
);

-- SEED VEHICLES

INSERT INTO vehicles
(registration, current_odometer, last_service_odometer)
VALUES
('ABC100', 10000, 5000),
('ABC200', 20000, 16000),
('ABC300', 30000, 29000);

-- (b) FUNCTION

CREATE OR REPLACE FUNCTION fn_service_due(
    p_vehicle_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(12,2);
    v_service NUMERIC(12,2);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_current, v_service
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle does not exist';
    END IF;

    RETURN (v_current - v_service) >= 5000;
END;
$$;

-- (d) TRIGGER

CREATE OR REPLACE FUNCTION fn_update_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(12,2);
BEGIN
    SELECT current_odometer
    INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle does not exist';
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at current odometer value';
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid trip mileage';
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_update_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_update_odometer();

-- (c) PROCEDURE

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on DATE,
    p_start NUMERIC,
    p_end NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id
    ) THEN
        RAISE EXCEPTION 'Vehicle does not exist';
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid trip mileage';
    END IF;

    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date is required';
    END IF;

    INSERT INTO trips
    (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES
    (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- SIX TRIPS ADDED THROUGH PROCEDURE

CALL pr_record_trip(1, CURRENT_DATE, 10000, 11000);
CALL pr_record_trip(1, CURRENT_DATE, 11000, 12000);
CALL pr_record_trip(2, CURRENT_DATE, 20000, 21000);
CALL pr_record_trip(2, CURRENT_DATE, 21000, 22000);
CALL pr_record_trip(3, CURRENT_DATE, 30000, 31000);
CALL pr_record_trip(3, CURRENT_DATE, 31000, 32000);

-- (e) VIEW

CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) INDEX

CREATE INDEX idx_trips_vehicle_date
ON trips(vehicle_id, trip_on);

EXPLAIN
SELECT *
FROM trips
WHERE vehicle_id = 1
AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) SERVICE ALERT PROCEDURE

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts
    (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        current_odometer - last_service_odometer,
        CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id)
    DO UPDATE SET
        km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;

    DELETE FROM service_alerts
    WHERE vehicle_id IN (
        SELECT vehicle_id
        FROM vehicles
        WHERE current_odometer - last_service_odometer < 5000
    );
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-service-alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;