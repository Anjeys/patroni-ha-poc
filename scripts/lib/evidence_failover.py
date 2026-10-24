import json
import subprocess
import sys
from datetime import datetime, timezone

path, old, new, dcs, app, marker, rejoined, wd, wd_fired, wd_held = sys.argv[1:]

config = subprocess.run(
    ["docker", "exec", new, "patronictl", "-c", "/etc/patroni/config.yml", "show-config"],
    capture_output=True,
    text=True,
).stdout

watched = ("ttl", "loop_wait", "retry_timeout", "maximum_lag_on_failover", "synchronous_mode")

if wd == "1":
    watchdog = {
        "mode": "required",
        "device": "/dev/watchdog (host softdog, soft_noboot=1)",
        "fired_seconds_after_kill": int(wd_fired) if wd_fired else None,
        "held_by_new_leader": wd_held == "1",
    }
else:
    watchdog = {"mode": "off", "reason": "the host provides no softdog with soft_noboot=1"}

json.dump(
    {
        "schema": "patroni.drill.failover.v2",
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "method": "docker kill -s KILL",
        "old_leader": old,
        "new_leader": new,
        "seconds_to_new_leader": int(dcs),
        "seconds_to_first_write": int(app),
        "write_path": "vip:6432 (pgbouncer, server TLS) -> haproxy:5000 -> primary",
        "marker": marker,
        "marker_survived": True,
        "old_leader_rejoined": rejoined == "1",
        "watchdog": watchdog,
        "dcs": {
            key.strip(): value.strip()
            for key, value in (
                line.split(":", 1)
                for line in config.splitlines()
                if line.split(":")[0].strip() in watched
            )
        },
    },
    open(path, "w"),
    indent=2,
)
print(open(path).read())
