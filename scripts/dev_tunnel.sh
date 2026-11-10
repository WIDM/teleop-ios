#!/bin/bash
# Keeps the SSH tunnel from this Mac to the simulator's teleop port (8766) up, reconnecting when it drops.
# Usage: scripts/dev_tunnel.sh user@host
set -u
host="${1:?usage: dev_tunnel.sh user@host}"
while true; do
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    -L 127.0.0.1:8766:127.0.0.1:8766 "$host"
  echo "$(date '+%H:%M:%S') tunnel dropped, retrying in 3 s"
  sleep 3
done
