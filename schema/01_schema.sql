-- Preventive maintenance and work-order database: schema, indexes and triggers (MySQL 8).
-- 14 relations. Rules that keys cannot express are CHECK constraints or triggers.
-- Designed by SE 3309 Group 20 (Western University, Fall 2026).

DROP DATABASE IF EXISTS pm_tracker;
CREATE DATABASE pm_tracker;
USE pm_tracker;

-- ---------------------------------------------------------------
-- Reference relations
-- ---------------------------------------------------------------

CREATE TABLE Building (
    building_code  VARCHAR(8)   NOT NULL,
    building_name  VARCHAR(80)  NOT NULL,
    client_name    VARCHAR(80)  NOT NULL,
    street         VARCHAR(100) NOT NULL,
    city           VARCHAR(50)  NOT NULL,
    province       CHAR(2)      NOT NULL,
    postal_code    CHAR(7)      NOT NULL,
    CONSTRAINT pk_building PRIMARY KEY (building_code),
    CONSTRAINT ck_building_province CHECK (province IN ('ON','QC','MB','SK','AB','BC','NS','NB','NL','PE')),
    -- Canadian postal code shape "A1A 1A1" (the city/province check from A2 3.1.3)
    CONSTRAINT ck_building_postal CHECK (postal_code LIKE '___ ___')
);

CREATE TABLE Asset_Type (
    type_name           VARCHAR(40) NOT NULL,
    category            VARCHAR(20) NOT NULL,
    expected_life_years SMALLINT    NOT NULL,
    CONSTRAINT pk_asset_type PRIMARY KEY (type_name),
    CONSTRAINT ck_asset_type_category CHECK (category IN ('HVAC','Electrical','Plumbing','Elevator','Fire Safety')),
    CONSTRAINT ck_asset_type_life CHECK (expected_life_years BETWEEN 1 AND 100)
);

CREATE TABLE Certification (
    cert_code    VARCHAR(10) NOT NULL,
    cert_name    VARCHAR(80) NOT NULL,
    issuing_body VARCHAR(80) NOT NULL,
    CONSTRAINT pk_certification PRIMARY KEY (cert_code),
    CONSTRAINT uq_certification_name UNIQUE (cert_name)          -- alternate key
);

CREATE TABLE Part (
    part_number   VARCHAR(12)   NOT NULL,
    part_name     VARCHAR(80)   NOT NULL,
    unit_cost     DECIMAL(10,2) NOT NULL,
    qty_on_hand   INT           NOT NULL DEFAULT 0,
    reorder_level INT           NOT NULL DEFAULT 0,
    CONSTRAINT pk_part PRIMARY KEY (part_number),
    CONSTRAINT ck_part_cost CHECK (unit_cost >= 0),
    -- General constraint 5: stock can never go below zero
    CONSTRAINT ck_part_stock CHECK (qty_on_hand >= 0),
    CONSTRAINT ck_part_reorder CHECK (reorder_level >= 0)
);

CREATE TABLE Technician (
    employee_number VARCHAR(8)   NOT NULL,
    first_name      VARCHAR(40)  NOT NULL,
    last_name       VARCHAR(40)  NOT NULL,
    trade           VARCHAR(20)  NOT NULL,
    hourly_rate     DECIMAL(6,2) NOT NULL,
    CONSTRAINT pk_technician PRIMARY KEY (employee_number),
    CONSTRAINT ck_technician_trade CHECK (trade IN ('Electrician','Refrigeration','Millwright','General')),
    CONSTRAINT ck_technician_rate CHECK (hourly_rate > 0)
);

CREATE TABLE Technician_Phone (
    employee_number VARCHAR(8)  NOT NULL,
    phone_number    VARCHAR(15) NOT NULL,
    CONSTRAINT pk_technician_phone PRIMARY KEY (employee_number, phone_number),
    CONSTRAINT fk_phone_technician FOREIGN KEY (employee_number)
        REFERENCES Technician (employee_number) ON DELETE CASCADE ON UPDATE CASCADE
);

-- ---------------------------------------------------------------
-- Assets and preventive maintenance plans
-- ---------------------------------------------------------------

CREATE TABLE Asset (
    asset_tag         VARCHAR(12)   NOT NULL,
    asset_name        VARCHAR(80)   NOT NULL,
    manufacturer      VARCHAR(40)   NOT NULL,
    model_number      VARCHAR(30)   NOT NULL,
    install_date      DATE          NOT NULL,
    retired_date      DATE,
    replacement_value DECIMAL(12,2) NOT NULL,
    building_code     VARCHAR(8)    NOT NULL,
    type_name         VARCHAR(40)   NOT NULL,
    parent_asset_tag  VARCHAR(12),                 -- NULL for top-level assets
    CONSTRAINT pk_asset PRIMARY KEY (asset_tag),
    CONSTRAINT fk_asset_building FOREIGN KEY (building_code) REFERENCES Building (building_code),
    CONSTRAINT fk_asset_type FOREIGN KEY (type_name) REFERENCES Asset_Type (type_name),
    CONSTRAINT fk_asset_parent FOREIGN KEY (parent_asset_tag) REFERENCES Asset (asset_tag),
    CONSTRAINT ck_asset_value CHECK (replacement_value > 0),
    CONSTRAINT ck_asset_dates CHECK (retired_date IS NULL OR retired_date >= install_date),
    -- General constraint 3 (part): an asset cannot contain itself
    CONSTRAINT ck_asset_not_own_parent CHECK (parent_asset_tag IS NULL OR parent_asset_tag <> asset_tag)
);

CREATE TABLE PM_Schedule (
    pm_plan_number      VARCHAR(10)  NOT NULL,
    task_description    VARCHAR(200) NOT NULL,
    interval_days       SMALLINT     NOT NULL,
    estimated_hours     DECIMAL(5,2) NOT NULL,
    complexity_level    SMALLINT     NOT NULL,
    priority            VARCHAR(10)  NOT NULL,
    start_date          DATE         NOT NULL,
    is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
    last_completed_date DATE,
    asset_tag           VARCHAR(12)  NOT NULL,
    CONSTRAINT pk_pm_schedule PRIMARY KEY (pm_plan_number),
    CONSTRAINT fk_pm_asset FOREIGN KEY (asset_tag) REFERENCES Asset (asset_tag),
    CONSTRAINT ck_pm_interval CHECK (interval_days > 0),
    CONSTRAINT ck_pm_hours CHECK (estimated_hours > 0),
    CONSTRAINT ck_pm_complexity CHECK (complexity_level BETWEEN 1 AND 5),
    CONSTRAINT ck_pm_priority CHECK (priority IN ('Emergency','High','Normal','Low')),
    CONSTRAINT ck_pm_last_done CHECK (last_completed_date IS NULL OR last_completed_date >= start_date)
);

-- ---------------------------------------------------------------
-- Work orders (superclass with failure_cause merged in) and subclass
-- ---------------------------------------------------------------

CREATE TABLE Work_Order (
    wo_number            INT          NOT NULL,
    wo_type              VARCHAR(10)  NOT NULL,
    status               VARCHAR(12)  NOT NULL,
    priority             VARCHAR(10)  NOT NULL,
    complexity_level     SMALLINT     NOT NULL,
    estimated_hours      DECIMAL(5,2) NOT NULL,
    opened_date          DATE         NOT NULL,
    due_date             DATE         NOT NULL,
    closed_date          DATE,
    problem_description  VARCHAR(300) NOT NULL,
    resolution_notes     VARCHAR(300),
    failure_cause        VARCHAR(40),              -- Reactive only (merged from Reactive_Work_Order)
    asset_tag            VARCHAR(12)  NOT NULL,
    lead_employee_number VARCHAR(8),
    assigned_date        DATE,
    CONSTRAINT pk_work_order PRIMARY KEY (wo_number),
    CONSTRAINT fk_wo_asset FOREIGN KEY (asset_tag) REFERENCES Asset (asset_tag),
    CONSTRAINT fk_wo_lead FOREIGN KEY (lead_employee_number) REFERENCES Technician (employee_number),
    -- General constraint 1: discriminator and failure_cause rules
    CONSTRAINT ck_wo_type CHECK (wo_type IN ('Preventive','Reactive')),
    CONSTRAINT ck_wo_failure_only_reactive CHECK (wo_type = 'Reactive' OR failure_cause IS NULL),
    CONSTRAINT ck_wo_closed_reactive_cause CHECK (NOT (wo_type = 'Reactive' AND status = 'Closed' AND failure_cause IS NULL)),
    CONSTRAINT ck_wo_status CHECK (status IN ('Open','In Progress','Closed','Cancelled')),
    CONSTRAINT ck_wo_priority CHECK (priority IN ('Emergency','High','Normal','Low')),
    CONSTRAINT ck_wo_complexity CHECK (complexity_level BETWEEN 1 AND 5),
    CONSTRAINT ck_wo_hours CHECK (estimated_hours > 0),
    CONSTRAINT ck_wo_due CHECK (due_date >= opened_date),
    -- closed_date is set exactly when the work order is finished (Closed or Cancelled)
    CONSTRAINT ck_wo_closed_date CHECK (
        (status IN ('Closed','Cancelled') AND closed_date IS NOT NULL AND closed_date >= opened_date)
        OR (status IN ('Open','In Progress') AND closed_date IS NULL)),
    -- General constraint 6: lead technician and assigned date are both NULL or both set
    CONSTRAINT ck_wo_assignment CHECK (
        (lead_employee_number IS NULL AND assigned_date IS NULL)
        OR (lead_employee_number IS NOT NULL AND assigned_date IS NOT NULL AND assigned_date >= opened_date))
);

CREATE TABLE Preventive_Work_Order (
    wo_number      INT         NOT NULL,
    pm_plan_number VARCHAR(10) NOT NULL,
    CONSTRAINT pk_preventive_wo PRIMARY KEY (wo_number),
    CONSTRAINT fk_pwo_work_order FOREIGN KEY (wo_number) REFERENCES Work_Order (wo_number) ON DELETE CASCADE,
    CONSTRAINT fk_pwo_schedule FOREIGN KEY (pm_plan_number) REFERENCES PM_Schedule (pm_plan_number)
);

-- ---------------------------------------------------------------
-- Weak entities of Work_Order
-- ---------------------------------------------------------------

CREATE TABLE Time_Entry (
    wo_number       INT          NOT NULL,
    entry_no        SMALLINT     NOT NULL,
    employee_number VARCHAR(8)   NOT NULL,
    work_date       DATE         NOT NULL,
    hours           DECIMAL(4,2) NOT NULL,
    rate_charged    DECIMAL(6,2) NOT NULL,       -- historical rate, not derivable (A2 flaw 5)
    CONSTRAINT pk_time_entry PRIMARY KEY (wo_number, entry_no),
    CONSTRAINT fk_time_work_order FOREIGN KEY (wo_number) REFERENCES Work_Order (wo_number) ON DELETE CASCADE,
    CONSTRAINT fk_time_technician FOREIGN KEY (employee_number) REFERENCES Technician (employee_number),
    CONSTRAINT ck_time_hours CHECK (hours > 0 AND hours <= 16),
    CONSTRAINT ck_time_rate CHECK (rate_charged > 0)
);

CREATE TABLE Part_Transaction (
    wo_number         INT           NOT NULL,
    txn_no            SMALLINT      NOT NULL,
    part_number       VARCHAR(12)   NOT NULL,
    txn_type          VARCHAR(6)    NOT NULL,
    quantity          INT           NOT NULL,
    unit_cost_at_time DECIMAL(10,2) NOT NULL,    -- historical price (A2 flaw 5)
    txn_date          DATE          NOT NULL,
    CONSTRAINT pk_part_transaction PRIMARY KEY (wo_number, txn_no),
    CONSTRAINT fk_ptxn_work_order FOREIGN KEY (wo_number) REFERENCES Work_Order (wo_number) ON DELETE CASCADE,
    CONSTRAINT fk_ptxn_part FOREIGN KEY (part_number) REFERENCES Part (part_number),
    CONSTRAINT ck_ptxn_type CHECK (txn_type IN ('Issue','Return')),
    CONSTRAINT ck_ptxn_qty CHECK (quantity > 0),
    CONSTRAINT ck_ptxn_cost CHECK (unit_cost_at_time >= 0)
);

-- ---------------------------------------------------------------
-- Many-to-many relationships
-- ---------------------------------------------------------------

CREATE TABLE Holds (
    employee_number    VARCHAR(8)  NOT NULL,
    cert_code          VARCHAR(10) NOT NULL,
    certificate_number VARCHAR(20) NOT NULL,
    issue_date         DATE        NOT NULL,
    expiry_date        DATE        NOT NULL,
    CONSTRAINT pk_holds PRIMARY KEY (employee_number, cert_code),
    CONSTRAINT uq_holds_certificate UNIQUE (cert_code, certificate_number),   -- alternate key
    CONSTRAINT fk_holds_technician FOREIGN KEY (employee_number)
        REFERENCES Technician (employee_number) ON DELETE CASCADE,
    CONSTRAINT fk_holds_certification FOREIGN KEY (cert_code) REFERENCES Certification (cert_code),
    CONSTRAINT ck_holds_dates CHECK (expiry_date > issue_date)
);

CREATE TABLE Requires (
    type_name VARCHAR(40) NOT NULL,
    cert_code VARCHAR(10) NOT NULL,
    CONSTRAINT pk_requires PRIMARY KEY (type_name, cert_code),
    CONSTRAINT fk_requires_type FOREIGN KEY (type_name) REFERENCES Asset_Type (type_name),
    CONSTRAINT fk_requires_cert FOREIGN KEY (cert_code) REFERENCES Certification (cert_code)
);

-- ---------------------------------------------------------------
-- Indexes for the application's main searches (A1 functions F2, F5, F7).
-- MySQL already indexes every primary key and foreign key column.
-- ---------------------------------------------------------------

CREATE INDEX idx_wo_status_due   ON Work_Order (status, due_date);       -- F7 backlog, overdue work
CREATE INDEX idx_wo_type_opened  ON Work_Order (wo_type, opened_date);   -- F5 breakdowns in a time span
CREATE INDEX idx_time_work_date  ON Time_Entry (work_date);              -- F6 hours in a period
CREATE INDEX idx_asset_name      ON Asset (asset_name);                  -- F2 search by name
CREATE INDEX idx_tech_name       ON Technician (last_name, first_name);

-- ---------------------------------------------------------------
-- Triggers for the general constraints keys and CHECKs cannot express
-- ---------------------------------------------------------------

DELIMITER //

-- General constraint 3: a component is in the same building as its parent
CREATE TRIGGER trg_asset_component_building_ins BEFORE INSERT ON Asset
FOR EACH ROW
BEGIN
    IF NEW.parent_asset_tag IS NOT NULL AND NEW.building_code <>
       (SELECT building_code FROM Asset WHERE asset_tag = NEW.parent_asset_tag) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A component must be in the same building as its parent asset';
    END IF;
END//

CREATE TRIGGER trg_asset_component_building_upd BEFORE UPDATE ON Asset
FOR EACH ROW
BEGIN
    IF NEW.parent_asset_tag IS NOT NULL AND NEW.building_code <>
       (SELECT building_code FROM Asset WHERE asset_tag = NEW.parent_asset_tag) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A component must be in the same building as its parent asset';
    END IF;
END//

-- General constraints 1 and 2: a Preventive_Work_Order row only for a Preventive work order,
-- and its work order must be on the same asset as its PM schedule
CREATE TRIGGER trg_pwo_consistency BEFORE INSERT ON Preventive_Work_Order
FOR EACH ROW
BEGIN
    IF (SELECT wo_type FROM Work_Order WHERE wo_number = NEW.wo_number) <> 'Preventive' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only Preventive work orders can have a PM schedule';
    END IF;
    IF (SELECT asset_tag FROM Work_Order WHERE wo_number = NEW.wo_number) <>
       (SELECT asset_tag FROM PM_Schedule WHERE pm_plan_number = NEW.pm_plan_number) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Preventive work order asset must match its schedule asset';
    END IF;
END//

-- General constraint 4: only a technician holding every certification the asset's type
-- requires, unexpired on the work date, can log time on that asset
CREATE TRIGGER trg_time_entry_qualified BEFORE INSERT ON Time_Entry
FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT *
        FROM Work_Order w
        JOIN Asset a     ON a.asset_tag = w.asset_tag
        JOIN Requires r  ON r.type_name = a.type_name
        WHERE w.wo_number = NEW.wo_number
          AND NOT EXISTS (SELECT * FROM Holds h
                          WHERE h.employee_number = NEW.employee_number
                            AND h.cert_code = r.cert_code
                            AND h.issue_date <= NEW.work_date
                            AND h.expiry_date >= NEW.work_date)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Technician is not certified for this asset type on the work date';
    END IF;
END//

-- General constraint 5: issues reduce stock and returns add it back; an issue larger than
-- the stock on hand is rejected (the CHECK on Part.qty_on_hand is the second line of defence)
CREATE TRIGGER trg_part_txn_stock BEFORE INSERT ON Part_Transaction
FOR EACH ROW
BEGIN
    IF NEW.txn_type = 'Issue' THEN
        IF (SELECT qty_on_hand FROM Part WHERE part_number = NEW.part_number) < NEW.quantity THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not enough stock on hand for this issue';
        END IF;
        UPDATE Part SET qty_on_hand = qty_on_hand - NEW.quantity WHERE part_number = NEW.part_number;
    ELSE
        UPDATE Part SET qty_on_hand = qty_on_hand + NEW.quantity WHERE part_number = NEW.part_number;
    END IF;
END//

DELIMITER ;
