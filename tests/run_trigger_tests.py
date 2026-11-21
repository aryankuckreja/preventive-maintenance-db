#!/usr/bin/env python3
"""Run each rule-breaking statement in tests/trigger_tests.sql inside a transaction that is
rolled back, and fail if any statement is accepted or is rejected with an unexpected error. Uses the mysql command-line client.

    MYSQL="mysql -u root" python3 tests/run_trigger_tests.py
"""
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

MYSQL = shlex.split(os.environ.get("MYSQL", "mysql -u root")) + ["pm_tracker"]
text = (Path(__file__).parent / "trigger_tests.sql").read_text()

cases = []
for block in re.split(r"^-- case: ", text, flags=re.M)[1:]:
    header, _, body = block.partition("\n")
    name, _, expect = header.partition("| expect:")
    sql = "\n".join(l for l in body.splitlines() if not l.startswith("--")).strip()
    cases.append((name.strip(), expect.strip(), sql))

bad = 0
for name, expect, sql in cases:
    run = subprocess.run(MYSQL, input=f"START TRANSACTION;\n{sql}\nROLLBACK;\n",
                         capture_output=True, text=True)
    msg = run.stderr.strip().splitlines()[-1] if run.stderr.strip() else ""
    if run.returncode == 0:
        bad += 1
        print(f"  FAIL accepted: {name}")
    elif expect.lower() not in msg.lower():
        bad += 1
        print(f"  FAIL rejected for the wrong reason: {name}\n      expected '{expect}', got: {msg}")
    else:
        print(f"  ok  {name}\n      {msg}")

print(f"  {len(cases) - bad} of {len(cases)} cases rejected with the expected error")
sys.exit(1 if bad else 0)
