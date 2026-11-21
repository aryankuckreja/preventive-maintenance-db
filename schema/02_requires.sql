-- Certification requirements: which certifications a technician must hold to work on an
-- asset type. Run after the stage 1 reference data. Shows three styles of INSERT.
USE pm_tracker;

-- (a) Single-row INSERT with VALUES and no column list (values in table order):
--     chillers need a 313A refrigeration licence.
INSERT INTO Requires VALUES ('Chiller', '313A');

-- (b) Multi-row INSERT with an explicit column list in a different order than the table:
--     ten requirements in one statement.
INSERT INTO Requires (cert_code, type_name) VALUES
    ('EDM',  'Passenger Elevator'),
    ('EDM',  'Freight Elevator'),
    ('G2',   'Boiler'),
    ('G2',   'Water Heater'),
    ('BPT',  'Backflow Preventer'),
    ('FAT',  'Fire Alarm Panel'),
    ('313A', 'Rooftop Unit'),
    ('313A', 'Compressor'),
    ('WAH',  'Rooftop Unit'),
    ('WAH',  'Cooling Tower');

-- (c) INSERT ... SELECT: every Electrical asset type except loose motors requires the 309A
--     electrician licence. The rows come from a query over Asset_Type and Certification, the
--     certification is found by name rather than hard-coded, and NOT EXISTS skips any pair
--     that is already present.
INSERT INTO Requires (type_name, cert_code)
SELECT t.type_name, c.cert_code
FROM Asset_Type t, Certification c
WHERE t.category = 'Electrical'
  AND t.type_name <> 'Motor'
  AND c.cert_name = 'Construction and Maintenance Electrician'
  AND NOT EXISTS (SELECT *
                  FROM Requires r
                  WHERE r.type_name = t.type_name
                    AND r.cert_code = c.cert_code);

