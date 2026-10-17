#!/usr/bin/env bash
# Bring a hairpin-mesh ring back up after a stop or a reboot, with one command.
#   ./ring-up.sh [mesh|plain]
#   mesh  (default) = hairpin mesh + RoCEnante roce_ring   (ENV_MESH)
#   plain           = plain ring config, mesh stopped       (ENV_PLAIN)
# Run on node0 (RING_HOSTS[0]) with the engine down. Settings come from ring.env next to this script.
# Re-applies what a reboot loses: hairpin_queue_size, /32 routes, tc rules and markers (systemctl start of
# MESH_UNIT on every node; the unit is installed but not enabled), the NFS exporter containers, and the
# .env.tp4 copy. Checks what a reboot keeps: GID index 3 = IPv4 on every fabric function.
# Ends with "RING-UP OK <cfg>" only when serve is Ready and the smoke test returns 42.
# This script was written from the one we ran, generalised for publication. It has been
# syntax-checked (bash -n) but not re-run in this form.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f $here/ring.env ]] || { echo "missing $here/ring.env (copy ring.env.example)"; exit 2; }
# shellcheck disable=SC1091
source "$here/ring.env"
CFG=${1:-mesh}
case "$CFG" in mesh) ENV=$ENV_MESH ;; plain) ENV=$ENV_PLAIN ;; *) echo "usage: $0 [mesh|plain]"; exit 2 ;; esac
read -r -a HOSTS <<< "$RING_HOSTS"
HEAD=${HOSTS[0]}
on() { local h=$1; shift; if [[ $h == "$HEAD" ]]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$h" "$*"; fi; }
step() { echo "== $(date -u +%H:%M:%SZ) $*"; }

step "1/7 engine must be down"
if docker ps --format '{{.Names}}' | grep -q '^dsv41-head'; then
  echo "head container is running: run ./start-tp4.sh stop first"; exit 1
fi

step "2/7 GID index 3 = IPv4 on all fabric functions"
for h in "${HOSTS[@]}"; do
  on "$h" "for d in $RDMA_DEVS; do g=\$(cat /sys/class/infiniband/\$d/ports/1/gids/3); [[ \$g == 0000:0000:0000:0000:0000:ffff:* ]] || { echo \"\$(hostname) \$d gid3=\$g is not IPv4 (see docs/cabling-and-roles.md, GID section, and scripts/fix-gid.sh)\"; exit 1; }; done; echo \"  \$(hostname) gid3 is IPv4 on all devices\""
done

step "3/7 mesh ($CFG)"
for h in "${HOSTS[@]}"; do
  if [[ $CFG == plain ]]; then
    on "$h" "systemctl stop $MESH_UNIT; echo \"  \$(hostname) mesh stopped\""
  else
    on "$h" "systemctl start $MESH_UNIT && systemctl is-active --quiet $MESH_UNIT && n=\$(systemctl list-units '$MESH_UNIT-marker@*' --state=running --no-legend | wc -l) && [[ \$n == 2 ]] && echo \"  \$(hostname) mesh active, markers \$n\" || { echo \"  \$(hostname) mesh FAILED\"; exit 1; }"
  fi
done

step "4/7 NFS exporters"
if [[ -n ${NFS_EXPORTER_HOSTS:-} ]]; then
  for h in $NFS_EXPORTER_HOSTS; do on "$h" "docker start $NFS_CONTAINER >/dev/null"; done
  sleep 3
  if [[ -n ${NFS_CHECK_HOST:-} ]]; then
    on "$NFS_CHECK_HOST" "mkdir -p /mnt/ringcheck; mount -t nfs4 -o ro,vers=4.2 $NFS_CHECK_SERVER:/ /mnt/ringcheck && n=\$(ls /mnt/ringcheck | grep -c safetensors); umount /mnt/ringcheck; echo \"  $NFS_CHECK_HOST sees \$n safetensors\"; [[ \$n == $NFS_EXPECTED_FILES ]]"
  fi
fi

step "5/7 memory clean"
if [[ -n ${MEMCLEAN_CMD:-} ]]; then
  for h in "${HOSTS[@]}"; do on "$h" "$MEMCLEAN_CMD | tail -1 | sed \"s/^/  \$(hostname) /\""; done
else
  echo "  skipped (MEMCLEAN_CMD empty)"
fi

step "6/7 env $ENV -> .env.tp4, serve"
cd "$RECIPE_DIR"
cp -p "$ENV" .env.tp4
md5sum .env.tp4 "$ENV"
./start-tp4.sh serve > "$LOG_DIR/ring-serve-$CFG.log" 2>&1
tail -3 "$LOG_DIR/ring-serve-$CFG.log"
curl -sf http://127.0.0.1:8888/v1/models | grep -o '"max_model_len":[0-9]*'

step "7/7 smoke"
./start-tp4.sh smoke | tee "$LOG_DIR/ring-smoke-$CFG.txt" | tail -5
grep -q '"42"\|: *"42\|\b42\b' "$LOG_DIR/ring-smoke-$CFG.txt" || { echo "smoke did not return 42"; exit 1; }
echo "RING-UP OK $CFG $(date -u +%H:%M:%SZ)"
