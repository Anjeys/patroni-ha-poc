# ADR-0005: watchdog fencing, TLS to PostgreSQL, monitoring with alerts

- Status: accepted
- Date: 2026-10-24

## Watchdog

A leader that loses the DCS must stop being a leader before its key expires.
Patroni demotes itself, but a hung Patroni cannot demote anything. The Linux
watchdog closes that gap: the leader arms the device and feeds it every loop,
and one that stops feeding it is rebooted by the kernel. `watchdog.mode:
required` means a node that cannot arm the device never takes the lead.

In this lab the kernel is shared with the machine running it, so a watchdog
that fires would reboot the laptop or the CI runner. `scripts/lab.sh` passes
the device through only when it is softdog loaded with `soft_noboot=1`: the
trigger becomes the kernel line `softdog: Triggered - Reboot ignored`, and the
failover drill records how many seconds after the kill it appeared and that
the new leader holds the device. On a real host `soft_noboot` is 0 and the
reboot is the fence. All three containers see the host's one device; only the
leader opens it, which is exactly the contract.

## TLS

PostgreSQL accepts TCP connections over TLS only: every `pg_hba` rule that is
not the local socket is `hostssl`, which covers replication, PgBouncer's
server side and the drills. Each node carries a self-signed certificate the
playbook generates once.

There is no CA, so clients get encryption and not identity: `sslmode=require`,
not `verify-full`. Client-to-PgBouncer TLS and a CA are the next step.

etcd stays plain HTTP without authentication. A three-node PKI for peer and
client certificates is what a real deployment gets from its PKI; here it would
be a second self-signed setup proving nothing the first one does not.

## Monitoring

`postgres_exporter` on every database node, HAProxy's built-in exporter, and
Patroni's own `/metrics`, scraped by Prometheus on the repository host. Six
alerting rules, each tied to a claim the README makes: no leader, no
synchronous standby (zero data loss not in force), PostgreSQL down, replica
lag, WAL archiving failing, no primary behind HAProxy.

`scripts/lab.sh status` asserts every target up, every rule loaded, every
series a rule depends on present, and nothing firing. A rule over a metric
nobody exports never fires, so the series are checked explicitly. The CI
drills run it after the cluster is built.

No Alertmanager and no Grafana: the rules are the contract, routing and
dashboards are site-specific.
