#!/usr/bin/env bash
# Post-start setup for running unitree_rl_lab inside the Isaac Lab container.
# Run this ON THE HOST after `container.py start` (or `docker start isaac-lab-base`).
# Idempotent — safe to re-run.
set -euo pipefail

CONTAINER=${CONTAINER:-isaac-lab-base}
ISAACLAB_DOCKER=${ISAACLAB_DOCKER:-$HOME/IsaacLab/docker}
REPO_HOST=${REPO_HOST:-$HOME/unitree_rl_lab}
REPO_CTR=/workspace/unitree_rl_lab
CTR_UID=166535   # container uid 1000 as seen by the host under rootless Docker

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

say "container"
if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" != running ]; then
    docker start "$CONTAINER" >/dev/null
fi
docker exec "$CONTAINER" test -d "$REPO_CTR" \
    || { echo "!! $REPO_CTR not mounted. Recreate the container with:"
         echo "   cd $ISAACLAB_DOCKER && ./container.py start base --files ../../unitree_rl_lab/docker/docker-compose.isaaclab.yaml"
         exit 1; }
echo "running, repo mounted"

say "acl (host <-> container write access on the bind mount)"
setfacl -R -m "u:1001:rwX,u:${CTR_UID}:rwX" "$REPO_HOST" 2>/dev/null || true
find "$REPO_HOST" -type d -exec setfacl -d -m "u:1001:rwX,u:${CTR_UID}:rwX" {} + 2>/dev/null || true
echo "ok"

say "python package (lives in the container's writable layer -> re-run after every recreate)"
docker exec "$CONTAINER" /isaac-sim/python.sh -m pip install -q -e "$REPO_CTR/source/unitree_rl_lab/"
docker exec "$CONTAINER" /isaac-sim/python.sh -m pip show unitree_rl_lab | sed -n '1,2p;/^Location/p'

say "x11"
if [ -n "${DISPLAY:-}" ]; then
    # 1. XWayland creates the socket 0775; container uid 1000 is "other" and cannot connect.
    #    DISPLAY may be ":0" or ":0.0" -- take the display number only, never the path.
    disp="${DISPLAY#*:}"          # "0" or "0.0"
    disp="${disp%%.*}"            # "0"
    sock="/tmp/.X11-unix/X${disp}"
    if [ -S "$sock" ]; then
        chmod 0777 "$sock" 2>/dev/null && echo "$sock -> 0777" \
            || echo "!! cannot chmod $sock (owned by another user?); GUI may fail"
    else
        echo "!! no X socket at $sock"
    fi
    # 2. the xauth cookie is 0600 root-owned inside the container -> copy it for uid 1000
    docker exec -u 0 "$CONTAINER" bash -lc \
        'install -m600 -o1000 -g1000 "$XAUTHORITY" /tmp/isaaclab.xauth' 2>/dev/null \
        && echo "cookie -> /tmp/isaaclab.xauth  (run GUI with: -e XAUTHORITY=/tmp/isaaclab.xauth)" \
        || echo "!! cookie copy failed; re-run 'container.py start' to regenerate the xauth file"
else
    echo "no DISPLAY"
fi

say "done"
cat <<'TXT'
Enter the container:
  docker exec -it -e XAUTHORITY=/tmp/isaaclab.xauth -w /workspace/unitree_rl_lab isaac-lab-base bash
Then:
  ./unitree_rl_lab.sh -l
  ./unitree_rl_lab.sh -t --task Unitree-G1-29dof-Velocity
TXT
