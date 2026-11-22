#!/usr/bin/env python3
"""Token-only execution guard: a live operator-issued mission is required."""
import json, sys, time
P = "/lab/state/mission/active.json"
try:
    d = json.load(open(P))
except Exception:
    print(json.dumps({"code": "deny_no_active_mission",
                      "hint": "open a mission with an operator code first"}))
    sys.exit(90)
if int(d.get("exp", 0)) <= int(time.time()):
    print(json.dumps({"code": "deny_mission_expired", "grant": d.get("grant_id")}))
    sys.exit(90)
sys.exit(0)
