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

## The repository in production: object storage, not a second host

`pgbackrest-repo.conf.j2` carries a commented `repo2-type=s3` block. On AWS
it is uncommented and the bucket is built the way the audit bucket is built
in the sibling platform repository (`modules/cloudtrail`, `modules/tfstate`):

- **versioning** and a lifecycle rule that expires noncurrent versions, so a
  bad backup run is one version back and the bucket does not grow forever;
- **SSE-KMS** with a rotating customer-managed key, or `repo2-cipher-type`
  when the storage offers nothing better;
- **Object Lock** in compliance mode for the retention window, or at least a
  bucket policy that denies `s3:DeleteObjectVersion`: a backup an attacker
  with the database credentials can delete is not a backup;
- **access through the hosts' IAM role** (`repo2-s3-key-type=auto`), never a
  key in a config file; the policy allows `PutObject`, `GetObject`,
  `ListBucket` and `DeleteObject` on this stanza's prefix only;
- **cross-region replication** to a second bucket, or a `repo3` in the other
  region, which is the archive's answer to losing a site.

pgBackRest writes to every configured repository on each backup and
archive-push, so `repo1` on `backup` keeps serving fast local restores while
`repo2` is the copy that survives the host. None of this runs here: a MinIO
container would prove the S3 API and nothing above, and would itself be a
single point of failure.

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
