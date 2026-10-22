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
| PgBouncer | 1.26.1 | transaction pooling on 6432 |
| Ansible | 2.17+ | deployment; `scripts/lab.sh` wraps it |

Versions are pinned to exact apt builds in `group_vars/all/versions.yml`. PGDG
keeps only the latest build of each package, so a stale pin fails the run
instead of quietly installing something else; etcd comes from its release
asset with a SHA-256 the playbook verifies.

## Evidence

| Claim | How it is proved | Result |
|---|---|---|
| A killed leader is replaced without losing a committed row | `scripts/drill.sh failover` | new leader in 24 s, writes accepted in 24 s, marker intact |
| A dropped table can be recovered to the second before it was dropped | `scripts/drill.sh pitr` | marker restored, cluster back under Patroni, both replicas streaming |
| A commit is on a replica before it is acknowledged | `synchronous_mode: true`, `maximum_lag_on_failover: 0`; the failover drill reads the marker from the promoted node | passes |
| WAL reaches the repository continuously | `pgbackrest --stanza=main check`, `pg_stat_archiver` | `failed_count = 0` |
| Running the playbook twice changes nothing | `scripts/lab.sh check` | `changed=0` |

Drill output lands in `evidence/` as JSON: the method, the intervals, the
marker, and whether it survived.

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
    scripts/drill.sh failover
    scripts/drill.sh pitr
    scripts/lab.sh down      # stop, keep the volumes
    scripts/lab.sh reset     # stop and drop the volumes

`lab.sh up` generates an SSH key pair and three passwords on first run.
Nothing is committed: `group_vars/all/secrets.yml` and `.ssh/` are gitignored,
and `secrets.yml.example` shows the shape. On real hosts the file is
`ansible-vault` encrypted.

Check the cluster:

    docker exec node1 patronictl -c /etc/patroni/config.yml list
    docker exec -u postgres balancer pgbackrest --stanza=main info

## What is not proved here

**The access layer is a single point of failure.** HAProxy, PgBouncer and the
backup repository all live on one container. Three database nodes survive a
node loss; the thing in front of them does not. On real infrastructure this is
a VIP with keepalived, or the client connects to all three directly with
`host=node1,node2,node3 target_session_attrs=read-write` and skips the proxy
for failover entirely. See ADR-0003.

**The containers are privileged.** systemd as PID 1 needs it here. Real hosts
do not.

**Numbers come from one laptop.** 24 s is what this network and these disks
give; the shape of the measurement transfers, the value does not.

**No CI.** The drills run by hand. Running them on every push needs a runner
that can host systemd containers.

## Decisions

- [ADR-0001](docs/adr/0001-etcd-from-upstream.md) - etcd from upstream, not from Ubuntu
- [ADR-0002](docs/adr/0002-recovery-outside-patroni.md) - PITR finishes before Patroni is involved
- [ADR-0003](docs/adr/0003-single-access-node.md) - one access node, and what that costs
