# Results

| file | what |
|---|---|
| `ab-runs/baseline/`, `ab-runs/armB/` | sparkDash 1.8.8 raw JSON for the plain ring (baseline) and the hairpin mesh with the switch hop (armB): `warm*`, `{prose,code,structured}-c1-{1,2,3}`, `-c4-{1,2,3}`, `prefill-{warm,1,2,3}`, and `realprefill.jsonl` |
| `ab-runs/armAB/` | the adopted config, dual-PCI NCCL plus the mesh: same file set as armB |
| `ab-runs/armA/` | the dual-PCI-domain NCCL arm (no mesh), not adopted |
| `qeval-baseline-plain-ring.txt`, `qeval-armB.txt` | `qeval.py` output, 75 tasks, one run each |
| `switch-hop-test.txt` | `ib_write_lat` and tc rule counters for the cables-only path and the switch-hop path |
| `armB-smoke.txt`, `armB-kv-workers.txt` | serve time and smoke answer; KV pool size (`max_total_num_tokens=4286976`) and per-worker memory on the mesh boot |
| `armAB-smoke.txt`, `armAB-kv-workers.txt` | smoke answer and per-worker memory on the dual-PCI + mesh boot (weight load 807 s on rank 3; KV 4,327,424 tokens) |
| `acc-armAB.txt`, `qeval-armAB.txt` | draft tokens per step (3 runs per prompt type) and 3 `qeval.py` runs (71/75 each) on the dual-PCI + mesh boot |
| `armB-txmax.txt` | peak transmit rate per function over the last 6 minutes, and `enomem` |

The tables in the main README are medians of three runs. To recompute one arm's numbers: `cd results && python3 -I ../scripts/abtab.py baseline` (or `armA`, `armB`, `armAB`).
The real-text prefill prompts came from a text corpus we did not publish; `scripts/realprefill.py` takes any large text file.
Node names were replaced by node0 to node3 (rank order) and addresses removed.
