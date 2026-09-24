#!/usr/bin/env python3
"""Tiny render.yaml query helper for the bats suites (no yq dependency).

  bpq.py <render.yaml|-> '<python expression over bp>'

Prints the result: lists one item per line, bools as true/false.
"""
import sys

import yaml

src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
bp = yaml.safe_load(src)
svcs = bp.get("services", [])
dbs = bp.get("databases", [])
res = eval(sys.argv[2], {"bp": bp, "svcs": svcs, "dbs": dbs})
if isinstance(res, bool):
    print("true" if res else "false")
elif isinstance(res, (list, tuple, set)):
    for x in res:
        print(x)
else:
    print(res)
