#!/usr/bin/env bash
# TensorBoard for the training logs, reachable from the HOST browser.
#
# Why a separate container: isaac-lab-base runs with `network_mode: host`, which under
# rootless Docker is rootlesskit's own netns -- ports opened in it are NOT reachable from
# the host. A throwaway container on the default bridge network with -p works fine.
# The logs are on a bind mount, so this container only needs to read the host directory.
#
#   ./docker/tensorboard.sh          -> http://localhost:6006
#   PORT=6007 ./docker/tensorboard.sh
set -euo pipefail

PORT=${PORT:-6006}
LOGDIR=${LOGDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs}
IMAGE=${IMAGE:-isaac-lab-base}

[ -d "$LOGDIR" ] || { echo "no logs yet at $LOGDIR"; exit 1; }
echo "serving $LOGDIR on http://localhost:${PORT}  (Ctrl-C to stop)"

# --entrypoint is required: the image's ENTRYPOINT is /isaac-sim/runheadless.sh, which
# would swallow the arguments and try to launch Kit instead of python.
exec docker run --rm --name "unitree-tensorboard-${PORT}" \
    -e ACCEPT_EULA=Y \
    -p "${PORT}:${PORT}" \
    -v "${LOGDIR}:/logs:ro" \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" -m tensorboard.main --logdir /logs --host 0.0.0.0 --port "${PORT}"
