# Hairpin mesh through one switch hop on a 4-node GB10 ring

Four GB10 nodes (two NVIDIA DGX Spark, two Acer GN100) in a tensor-parallel ring, where **one of the four ring links goes through a
switch instead of a direct cable**. We ran sparkring's hardware-forwarded "hairpin" mesh over that ring, so the opposite-node
RoCEnante paths work and one of the forwarded legs crosses the switch. No cable was moved: one node's two ring ports are
swapped **in software**.

This repository is the recipe, the scripts and the raw numbers. It was measured on DeepSeek-V4.1-Flash-1017, TP4, using
[knapcio's TP4 recipe](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4) through [our fork for the 1017 weights](https://github.com/adapt-ai-systems/DeepSeek-V4.1-Flash-1017-4x-GB10-TP4).
We found no public report of the hairpin mesh crossing a switch hop. That is a statement about what we found, not a claim that nobody has done it.

## What is here

| Path | What |
|---|---|
| [docs/cabling-and-roles.md](docs/cabling-and-roles.md) | The layout, why the stock planner refuses it, the software port-role swap, the GID index 3 problem |
| [docs/setup.md](docs/setup.md) | Step by step: GID fix, marker build, patched planner, install, verify, env |
| [docs/persistence-and-revert.md](docs/persistence-and-revert.md) | What a reboot keeps and loses, the one-command bring-up, how to go back |
| [patches/plan.py.diff](patches/plan.py.diff) | 4 hunks for `scripts/ring_mesh/plan.py` of the recipe at `27616be` (adds `MESH_REVERSED_HOSTS`) |
| [scripts/](scripts/) | `fix-gid.sh`, `ring-up.sh`, `ring-down.sh`, `ring.env.example`, `realprefill.py`, `abtab.py` |
| [results/](results/) | Raw A/B runs, the switch-hop test, qeval, boot logs |

## Result

DeepSeek-V4.1-Flash-1017, TP4, decode k=5, same weights, same image, same day. Baseline = the plain switchless-ring configuration
(NCCL carries the collectives, RoCEnante off). Mesh = hairpin mesh with one switch hop, RoCEnante `roce_ring` on.
Tool: sparkDash 1.8.8, 256 new tokens, temperature 0. Every number is the **median of 3 runs** of that cell. Raw files: [results/ab-runs/](results/ab-runs/).

| decode, tok/s | baseline | mesh | change |
|---|---:|---:|---:|
| code, 1 stream | 122.87 | 133.68 | +8.8 % |
| structured, 1 stream | 138.54 | 151.97 | +9.7 % |
| prose, 1 stream | 68.21 | 84.29 | +23.6 % (see caveat 1) |
| code, 4 streams, aggregate | 235.21 | 246.95 | +5.0 % |
| structured, 4 streams, aggregate | 164.31 | 193.62 | +17.8 % (runs: 176.8 / 193.6 / 201.6, noisy) |
| prose, 4 streams, aggregate | 154.21 | 174.32 | +13.0 % |

Prefill (tok/s, median of 3; the filler is one repeated token, the real-text prompts are unique documentation and source code):

| prompt | baseline | mesh | change |
|---|---:|---:|---:|
| filler 8k | 4,671 | 4,445 | -4.8 % |
| filler 32k | 5,140 | 5,035 | -2.0 % |
| real text 8k | 4,030 | 3,877 | -3.8 % |
| real text 32k | 4,634 | 4,650 | +0.3 % |

The mesh does not speed up prefill. Prefill runs its large collectives over NCCL, which the mesh does not change.

Quality check, `qeval.py` (75 auto-scored tasks, 1 stream, temperature 0), single run each: baseline **72/75**, median 77.03 tok/s; mesh **71/75**, median 84.99 tok/s.
Failed tasks: baseline `code_interval_intersect`, `json_escape`, `math_m9`; mesh the same three plus `json_count` (11 instead of 10).
One run each cannot tell a one-task difference from noise. See [results/](results/).

Link test (`ib_write_lat`, 61,440 B, 2,000 iterations, typical latency, one run each): direct neighbour 8.41 us; opposite node through a neighbour over cables only 10.12 us;
opposite node through the **switch** hop 11.48 us. The neighbour's tc rule matched 32,001 packets in hardware, `Sent software 0`, and `IpForwDatagrams` stayed flat
(10 to 14 during background traffic). Raw: [results/switch-hop-test.txt](results/switch-hop-test.txt).

### Caveats

1. **Prose, 1 stream is one greedy prompt.** The mesh changes the reduction order, so that prompt produces a different text and a different speculative-decoding acceptance.
   Part of the +23.6 % can be that. We did not record per-step time, so we cannot split speed from acceptance. Code and structured, 1 stream (+8.8 % and +9.7 %) are the better signal, and
   even they carry that effect. The recipe's own documentation reports prose with 1 stream moving in the other direction on its direct-cable ring.
2. One hardware set, one model, one day. Baseline and mesh are separate boots; the KV pool was 4,198,912 tokens on the baseline boot and 4,286,976 on the mesh boot (it varies by boot).
3. A third arm, dual-PCI-domain NCCL only (no mesh), was **not adopted**: decode within 1.4 % of baseline, prefill noisy (filler 8k 4,409, 32k 5,416), KV pool 3,240,448. Its raw runs are in [results/ab-runs/armA/](results/ab-runs/armA/).
4. We measured peak transmit (1-second samples, last 6 minutes of the mesh boot) of about 31 Gb/s on one function per node, and `enomem` stayed 0 ([results/armB-txmax.txt](results/armB-txmax.txt)).
5. The reboot persistence of the GID fix was **not tested** (see [docs/persistence-and-revert.md](docs/persistence-and-revert.md)). `ring-up.sh`, `ring-down.sh` and `fix-gid.sh` were syntax-checked with `bash -n`; they are generalised from scripts we ran
   and were not re-run in this form.
6. The mesh is sparkring's, and its authors label it research-only. A switch hop is outside what they describe. It worked for us; read the licence and the status label before you build on it.

## Related

- [adapt-ai-systems/gb10-switch-ring-hybrid](https://github.com/adapt-ai-systems/gb10-switch-ring-hybrid): a different setup (two boxes on a switch, two on direct cables, the gr8 engine relays the diagonal pair). This repository is the SGLang / hairpin-mesh way.
- [knapcio's recipe](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4) and its chapter `docs/switchless-ring.md` (the mesh setup this builds on); [sparkring](https://github.com/FujitsuPolycom/sparkring) (the mesh).
- Pull requests on knapcio's repository for the same ideas: [#12](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4/pull/12) (`--reversed HOST`, a command-line option; we ran the environment-variable patch here),
  [#13](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4/pull/13) (one mesh hop across a plain L2 switch), [#14](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4/pull/14) (preflight accepts a different GID index per port),
  [#15](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4/pull/15) (link-local IPv6 taking GID index 3).

## Licence

Documentation, scripts and results: MIT ([LICENSE](LICENSE)). `patches/plan.py.diff` changes an AGPL-3.0 file and stays AGPL-3.0-or-later ([LICENSES/AGPL-3.0.txt](LICENSES/AGPL-3.0.txt)). See [NOTICE](NOTICE).
