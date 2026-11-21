-- Integrity checks: every query returns the number of rows that break a business rule.
-- All counts must be 0. scripts/test.sh fails if any is not.
USE pm_tracker;

SELECT 'component in a different building than its parent' AS rule_checked, COUNT(*) AS violations
FROM Asset c JOIN Asset p ON p.asset_tag = c.parent_asset_tag
WHERE c.building_code <> p.building_code
UNION ALL
SELECT 'preventive work order on a different asset than its schedule', COUNT(*)
FROM Preventive_Work_Order pw
JOIN Work_Order w   ON w.wo_number = pw.wo_number
JOIN PM_Schedule s  ON s.pm_plan_number = pw.pm_plan_number
WHERE w.asset_tag <> s.asset_tag OR w.wo_type <> 'Preventive'
UNION ALL
SELECT 'time logged by a technician missing a required, unexpired certification', COUNT(*)
FROM Time_Entry te
JOIN Work_Order w ON w.wo_number = te.wo_number
JOIN Asset a      ON a.asset_tag = w.asset_tag
JOIN Requires r   ON r.type_name = a.type_name
WHERE NOT EXISTS (SELECT * FROM Holds h
                  WHERE h.employee_number = te.employee_number AND h.cert_code = r.cert_code
                    AND te.work_date BETWEEN h.issue_date AND h.expiry_date)
UNION ALL
SELECT 'part with negative stock', COUNT(*) FROM Part WHERE qty_on_hand < 0
UNION ALL
SELECT 'closed reactive work order without a failure cause', COUNT(*)
FROM Work_Order WHERE wo_type = 'Reactive' AND status = 'Closed' AND failure_cause IS NULL
UNION ALL
SELECT 'work order with time logged before it was opened', COUNT(*)
FROM Time_Entry te JOIN Work_Order w ON w.wo_number = te.wo_number
WHERE te.work_date < w.opened_date
UNION ALL
SELECT 'Requires rows differ from the 16 the generator assumes', ABS(COUNT(*) - 16) FROM Requires;
