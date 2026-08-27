#!/usr/bin/env bash
#
# Open Gazebo and LEAVE IT OPEN so a camera angle can be found by hand.
#
# record_demo.sh is the wrong tool for this: it traps EXIT and kills Gazebo when
# the flight ends, so the window you are trying to aim disappears out from under
# you after about ninety seconds.
#
# Usage, from a terminal on the machine's desktop (needs a real DISPLAY):
#     docker exec -it sitl_drone /workspace/sitl_drone/scripts/tune_camera.sh
#
# Then:
#   * orbit with left-drag, pan with middle-drag, zoom with the wheel
#   * when the view looks right, in ANOTHER terminal:
#         docker exec sitl_drone /workspace/sitl_drone/scripts/camera_pose.sh
#   * paste the printed <camera_pose> into a docker/gz/*.config, or pass the
#     CAM_POSE="..." line to record_demo.sh
#
# Ctrl-C here when done.
#
set -euo pipefail

REPO=/workspace/sitl_drone
WORLD="${WORLD:-iris_runway.sdf}"
GUI_CFG="${GUI_CFG:-$REPO/docker/gz/gui-crash-above.config}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ -z "${DISPLAY:-}" ]]; then
    cat >&2 <<'EOF'
No DISPLAY.

Mouse control needs a real screen, so run this from a terminal on the machine's
desktop. If the container was created without the X mounts, recreate it from a
desktop session first:

    cd ~/Projects/sitl_drone/docker && ./run.sh stop && ./run.sh run
EOF
    exit 1
fi

log "world:  $WORLD"
log "config: $GUI_CFG"
log "opening Gazebo on $DISPLAY — it stays open until you Ctrl-C"
echo
echo "  orbit: left-drag   pan: middle-drag   zoom: wheel"
echo "  read the pose back with:  docker exec sitl_drone $REPO/scripts/camera_pose.sh"
echo

exec gz sim -v2 -r --gui-config "$GUI_CFG" "$WORLD"
