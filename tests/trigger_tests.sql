-- Each case breaks one business rule and must be rejected with the error named after "expect:".
-- tests/run_trigger_tests.py runs every case inside a transaction that is rolled back.
-- IDs refer to the seeded data (random.seed(3309)), which keeps them the same on every load.

-- case: component placed in a different building than its parent | expect: same building as its parent
-- A-00002 is a Chiller in B001; its new compressor is put in B002.
INSERT INTO Asset VALUES ('T-00001', 'Test compressor', 'Copeland', 'ZZ-1', DATE '2024-01-01', NULL,
                          5000, 'B002', 'Compressor', 'A-00002');

-- case: PM schedule linked to a reactive work order | expect: Only Preventive work orders
INSERT INTO Preventive_Work_Order VALUES (100011, 'PM-00001');

-- case: technician without the 313A licence logs time on a chiller | expect: not certified
-- Work order 100015 is on a Chiller; E1001 is an electrician with no 313A.
INSERT INTO Time_Entry VALUES (100015, 99, 'E1001', DATE '2023-11-02', 2.0, 50.00);

-- case: issuing more parts than are on hand | expect: Not enough stock
INSERT INTO Part_Transaction VALUES (100001, 99, 'P-00001', 'Issue', 100000, 10.00, DATE '2026-11-12');

-- case: failure cause on a preventive work order | expect: ck_wo_failure_only_reactive
UPDATE Work_Order SET failure_cause = 'Belt worn' WHERE wo_number = 100001;

-- case: preventive work order closed without a closed date | expect: ck_wo_closed_date
UPDATE Work_Order SET status = 'Closed' WHERE wo_number = 100059;

-- case: lead technician kept but assigned date removed | expect: ck_wo_assignment
UPDATE Work_Order SET assigned_date = NULL WHERE wo_number = 100001;

-- case: part stock set below zero directly | expect: ck_part_stock
UPDATE Part SET qty_on_hand = -1 WHERE part_number = 'P-00001';

-- case: asset made its own parent | expect: ck_asset_not_own_parent
UPDATE Asset SET parent_asset_tag = asset_tag WHERE asset_tag = 'A-00002';
