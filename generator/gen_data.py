#!/usr/bin/env python3
"""
Synthetic data generator for the preventive maintenance database (about 26,000 rows, 3 years).

Writes two SQL files that are loaded around schema/02_requires.sql:
    build/load_stage1.sql  reference data (Building, Asset_Type, Certification)
    build/load_stage2.sql  everything else, November 2023 to November 2026

    python3 generator/gen_data.py          # or: python3 generator/gen_data.py --out some/dir
    scripts/load.sh                        # schema, stage 1, requires, stage 2

How the data stays valid and joinable:
  * Keys are generated sequentially (A-00001, WO 100001, ...) and never repeat.
  * Foreign keys are always picked from rows generated earlier (buildings -> assets -> schedules ->
    work orders -> time entries / part transactions), which means every join returns rows.
  * The generator applies the same business rules the triggers in schema/01_schema.sql enforce:
    components share their parent's building, preventive work orders match their schedule's asset,
    only technicians certified (and unexpired) for the asset type log time, and part issues never
    take stock below zero. If the generator broke a rule, the load would fail on a trigger.
  * random.seed(3309) makes every run produce the same files byte for byte.
Values (names, model numbers, postal codes) are plausible but made up.
"""

import datetime as dt
import argparse
import random
from pathlib import Path

random.seed(3309)
_ap = argparse.ArgumentParser(description="Generate the load files.")
_ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "build"))
OUT = Path(_ap.parse_args().out)
OUT.mkdir(parents=True, exist_ok=True)
D = dt.date
START, TODAY = D(2023, 11, 1), D(2026, 11, 12)          # data window; "today" for statuses


def q(v):
    """SQL literal for a Python value (ISO SQL: strings in single quotes, DATE 'yyyy-mm-dd')."""
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, dt.date):
        return f"DATE '{v.isoformat()}'"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def inserts(table, cols, rows, batch=400):
    out = []
    for i in range(0, len(rows), batch):
        vals = ",\n".join("(" + ", ".join(q(v) for v in r) + ")" for r in rows[i:i + batch])
        out.append(f"INSERT INTO {table} ({', '.join(cols)}) VALUES\n{vals};")
    return "\n".join(out) + "\n"


def rand_date(a, b):
    return a + dt.timedelta(days=random.randint(0, (b - a).days))


# ------------------------------------------------------------------ reference data
CERTS = [
    ("309A", "Construction and Maintenance Electrician", "Skilled Trades Ontario"),
    ("313A", "Refrigeration and Air Conditioning Systems Mechanic", "Skilled Trades Ontario"),
    ("306A", "Plumber", "Skilled Trades Ontario"),
    ("433A", "Industrial Mechanic Millwright", "Skilled Trades Ontario"),
    ("G2", "Gas Technician 2", "Technical Standards and Safety Authority"),
    ("EDM", "Elevating Devices Mechanic", "Technical Standards and Safety Authority"),
    ("WAH", "Working at Heights", "Ontario Ministry of Labour approved provider"),
    ("FAT", "Fire Alarm Technician", "Canadian Fire Alarm Association"),
    ("BPT", "Backflow Prevention Device Tester", "Ontario Water Works Association"),
]

# type_name: (category, expected life, top-level?, manufacturers, replacement value range, breakdowns/yr)
TYPES = {
    "Rooftop Unit":            ("HVAC", 20, True,  ["Carrier", "Trane", "Lennox", "York"], (18000, 65000), 1.6),
    "Chiller":                 ("HVAC", 25, True,  ["Trane", "Carrier", "Daikin", "York"], (120000, 420000), 1.2),
    "Boiler":                  ("HVAC", 30, True,  ["Viessmann", "Lochinvar", "Cleaver-Brooks"], (40000, 160000), 0.9),
    "Air Handling Unit":       ("HVAC", 25, True,  ["Daikin", "Trane", "Engineered Air"], (30000, 110000), 1.0),
    "Cooling Tower":           ("HVAC", 20, True,  ["BAC", "Evapco", "Marley"], (60000, 220000), 0.8),
    "Exhaust Fan":             ("HVAC", 15, True,  ["Greenheck", "Loren Cook"], (2500, 12000), 0.9),
    "Compressor":              ("HVAC", 15, False, ["Copeland", "Bitzer", "Danfoss"], (6000, 30000), 0.6),
    "Switchgear":              ("Electrical", 30, True, ["Schneider Electric", "Eaton", "Siemens"], (50000, 250000), 0.3),
    "Transformer":             ("Electrical", 30, True, ["Hammond", "Eaton", "ABB"], (15000, 90000), 0.2),
    "Emergency Generator":     ("Electrical", 25, True, ["Cummins", "Generac", "Caterpillar"], (45000, 200000), 0.7),
    "Variable Frequency Drive": ("Electrical", 15, True, ["ABB", "Danfoss", "Yaskawa"], (3000, 25000), 0.6),
    "Lighting Panel":          ("Electrical", 25, True, ["Schneider Electric", "Eaton"], (4000, 15000), 0.3),
    "Motor":                   ("Electrical", 15, False, ["Baldor", "WEG", "Toshiba"], (1500, 18000), 0.5),
    "Domestic Water Pump":     ("Plumbing", 20, True, ["Grundfos", "Armstrong", "Bell & Gossett"], (6000, 35000), 0.8),
    "Water Heater":            ("Plumbing", 12, True, ["A.O. Smith", "Bradford White", "Rheem"], (4000, 22000), 0.7),
    "Backflow Preventer":      ("Plumbing", 20, True, ["Watts", "Zurn Wilkins", "Apollo"], (1500, 9000), 0.4),
    "Sump Pump":               ("Plumbing", 10, True, ["Zoeller", "Liberty", "Grundfos"], (900, 5000), 0.9),
    "Passenger Elevator":      ("Elevator", 25, True, ["Otis", "KONE", "Schindler", "ThyssenKrupp"], (90000, 300000), 2.2),
    "Freight Elevator":        ("Elevator", 25, True, ["Otis", "KONE", "Schindler"], (110000, 320000), 1.8),
    "Fire Alarm Panel":        ("Fire Safety", 15, True, ["Edwards", "Simplex", "Notifier"], (12000, 60000), 0.5),
    "Fire Pump":               ("Fire Safety", 25, True, ["Aurora", "Patterson", "Peerless"], (35000, 120000), 0.3),
    "Sprinkler Riser":         ("Fire Safety", 40, True, ["Viking", "Victaulic", "Tyco"], (8000, 40000), 0.2),
}

# Must be exactly the set schema/02_requires.sql inserts (tests/check_requires.sql verifies it).
REQUIRES = {
    ("Chiller", "313A"),                                                     # requires (a)
    ("Passenger Elevator", "EDM"), ("Freight Elevator", "EDM"), ("Boiler", "G2"),
    ("Water Heater", "G2"), ("Backflow Preventer", "BPT"), ("Fire Alarm Panel", "FAT"),
    ("Rooftop Unit", "313A"), ("Compressor", "313A"), ("Rooftop Unit", "WAH"),
    ("Cooling Tower", "WAH"),                                                # requires (b)
} | {(t, "309A") for t, v in TYPES.items() if v[0] == "Electrical" and t != "Motor"}   # requires (c)

CITIES = [("London", "N6"), ("Toronto", "M5"), ("Hamilton", "L8"), ("Kitchener", "N2"),
          ("Waterloo", "N2"), ("Windsor", "N9"), ("Guelph", "N1"), ("Sarnia", "N7"), ("Mississauga", "L5")]
CLIENTS = ["Northgate Property Group", "Thames Valley Holdings", "Lakeshore REIT", "Forest City Properties",
           "Grand River Commercial", "Huron Office Partners", "Maple Leaf Industrial", "Carling Realty"]
STREETS = ["Dundas St", "Richmond St", "Wellington Rd", "King St", "Queen St", "Oxford St", "Commissioners Rd",
           "Adelaide St", "Highbury Ave", "Wonderland Rd", "Main St", "Bay St", "Victoria St", "York St"]
BLD_KIND = ["Tower", "Plaza", "Centre", "Business Park", "Medical Building", "Distribution Centre", "Campus"]
LETTERS = "ABCEGHJKLMNPRSTVWXYZ"

buildings = []
for i in range(1, 26):
    city, fsa = random.choice(CITIES)
    pc = f"{fsa}{random.choice(LETTERS)} {random.randint(1, 9)}{random.choice(LETTERS)}{random.randint(0, 9)}"
    name = f"{random.choice(['North', 'South', 'East', 'West', 'Central', 'Riverside', 'Parkview', 'Lakeview', 'Hillcrest', 'Westmount'])} {random.choice(BLD_KIND)}"
    buildings.append((f"B{i:03d}", name, random.choice(CLIENTS),
                      f"{random.randint(10, 2999)} {random.choice(STREETS)}", city, "ON", pc))

stage1 = ["-- Generated by generator/gen_data.py: reference data (stage 1)\n",
          inserts("Building", ["building_code", "building_name", "client_name", "street", "city", "province", "postal_code"], buildings),
          inserts("Asset_Type", ["type_name", "category", "expected_life_years"], [(t, v[0], v[1]) for t, v in TYPES.items()]),
          inserts("Certification", ["cert_code", "cert_name", "issuing_body"], CERTS)]
(OUT / "load_stage1.sql").write_text("\n".join(stage1))

# ------------------------------------------------------------------ technicians
FIRST = ["Liam", "Noah", "Emma", "Olivia", "Ava", "Ethan", "Lucas", "Mia", "Aiden", "Priya", "Arjun", "Wei", "Mateo",
         "Sofia", "Hannah", "Omar", "Fatima", "Daniel", "Grace", "Nathan", "Chloe", "Ryan", "Zara", "Owen", "Isaac",
         "Leah", "Jacob", "Maya", "Ahmed", "Elena", "Marcus", "Nadia", "Tyler", "Jasmine", "Connor", "Amara"]
LAST = ["Smith", "Brown", "Tremblay", "Martin", "Roy", "Wilson", "MacDonald", "Gagnon", "Taylor", "Patel", "Singh",
        "Nguyen", "Chen", "Kowalski", "Rossi", "Campbell", "Anderson", "Leblanc", "Thompson", "Khan", "Ali",
        "O'Brien", "Kim", "Fraser", "Stewart", "Morin", "Clarke", "Ahmed", "Bergeron", "Hughes"]
TRADE_CERTS = {   # (cert, probability) per trade
    "Electrician": [("309A", 1.0), ("WAH", 0.8), ("FAT", 0.35)],
    "Refrigeration": [("313A", 1.0), ("G2", 0.7), ("WAH", 0.85)],
    "Millwright": [("433A", 1.0), ("EDM", 0.45), ("WAH", 0.6)],
    "General": [("306A", 0.4), ("BPT", 0.5), ("G2", 0.25), ("WAH", 0.5), ("FAT", 0.15)],
}
RATE = {"Electrician": (44, 58), "Refrigeration": (46, 62), "Millwright": (42, 56), "General": (30, 40)}
techs, phones, holds = [], [], []
holds_by_tech = {}
cert_serial = {c[0]: 1000 for c in CERTS}
trades = ["Electrician"] * 17 + ["Refrigeration"] * 17 + ["Millwright"] * 12 + ["General"] * 14
for i, trade in enumerate(trades, start=1):
    emp = f"E{1000 + i}"
    techs.append((emp, random.choice(FIRST), random.choice(LAST), trade, round(random.uniform(*RATE[trade]), 2)))
    for k in range(random.choice([1, 1, 2])):
        phones.append((emp, f"519-{random.randint(200, 999)}-{random.randint(1000, 9999)}"))
    holds_by_tech[emp] = {}
    for cert, p in TRADE_CERTS[trade]:
        if random.random() < p:
            issued = rand_date(D(2016, 1, 1), D(2023, 6, 1))
            years = 3 if cert in ("WAH", "BPT", "FAT") else 5
            expiry = D(issued.year + years, issued.month, min(issued.day, 28))
            if expiry < D(2026, 12, 31) and random.random() < 0.8:      # most get renewed, some lapse
                issued = D(expiry.year - years, expiry.month, expiry.day)
                expiry = D(expiry.year + years, expiry.month, expiry.day)
            cert_serial[cert] += random.randint(1, 37)
            holds.append((emp, cert, f"{cert}-{cert_serial[cert]}", issued, expiry))
            holds_by_tech[emp][cert] = (issued, expiry)
tech_rate = {t[0]: t[4] for t in techs}
tech_trade = {t[0]: t[3] for t in techs}

req_by_type = {}
for t, c in REQUIRES:
    req_by_type.setdefault(t, set()).add(c)
CATEGORY_TRADE = {"HVAC": ["Refrigeration", "Millwright", "General"], "Electrical": ["Electrician"],
                  "Plumbing": ["General", "Millwright"], "Elevator": ["Millwright"],
                  "Fire Safety": ["Electrician", "General"]}


def qualified(type_name, on):
    need = req_by_type.get(type_name, set())
    cat = TYPES[type_name][0]
    out = []
    for emp in tech_rate:
        if tech_trade[emp] not in CATEGORY_TRADE[cat] and need:
            pass
        ok = all(c in holds_by_tech[emp] and holds_by_tech[emp][c][0] <= on <= holds_by_tech[emp][c][1] for c in need)
        if ok and (tech_trade[emp] in CATEGORY_TRADE[cat] or not need):
            out.append(emp)
    return out


# ------------------------------------------------------------------ parts
PART_KINDS = {
    "HVAC": ["V-belt", "Pleated filter 24x24x2", "Bag filter 24x24", "Fan bearing", "Condenser fan motor",
             "Contactor 40A", "Capacitor 45/5 uF", "Refrigerant R-410A (lb)", "Thermostatic expansion valve",
             "Igniter", "Flame sensor", "Pressure switch", "Damper actuator", "Drain pan tablet"],
    "Electrical": ["Breaker 20A", "Breaker 100A", "Fuse 30A", "Overload relay", "Control transformer",
                   "LED driver", "Battery 12V 100Ah", "Surge protector", "Terminal block", "Starter coil"],
    "Plumbing": ["Mechanical seal", "Impeller", "Check valve 2 in", "Ball valve 1 in", "Anode rod",
                 "Thermocouple", "Float switch", "Repair kit (backflow)", "Gasket set", "Pressure gauge"],
    "Elevator": ["Door roller", "Door operator belt", "Hoist rope (m)", "Guide shoe insert", "Hall button",
                 "Limit switch", "Brake pad set"],
    "Fire Safety": ["Smoke detector", "Heat detector", "Pull station", "Sprinkler head", "Tamper switch",
                    "Flow switch", "Horn strobe", "Panel battery 12V 7Ah"],
}
parts, parts_by_cat = [], {}
pn = 0
while len(parts) < 300:
    cat = random.choice(list(PART_KINDS))
    base = random.choice(PART_KINDS[cat])
    pn += 1
    num = f"P-{pn:05d}"
    name = f"{base} ({random.choice(['Std', 'HD', 'OEM', 'Universal', 'Type ' + random.choice('ABCDE')])})"
    if "filter" in base.lower() or "tablet" in base.lower():
        cost = round(random.uniform(4, 40), 2)
    else:   # mostly small parts, a few expensive ones (motors, drivers, valves)
        cost = round(random.choices([random.uniform(8, 120), random.uniform(120, 400), random.uniform(400, 900)],
                                    [70, 22, 8])[0], 2)
    parts.append([num, name, cost, 0, 0])
    parts_by_cat.setdefault(cat, []).append(num)
part_cost = {p[0]: p[2] for p in parts}

# ------------------------------------------------------------------ assets
assets, asset_by_tag = [], {}
an = 0
COMPONENT_OF = {"Chiller": "Compressor", "Rooftop Unit": "Compressor", "Air Handling Unit": "Motor",
                "Exhaust Fan": "Motor", "Domestic Water Pump": "Motor", "Fire Pump": "Motor", "Cooling Tower": "Motor"}
top_types = [t for t, v in TYPES.items() if v[2]]


def new_asset(type_name, bcode, parent=None, earliest=D(1998, 1, 1)):
    global an
    an += 1
    tag = f"A-{an:05d}"
    cat, life, _, makers, (lo, hi), _ = TYPES[type_name]
    inst = rand_date(max(earliest, D(1998, 1, 1)), D(2023, 9, 30))
    retired = None
    if parent is None and random.random() < 0.04:
        retired = rand_date(D(2024, 2, 1), D(2026, 6, 1))
    name = f"{type_name} {an}" if parent is None else f"{type_name} {an} of {asset_by_tag[parent][1]}"
    model = f"{random.choice('ABCDEFGHJKLMNPRSTVXZ')}{random.choice('ABCDEFGHJKLMNPRSTVXZ')}-{random.randint(100, 9999)}"
    row = [tag, name, random.choice(makers), model, inst, retired,
           round(random.uniform(lo, hi), -2), bcode, type_name, parent]
    assets.append(row)
    asset_by_tag[tag] = row
    return tag


for b in buildings:
    for _ in range(random.randint(10, 13)):
        t = random.choice(top_types)
        tag = new_asset(t, b[0])
        if t in COMPONENT_OF and random.random() < 0.6:
            for _ in range(random.choice([1, 1, 2])):
                new_asset(COMPONENT_OF[t], b[0], parent=tag, earliest=asset_by_tag[tag][4])


def in_service(a, day):
    return a[4] <= day and (a[5] is None or day < a[5])


# ------------------------------------------------------------------ PM schedules
TASKS = {
    "HVAC": ["Replace filters, check belts and lubricate bearings", "Seasonal start-up inspection and coil cleaning",
             "Inspect refrigerant circuit and check pressures"],
    "Electrical": ["Infrared scan and torque check of connections", "Load bank test and battery check",
                   "Inspect, clean and exercise breakers"],
    "Plumbing": ["Inspect seals and check pump operation", "Flush tank and test relief valve",
                 "Annual backflow test and tag"],
    "Elevator": ["Monthly maintenance: doors, brakes and ropes", "Annual safety test"],
    "Fire Safety": ["Annual fire alarm inspection (CAN/ULC-S536)", "Weekly churn test and monthly flow check",
                    "Quarterly sprinkler inspection"],
}
INTERVALS = {"HVAC": [90, 90, 180, 365], "Electrical": [180, 365], "Plumbing": [90, 180, 365],
             "Elevator": [30, 30, 365], "Fire Safety": [30, 90, 365]}
schedules = []
sn = 0
for a in assets:
    if a[9] is not None:          # schedules on top-level assets only
        continue
    cat = TYPES[a[8]][0]
    for _ in range(1 if random.random() < 0.8 else 2):
        sn += 1
        interval = random.choice(INTERVALS[cat])
        start = max(START, a[4]) + dt.timedelta(days=random.randint(0, min(interval, 60)))
        cx = random.randint(1, 4)
        schedules.append({"pm": f"PM-{sn:05d}", "task": random.choice(TASKS[cat]), "interval": interval,
                          "hours": round(random.choice([1, 1.5, 2, 3, 4, 6]) * (1 + cx / 5), 1),
                          "cx": cx, "prio": random.choice(["High", "Normal", "Normal", "Low"]),
                          "start": start, "active": a[5] is None, "last": None, "asset": a[0]})

# ------------------------------------------------------------------ work orders
FAIL = {
    "HVAC": ["Refrigerant leak", "Belt worn", "Bearing failure", "Clogged filter", "Control board failure",
             "Ignition failure", "Frozen coil", "Sensor failure"],
    "Electrical": ["Tripped breaker", "Loose connection", "Overheating", "Battery failure", "Insulation breakdown"],
    "Plumbing": ["Seal leak", "Impeller damage", "Clogged line", "Valve failure", "Corrosion"],
    "Elevator": ["Door operator fault", "Leveling error", "Controller fault", "Brake wear", "Vandalism"],
    "Fire Safety": ["Detector fault", "Ground fault", "Low water pressure", "Tamper switch fault", "Power outage"],
}
PROBLEM = {
    "HVAC": ["No cooling reported", "Unit short cycling", "Loud noise from fan section", "No heat on floor",
             "Water leaking from unit"],
    "Electrical": ["Breaker keeps tripping", "Burning smell at panel", "Generator failed weekly test",
                   "Lights out in corridor", "Drive showing fault code"],
    "Plumbing": ["Low water pressure upstairs", "Pump leaking at seal", "No hot water", "Sump pit alarm"],
    "Elevator": ["Car stuck between floors", "Doors not closing", "Car not leveling", "Hall call button dead"],
    "Fire Safety": ["Panel in trouble", "False alarm on 3rd floor", "Supervisory signal on riser",
                    "Fire pump failed churn test"],
}
DUE_DAYS = {"Emergency": 0, "High": 2, "Normal": 7, "Low": 14}

wos = []   # dicts; wo_number assigned after sorting by opened date


def make_wo(kind, asset, opened, due, prio, cx, est, problem, pm=None):
    wos.append({"type": kind, "asset": asset, "opened": opened, "due": due, "prio": prio, "cx": cx,
                "est": est, "problem": problem, "pm": pm})


for s in schedules:
    a = asset_by_tag[s["asset"]]
    day = s["start"]
    while day <= TODAY + dt.timedelta(days=10):
        if not in_service(a, day):
            break
        opened = day - dt.timedelta(days=7)
        if opened >= START:
            make_wo("Preventive", a[0], opened, day, s["prio"], s["cx"], s["hours"], f"PM: {s['task']}", s["pm"])
        day += dt.timedelta(days=s["interval"])

for a in assets:
    rate = 2.6 * TYPES[a[8]][5] * (0.6 if a[9] else 1.0) * random.uniform(0.4, 1.8)
    years = (TODAY - max(START, a[4])).days / 365
    for _ in range(int(rate * years + random.random())):
        opened = rand_date(max(START, a[4]), TODAY)
        if not in_service(a, opened):
            continue
        cat = TYPES[a[8]][0]
        prio = random.choices(["Emergency", "High", "Normal", "Low"], [10, 25, 45, 20])[0]
        cx = random.randint(1, 5)
        make_wo("Reactive", a[0], opened, opened + dt.timedelta(days=DUE_DAYS[prio]), prio, cx,
                round(random.choice([1, 2, 2, 3, 4, 6]) * (0.6 + cx / 4), 1), random.choice(PROBLEM[cat]))

wos.sort(key=lambda w: (w["opened"], w["asset"]))
work_orders, pwos, time_entries, ptxns = [], [], [], []
for i, w in enumerate(wos):
    w["no"] = 100001 + i
    a = asset_by_tag[w["asset"]]
    cat = TYPES[a[8]][0]
    age = (TODAY - w["opened"]).days
    if age > 30:
        status = random.choices(["Closed", "Cancelled", "Open"], [95, 3, 2])[0]   # a few stale open jobs
    elif age > 7:
        status = random.choices(["Closed", "In Progress", "Open"], [70, 20, 10])[0]
    else:
        status = random.choices(["Closed", "In Progress", "Open"], [25, 35, 40])[0]
    if w["due"] > TODAY and status == "Closed":
        status = "Open"
    cands = qualified(a[8], w["due"])
    lead = assigned = None
    if cands and (status != "Open" or random.random() < 0.6):
        lead = random.choice(cands)
        assigned = w["opened"] + dt.timedelta(days=random.choice([0, 0, 1]))
        if assigned > TODAY:
            assigned = w["opened"]
    if status in ("Closed", "In Progress") and lead is None:
        status = "Open"                         # nobody qualified: job waits
    closed = None
    if status == "Closed":
        slip = random.choices([0, 1, 3, 7, 20], [45, 25, 15, 10, 5])[0]
        closed = min(TODAY, max(w["opened"], w["due"] - dt.timedelta(days=random.randint(0, 3)) + dt.timedelta(days=slip)))
    elif status == "Cancelled":
        closed = w["opened"] + dt.timedelta(days=random.randint(0, 10))
    cause = None
    if w["type"] == "Reactive" and status == "Closed":
        cause = random.choice(FAIL[cat])
    notes = None
    if status == "Closed":
        notes = ("Completed as scheduled; no deficiencies found." if w["type"] == "Preventive"
                 else f"Repaired: {cause.lower()}; unit tested and returned to service.")
    elif status == "Cancelled":
        notes = "Cancelled: duplicate request or no longer required."
    work_orders.append((w["no"], w["type"], status, w["prio"], w["cx"], w["est"], w["opened"], w["due"], closed,
                        w["problem"], notes, cause, w["asset"], lead, assigned))
    if w["pm"]:
        pwos.append((w["no"], w["pm"]))
    # ---- labour
    if status in ("Closed", "In Progress") and lead:
        end = closed or TODAY
        total = w["est"] * random.uniform(0.6, 1.7)
        crew = [lead] + random.sample([c for c in cands if c != lead], k=min(len(cands) - 1, random.choice([0, 0, 0, 1, 1, 2])))
        entry = 0
        for emp in crew:
            for _ in range(random.choice([1, 1, 2])):
                day = rand_date(assigned, max(assigned, end))
                ok = all(holds_by_tech[emp][c][0] <= day <= holds_by_tech[emp][c][1] for c in req_by_type.get(a[8], set()))
                if not ok:
                    continue
                entry += 1
                hrs = max(0.25, round(min(12, total / len(crew) * random.uniform(0.5, 1.0)) * 4) / 4)
                rate = round(tech_rate[emp] / (1.03 ** (TODAY.year - day.year)), 2)   # 3%/year raises
                time_entries.append((w["no"], entry, emp, day, hrs, rate))
        # ---- parts
        if random.random() < (0.45 if w["type"] == "Preventive" else 0.75):
            txn = 0
            pool = parts_by_cat[cat]
            for part in random.sample(pool, k=min(len(pool), random.choice([1, 1, 2, 3]))):
                txn += 1
                qty = 1 if part_cost[part] > 120 else random.choice([1, 1, 1, 2, 2, 4, 6])
                day = rand_date(w["opened"], max(w["opened"], end))
                cost = round(part_cost[part] / (1.04 ** (TODAY.year - day.year)), 2)       # 4%/year inflation
                ptxns.append([w["no"], txn, part, "Issue", qty, cost, day])
                if qty > 1 and random.random() < 0.12:
                    txn += 1
                    ptxns.append([w["no"], txn, part, "Return", random.randint(1, qty - 1), cost,
                                  min(end, day + dt.timedelta(days=random.randint(0, 5)))])
    # PM schedule last completed
    if w["pm"] and status == "Closed":
        s = next(s for s in schedules if s["pm"] == w["pm"])
        s["last"] = max(s["last"] or closed, closed)

for s in schedules:
    if s["last"] and s["last"] < s["start"]:
        s["last"] = s["start"]

# ---- part stock: start each part with enough stock that it never goes negative, then
# leave about a quarter of parts at or below their reorder level at the end
ptxns.sort(key=lambda t: (t[6], t[0], t[1]))
running, low = {}, {}
for t in ptxns:
    running[t[2]] = running.get(t[2], 0) + (t[4] if t[3] == "Issue" else -t[4])
    low[t[2]] = max(low.get(t[2], 0), running[t[2]])
for p in parts:
    reorder = random.choice([5, 10, 10, 15, 20, 25, 40])
    final_target = random.randint(0, reorder) if random.random() < 0.25 else random.randint(reorder + 1, reorder + 80)
    net = running.get(p[0], 0)
    peak = low.get(p[0], 0)
    p[3] = max(peak, net + final_target)       # starting stock
    p[4] = reorder

stage2 = ["-- Generated by generator/gen_data.py: operational data (stage 2), about 3 years\n",
          inserts("Technician", ["employee_number", "first_name", "last_name", "trade", "hourly_rate"], techs),
          inserts("Technician_Phone", ["employee_number", "phone_number"], phones),
          inserts("Holds", ["employee_number", "cert_code", "certificate_number", "issue_date", "expiry_date"], holds),
          inserts("Part", ["part_number", "part_name", "unit_cost", "qty_on_hand", "reorder_level"], parts),
          inserts("Asset", ["asset_tag", "asset_name", "manufacturer", "model_number", "install_date", "retired_date",
                            "replacement_value", "building_code", "type_name", "parent_asset_tag"], assets),
          inserts("PM_Schedule", ["pm_plan_number", "task_description", "interval_days", "estimated_hours",
                                  "complexity_level", "priority", "start_date", "is_active", "last_completed_date",
                                  "asset_tag"],
                  [(s["pm"], s["task"], s["interval"], s["hours"], s["cx"], s["prio"], s["start"], s["active"],
                    s["last"], s["asset"]) for s in schedules]),
          inserts("Work_Order", ["wo_number", "wo_type", "status", "priority", "complexity_level", "estimated_hours",
                                 "opened_date", "due_date", "closed_date", "problem_description", "resolution_notes",
                                 "failure_cause", "asset_tag", "lead_employee_number", "assigned_date"], work_orders),
          inserts("Preventive_Work_Order", ["wo_number", "pm_plan_number"], pwos),
          inserts("Time_Entry", ["wo_number", "entry_no", "employee_number", "work_date", "hours", "rate_charged"],
                  time_entries),
          inserts("Part_Transaction", ["wo_number", "txn_no", "part_number", "txn_type", "quantity",
                                       "unit_cost_at_time", "txn_date"], ptxns)]
(OUT / "load_stage2.sql").write_text("\n".join(stage2))

counts = {"Building": len(buildings), "Asset_Type": len(TYPES), "Certification": len(CERTS),
          "Requires": len(REQUIRES), "Technician": len(techs), "Technician_Phone": len(phones), "Holds": len(holds),
          "Part": len(parts), "Asset": len(assets), "PM_Schedule": len(schedules), "Work_Order": len(work_orders),
          "Preventive_Work_Order": len(pwos), "Time_Entry": len(time_entries), "Part_Transaction": len(ptxns)}
for k, v in counts.items():
    print(f"{k:22s} {v:6d}")
