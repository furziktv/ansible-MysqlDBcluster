# MySQL Replication + Orchestrator acceptance tests

Run only on disposable/test VMs with no user data. Record executed and executed-retrieved GTID sets before and after each test. Verify exactly one writable node and VIP ownership at every step. These cases are required before calling the topology production-ready.

## Baseline

1. Run `playbooks/healthcheck.yml`; require all three MySQL containers healthy.
2. On each node, inspect `SHOW REPLICA STATUS\G`, `@@global.read_only`, and `@@global.super_read_only`. The primary has no source and is writable; both replicas point to the primary with both threads running and are read-only.
3. Query Orchestrator API `/api/cluster/alias/production-mysql`. It must show all expected nodes, a single current root and recent valid observations.
4. Confirm the VIP is present on exactly the writable root and accepts a test write on port 3306. Verify read-only nodes reject writes.

## Primary process failure

1. Record GTIDs, then stop only the primary's MySQL container.
2. Confirm Orchestrator detects the failure and promotes only one eligible replica. Check the other replica re-parents to the promoted node.
3. Confirm Keepalived removes the VIP from the failed host and assigns it only to the new writable root. Write through VIP:3306 and verify the row on both replicas.
4. Restart the former primary. It must not claim the VIP while stale/read-only. Verify it rejoins beneath the new primary and catches up before considering a controlled return.

## Orchestrator/Raft failure

1. Stop one Orchestrator member. With two of three members remaining, observe API and VIP behavior; there must still be at most one VIP and one writable primary.
2. Stop a second member. The Keepalived check should fail closed where current topology cannot be confirmed. Confirm the existing MySQL writer behavior and client endpoint failure are understood; do not force a second promotion.
3. Restore members and verify Raft state converges without losing the discovered topology.

## Network partition / split-brain gate

On an isolated test network, block MySQL replication between the old primary and both replicas while leaving the old primary reachable by clients. Separately block Orchestrator/Raft paths. Observe whether the old primary remains writable, whether Orchestrator promotes, and whether Keepalived can expose multiple or stale writers. The current system has no external STONITH/power fencing, so a topology that permits two writable nodes fails acceptance; do not deploy it for production writes until fencing or equivalent quorum-safe design is added and retested.

## Replica and restore checks

1. Stop one replica; primary writes must continue and the other replica remains current.
2. Restart the stopped replica and verify GTID auto-position catch-up.
3. Test a rebuild from a verified backup separately. Never use `RESET REPLICA`, clone, delete, or reparent against a node with uncertain GTID state without a backup and explicit operator review.
