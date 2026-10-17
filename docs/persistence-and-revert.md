# Persistence, re-applying and reverting

## What a reboot keeps

| item | where | why it survives |
|---|---|---|
| GID index 3 = IPv4 (the fabric NetworkManager connections set to `ipv6.method disabled`) | `/etc/NetworkManager/system-connections/` | `nmcli con mod` writes the profile file; at boot the extra link-local GID is not created. **Reboot not tested; UNVERIFIED.** `ring-up.sh` checks it and stops if it is wrong. |
| `/opt/dsv41-mesh` (`hairpin.sh`, `mesh-up.sh`, `mesh-down.sh`, the marker binary) and the units `dsv41-mesh.service`, `dsv41-mesh-marker@.service` | every node | files on disk. `mesh-up.sh` is generated per node with fixed MACs and IPs and stays valid until a NIC, cable or address changes. |
| env files for the two configs | node0, in the recipe checkout | files on disk |
| the patched `plan.py` | wherever you ran the planner | only needed to regenerate `mesh-up.sh` after recabling or a NIC swap |

## What a reboot loses

| item | why | re-applied by |
|---|---|---|
| `hairpin_queue_size` 8192 on all 16 functions | devlink `driverinit` parameter, back to 1024 at boot | `dsv41-mesh.service` runs `hairpin.sh 8192` before `mesh-up.sh` |
| the `/32` routes, tc flower rules, the 2 marker processes per node | runtime state | `systemctl start dsv41-mesh` (it runs `mesh-up.sh`) |
| the NFS exporter containers, if you use them | containers do not restart on their own, and `start-tp4.sh stop` kills them | `docker start dsv41-nfs` (done by `ring-up.sh`) |

## Why the mesh unit is not enabled

`dsv41-mesh.service` is installed but we did **not** `systemctl enable` it. With the mesh up, the `/32` routes send IP traffic for the opposite node's fabric address to a neighbour, and the neighbour does not forward plain IP.
Our inference, not tested: a different workload that talks to the opposite node over those fabric addresses would break while the mesh is up. So the mesh is started on purpose, by `ring-up.sh`, and stopped for other workloads
(`ring-down.sh --mesh-off`). If your nodes only run this engine, enabling the unit is a choice you can make; the recipe's chapter does it.

## Bring up and take down

```bash
cp scripts/ring.env.example scripts/ring.env     # edit: hosts, user, paths, RDMA devices
nohup scripts/ring-up.sh mesh > ring-up.log 2>&1 &     # or: plain
scripts/ring-down.sh [--mesh-off]
```

`ring-up.sh` steps: engine-down check; GID index 3 is IPv4 on all devices of all nodes; start the mesh unit on every node and check 2 markers each; start the NFS exporters; optional memory clean;
copy the chosen env file to `.env.tp4`; `start-tp4.sh serve`; `start-tp4.sh smoke` must contain 42. Last line `RING-UP OK <cfg>`. `plain` stops the mesh unit instead (the hairpin size stays 8192 and the GID fix stays).
`ring-down.sh` stops the engine, restarts the NFS exporters (otherwise removing the worker containers hangs on the NFS mount), removes leftover `dsv41-*` containers except the exporter, and with `--mesh-off` stops the mesh unit.

Both scripts were generalised from the ones we ran (our hostnames, user, paths, addresses and a local memory-clean helper removed). They pass `bash -n`; they were not re-run in this form.

## Revert to the plain ring

1. Engine down: `scripts/ring-down.sh --mesh-off`.
2. Every node: `sudo systemctl disable --now dsv41-mesh` (removes markers, rules and routes; the unit was never enabled in our setup, so `stop` is enough there), then `/opt/dsv41-mesh/hairpin.sh 1024` (back to the driver default; re-initialises each function).
3. GID: `sudo scripts/fix-gid.sh revert` on each node you ran `apply` on (it restores `ipv6.method link-local` on the connections it changed and reloads `mlx5_ib`). Check that the GID table looks as before.
4. Env: restore the plain `.env.tp4` (`SGLANG_ROCE_ALLREDUCE=0`, no `DSV41_ROCE_RING`, no `DSV41_ROCE_GATHER`).
5. Never stop the mesh unit, a marker, or change the hairpin size while the engine is running: opposite-node traffic stops and the RoCE health check fails the step.

Reverting the GID fix is only needed if something else on the node depends on the second link-local address. We have no evidence that anything did.
