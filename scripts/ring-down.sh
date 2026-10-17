#!/usr/bin/env bash
# Take the ring down cleanly.   ./ring-down.sh [--mesh-off]
# --mesh-off also stops MESH_UNIT on every node (removes the /32 routes, tc rules and markers), for a foreign workload.
# Ends with "RING-DOWN OK" when no dsv41 container except the NFS exporter runs on any node.
# Generalised from the script we ran; syntax-checked (bash -n), not re-run in this form.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f $here/ring.env ]] || { echo "missing $here/ring.env (copy ring.env.example)"; exit 2; }
# shellcheck disable=SC1091
source "$here/ring.env"
read -r -a HOSTS <<< "$RING_HOSTS"
HEAD=${HOSTS[0]}
on() { local h=$1; shift; if [[ $h == "$HEAD" ]]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$h" "$*"; fi; }
cd "$RECIPE_DIR"
timeout 300 ./start-tp4.sh stop || echo "stop returned $? (continuing)"
# stop kills the NFS exporters; removing the worker containers then hangs on the NFS mount. Start them again first.
for h in ${NFS_EXPORTER_HOSTS:-}; do on "$h" "docker start $NFS_CONTAINER >/dev/null"; done
for h in "${HOSTS[@]}"; do
  on "$h" "for c in \$(docker ps -a --format '{{.Names}}' | grep '^dsv41-' | grep -v '^$NFS_CONTAINER\$'); do timeout 60 docker rm -f \$c >/dev/null || echo \"  \$(hostname) rm \$c failed\"; done"
done
if [[ ${1:-} == --mesh-off ]]; then
  for h in "${HOSTS[@]}"; do on "$h" "systemctl stop $MESH_UNIT; echo \"  \$(hostname) mesh \$(systemctl is-active $MESH_UNIT)\""; done
fi
bad=0
for h in "${HOSTS[@]}"; do
  l=$(on "$h" "docker ps --format '{{.Names}}' | grep '^dsv41-' | grep -v '^$NFS_CONTAINER\$'")
  if [[ -n $l ]]; then echo "  $h still running: $l"; bad=1; fi
done
if [[ -n ${MEMCLEAN_CMD:-} ]]; then
  for h in "${HOSTS[@]}"; do on "$h" "$MEMCLEAN_CMD | tail -1 | sed \"s/^/  \$(hostname) /\""; done
fi
[[ $bad == 0 ]] && echo "RING-DOWN OK $(date -u +%H:%M:%SZ)"
