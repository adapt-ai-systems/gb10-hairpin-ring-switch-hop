# Setup

Prerequisite: the recipe, with its ring chapter. We used
[our fork of knapcio's recipe](https://github.com/adapt-ai-systems/DeepSeek-V4.1-Flash-1017-4x-GB10-TP4); its `docs/switchless-ring.md` ("RoCEnante on the ring") describes the mesh install in detail.
This page lists only what differs when a node is reversed and one link crosses a switch. Run the engine **down** for steps 1 to 5.

Below, `RECIPE` is a checkout of the recipe on node0, and the nodes are node0 to node3 as in [cabling-and-roles.md](cabling-and-roles.md).

1. **Cabling and addresses.** Each link has its own /24 per PCI domain, MTU 9000, as in cabling-and-roles.md. Test every link with `ib_write_bw` before anything else.
   The NIC profile (`hairpin_num_queues` 4, `flow_steering_mode` `hmfs`, eswitch `legacy`, `hw-tc-offload on`) must be set on all 16 functions.

2. **Inventory.** `RECIPE/scripts/ring_mesh/inventory.sh` on a node prints, per netdev: link state, IPv4, MTU, GID index 3, TC offload, steering mode. Read it for all four nodes.

3. **GID index 3.** On each node that shows a GID index 3 that is not `0000:...:ffff:<ipv4>`:

   ```bash
   sudo scripts/fix-gid.sh check
   sudo scripts/fix-gid.sh apply enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1   # list the netdevs whose GID 3 is wrong
   ```

   `apply` changes only connections that have `ipv6.method=link-local`, and it reloads `mlx5_ib`, which breaks every RDMA connection on the node (the engine must be down).
   It also bounces the link of each changed connection for a few seconds.

4. **The marker**, built on every node from a sparkring checkout at `f16b5f4` (as in the recipe's chapter):

   ```bash
   git clone https://github.com/FujitsuPolycom/sparkring ~/sparkring && git -C ~/sparkring checkout f16b5f4
   sudo install -d /opt/dsv41-mesh/bin
   cc -O2 -Wall -Wextra ~/sparkring/spark_transport/fabric/cx7_hairpin_diagonal/native/mlx5_rdma_tx_rewrite_probe.c \
      -o /tmp/mlx5-rdma-tx-rewrite-probe -libverbs -lmlx5 && sudo install -m 755 /tmp/mlx5-rdma-tx-rewrite-probe /opt/dsv41-mesh/bin/
   ```

5. **The patched planner.** In the recipe checkout on node0:

   ```bash
   git -C RECIPE apply /path/to/this-repo/patches/plan.py.diff     # applies to scripts/ring_mesh/plan.py at 27616be
   cd RECIPE
   MESH_REVERSED_HOSTS=node1 python3 scripts/ring_mesh/plan.py --sparkring ~/sparkring --out ring-mesh node0 node1 node2 node3
   ```

   The hosts are the SSH names in TP rank order. `MESH_REVERSED_HOSTS` takes the SSH names of the nodes whose roles are swapped (here the one whose switch-side port is its physical f0). Without it the planner refuses this ring.
   Check that the printed ring order is node0, node3, node2, node1. The planner writes `mesh-up-<host>.sh`, `mesh-down-<host>.sh` and `env.txt`.

   `plan.py` takes the RoCE size cap from the hairpin queue size it finds. At the driver default (1024) it emits a safe 81,920-byte cap. If you want the 262,144-byte cap, set the queue size to 8192
   first (step 6) and run the planner a second time.

6. **Install on every node** (hairpin sizing re-initialises each fabric function, so the engine must be down):

   ```bash
   sudo install -m 755 ring-mesh/mesh-up-$HOST.sh   /opt/dsv41-mesh/mesh-up.sh
   sudo install -m 755 ring-mesh/mesh-down-$HOST.sh /opt/dsv41-mesh/mesh-down.sh
   sudo install -m 755 scripts/ring_mesh/hairpin.sh /opt/dsv41-mesh/
   sudo install -m 644 scripts/ring_mesh/dsv41-mesh.service scripts/ring_mesh/dsv41-mesh-marker@.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl start dsv41-mesh        # start, not enable: see persistence-and-revert.md
   ```

7. **Verify the path** before you boot the engine.
   - Every rule shows `in_hw`: `tc -s filter show dev <netdev> ingress`.
   - Test the switch leg: from node2 to node0 (through node1), `ib_write_lat -d <dev> -x 3 --flow_label=16383 ...` with the flow label on **both** sides, then look at the rule counters on node1 and `nstat IpForwDatagrams` on node1.
     The counters must rise, `Sent software` must stay 0, `IpForwDatagrams` must stay flat. Our numbers are in [results/switch-hop-test.txt](../results/switch-hop-test.txt).
   - Test one all-DAC opposite path the same way as a control (we used node3 to node1 via node0).

8. **Environment.** Append `env.txt` to `EXTRA_CONTAINER_ENV` in the recipe's `.env.tp4`, and remove `SGLANG_ROCE_ALLREDUCE=0`. On our ring `env.txt` was:

   ```
   DSV41_ROCE_RING=1 SGLANG_ROCE_ALLREDUCE=1 SGLANG_ROCE_MAX_SIZE=262144 DSV41_ROCE_GATHER=262144
   B12X_ROCE_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1
   B12X_ROCE_PEER_HCA_MAPS=1=1/3,2=0/3,3=0/2;0=1/3,2=0/2,3=0/3;0=1/2,1=0/2,3=1/3;0=1/3,1=0/3,2=0/2
   B12X_ROCE_TWO_WAVE_THRESHOLD_BYTES=0
   ```

   (one line in the env file). The peer maps depend on your ring; use the ones your planner writes. Build the recipe's `Dockerfile.canary-roce` image as usual. The boot log should show
   `RoCEnante ready: world=4 hcas=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 gid_index=3`. Ours did, with `max_size=262144`.

9. **Serve and smoke.** `./start-tp4.sh serve`, then `./start-tp4.sh smoke`; it should answer 42. On our mesh boot serve took 411 s from `serve` to Ready (the plain ring boot took 543 s; boots vary).

`scripts/ring-up.sh` does steps 3-check, mesh start, serve and smoke in one command once everything is installed. See [persistence-and-revert.md](persistence-and-revert.md).
