-- Three set-based data modifications (INSERT ... SELECT, UPDATE with subquery, DELETE with NOT EXISTS).
-- Each prints the affected rows before and after.
USE pm_tracker;

-- M1 (F1/F5) - INSERT of a query result:
-- open a High priority follow-up work order for every asset that broke down 3 or more times
-- since June 15, 2026 and has no open work order yet. New work order numbers continue from
-- the current maximum using ROW_NUMBER().
SELECT COUNT(*) AS work_orders_before FROM Work_Order;

INSERT INTO Work_Order (wo_number, wo_type, status, priority, complexity_level, estimated_hours,
                        opened_date, due_date, problem_description, asset_tag)
SELECT m.max_no + ROW_NUMBER() OVER (ORDER BY f.asset_tag),
       'Reactive', 'Open', 'High', 3, 4.0,
       DATE '2026-11-12', DATE '2026-11-14',
       'Follow-up: 3+ failures since June 15, find the root cause', f.asset_tag
FROM (SELECT w.asset_tag
      FROM Work_Order w
      WHERE w.wo_type = 'Reactive'
        AND w.opened_date >= DATE '2026-06-15'
      GROUP BY w.asset_tag
      HAVING COUNT(*) >= 3) f,
     (SELECT MAX(wo_number) AS max_no FROM Work_Order) m
WHERE NOT EXISTS (SELECT *
                  FROM Work_Order o
                  WHERE o.asset_tag = f.asset_tag
                    AND o.status IN ('Open', 'In Progress'));

SELECT wo_number, wo_type, status, priority, opened_date, due_date, asset_tag
FROM Work_Order
WHERE problem_description LIKE 'Follow-up:%';

-- M2 (F4) - UPDATE of several rows chosen by a subquery:
-- parts that had more than 20 units issued in the last 6 months get their reorder level raised
-- by 50% (rounded up), which makes the stock room reorder them sooner.
SELECT part_number, reorder_level FROM Part
WHERE part_number IN (SELECT pt.part_number FROM Part_Transaction pt
                      WHERE pt.txn_type = 'Issue' AND pt.txn_date >= DATE '2026-05-12'
                      GROUP BY pt.part_number HAVING SUM(pt.quantity) > 20);

UPDATE Part
SET reorder_level = CEILING(reorder_level * 1.5)
WHERE part_number IN (SELECT pt.part_number
                      FROM Part_Transaction pt
                      WHERE pt.txn_type = 'Issue'
                        AND pt.txn_date >= DATE '2026-05-12'
                      GROUP BY pt.part_number
                      HAVING SUM(pt.quantity) > 20);

SELECT part_number, reorder_level FROM Part
WHERE part_number IN (SELECT pt.part_number FROM Part_Transaction pt
                      WHERE pt.txn_type = 'Issue' AND pt.txn_date >= DATE '2026-05-12'
                      GROUP BY pt.part_number HAVING SUM(pt.quantity) > 20);

-- M3 (housekeeping) - DELETE of some but not all tuples:
-- remove cancelled work orders opened before 2025 that never had labour or parts booked.
-- ON DELETE CASCADE also removes their Preventive_Work_Order rows.
SELECT status, COUNT(*) AS n FROM Work_Order GROUP BY status;

DELETE FROM Work_Order
WHERE status = 'Cancelled'
  AND opened_date < DATE '2025-01-01'
  AND NOT EXISTS (SELECT * FROM Time_Entry te WHERE te.wo_number = Work_Order.wo_number)
  AND NOT EXISTS (SELECT * FROM Part_Transaction pt WHERE pt.wo_number = Work_Order.wo_number);

SELECT status, COUNT(*) AS n FROM Work_Order GROUP BY status;
