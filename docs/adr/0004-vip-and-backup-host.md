# ADR-0004: two access nodes behind a virtual address; the repository on its own host

- Status: accepted; supersedes ADR-0003
- Date: 2026-10-23

## Context

ADR-0003 recorded a single access node as an accepted limit. A cluster that
survives a database node but not the container in front of it is highly
available on a diagram only, and the same container held the backups.

## Decision

- **Two access nodes, one address.** HAProxy and PgBouncer on `balancer` and
  `balancer2`; keepalived moves `172.18.0.100` between them over unicast VRRP
  and tracks HAProxy, so a dead proxy on a live host also moves the address.
  `scripts/drill.sh access` kills the holder and measures the takeover.
- **The backup repository on its own host.** `backup` runs pgBackRest only:
  losing a balancer no longer touches the archive. The repository is a single
  host by design; replicating it is what object storage is for on real
  infrastructure (`repo1-type=s3`), not a second directory on a second node.

## What changes with two data centres

This lab is one site. Across two the shape is: a Patroni standby cluster in
the second site (`standby_cluster` in the DCS) rather than one cluster
stretched over the link; an etcd quorum over three sites or a witness,
because two sites cannot form a majority when one is lost; and a second
pgBackRest repository (`repo2`) or shared object storage so a site loss
keeps the archive. None of that is proved here, and it is named so that it
is not mistaken for something this lab shows.

## Consequences

Six containers plus the control node. The access drill proves the takeover;
the database drills are unchanged and no longer depend on which balancer
is alive.
