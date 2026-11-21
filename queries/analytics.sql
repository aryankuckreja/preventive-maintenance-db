-- Analytics over the preventive maintenance database (MySQL 8: CTEs and window functions).
-- Each query answers one question a maintenance manager would ask. "Today" is fixed so the
-- results are reproducible against the seeded data.
USE pm_tracker;
SET @as_of = DATE '2026-11-12';

-- Q1. Overdue backlog: which open work orders are past due, by building and priority?
SELECT b.building_code,
       b.building_name,
       w.priority,
       COUNT(*)                                AS overdue_orders,
       MAX(DATEDIFF(@as_of, w.due_date))       AS oldest_days_overdue,
       SUM(w.lead_employee_number IS NULL)     AS unassigned
FROM Work_Order w
JOIN Asset a    ON a.asset_tag = w.asset_tag
JOIN Building b ON b.building_code = a.building_code
WHERE w.status IN ('Open', 'In Progress')
  AND w.due_date < @as_of
GROUP BY b.building_code, b.building_name, w.priority
ORDER BY FIELD(w.priority, 'Emergency', 'High', 'Normal', 'Low'), overdue_orders DESC
LIMIT 15;

-- Q2. PM compliance: what share of preventive work orders closed on time, per category and quarter?
WITH pm AS (
    SELECT t.category,
           CONCAT(YEAR(w.due_date), '-Q', QUARTER(w.due_date)) AS quarter,
           w.closed_date <= w.due_date                         AS on_time
    FROM Work_Order w
    JOIN Asset a      ON a.asset_tag = w.asset_tag
    JOIN Asset_Type t ON t.type_name = a.type_name
    WHERE w.wo_type = 'Preventive'
      AND w.status = 'Closed'
      AND w.due_date >= DATE '2025-10-01'
      AND w.due_date <  DATE '2026-10-01'
)
SELECT category,
       quarter,
       COUNT(*)                           AS closed_pms,
       ROUND(100 * AVG(on_time), 1)       AS pct_on_time
FROM pm
GROUP BY category, quarter
ORDER BY category, quarter;

-- Q3. Reliability: mean days between breakdowns for each asset type (LAG over each asset's failures).
WITH failures AS (
    SELECT a.type_name,
           w.asset_tag,
           w.opened_date,
           LAG(w.opened_date) OVER (PARTITION BY w.asset_tag ORDER BY w.opened_date, w.wo_number) AS prev_failure
    FROM Work_Order w
    JOIN Asset a ON a.asset_tag = w.asset_tag
    WHERE w.wo_type = 'Reactive'
)
SELECT type_name,
       COUNT(DISTINCT asset_tag)                          AS assets_with_failures,
       COUNT(prev_failure)                                AS intervals,
       ROUND(AVG(DATEDIFF(opened_date, prev_failure)), 0) AS mean_days_between_failures
FROM failures
WHERE prev_failure IS NOT NULL
GROUP BY type_name
ORDER BY mean_days_between_failures
LIMIT 10;

-- Q4. Repair or replace: assets whose last-12-month repair cost (labour + parts) is the largest
--     share of their replacement value.
WITH labour AS (
    SELECT wo_number, SUM(hours * rate_charged) AS cost FROM Time_Entry GROUP BY wo_number
),
parts AS (
    SELECT wo_number,
           SUM(CASE txn_type WHEN 'Issue' THEN quantity ELSE -quantity END * unit_cost_at_time) AS cost
    FROM Part_Transaction GROUP BY wo_number
),
repairs AS (
    SELECT w.asset_tag,
           COUNT(*)                                          AS breakdowns,
           SUM(COALESCE(l.cost, 0) + COALESCE(p.cost, 0))    AS repair_cost
    FROM Work_Order w
    LEFT JOIN labour l ON l.wo_number = w.wo_number
    LEFT JOIN parts p  ON p.wo_number = w.wo_number
    WHERE w.wo_type = 'Reactive'
      AND w.opened_date > @as_of - INTERVAL 12 MONTH
    GROUP BY w.asset_tag
)
SELECT a.asset_tag,
       a.asset_name,
       a.building_code,
       TIMESTAMPDIFF(YEAR, a.install_date, @as_of)            AS age_years,
       t.expected_life_years,
       r.breakdowns,
       ROUND(r.repair_cost, 2)                                AS repair_cost_12m,
       a.replacement_value,
       ROUND(100 * r.repair_cost / a.replacement_value, 1)    AS pct_of_replacement
FROM repairs r
JOIN Asset a      ON a.asset_tag = r.asset_tag
JOIN Asset_Type t ON t.type_name = a.type_name
WHERE a.retired_date IS NULL
ORDER BY pct_of_replacement DESC
LIMIT 10;

-- Q5. Workload: hours logged per technician over the last 6 months, ranked within their trade.
SELECT trade,
       employee_number,
       technician,
       hours_6m,
       DENSE_RANK() OVER (PARTITION BY trade ORDER BY hours_6m DESC)           AS rank_in_trade,
       ROUND(hours_6m / AVG(hours_6m) OVER (PARTITION BY trade), 2)            AS vs_trade_avg
FROM (
    SELECT t.trade,
           t.employee_number,
           CONCAT(t.first_name, ' ', t.last_name) AS technician,
           ROUND(COALESCE(SUM(te.hours), 0), 1)   AS hours_6m
    FROM Technician t
    LEFT JOIN Time_Entry te
           ON te.employee_number = t.employee_number
          AND te.work_date > @as_of - INTERVAL 6 MONTH
    GROUP BY t.trade, t.employee_number, t.first_name, t.last_name
) h
ORDER BY trade, rank_in_trade
LIMIT 20;

-- Q6. Stock room: parts at or below their reorder level, with 90-day usage and days of cover left.
WITH usage_90 AS (
    SELECT part_number,
           SUM(CASE txn_type WHEN 'Issue' THEN quantity ELSE -quantity END) AS net_issued
    FROM Part_Transaction
    WHERE txn_date > @as_of - INTERVAL 90 DAY
    GROUP BY part_number
)
SELECT p.part_number,
       p.part_name,
       p.qty_on_hand,
       p.reorder_level,
       COALESCE(u.net_issued, 0)                                          AS issued_90d,
       CASE WHEN COALESCE(u.net_issued, 0) > 0
            THEN ROUND(p.qty_on_hand / (u.net_issued / 90), 0) END        AS days_of_cover
FROM Part p
LEFT JOIN usage_90 u ON u.part_number = p.part_number
WHERE p.qty_on_hand <= p.reorder_level
ORDER BY days_of_cover IS NULL, days_of_cover, issued_90d DESC
LIMIT 15;

-- Q7. Coverage risk: for each certified asset type, how many technicians are qualified today and
--     how many will still be qualified in 90 days if no one renews?
WITH need AS (
    SELECT type_name, COUNT(*) AS certs_required FROM Requires GROUP BY type_name
),
qualified AS (
    SELECT r.type_name,
           h.employee_number,
           MIN(h.expiry_date) AS first_expiry,
           COUNT(*)           AS certs_held
    FROM Requires r
    JOIN Holds h ON h.cert_code = r.cert_code
                AND h.issue_date <= @as_of
                AND h.expiry_date >= @as_of
    GROUP BY r.type_name, h.employee_number
)
SELECT n.type_name,
       n.certs_required,
       COUNT(q.employee_number)                                            AS qualified_now,
       COALESCE(SUM(q.first_expiry >= @as_of + INTERVAL 90 DAY), 0)        AS qualified_in_90d,
       (SELECT COUNT(*) FROM Asset a
        WHERE a.type_name = n.type_name AND a.retired_date IS NULL)        AS active_assets
FROM need n
LEFT JOIN qualified q ON q.type_name = n.type_name AND q.certs_held = n.certs_required
GROUP BY n.type_name, n.certs_required
ORDER BY qualified_in_90d, qualified_now;

-- Q8. Spend trend: monthly maintenance cost per building with a rolling 12-month total.
WITH monthly AS (
    SELECT a.building_code,
           DATE_FORMAT(x.d, '%Y-%m-01') AS month,
           SUM(x.cost)                  AS cost
    FROM (
        SELECT te.wo_number, te.work_date AS d, te.hours * te.rate_charged AS cost FROM Time_Entry te
        UNION ALL
        SELECT pt.wo_number, pt.txn_date,
               CASE pt.txn_type WHEN 'Issue' THEN 1 ELSE -1 END * pt.quantity * pt.unit_cost_at_time
        FROM Part_Transaction pt
    ) x
    JOIN Work_Order w ON w.wo_number = x.wo_number
    JOIN Asset a      ON a.asset_tag = w.asset_tag
    GROUP BY a.building_code, DATE_FORMAT(x.d, '%Y-%m-01')
)
SELECT building_code, month, month_cost, rolling_12m
FROM (
    SELECT building_code,
           month,
           ROUND(cost, 0)                                                         AS month_cost,
           ROUND(SUM(cost) OVER (PARTITION BY building_code ORDER BY month
                                 ROWS BETWEEN 11 PRECEDING AND CURRENT ROW), 0)   AS rolling_12m
    FROM monthly
) r
WHERE building_code IN ('B001', 'B002')
  AND month >= '2025-11-01'
ORDER BY building_code, month;
