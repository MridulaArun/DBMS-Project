-- ============================================================
-- AI-Powered Wildlife Conservation Monitoring System (WildTrack)
-- Final Schema Proposal (PostgreSQL + PostGIS) — 14 tables
-- ============================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------- CORE TABLES ----------

CREATE TABLE Species (
    species_id          SERIAL PRIMARY KEY,
    species_name        VARCHAR(100) NOT NULL,
    scientific_name      VARCHAR(150) NOT NULL,
    conservation_status  VARCHAR(50) NOT NULL   -- IUCN category, e.g. 'Endangered'
);

CREATE TABLE Reserve (
    reserve_id    SERIAL PRIMARY KEY,
    reserve_name  VARCHAR(150) NOT NULL,
    state         VARCHAR(100),
    boundary      geometry(Polygon, 4326) NOT NULL
);

CREATE TABLE Animal (
    animal_id        SERIAL PRIMARY KEY,
    species_id       INT NOT NULL REFERENCES Species(species_id) ON DELETE RESTRICT,
    home_reserve_id  INT REFERENCES Reserve(reserve_id) ON DELETE SET NULL,
    tag_id           VARCHAR(50) NOT NULL UNIQUE,
    sex              CHAR(1) CHECK (sex IN ('M', 'F', 'U')),
    birth_year       INT,
    status           VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive', 'deceased', 'unknown'))
);

CREATE TABLE GPS_Tracking (
    tracking_id   BIGSERIAL PRIMARY KEY,
    animal_id     INT NOT NULL REFERENCES Animal(animal_id) ON DELETE CASCADE,
    timestamp     TIMESTAMPTZ NOT NULL,
    location      geometry(Point, 4326) NOT NULL,
    speed         NUMERIC(6,2)   -- km/h, nullable
);

CREATE TABLE Risk_Zone (
    zone_id       SERIAL PRIMARY KEY,
    reserve_id    INT NOT NULL REFERENCES Reserve(reserve_id) ON DELETE CASCADE,
    zone_name     VARCHAR(150) NOT NULL,
    risk_level    VARCHAR(10) NOT NULL
        CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
    boundary      geometry(Polygon, 4326) NOT NULL
    -- risk_type removed: a zone can have more than one risk type, see Zone_Risk_Type
);

CREATE TABLE Animal_Risk_Event (
    event_id      BIGSERIAL PRIMARY KEY,
    animal_id     INT NOT NULL REFERENCES Animal(animal_id) ON DELETE CASCADE,
    zone_id       INT NOT NULL REFERENCES Risk_Zone(zone_id) ON DELETE CASCADE,
    tracking_id   BIGINT NOT NULL REFERENCES GPS_Tracking(tracking_id) ON DELETE CASCADE,
    detected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    distance_m    NUMERIC(10,2) NOT NULL,   -- meters, computed via ST_Distance
    risk_level    VARCHAR(10) NOT NULL
        CHECK (risk_level IN ('low', 'medium', 'high', 'critical'))
);

CREATE TABLE Prediction (
    prediction_id     BIGSERIAL PRIMARY KEY,
    animal_id         INT NOT NULL REFERENCES Animal(animal_id) ON DELETE CASCADE,
    tracking_id       BIGINT REFERENCES GPS_Tracking(tracking_id) ON DELETE SET NULL,
    predicted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    predicted_risk    VARCHAR(10) NOT NULL
        CHECK (predicted_risk IN ('low', 'medium', 'high', 'critical')),
    risk_probability  NUMERIC(5,4) NOT NULL CHECK (risk_probability BETWEEN 0 AND 1)
);

CREATE TABLE Alert (
    alert_id      BIGSERIAL PRIMARY KEY,
    event_id      BIGINT REFERENCES Animal_Risk_Event(event_id) ON DELETE CASCADE,
    prediction_id BIGINT REFERENCES Prediction(prediction_id) ON DELETE CASCADE,
    alert_type    VARCHAR(50) NOT NULL,   -- 'detected' or 'predicted'
    severity      VARCHAR(10) NOT NULL
        CHECK (severity IN ('info', 'warning', 'critical')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    status        VARCHAR(20) NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'acknowledged', 'resolved', 'dismissed')),
    CONSTRAINT chk_alert_source CHECK (
        (event_id IS NOT NULL AND prediction_id IS NULL) OR
        (event_id IS NULL AND prediction_id IS NOT NULL)
    )
);

CREATE TABLE Ranger (
    ranger_id     SERIAL PRIMARY KEY,
    reserve_id    INT NOT NULL REFERENCES Reserve(reserve_id) ON DELETE CASCADE,
    name          VARCHAR(100) NOT NULL
    -- contact removed: a ranger can have multiple contact methods, see Ranger_Contact
);

CREATE TABLE Alert_Assignment (
    assignment_id    BIGSERIAL PRIMARY KEY,
    alert_id         BIGINT NOT NULL REFERENCES Alert(alert_id) ON DELETE CASCADE,
    ranger_id        INT NOT NULL REFERENCES Ranger(ranger_id) ON DELETE CASCADE,
    assigned_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    response_status  VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (response_status IN ('pending', 'in_progress', 'resolved', 'escalated')),
    UNIQUE (alert_id, ranger_id, assigned_at)
);

-- ---------- NEW TABLES (10 -> 14) ----------

-- 1. Normalizes the multivalued "risk type" attribute on Risk_Zone
--    (a single zone can be both, e.g., a road running through a settlement)
CREATE TABLE Zone_Risk_Type (
    zone_id     INT NOT NULL REFERENCES Risk_Zone(zone_id) ON DELETE CASCADE,
    risk_type   VARCHAR(30) NOT NULL
        CHECK (risk_type IN ('human_settlement', 'road', 'poaching_zone', 'agricultural_land', 'other')),
    PRIMARY KEY (zone_id, risk_type)
);

-- 2. Normalizes the multivalued "contact" attribute on Ranger
--    (phone, radio channel, email, etc.)
CREATE TABLE Ranger_Contact (
    contact_id    SERIAL PRIMARY KEY,
    ranger_id     INT NOT NULL REFERENCES Ranger(ranger_id) ON DELETE CASCADE,
    contact_type  VARCHAR(20) NOT NULL
        CHECK (contact_type IN ('phone', 'email', 'radio')),
    contact_value VARCHAR(100) NOT NULL,
    UNIQUE (ranger_id, contact_type, contact_value)
);

-- 3. Tracks the physical GPS collar / RFID tag hardware, separate from the
--    animal record itself — devices get serviced, swapped, and retired.
CREATE TABLE Equipment (
    equipment_id     SERIAL PRIMARY KEY,
    animal_id        INT REFERENCES Animal(animal_id) ON DELETE SET NULL,
    equipment_type   VARCHAR(30) NOT NULL
        CHECK (equipment_type IN ('gps_collar', 'rfid_tag', 'camera_trap')),
    model            VARCHAR(100),
    install_date     DATE NOT NULL,
    removal_date     DATE,
    battery_level    NUMERIC(5,2) CHECK (battery_level BETWEEN 0 AND 100),
    status           VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive', 'lost', 'damaged')),
    CHECK (removal_date IS NULL OR removal_date >= install_date)
);

-- 4. Closes the operational loop: what the ranger actually found/did
--    after being dispatched to an alert.
CREATE TABLE Field_Report (
    report_id      BIGSERIAL PRIMARY KEY,
    assignment_id  BIGINT NOT NULL REFERENCES Alert_Assignment(assignment_id) ON DELETE CASCADE,
    submitted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    summary        TEXT NOT NULL,
    outcome        VARCHAR(30) NOT NULL
        CHECK (outcome IN ('resolved', 'false_alarm', 'escalated', 'animal_relocated', 'other'))
);

-- ---------- INDEXES ----------

-- Spatial indexes (critical for PostGIS performance)
CREATE INDEX idx_reserve_boundary   ON Reserve USING GIST (boundary);
CREATE INDEX idx_riskzone_boundary  ON Risk_Zone USING GIST (boundary);
CREATE INDEX idx_gps_location       ON GPS_Tracking USING GIST (location);

-- Query-pattern indexes
CREATE INDEX idx_gps_animal_time    ON GPS_Tracking (animal_id, timestamp);
CREATE INDEX idx_event_animal       ON Animal_Risk_Event (animal_id, detected_at);
CREATE INDEX idx_alert_status       ON Alert (status);
CREATE INDEX idx_assignment_ranger  ON Alert_Assignment (ranger_id, response_status);
CREATE INDEX idx_zonerisk_zone      ON Zone_Risk_Type (zone_id);
CREATE INDEX idx_rangercontact_r    ON Ranger_Contact (ranger_id);
CREATE INDEX idx_equipment_animal   ON Equipment (animal_id);
CREATE INDEX idx_fieldreport_assign ON Field_Report (assignment_id);

-- Optional: partition GPS_Tracking by month if loading a large Movebank dataset
-- (recommended once row count exceeds a few million)
