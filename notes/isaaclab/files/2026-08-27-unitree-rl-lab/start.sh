#!/usr/bin/env bash
# Start (or recreate) the Isaac Lab container WITH the unitree_rl_lab mounts, then set it up.
# Run this ON THE HOST. Use this instead of `container.py start` -- plain `container.py start`
# recreates the container from IsaacLab's compose file alone and silently drops the
# /workspace/unitree_rl_lab and /workspace/unitree_model mounts (and the pip install with them).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISAACLAB_DOCKER=${ISAACLAB_DOCKER:-$HOME/IsaacLab/docker}
CONTAINER=${CONTAINER:-isaac-lab-base}

if [ -n "${WORKSPACE:-}" ] || [ -d /workspace/isaaclab ]; then
    echo "!! You appear to be INSIDE the container (no docker CLI here). Exit first, then run this on the host."
    exit 1
fi

cd "$ISAACLAB_DOCKER"
./container.py start base --files "${REPO}/docker/docker-compose.isaaclab.yaml"
exec "${REPO}/docker/setup_container.sh"
