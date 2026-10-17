# Cabling and port roles

## The layout we ran

Four GB10 nodes, named node0 to node3 here. Node0 is the head (TP rank 0). Node0 and node3 are Acer GN100; node1 and node2 are DGX Spark.
Each node has two physical QSFP ports, and each port shows up as two netdevs and two RDMA devices (one per PCI domain), so a node has four RDMA functions.
In the recipe's naming: `enp1s0f0np0` / `rocep1s0f0` and `enP2p1s0f0np0` / `roceP2p1s0f0` are physical port 0 (function f0, domain 0 and 2);
`enp1s0f1np1` / `rocep1s0f1` and `enP2p1s0f1np1` / `roceP2p1s0f1` are physical port 1 (f1).

```
node0 --DAC-- node3 --DAC-- node2 --SWITCH-- node1 --DAC-- node0
```

Three links are direct cables. The link between node2 and node1 goes through a switch. Ring order is node0, node3, node2, node1. TP rank order is node0, node1, node2, node3.
Opposite pairs are node0/node2 and node3/node1.

## What the mesh needs

The recipe's planner (`scripts/ring_mesh/plan.py`, from knapcio's recipe at `27616be`) follows sparkring's convention: every node's f0 ports are the "clockwise" outputs and must be cabled
to the **next** node's f1 ports, on the same PCI domain. It refuses anything else, with a message like
`node2 enp1s0f0np0 reaches node1 enp1s0f0np0; sparkring needs every f0 port cabled to the next node's f1 port`.

Our cabling had two f0-to-f0 / f1-to-f1 links: node2 f0 to the switch to node1 f0, and node1 f1 to node0 f1. The options without the software swap were to move cables
(the node1-node0 cable to node1's port 0, and the switch hop replaced by a direct cable) or to run the plain ring.

## The software swap

Treat node1 as **reversed**: for node1 only, clockwise means physical f1 and counter-clockwise means physical f0. With that, the orientation the planner checks becomes
node0 f0 -> node3 f1, node3 f0 -> node2 f1, node2 f0 -> (switch) node1 logical f1 = physical f0, node1 logical f0 = physical f1 -> node0 f1. Every check passes.

[`patches/plan.py.diff`](../patches/plan.py.diff) adds that to the planner: an environment variable `MESH_REVERSED_HOSTS` (comma-separated SSH names; empty by default, so unreversed behaviour is unchanged)
and a helper `port_of(host, direction, f)` used in `ring_order()` and `topology()`. Nothing else in the planner changed.

Why that is enough, from reading the sources (and then confirmed by the test below):

- sparkring's fabric planner takes netdev and RDMA device as free per-rank data and checks only logical direction and function reciprocity. Nothing in it ties f1 to receive or f0 to transmit.
- `hairpin.sh` sets the queue size on all four functions the same way, and the marker runs per RDMA device, with no direction.
- RoCEnante's `roce_ring` in the recipe's image checks for the canonical peer map (f0 = clockwise on every rank) only when `B12X_ROCE_OPPOSITE_PATHS=4` or a non-default wave mode is set.
  With the recipe's setting (two opposite paths, `B12X_ROCE_TWO_WAVE_THRESHOLD_BYTES=0`) the check does not apply. **Do not set `B12X_ROCE_OPPOSITE_PATHS=4` or `B12X_ROCE_WAVE_MODE` with a reversed node.**
  (This was read from the image source, `_roce_proxy.c`; it is why the setting matters. We did not test the failing case.)

The planner then produced, for our ring, the peer maps `1=1/3,2=0/3,3=0/2;0=1/3,2=0/2,3=0/3;0=1/2,1=0/2,3=1/3;0=1/3,1=0/3,2=0/2` (rank 0 first).

## Addressing

The planner infers a link from "exactly two inventoried ports on one /24". Give each cable's two netdevs (domain 0 and domain 2) their own /24 each.
The switch hop is also two /24s (one per PCI domain) with only node2 and node1 on them among the four nodes. Other machines may share the switch network, because the planner only looks at the four nodes you give it.
`inventory.sh` takes the **first** IPv4 address of each netdev. If a netdev has two addresses, the ring one must be first.

Placeholder example, not our real addresses:

| link | domain 0 | domain 2 |
|---|---|---|
| node0 - node3 | 10.50.1.0/24 | 10.60.1.0/24 |
| node3 - node2 | 10.50.2.0/24 | 10.60.2.0/24 |
| node2 - node1 (switch) | 10.50.3.0/24 | 10.60.3.0/24 |
| node1 - node0 | 10.50.4.0/24 | 10.60.4.0/24 |

MTU 9000 on all 16 functions. The NIC profile sparkring qualified for the hardware forwarding must be set on all of them: `hairpin_num_queues` 4, `flow_steering_mode` `hmfs`, eswitch `legacy`, `hw-tc-offload on`.
`inventory.sh` prints all of this; `plan.py` refuses a node that does not match.

## The switch hop

What goes over the wire (from sparkring's README and the recipe's chapter): the sender's NIC changes the EtherType of RDMA packets of the opposite-node queue pairs from 0x0800 to 0x88b5; a `/32` route sends them to the
neighbour's MAC; on the neighbour a `skip_sw` tc flower rule restores 0x0800, rewrites the destination MAC and redirects the packet out of its other port. The source MAC stays the origin's.
With a switch between two nodes, those frames (unicast to a real port MAC, EtherType 0x88b5) cross the switch.

What we observed (results/switch-hop-test.txt): the hairpin rule on the neighbour matched 32,001 frames, all in hardware, with `Sent software 0`, and `IpForwDatagrams` stayed flat. So a plain L2 switch
forwarded the 0x88b5 frames and the forwarding on the node stayed in hardware. Latency (`ib_write_lat`, 61,440 B, 2,000 iterations, typical):

| path | latency |
|---|---:|
| direct neighbour, cables only, no flow label | 8.41 us |
| opposite node through a neighbour, cables only (node3 to node1 via node0) | 10.12 us |
| opposite node through the switch hop (node2 to node0 via node1) | 11.48 us |

One run each. The switch added about 1.4 us. Our first attempt moved no rule counters; the retest sets `--flow_label=16383` on **both** sides (the flow label is how the marker recognises the opposite-node queue pairs).

Not known: the switch model and its settings are not described here, and we did not test a switch with an EtherType filter or ACL (a filter on EtherType 0x88b5 would stop the marked frames; we did not try one).
We did not test packet loss over the switch under heavy load beyond the benchmark runs. `enomem` stayed 0.

## GID index 3

The planner and the RoCEnante ring code read the RoCEv2 GID at **index 3** and need it to be the port's IPv4 GID. On our nodes, 11 of 16 fabric functions had a second IPv6 link-local address at index 3
(GID 0 and 1 are the EUI-64 link-local, 2 and 3 a second NetworkManager link-local, 4 and 5 the IPv4). The ports where NetworkManager had `ipv6.method=disabled` already had the IPv4 GID at index 3, and
the 11 bad ports were exactly the fabric connections with `ipv6.method=link-local`.

Fix, engine down: set `ipv6.method disabled` on those connections, bring them up, then `modprobe -r mlx5_ib && modprobe mlx5_ib`. After it, index 3 was the IPv4 GID on all 16 functions.
[`scripts/fix-gid.sh`](../scripts/fix-gid.sh) wraps those commands (apply, check, revert). Alternatively `NCCL_IB_GID_AUTO=1` lets NCCL find the index, but the mesh planner still requires index 3.
