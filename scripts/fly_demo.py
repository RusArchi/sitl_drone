#!/usr/bin/env python3
"""
Phase 2 smoke flight: prove the SITL -> Gazebo loop end to end.

Predetermined input, no sticks: wait for EKF/GPS, arm in GUIDED, take off to a
set altitude, fly a small square, land. If this completes and the iris moves in
Gazebo, the whole chain works -- mixer -> PWM -> _simulator_servos() -> JSON ->
ardupilot_gazebo plugin -> physics.

Run inside the container, with the venv active:
    source ~/ardupilot/venv-ardupilot/bin/activate
    python3 /workspace/sitl_drone/scripts/fly_demo.py
"""
import sys
import time

from pymavlink import mavutil

CONNECT = "tcp:127.0.0.1:5760"
TAKEOFF_ALT = 15.0      # metres
SQUARE_SIDE = 20.0      # metres
GUIDED = 4              # copter mode number


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def request_streams(m, rate_hz=4):
    """Ask SITL to stream telemetry.

    Without this nothing arrives: ArduPilot only sends periodic messages to a
    GCS that asked for them. MAVProxy does this for you, so the omission only
    shows up on a raw pymavlink connection -- as a silent timeout waiting for
    GPS_RAW_INT that looks exactly like a broken simulator.
    """
    m.mav.request_data_stream_send(
        m.target_system, m.target_component,
        mavutil.mavlink.MAV_DATA_STREAM_ALL, rate_hz, 1)


def wait_ready(m, timeout=180):
    """Block until the EKF is happy enough to arm."""
    log("waiting for GPS lock and EKF...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = m.recv_match(type=["GPS_RAW_INT", "EKF_STATUS_REPORT"],
                           blocking=True, timeout=5)
        if msg is None:
            continue
        if msg.get_type() == "GPS_RAW_INT" and msg.fix_type >= 3:
            sats = msg.satellites_visible
            log(f"GPS 3D fix, {sats} satellites")
            # EKF needs a moment beyond first fix to settle
            time.sleep(8)
            return True
    raise TimeoutError("no GPS lock within timeout")


def set_mode(m, mode_id, name):
    log(f"mode -> {name}")
    m.mav.set_mode_send(
        m.target_system,
        mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
        mode_id)
    deadline = time.time() + 15
    while time.time() < deadline:
        hb = m.recv_match(type="HEARTBEAT", blocking=True, timeout=5)
        if hb and hb.custom_mode == mode_id:
            return True
    raise RuntimeError(f"mode {name} not accepted")


def arm(m):
    log("arming...")
    m.arducopter_arm()
    m.motors_armed_wait()
    log("armed")


def takeoff(m, alt):
    log(f"takeoff to {alt} m")
    m.mav.command_long_send(
        m.target_system, m.target_component,
        mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
        0, 0, 0, 0, 0, 0, 0, alt)
    deadline = time.time() + 90
    while time.time() < deadline:
        msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=5)
        if msg is None:
            continue
        rel = msg.relative_alt / 1000.0
        if rel >= alt * 0.95:
            log(f"reached {rel:.1f} m")
            return True
        if int(time.time()) % 5 == 0:
            log(f"  climbing: {rel:.1f} m")
    raise TimeoutError("takeoff did not reach target altitude")


def goto_ned(m, north, east, down, settle=12):
    """Move to a position relative to the EKF origin, in metres."""
    log(f"goto N={north} E={east} alt={-down}")
    m.mav.set_position_target_local_ned_send(
        0, m.target_system, m.target_component,
        mavutil.mavlink.MAV_FRAME_LOCAL_NED,
        0b0000111111111000,          # position only
        north, east, down,
        0, 0, 0, 0, 0, 0, 0, 0)
    time.sleep(settle)


def main():
    log(f"connecting to {CONNECT}")
    m = mavutil.mavlink_connection(CONNECT)
    m.wait_heartbeat()
    log(f"heartbeat from system {m.target_system} component {m.target_component}")

    request_streams(m)
    wait_ready(m)
    set_mode(m, GUIDED, "GUIDED")
    arm(m)
    takeoff(m, TAKEOFF_ALT)

    s = SQUARE_SIDE
    down = -TAKEOFF_ALT
    for north, east in [(s, 0), (s, s), (0, s), (0, 0)]:
        goto_ned(m, north, east, down)

    log("landing")
    m.mav.command_long_send(
        m.target_system, m.target_component,
        mavutil.mavlink.MAV_CMD_NAV_LAND,
        0, 0, 0, 0, 0, 0, 0, 0)

    deadline = time.time() + 120
    while time.time() < deadline:
        if not m.motors_armed():
            log("disarmed — landed")
            return 0
        m.recv_match(type="HEARTBEAT", blocking=True, timeout=5)
    log("still armed after landing timeout")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:               # noqa: BLE001 - smoke test, report and exit
        log(f"FAILED: {exc}")
        sys.exit(1)
