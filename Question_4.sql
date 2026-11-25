-- (a) TABLES

CREATE TABLE Patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE Doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INTEGER REFERENCES Patients(patient_id),
    doctor_id INTEGER REFERENCES Doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,
    status VARCHAR(15) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INTEGER NOT NULL,
    attended_count INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

-- (d) TRIGGER

CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.slot_time NOT IN (
        TIME '09:00', TIME '10:00',
        TIME '11:00', TIME '12:00'
    ) THEN
        RAISE EXCEPTION 'Unsupported appointment slot';
    END IF;

    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1
        FROM appointments
        WHERE doctor_id = NEW.doctor_id
        AND appointment_day = NEW.appointment_day
        AND slot_time = NEW.slot_time
        AND status <> 'CANCELLED'
        AND appointment_id <> COALESCE(NEW.appointment_id, -1)
    ) THEN
        RAISE EXCEPTION 'Doctor already has an appointment in this slot';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_check_appointment_clash();

-- SEED DATA

INSERT INTO Patients(full_name)
VALUES ('John Banda'), ('Mary Phiri'), ('Peter Zulu');

INSERT INTO Doctors(full_name)
VALUES ('Dr James'), ('Dr Grace'), ('Dr Brian');

-- (b) FUNCTION

CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INTEGER,
    p_day DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM Doctors WHERE doctor_id = p_doctor_id
    ) THEN
        RAISE EXCEPTION 'Doctor does not exist';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
    AND appointment_day = p_day
    AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- (c) PROCEDURE

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id INTEGER,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM Patients WHERE patient_id = p_patient_id
    ) THEN
        RAISE EXCEPTION 'Patient does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM Doctors WHERE doctor_id = p_doctor_id
    ) THEN
        RAISE EXCEPTION 'Doctor does not exist';
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book a past date';
    END IF;

    IF p_slot NOT IN (
        TIME '09:00', TIME '10:00',
        TIME '11:00', TIME '12:00'
    ) THEN
        RAISE EXCEPTION 'Unsupported appointment slot';
    END IF;

    INSERT INTO appointments
    (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES
    (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- SIX APPOINTMENTS

CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE, '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE, '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE, '10:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE, '11:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE, '12:00');

-- (e) VIEW

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN Patients p ON p.patient_id = a.patient_id
JOIN Doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;

-- (f) INDEX

CREATE INDEX idx_appointments_day_doctor
ON appointments(appointment_day, doctor_id);

EXPLAIN
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
AND doctor_id = 1;

-- (g) SUMMARY PROCEDURE

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked INTEGER;
    v_attended INTEGER;
    v_cancelled INTEGER;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-clinic-summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);$$
);

CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary;