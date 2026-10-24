# PostgreSQL high availability: Patroni, etcd, pgBackRest

A three-node PostgreSQL cluster with automatic failover, synchronous
replication and point-in-time recovery, deployed by Ansible onto systemd
containers that stand in for bare metal.

Every claim below is a number a script produced, not a description of what the
components are supposed to do. The two drills kill the leader and destroy a
table, then check that the last committed row is still there.

## What it runs

| Component | Version | Role |
|---|---|---|
| PostgreSQL | 18.6 | the database |
| Patroni | 4.1.5 | leader election, failover, cluster configuration |
| etcd | 3.7.2 | consensus; the leader key lives here |
| pgBackRest | 2.59.3 | WAL archive, backups, point-in-time recovery |
| HAProxy | 2.8.16 | routes 5000 to the primary, 5001 to replicas |
| keepalived | 2.2.8 | one virtual address over two access nodes |
| PgBouncer | 1.26.1 | transaction pooling on 6432 |
| postgres_exporter / Prometheus | 0.20.1 / 3.15.1 | metrics and six alerting rules on the repository host |
| Ansible | 2.17+ | deployment; `scripts/lab.sh` wraps it |

Versions are pinned to exact apt builds in `group_vars/all/versions.yml`. PGDG
keeps only the latest build of each package, so a stale pin fails the run
instead of quietly installing something else; etcd comes from its release
asset with a SHA-256 the playbook verifies.

## Evidence

| Claim | How it is proved | Result |
|---|---|---|
| A killed leader is replaced without losing a committed row | `scripts/drill.sh failover` | new leader in 23-24 s, writes accepted in 24-38 s, marker intact |
| A killed access node is replaced behind the same address | `scripts/drill.sh access` | VIP moved in 4 s, writes accepted in 4 s, marker intact; the database cluster is not touched |
| A dropped table can be recovered to the second before it was dropped | `scripts/drill.sh pitr` | marker restored, cluster back under Patroni, both replicas streaming |
| A commit is on a replica before it is acknowledged | `synchronous_mode: true`, `maximum_lag_on_failover: 0`; the failover drill reads the marker from the promoted node | passes |
| WAL reaches the repository continuously | `pgbackrest --stanza=main check`, `pg_stat_archiver` | `failed_count = 0` |
| Running the playbook twice changes nothing | `scripts/lab.sh check` | `changed=0` |
| A killed leader is fenced by the kernel watchdog, and the new leader arms it | `scripts/drill.sh failover`, watchdog section of the evidence | `softdog: Triggered` in the kernel log seconds after the kill; `/dev/watchdog` held by the new leader (`held_by_new_leader: true`) |
| PostgreSQL refuses a connection that is not TLS | `psql "sslmode=disable"` against 5000 | `no pg_hba.conf entry`; replication and the pooler connect with `ssl = t` |
| Every monitoring target is up, every rule loaded, nothing firing | `scripts/lab.sh status` | passes |

Drill output lands in `evidence/` as JSON: the method, the intervals, the
marker, and whether it survived.
The same drills run weekly in CI (`drills` workflow); each run uploads its
`evidence/` as an artifact.

## Failover, measured

`scripts/drill.sh failover` writes a row through PgBouncer, kills the leader
with `SIGKILL`, and times two things:

- **24 s** until the cluster agrees on a new leader
- **24 s** until an application can write again on port 6432

`SIGKILL` rather than `docker stop` on purpose: a process allowed to shut down
cleanly hands over the leader key, and timing that measures a switchover, which
is a different event. An earlier version of this README claimed under ten
seconds - that number came from a switchover.

The floor is `ttl`: nothing may promote while the dead leader's key is still
valid. At `ttl: 20` the drill measured 29 s; at `ttl: 10` it measures 24 s.
Lower is not free - a leader whose writes to etcd are slow loses its own key
and demotes itself - so `ttl: 10, loop_wait: 3, retry_timeout: 3` is a bet on a
fast, local network, and on a real one it would be raised.

## Point-in-time recovery

`scripts/drill.sh pitr` commits a marker, takes an incremental backup, drops
the table, and restores to a timestamp between the two.

The interesting part is the order. Patroni owns `postgresql.conf`,
`postgresql.auto.conf` and the standby marker, and rewrites all three when it
starts. Handed a half-recovered directory it clears `recovery_target_time`,
decides the node should follow a leader that no longer exists, and waits for
WAL nobody will ever write. So recovery finishes **with Patroni stopped**:
`pgbackrest restore --target-action=pause`, `pg_ctl start`, replay to the
target, `pg_ctl promote`, `pg_ctl stop`. Only then does Patroni get the
directory - with the cluster state cleared from etcd, so it adopts what it
finds instead of arguing with it.

The marker is checked while the database is still standalone: *the backup
restored the data* and *the orchestrator accepted the result* are two claims,
and the drill proves them separately.

This is disruptive by design. The whole cluster stops, the primary is replaced,
and both replicas rebuild from the new timeline. That is what an in-place PITR
costs.

## Running it

    scripts/lab.sh up        # keys, secrets, containers, playbook
    scripts/lab.sh check     # run the playbook again; fails if anything changed
    scripts/lab.sh status    # monitoring: targets, rules, series, alerts
    scripts/drill.sh failover
    scripts/drill.sh access
    scripts/drill.sh pitr
    scripts/lab.sh down      # stop, keep the volumes
    scripts/lab.sh reset     # stop and drop the volumes

`lab.sh up` generates an SSH key pair and three passwords on first run.
Nothing is committed: `group_vars/all/secrets.yml` and `.ssh/` are gitignored,
and `secrets.yml.example` shows the shape. On real hosts the file is
`ansible-vault` encrypted.

Check the cluster:

    docker exec node1 patronictl -c /etc/patroni/config.yml list
    docker exec -u postgres backup pgbackrest --stanza=main info
    psql -h 172.18.0.100 -p 6432 -U postgres     # the VIP; the octet is in .lab_net if 172.18 was taken

## What is not proved here

**The backup repository is one host.** Losing it loses the archive until it
is restored. On real infrastructure a second repository lives in object
storage: the `repo2-type=s3` block in the repository config is ready to be
uncommented, and ADR-0004 says how that bucket is built (versioning, KMS,
Object Lock, IAM role, replication) and what changes across two data centres.

**The containers are privileged.** systemd as PID 1 needs it here. Real hosts
do not.

**The watchdog cannot reboot here.** Patroni takes `watchdog.mode: required`
and the device is the host's softdog, passed through only when it was loaded
with `soft_noboot=1`: a watchdog that fires reboots the host that owns it, and
here that host is the laptop or the CI runner. The drill proves the fence by
the kernel log line the suppressed reboot leaves behind; a real host leaves
`soft_noboot` at 0 and the reboot is the fence. A host without softdog runs
with the watchdog off and the evidence says so.

**etcd is plain HTTP without authentication, and there is no CA.** PostgreSQL
TLS is self-signed per node, so `sslmode=require` rather than `verify-full`.
Client-to-PgBouncer TLS and an etcd PKI are named in ADR-0005 as the next step.

**Alerts go nowhere.** Six rules evaluate and `lab.sh status` asserts them;
routing them through Alertmanager and drawing them in Grafana is site-specific.

**Numbers come from one laptop and one hosted runner.** 24 s is what this network and these disks
give; the shape of the measurement transfers, the value does not.

**Drills run weekly, not on every push.** `.github/workflows/drills.yml`
builds the cluster on a GitHub-hosted runner and runs all three drills;
evidence is attached to the run. Ten minutes of systemd containers per run
is a weekly cost, not a per-commit one; lint runs on every push.

## Decisions

- [ADR-0001](docs/adr/0001-etcd-from-upstream.md) - etcd from upstream, not from Ubuntu
- [ADR-0002](docs/adr/0002-recovery-outside-patroni.md) - PITR finishes before Patroni is involved
- [ADR-0003](docs/adr/0003-single-access-node.md) - one access node, and what that costs (superseded)
- [ADR-0004](docs/adr/0004-vip-and-backup-host.md) - two access nodes behind a VIP; the repository on its own host
- [ADR-0005](docs/adr/0005-fencing-tls-monitoring.md) - watchdog fencing, TLS to PostgreSQL, monitoring with alerts
