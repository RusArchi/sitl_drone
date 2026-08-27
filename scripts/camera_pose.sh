#!/usr/bin/env bash
#
# Print the Gazebo GUI camera's current pose as a ready-to-paste <camera_pose>.
#
# Workflow for setting a camera angle by hand:
#   1. Bring the sim up with the GUI on your desktop:
#        docker exec -e VISIBLE=1 -e FLIGHT=fly_fail.py sitl_drone \
#            /workspace/sitl_drone/scripts/record_demo.sh
#      (or just run `gz sim -r iris_runway.sdf` in the container)
#   2. Fly the view where you want it with the mouse.
#   3. Run this script. It prints the pose in SDF order.
#   4. Either paste that line into a docker/gz/*.config, or pass it straight to
#      the recorder:  CAM_POSE="22 -14 22 0 0.71 2.28" ./record_demo.sh
#
# Run INSIDE the container:  docker exec sitl_drone /workspace/sitl_drone/scripts/camera_pose.sh
#
set -euo pipefail

# Gazebo publishes position + an orientation QUATERNION, but <camera_pose> wants
# roll/pitch/yaw in radians, so it has to be converted.
timeout "${TIMEOUT:-8}" gz topic -e -t /gui/camera/pose 2>/dev/null \
  | head -12 \
  | python3 "$(dirname "$0")/_camera_pose.py"
