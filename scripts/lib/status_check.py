import json, sys, time, urllib.request as u

base = sys.argv[1]


def get(path):
    return json.load(u.urlopen(base + path, timeout=10))["data"]


# A rule over a metric nobody exports never fires: assert the series too.
need = {
    "patroni_primary": 3,
    "patroni_sync_standby": 3,
    "pg_up": 3,
    "pg_stat_archiver_failed_count": 3,
    "haproxy_backend_status": 2,
}

targets = []
for _ in range(12):
    targets = get("/api/v1/targets")["activeTargets"]
    if targets and all(t["health"] == "up" for t in targets):
        break
    time.sleep(5)

bad = 0
for t in sorted(targets, key=lambda t: (t["labels"]["job"], t["labels"]["instance"])):
    ok = t["health"] == "up"
    bad += not ok
    tail = "" if ok else "  " + t["lastError"][:90]
    print(f"  {'ok' if ok else 'DOWN':5} {t['labels']['job']:12} {t['labels']['instance']}{tail}")

rules = sum(len(g["rules"]) for g in get("/api/v1/rules")["groups"])
print(f"  rules loaded: {rules}")
if rules < 6:
    print("  ERROR: expected six alerting rules")
    bad += 1

for metric, want in need.items():
    result = get(f"/api/v1/query?query=count({metric})")["result"]
    got = int(result[0]["value"][1]) if result else 0
    print(f"  {'ok' if got >= want else 'MISSING':8} {metric}: {got} series (need {want})")
    if got < want:
        bad += 1

for alert in get("/api/v1/alerts")["alerts"]:
    if alert["state"] == "firing":
        print("  FIRING", alert["labels"]["alertname"], alert["labels"].get("instance", ""))
        bad += 1

sys.exit(1 if bad else 0)
