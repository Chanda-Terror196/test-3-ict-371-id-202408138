-- ============================================================================
-- ICT371 Advanced Database — Question 8: Transport Fleet Maintenance
-- Student: Chanda Mubanga | ID: 202408138
-- Note: Run CREATE EXTENSION IF NOT EXISTS pg_cron; once before part (g).
-- ============================================================================

-- (a) Database Tables and Seed Data
DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path TO q8_fleet, public;

CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) UNIQUE NOT NULL,
    current_odometer      NUMERIC(10,1) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(10,1) NOT NULL CHECK (
        last_service_odometer >= 0 AND last_service_odometer <= current_odometer
    )
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(10,1) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(10,1) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(10,1) NOT NULL,
    flagged_on       DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAA 2024', 10000.0,  6000.0), -- 4,000 km since service (will cross 5,000 after trips)
    ('BCB 8138', 25000.0, 24500.0), -- 500 km since service (well below threshold)
    ('BCD 5510', 42000.0, 36800.0); -- 5,200 km since service (already due)

-- (b) Function: fn_service_due
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(10,1);
    v_last NUMERIC(10,1);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_curr, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000.0;
END;
$$;

-- (c) Procedure: pr_record_trip
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC(10,1),
    p_end        NUMERIC(10,1)
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date cannot be NULL';
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)', p_end, p_start;
    END IF;

    -- Insert trip; trigger validates start odometer and updates vehicle odometer
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger: BEFORE INSERT on trips
CREATE OR REPLACE FUNCTION trg_fn_validate_and_advance_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(10,1);
BEGIN
    SELECT current_odometer INTO v_curr_odo
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must exceed start_odometer (%)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'Start odometer (%) does not match vehicle current odometer (%)',
            NEW.start_odometer, v_curr_odo;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_validate_and_advance_odometer();

-- Load six trips via procedure after trigger installation (Part a)
CALL pr_record_trip(1, CURRENT_DATE - 3, 10000.0, 10600.0);
CALL pr_record_trip(1, CURRENT_DATE - 1, 10600.0, 11200.0); -- Vehicle 1 now at 5,200 km since service
CALL pr_record_trip(2, CURRENT_DATE - 2, 25000.0, 25400.0);
CALL pr_record_trip(2, CURRENT_DATE,     25400.0, 25900.0);
CALL pr_record_trip(3, CURRENT_DATE - 4, 42000.0, 42350.0);
CALL pr_record_trip(3, CURRENT_DATE - 1, 42350.0, 42700.0);

-- (e) View: v_service_due
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE fn_service_due(vehicle_id) = TRUE;

-- (f) Index, Query, EXPLAIN & Justification
-- Justification: A composite index on (vehicle_id, trip_on) filters directly to a single
-- vehicle's log and traverses the trip_on date range in index order.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_service_alerts
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Remove alerts for vehicles no longer due
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND (v.current_odometer - v.last_service_odometer) >= 5000.0
    );

    -- Insert or update alerts for due vehicles
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000.0
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;
END;
$$;

-- Schedule every Monday at 06:00
SELECT cron.schedule(
    'q8_weekly_service_alerts',
    '0 6 * * 1',
    $$CALL q8_fleet.pr_refresh_service_alerts();$$
);
