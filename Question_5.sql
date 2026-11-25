-- (a) TABLES

CREATE TABLE Students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE Rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE Allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES Students(student_id),
    room_id INTEGER NOT NULL REFERENCES Rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL
        CHECK (status IN ('ACTIVE', 'ENDED')),
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL REFERENCES Rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- SEED DATA

INSERT INTO Students(student_number, full_name)
VALUES
('S001', 'John Banda'),
('S002', 'Mary Phiri'),
('S003', 'Peter Zulu'),
('S004', 'James Mwila'),
('S005', 'Grace Tembo');

INSERT INTO Rooms(room_number, capacity)
VALUES ('R101', 2), ('R102', 3), ('R103', 2);

-- (b) FUNCTION

CREATE OR REPLACE FUNCTION fn_free_beds(
    p_room_id INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    SELECT capacity INTO v_capacity
    FROM Rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room does not exist';
    END IF;

    SELECT COUNT(*) INTO v_occupied
    FROM Allocations
    WHERE room_id = p_room_id
    AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

-- (d) TRIGGER

CREATE OR REPLACE FUNCTION fn_check_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN

        IF EXISTS (
            SELECT 1
            FROM Allocations
            WHERE student_id = NEW.student_id
            AND status = 'ACTIVE'
            AND allocation_id <> COALESCE(NEW.allocation_id, -1)
        ) THEN
            RAISE EXCEPTION 'Student already has an active allocation';
        END IF;

        SELECT capacity INTO v_capacity
        FROM Rooms
        WHERE room_id = NEW.room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Room does not exist';
        END IF;

        SELECT COUNT(*) INTO v_occupied
        FROM Allocations
        WHERE room_id = NEW.room_id
        AND status = 'ACTIVE'
        AND allocation_id <> COALESCE(NEW.allocation_id, -1);

        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION 'Room capacity exceeded';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_allocation
BEFORE INSERT OR UPDATE ON Allocations
FOR EACH ROW
EXECUTE FUNCTION fn_check_allocation();

-- (c) PROCEDURE

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INTEGER,
    p_room_id INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM Students WHERE student_id = p_student_id
    ) THEN
        RAISE EXCEPTION 'Student does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM Rooms WHERE room_id = p_room_id
    ) THEN
        RAISE EXCEPTION 'Room does not exist';
    END IF;

    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;

    IF EXISTS (
        SELECT 1 FROM Allocations
        WHERE student_id = p_student_id
        AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student already has an active allocation';
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room is full';
    END IF;

    INSERT INTO Allocations
    (student_id, room_id, allocated_on, released_on, status)
    VALUES
    (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- SEED ALLOCATIONS

CALL pr_allocate_room(1, 1, CURRENT_DATE);
CALL pr_allocate_room(2, 1, CURRENT_DATE);
CALL pr_allocate_room(3, 2, CURRENT_DATE);
CALL pr_allocate_room(4, 2, CURRENT_DATE);

-- (e) VIEW

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) AS free_beds
FROM Rooms r
LEFT JOIN Allocations a
    ON r.room_id = a.room_id
    AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;

-- (f) INDEX

CREATE INDEX idx_active_allocations_room
ON Allocations(room_id)
WHERE status = 'ACTIVE';

EXPLAIN
SELECT *
FROM Allocations
WHERE room_id = 1
AND status = 'ACTIVE';

-- (g) OCCUPANCY PROCEDURE

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot
    (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id),
        r.capacity - COUNT(a.allocation_id)
    FROM Rooms r
    LEFT JOIN Allocations a
        ON r.room_id = a.room_id
        AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-occupancy',
    '55 23 * * *',
    $$CALL pr_refresh_occupancy();$$
);

CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot;