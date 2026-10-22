# ADR-0001: etcd from the upstream release, not from Ubuntu

- Status: accepted
- Date: 2026-10-22

## Context

Ubuntu 24.04 ships etcd 3.4. Patroni talks to the DCS over either the v2 or the
v3 API; v2 is disabled by default from etcd 3.4 and removed in 3.6. A cluster
built on `apt install etcd` is therefore built on an API that is already on its
way out, and the Ubuntu package version is whatever the distribution decided.

## Decision

etcd 3.7.2 from the upstream release asset, SHA-256 verified before it is
unpacked, with a systemd unit the playbook writes. Patroni uses `etcd3:` and
lists all three members, not `127.0.0.1`.

## Consequences

A dead local etcd no longer demotes a healthy leader: Patroni asks the other
members. The cost is an upgrade path the distribution does not manage - a bump
is a deliberate commit that changes both the version and its checksum.
