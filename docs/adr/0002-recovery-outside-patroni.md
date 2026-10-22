# ADR-0002: point-in-time recovery finishes before Patroni is involved

- Status: accepted
- Date: 2026-10-22

## Context

Patroni generates `postgresql.conf` and `postgresql.auto.conf` from the DCS
every time it starts. Recovery settings written by pgBackRest - including
`recovery_target_time` - are cleared, because the DCS has no such parameters.
It also writes `standby.signal` whenever the node is not the leader key holder.

Handing Patroni a restored-but-not-replayed directory produces a node that
waits forever: it is a standby of a leader that no longer exists, looking for a
WAL segment nobody will write. Four attempts to work around this by writing the
settings somewhere Patroni would not touch all failed, in different ways.

## Decision

Recovery completes with Patroni stopped:

1. `pgbackrest restore --type=time --target=... --target-action=pause --delta`
2. `pg_ctl start` - PostgreSQL replays to the target and pauses
3. `pg_ctl promote` - recovery ends, a new timeline begins
4. the marker is verified here, against a standalone database
5. `pg_ctl stop`
6. the cluster state is deleted from etcd
7. Patroni starts and adopts a healthy directory on a new timeline

Replicas are reinitialised from the restored primary.

## Consequences

The drill is disruptive: the whole cluster stops and both replicas rebuild.
That is the honest cost of an in-place PITR and the reason this is a runbook
rather than something an operator does casually.

Verifying the marker before Patroni starts separates two claims that are easy
to confuse: the backup restored the data, and the orchestrator accepted the
result.

## Revisit when

Patroni grows a first-class recovery mode, or the cluster is large enough that
restoring beside the live one and switching over is cheaper than stopping it.
