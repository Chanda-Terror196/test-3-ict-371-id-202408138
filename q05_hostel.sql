-- ============================================================================
-- ICT371 Advanced Database — Question 5: Hostel Room Allocation
-- Student: Chanda Mubanga | ID: 202408138
-- Note: Run CREATE EXTENSION IF NOT EXISTS pg_cron; once before part (g).
-- ============================================================================

-- (a) Database Tables and Seed Data
DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path TO q5_hostel, public;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_alloc_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2), -- Will be FULL (2/2)
    ('A102', 3), -- Will be PARTLY OCCUPIED (1/3)
    ('A103', 2); -- Will be EMPTY (0/2)

INSERT INTO students (student_number, full_name) VALUES
    ('202408138', 'Chanda Mubanga'),
    ('202408141', 'Kasonde Lungu'),
    ('202408142', 'Bupe Katongo'),
    ('202408143', 'Sampa Nkandu');

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, CURRENT_DATE - 30, NULL,              'ACTIVE'),
    (2, 1, CURRENT_DATE - 25, NULL,              'ACTIVE'),
    (3, 2, CURRENT_DATE - 10, NULL,              'ACTIVE'),
    (4, 3, CURRENT_DATE - 60, CURRENT_DATE - 15, 'ENDED'); -- Ended history

-- (b) Function: fn_free_beds
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

-- (c) Procedure: pr_allocate_room
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL';
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE room allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds available', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE on allocations
CREATE OR REPLACE FUNCTION trg_fn_enforce_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- Enforce one ACTIVE allocation per student
        IF EXISTS (
            SELECT 1 FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Student % already holds an ACTIVE allocation', NEW.student_id;
        END IF;

        -- Lock room and enforce capacity
        SELECT capacity INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        SELECT COUNT(*) INTO v_occupied
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION 'Room % capacity (%) exceeded', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_validate
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_enforce_allocation_rules();

-- (e) View: v_room_occupancy
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
    ON a.room_id = r.room_id
   AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Index & Justification
-- Justification: A partial index on room_id filtered by status = 'ACTIVE' stays compact by excluding
-- historical ENDED rows while accelerating occupancy counts and free-bed checks per room.
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

-- (g) Scheduled Job: pr_refresh_occupancy
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

-- Schedule daily at 23:55
SELECT cron.schedule(
    'q5_refresh_hostel_occupancy',
    '55 23 * * *',
    $$CALL q5_hostel.pr_refresh_occupancy();$$
);
