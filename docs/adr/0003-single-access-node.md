# ADR-0003: one access node, and what that costs

- Status: accepted
- Date: 2026-10-22

## Context

HAProxy, PgBouncer and the pgBackRest repository all run on `balancer`. Three
database nodes tolerate the loss of one; the container in front of them does
not. Losing it takes away both the way in and the place backups are written.

## Decision

Keep it, and say so. A second access node needs a virtual address and something
to move it - keepalived, or the platform's load balancer - and neither adds
anything to what this project set out to show: Patroni's failover, synchronous
replication, and recovery from a backup.

## Consequences

The PoC demonstrates database availability, not end-to-end availability. An
honest diagram has a single point in front of a highly available cluster.

Two ways out, both real:

- **A VIP.** keepalived on two access nodes, HAProxy and PgBouncer on each.
- **No proxy.** libpq connects to every node and lets the driver find the
  primary: `host=node1,node2,node3 target_session_attrs=read-write`. The
  application fails over without anything in the path, at the cost of losing
  connection pooling.

The backup repository is a separate question: on real infrastructure it is
object storage, not a directory on a node.
