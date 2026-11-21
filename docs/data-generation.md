# Data generation

`generator/gen_data.py` writes two SQL files. Everything is driven by `random.seed(3309)`, which means the same files come out on every run (CI checks this with SHA-256).

## Load order

| Step | File | Why it is here |
|---|---|---|
| 1 | `schema/01_schema.sql` | creates the 14 tables, constraints, indexes and triggers |
| 2 | `build/load_stage1.sql` | reference data: 25 buildings, 22 asset types, 9 certifications |
| 3 | `schema/02_requires.sql` | which certifications each asset type requires (16 rows). Needs asset types and certifications from step 2 |
| 4 | `build/load_stage2.sql` | technicians, certifications held, parts, assets, PM schedules, work orders, labour and parts movements. The time-entry trigger checks every labour row against `Requires`, which means step 3 must come first |

The generator keeps its own copy of the 16 requirement pairs. `tests/integrity.sql` fails if the loaded `Requires` table ever drifts from that set.

## Row counts

| Table | Rows | Table | Rows |
|---|---:|---|---:|
| Building | 25 | PM_Schedule | 344 |
| Asset_Type | 22 | Work_Order | 5,329 |
| Certification | 9 | Preventive_Work_Order | 3,190 |
| Requires | 16 | Time_Entry | 11,190 |
| Technician | 60 | Part_Transaction | 5,268 |
| Technician_Phone | 82 | Part | 300 |
| Holds | 127 | Asset | 360 |

## How each table is built

**Technicians and certifications.** 60 technicians in four trades (17 electricians, 17 refrigeration mechanics, 12 millwrights, 14 general). Each trade has a list of likely certifications with a probability, for example every electrician holds the 309A licence, 80% hold Working at Heights and 35% hold Fire Alarm Technician. Certifications last 3 or 5 years. About 80% of those that would expire before the end of 2026 are renewed; the rest lapse on purpose, which the coverage query (Q7) then picks up.

**Assets.** Each of the 25 buildings gets 10 to 13 top-level assets of random types. Chillers, rooftop units, air handlers, fans and pumps can get one or two components (compressors or motors) that inherit the parent's building and are installed no earlier than the parent. About 4% of top-level assets are retired during the window.

**PM schedules.** Top-level assets only. Intervals depend on the category: elevators every 30 or 365 days, HVAC every 90 to 365, electrical every 180 or 365. Each schedule produces a preventive work order 7 days before every due date while the asset is in service.

**Reactive work orders.** Each asset type has a breakdowns-per-year rate (passenger elevators 2.2, transformers 0.2), scaled by a random factor per asset and reduced for components. Priority sets the due date (emergency same day, high 2 days, normal 7, low 14).

**Status, assignment and closure.** Status depends on age: old orders are almost all closed, with a few cancelled and a few left open (stale backlog for Q1); recent orders are a mix. A lead is assigned only from technicians who are qualified on the due date. If no one is qualified, the order stays open. Closed reactive orders get a failure cause that fits the category.

**Labour.** The lead and up to two qualified crew members log one or two entries each, on dates between assignment and closure, and only on dates their certifications are valid. Rates are back-dated with 3% annual raises, which means older entries carry lower historical rates.

**Parts.** 45% of preventive and 75% of reactive orders use parts from the matching category, with occasional returns. Prices are back-dated with 4% annual inflation. After all movements exist, each part's starting stock is set high enough that the running balance never drops below zero, and about a quarter of parts are left at or below their reorder level at the end.

## Helpers

- `q(value)` turns Python values into SQL literals: `NULL`, `TRUE`/`FALSE`, `DATE 'yyyy-mm-dd'`, numbers, and strings with single quotes escaped.
- `inserts(table, columns, rows)` writes multi-row `INSERT` statements in batches of 400 rows, which keeps the 2.4 MB stage 2 file loading in about a second.
