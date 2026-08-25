#!/usr/bin/env bash
#
# Build and run the sitl_drone environment container.
#
#   ./run.sh          — build image (if needed) + start detached container
#   ./run.sh shell    — open an interactive shell in the running container
#   ./run.sh check    — run the repo's --check inside the container
#   ./run.sh stop     — stop and remove the container
#
# Repos are bind-mounted from the host (~/ardupilot, ~/ardupilot_gazebo,
# ~/Projects/sitl_drone) so sources, patches, venv, and build artifacts
# persist on the host and stay usable by host-side agents.
#
set -euo pipefail

IMAGE="sitl_drone:latest"
NAME="sitl_drone"

do_build() {
    docker build -t "$IMAGE" "$(dirname "$0")"
}

do_run() {
    docker build -t "$IMAGE" "$(dirname "$0")" || true
    docker run -d --name "$NAME" \
        --network host \
        -v "$HOME/ardupilot:/home/rusik/ardupilot" \
        -v "$HOME/ardupilot_gazebo:/home/rusik/ardupilot_gazebo" \
        -v "$(dirname "$0")/..:/workspace/sitl_drone" \
        -v sitl_drone-ccache:/home/rusik/.ccache \
        -w /home/rusik \
        "$IMAGE"
}

case "${1:-run}" in
    build) do_build ;;
    run)
        if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
            echo "container '$NAME' already exists — use './run.sh shell'"
        else
            do_run
        fi
        ;;
    shell)
        docker exec -it "$NAME" bash -l
        ;;
    check)
        docker exec -it "$NAME" bash -lc \
            'source ~/ardupilot/venv-ardupilot/bin/activate 2>/dev/null; /workspace/sitl_drone/scripts/setup_env.sh --check'
        ;;
    stop)
        docker rm -f "$NAME"
        ;;
    *) echo "usage: $0 [build|run|shell|check|stop]" >&2; exit 1 ;;
esac
