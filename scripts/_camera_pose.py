#!/usr/bin/env python3
"""Convert Gazebo's /gui/camera/pose output into an SDF <camera_pose> line.

Gazebo publishes position plus an orientation QUATERNION, but <camera_pose>
wants roll/pitch/yaw in radians, so a conversion is needed. Reads the topic
dump on stdin.
"""
import math
import re
import sys

text = sys.stdin.read()


def grab(block, key):
    m = re.search(block + r"\s*\{([^}]*)\}", text, re.S)
    if not m:
        return None
    v = re.search(key + r":\s*(-?[0-9.eE+-]+)", m.group(1))
    return float(v.group(1)) if v else None


px, py, pz = (grab("position", k) for k in "xyz")
qx, qy, qz, qw = (grab("orientation", k) for k in ("x", "y", "z", "w"))

if None in (px, py, pz, qx, qy, qz, qw):
    sys.exit("no camera pose on /gui/camera/pose -- is the Gazebo GUI running?")

roll = math.atan2(2 * (qw * qx + qy * qz), 1 - 2 * (qx * qx + qy * qy))
pitch = math.asin(max(-1.0, min(1.0, 2 * (qw * qy - qz * qx))))
yaw = math.atan2(2 * (qw * qz + qx * qy), 1 - 2 * (qy * qy + qz * qz))

pose = f"{px:.6g} {py:.6g} {pz:.6g} {roll:.3f} {pitch:.3f} {yaw:.3f}"
print()
print(f"  <camera_pose>{pose}</camera_pose>")
print()
print(f'  CAM_POSE="{pose}"')
print()
print(f"  degrees: roll {math.degrees(roll):.1f}  "
      f"pitch {math.degrees(pitch):.1f}  yaw {math.degrees(yaw):.1f}")
