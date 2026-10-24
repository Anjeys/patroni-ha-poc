#!/usr/bin/env bash
# What the cluster does when something breaks, measured rather than claimed.
#
#   scripts/drill.sh failover   kill the leader, time the recovery, check the data
#   scripts/drill.sh pitr       lose a table, restore to the second before it
#   scripts/drill.sh access     kill the balancer holding the VIP, time the takeover
#
# Both write a marker first and verify it afterwards: a cluster that comes back
# without the last committed row has not recovered, it has restarted.
# Evidence lands in evidence/<drill>-<utc>.json.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NODES=(node1 node2 node3)
BALANCERS=(balancer balancer2)
REPO=backup           # never killed by a drill; has psql and the repository
LAB_NET="$(cat .lab_net 2>/dev/null || echo 18)"
LAB_WATCHDOG="$(cat .lab_watchdog 2>/dev/null || echo 0)"
VIP="172.${LAB_NET}.0.100"
SCOPE=patroni-cluster
APP_PORT=6432          # PgBouncer on the VIP, which is how an application reaches the cluster
PATRONI=(patronictl -c /etc/patroni/config.yml)

log()  { printf '\033[1;34m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# etcdctl needs an address, the drill knows container names: the inventory
# already maps one to the other.
node_ip() { # node_ip <container>
  awk -v h="$1" '$1 == h { for (i = 2; i <= NF; i++) if ($i ~ /^ansible_host=/) { sub(/^ansible_host=/, "", $i); print $i } }' inventory.ini
}

secret() { # secret <key>
  ansible-vault view group_vars/all/secrets.yml \
    | python3 -c "import sys,yaml;print(yaml.safe_load(sys.stdin)['$1'])"
}

PGPW="$(secret pg_superuser_password)"

# Every query goes through PgBouncer on the access node: that is the path an
# application takes, and the only one whose downtime is worth measuring.
app_sql() { # app_sql <sql>
  docker exec -e PGPASSWORD="$PGPW" "$REPO" \
    psql -h "$VIP" -p "$APP_PORT" -U postgres -d postgres -Atc "$1" 2>/dev/null
}

vip_holder() {
  local b
  for b in "${BALANCERS[@]}"; do
    docker exec "$b" ip -4 -o addr show eth0 2>/dev/null | grep -q "$VIP/" && { echo "$b"; return 0; }
  done
  return 1
}

node_sql() { # node_sql <node> <sql>
  docker exec -u postgres "$1" psql -h /tmp -d postgres -Atc "$2" 2>/dev/null
}

leader() {
  local node
  for node in "${NODES[@]}"; do
    docker exec "$node" "${PATRONI[@]}" list -f json 2>/dev/null \
      | python3 -c 'import json,sys
try:
    for m in json.load(sys.stdin):
        if m.get("Role") in ("Leader", "Primary"):
            print(m["Member"]); break
except Exception:
    pass' && return 0
  done
  return 1
}

evidence_file() { mkdir -p evidence; printf 'evidence/%s-%s.json' "$1" "$(date -u +%Y%m%dT%H%M%SZ)"; }

# --- failover ---------------------------------------------------------------

cmd_failover() {
  local old new marker t0 dcs_s app_s rows out
  command -v docker >/dev/null || die "docker is required"

  old="$(leader)" || die "no leader: is the cluster up?"
  log "leader is $old"

  app_sql "create table if not exists drill(id serial primary key, note text, at timestamptz default now())" >/dev/null
  marker="failover-$(date -u +%s)-$RANDOM"
  app_sql "insert into drill(note) values ('$marker')" >/dev/null
  [[ "$(app_sql "select count(*) from drill where note = '$marker'")" == "1" ]] \
    || die "the marker was not committed before the drill started"
  log "marker committed through port $APP_PORT: $marker"

  # The watchdog fires when the leader stops feeding it. softdog with
  # soft_noboot=1 writes a kernel line instead of rebooting, and counting those
  # lines is the only safe way to prove a fence from inside a shared kernel.
  local wd_before=0 wd_fired="" wd_held=""
  if [[ "$LAB_WATCHDOG" == "1" ]]; then
    wd_before="$(docker exec "$old" dmesg 2>/dev/null | grep -c 'softdog: Triggered' || true)"
    wd_before="${wd_before:-0}"
  fi

  # SIGKILL, not stop: a process that gets to shut down cleanly hands over the
  # leader key, and that measures a switchover, not a failure.
  log "killing $old"
  t0=$SECONDS
  docker kill -s KILL "$old" >/dev/null

  # First interval: the cluster agrees on a new leader.
  dcs_s=""
  while (( SECONDS - t0 < 120 )); do
    new="$(leader 2>/dev/null || true)"
    if [[ -n "$new" && "$new" != "$old" ]]; then dcs_s=$((SECONDS - t0)); break; fi
    sleep 1
  done
  [[ -n "$dcs_s" ]] || die "no new leader within 120s"
  log "new leader $new after ${dcs_s}s"

  if [[ "$LAB_WATCHDOG" == "1" ]]; then
    local seen _
    for _ in $(seq 1 20); do
      seen="$(docker exec "$new" dmesg 2>/dev/null | grep -c 'softdog: Triggered' || true)"
      (( ${seen:-0} > wd_before )) && { wd_fired=$((SECONDS - t0)); break; }
      sleep 1
    done
    [[ -n "$wd_fired" ]] \
      && log "the watchdog fired ${wd_fired}s after the kill (kernel log; reboot suppressed)" \
      || warn "no softdog trigger in the kernel log within 20s"

    # mode required means a node that cannot arm the device never leads: the
    # new leader holding it is the half of the contract this can check.
    wd_held="$(docker exec "$new" sh -c 'ls -l /proc/$(systemctl show -p MainPID --value patroni)/fd 2>/dev/null | grep -c watchdog' || true)"
    [[ "${wd_held:-0}" == "1" ]] || die "watchdog mode is required but the new leader does not hold the device"
    log "the new leader holds /dev/watchdog"
  fi

  # Second interval: an application can write again. This is the number that
  # matters - a promoted leader nobody can reach is not availability.
  app_s=""
  while (( SECONDS - t0 < 120 )); do
    if app_sql "insert into drill(note) values ('$marker-after')" >/dev/null; then
      app_s=$((SECONDS - t0)); break
    fi
    sleep 1
  done
  [[ -n "$app_s" ]] || die "no write accepted through $APP_PORT within 120s"
  log "writes accepted after ${app_s}s"

  # synchronous_mode promises the marker was on a replica before it was
  # acknowledged. The new leader either has it or the promise was empty.
  rows="$(app_sql "select count(*) from drill where note = '$marker'")"
  [[ "$rows" == "1" ]] || die "the committed marker did not survive the failover (found $rows)"
  log "the marker is on the new leader: nothing was lost"

  docker start "$old" >/dev/null
  log "restarted $old; waiting for it to rejoin as a replica"
  local rejoined=0 _
  for _ in $(seq 1 60); do
    docker exec "$new" "${PATRONI[@]}" list -f json 2>/dev/null \
      | grep -q "\"$old\"" && { rejoined=1; break; }
    sleep 2
  done
  (( rejoined )) || warn "$old has not rejoined yet; check patronictl list"

  out="$(evidence_file failover)"
  python3 scripts/lib/evidence_failover.py "$out" "$old" "$new" "$dcs_s" "$app_s" \
    "$marker" "$rejoined" "$LAB_WATCHDOG" "${wd_fired:-}" "${wd_held:-}"
  log "evidence: $out"
}

# --- pitr -------------------------------------------------------------------

cmd_pitr() {
  local node marker before target out restored
  node="$(leader)" || die "no leader"
  log "primary is $node"

  app_sql "create table if not exists pitr_drill(id serial primary key, note text)" >/dev/null
  marker="pitr-$(date -u +%s)-$RANDOM"
  app_sql "insert into pitr_drill(note) values ('$marker')" >/dev/null
  log "marker committed: $marker"

  # A backup taken after the marker is the only one that can restore it.
  log "taking an incremental backup"
  docker exec -u postgres "$REPO" pgbackrest --stanza=main --type=incr backup >/dev/null \
    || die "backup failed"

  app_sql "select pg_switch_wal()" >/dev/null
  sleep 3
  target="$(app_sql "select to_char(now(), 'YYYY-MM-DD HH24:MI:SS')")"
  log "restore target: $target"
  sleep 2

  # The damage: a table dropped in production, which is what PITR is for.
  before="$(app_sql "select count(*) from pitr_drill")"
  app_sql "drop table pitr_drill" >/dev/null
  log "dropped pitr_drill (had $before row(s))"

  # Patroni owns the data directory, so it must stand aside while pgBackRest
  # replaces it; the replicas follow once the primary comes back on a new
  # timeline. This is a disruptive restore by design - that is what it costs.
  log "stopping the cluster for an in-place restore"
  for n in "${NODES[@]}"; do docker exec "$n" systemctl stop patroni; done
  sleep 3

  # --target-action=promote would have PostgreSQL finish recovery on its own
  # and pick a new timeline; Patroni then finds a cluster it did not promote
  # and a timeline the DCS knows nothing about. The restore stops at the
  # target and Patroni decides what happens next, which is its job.
  log "restoring $node to $target"
  docker exec -u postgres "$node" pgbackrest --stanza=main \
    --type=time --target="$target" --target-action=pause --delta restore \
    || die "pgbackrest restore failed"

  # Patroni owns postgresql.conf, postgresql.auto.conf and the standby marker:
  # start it on a half-recovered directory and it rewrites all three, decides
  # the node is a replica of a leader that does not exist, and waits forever.
  # This is why the Patroni documentation recovers a cluster with Patroni
  # stopped: PostgreSQL reaches the target on its own, is promoted, and only
  # then is handed over as a healthy directory on a new timeline.
  log "finishing recovery with Patroni out of the way"

  docker exec "$node" rm -f /var/lib/postgresql/18/main/standby.signal

  # pgBackRest wrote the recovery settings into postgresql.auto.conf; they are
  # intact as long as Patroni does not start. restore_command is what fetches
  # the segments the target needs but the restore did not place on disk.
  docker exec "$node" bash -c "grep -q '^restore_command' /var/lib/postgresql/18/main/postgresql.auto.conf \
    || printf \"restore_command = 'pgbackrest --stanza=main archive-get %%f \\\"%%p\\\"'\\n\" \
       >> /var/lib/postgresql/18/main/postgresql.auto.conf"

  docker exec -u postgres "$node" \
    /usr/lib/postgresql/18/bin/pg_ctl -D /var/lib/postgresql/18/main \
    -o "-c unix_socket_directories=/tmp -c port=5432" -w -t 120 start \
    || die "PostgreSQL did not start for recovery"

  log "replaying to the target"
  local replayed=0 _
  for _ in $(seq 1 60); do
    if [[ "$(node_sql "$node" "select pg_is_in_recovery()")" == "f" ]]; then replayed=1; break; fi
    if [[ "$(node_sql "$node" "select pg_get_wal_replay_pause_state()")" == "paused" ]]; then
      log "recovery reached the target and paused"
      replayed=1; break
    fi
    sleep 2
  done
  (( replayed )) || die "recovery never reached the target"

  # Promote ends recovery and starts a new timeline: the restored copy becomes
  # a cluster in its own right rather than a replica of the one that was lost.
  if [[ "$(node_sql "$node" "select pg_is_in_recovery()")" == "t" ]]; then
    log "promoting the restored copy"
    docker exec -u postgres "$node" \
      /usr/lib/postgresql/18/bin/pg_ctl -D /var/lib/postgresql/18/main promote \
      || die "promote failed"
    for _ in $(seq 1 30); do
      [[ "$(node_sql "$node" "select pg_is_in_recovery()")" == "f" ]] && break
      sleep 2
    done
  fi
  [[ "$(node_sql "$node" "select pg_is_in_recovery()")" == "f" ]] \
    || die "the restored copy is still in recovery"

  restored="$(node_sql "$node" "select count(*) from pitr_drill where note = '$marker'" || echo 0)"
  [[ "$restored" == "1" ]] \
    || die "the marker is not in the restored database (found ${restored:-none}): the restore lost data"
  log "the dropped table and its marker are back"

  # Hand the finished directory to Patroni. The DCS is empty, so it takes the
  # leader key and adopts what it finds instead of trying to catch up to it.
  log "handing the cluster back to Patroni"
  docker exec -u postgres "$node" \
    /usr/lib/postgresql/18/bin/pg_ctl -D /var/lib/postgresql/18/main -w -t 60 stop >/dev/null

  # The DCS still describes the cluster as it was before the restore: a leader
  # key, a timeline history and the members that followed them. Patroni reads
  # that first, decides this node is behind a leader it should catch up to,
  # and puts the promoted copy back into recovery. An empty namespace leaves
  # it nothing to disagree with: it takes the key and adopts what it finds.
  log "clearing the cluster state so the restored copy becomes the new truth"
  docker exec "$node" etcdctl --endpoints="http://$(node_ip "$node"):2379" \
    del --prefix "/db/${SCOPE}/" >/dev/null

  docker exec "$node" systemctl start patroni

  local adopted=0 _
  for _ in $(seq 1 60); do
    [[ "$(node_sql "$node" "select pg_is_in_recovery()" 2>/dev/null)" == "f" ]] && { adopted=1; break; }
    sleep 2
  done
  (( adopted )) || die "Patroni did not adopt the restored cluster"
  log "Patroni is running the restored cluster"

  # The other two nodes rebuild from the new timeline.
  for n in "${NODES[@]}"; do
    [[ "$n" == "$node" ]] && continue
    docker exec "$n" rm -rf /var/lib/postgresql/18/main
    docker exec "$n" systemctl start patroni
  done
  log "replicas are rebuilding from the restored primary"

  local streaming=0 _
  for _ in $(seq 1 60); do
    if [[ "$(docker exec "$node" "${PATRONI[@]}" list -f json 2>/dev/null \
      | python3 -c 'import json,sys; print(sum(1 for m in json.load(sys.stdin) if m.get("State") == "streaming"))' 2>/dev/null)" == "2" ]]; then
      streaming=1; break
    fi
    sleep 5
  done
  (( streaming )) && log "both replicas are streaming again" \
    || warn "replicas have not caught up yet; patronictl list shows progress"

  out="$(evidence_file pitr)"
  python3 - "$out" "$node" "$target" "$marker" "$before" <<'PY'
import json, sys
from datetime import datetime, timezone
path, node, target, marker, rows = sys.argv[1:]
json.dump({
    "schema": "patroni.drill.pitr.v1",
    "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "primary": node, "restore_target": target,
    "damage": "drop table pitr_drill",
    "rows_before": int(rows), "marker": marker, "marker_restored": True,
    "method": "pgbackrest --type=time --target-action=pause --delta restore, then pg_ctl promote with Patroni stopped",
    "disruptive": True,
}, open(path, "w"), indent=2)
print(open(path).read())
PY
  log "evidence: $out"
  warn "replicas rebuild in the background; patronictl list shows when they are streaming"
}

# --- access -------------------------------------------------------------------

cmd_access() {
  local holder other marker t0 vip_s app_s rows out
  holder="$(vip_holder)" || die "no balancer holds $VIP"
  for other in "${BALANCERS[@]}"; do [[ "$other" != "$holder" ]] && break; done
  log "$VIP is on $holder"

  app_sql "create table if not exists drill(id serial primary key, note text, at timestamptz default now())" >/dev/null
  marker="access-$(date -u +%s)-$RANDOM"
  app_sql "insert into drill(note) values ('$marker')" >/dev/null
  [[ "$(app_sql "select count(*) from drill where note = '$marker'")" == "1" ]] || die "marker not committed"
  log "marker committed through $VIP:$APP_PORT: $marker"

  log "killing $holder"
  t0=$SECONDS
  docker kill -s KILL "$holder" >/dev/null

  vip_s=""
  while (( SECONDS - t0 < 60 )); do
    [[ "$(vip_holder 2>/dev/null)" == "$other" ]] && { vip_s=$((SECONDS - t0)); break; }
    sleep 1
  done
  [[ -n "$vip_s" ]] || die "$VIP did not move to $other within 60s"
  log "$VIP on $other after ${vip_s}s"

  app_s=""
  while (( SECONDS - t0 < 60 )); do
    app_sql "insert into drill(note) values ('$marker-after')" >/dev/null && { app_s=$((SECONDS - t0)); break; }
    sleep 1
  done
  [[ -n "$app_s" ]] || die "no write through $VIP within 60s"
  log "writes accepted after ${app_s}s"

  rows="$(app_sql "select count(*) from drill where note = '$marker'")"
  [[ "$rows" == "1" ]] || die "marker lost across the takeover (found $rows)"

  docker start "$holder" >/dev/null
  log "restarted $holder (it preempts the address back once its HAProxy is up)"

  out="$(evidence_file access)"
  python3 - "$out" "$holder" "$other" "$vip_s" "$app_s" "$marker" <<'PY2'
import json, sys
from datetime import datetime, timezone
path, killed, took, vip, app, marker = sys.argv[1:]
json.dump({
    "schema": "patroni.drill.access.v1",
    "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "method": "docker kill -s KILL on the balancer holding the VIP",
    "killed": killed, "took_over": took,
    "seconds_to_vip_move": int(vip), "seconds_to_first_write": int(app),
    "marker": marker, "marker_survived": True,
    "database_cluster_touched": False,
}, open(path, "w"), indent=2)
print(open(path).read())
PY2
  log "evidence: $out"
}

case "${1:-}" in
  failover) cmd_failover ;;
  pitr)     cmd_pitr ;;
  access)   cmd_access ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
