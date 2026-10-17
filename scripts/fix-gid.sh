#!/usr/bin/env bash
# Make RoCEv2 GID index 3 the IPv4 GID on this node's fabric functions.
#   fix-gid.sh check
#   fix-gid.sh apply  <netdev> [<netdev> ...]
#   fix-gid.sh revert
# Run ON each node, as root, with the engine DOWN (apply reloads mlx5_ib).
# Cause: when a fabric NetworkManager connection has ipv6.method=link-local, the port gets a second fe80
# address, and it takes GID index 3 and pushes the IPv4 GID to index 4. The mesh planner (plan.py) and
# the RoCEnante ring code read GID index 3. With ipv6.method=disabled index 3 is the IPv4 GID.
# apply  : for each given netdev whose connection is ipv6.method=link-local, set it to disabled, bring it up,
#          then `modprobe -r mlx5_ib && modprobe mlx5_ib`. The changed connections are remembered in STATE.
# revert : set the remembered connections back to link-local, bring them up, reload mlx5_ib.
# We ran these nmcli/modprobe commands by hand on four nodes (16 functions, 11 needed the change, all 16 then
# had the IPv4 GID at index 3). This wrapper script has been syntax-checked (bash -n) but not run as written.
# Reboot persistence of the change was NOT tested.
set -euo pipefail
STATE=${STATE:-/var/lib/ring-gid-fix.txt}
conn_of() { nmcli -g GENERAL.CONNECTION device show "$1"; }
reload_ib() { modprobe -r mlx5_ib && modprobe mlx5_ib; sleep 5; }
check() {
  for d in /sys/class/infiniband/*; do
    n=$(basename "$d"); g=$(cat "$d/ports/1/gids/3" 2>/dev/null || echo "-")
    if [[ $g == 0000:0000:0000:0000:0000:ffff:* ]]; then echo "$n gid3 IPv4  ($g)"; else echo "$n gid3 NOT IPv4 ($g)"; fi
  done
}
case "${1:-}" in
  check) check ;;
  apply)
    shift; [[ $# -ge 1 ]] || { echo "usage: $0 apply <netdev> ..."; exit 2; }
    : > "$STATE"
    for nd in "$@"; do
      c=$(conn_of "$nd"); [[ -n $c && $c != "--" ]] || { echo "$nd: no active NetworkManager connection"; continue; }
      m=$(nmcli -g ipv6.method connection show "$c")
      if [[ $m == link-local ]]; then
        nmcli connection modify "$c" ipv6.method disabled && nmcli connection up "$c" >/dev/null
        echo "$c" >> "$STATE"; echo "$nd ($c): link-local -> disabled"
      else
        echo "$nd ($c): ipv6.method=$m, unchanged"
      fi
    done
    reload_ib; check ;;
  revert)
    [[ -s $STATE ]] || { echo "nothing to revert ($STATE empty or missing)"; exit 0; }
    while read -r c; do nmcli connection modify "$c" ipv6.method link-local && nmcli connection up "$c" >/dev/null; echo "$c: disabled -> link-local"; done < "$STATE"
    reload_ib; check ;;
  *) echo "usage: $0 check | apply <netdev>... | revert"; exit 2 ;;
esac
