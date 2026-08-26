#!/usr/bin/env python3
"""
Phase 3 baseline: kill a motor in the simulator, with NO ArduPilot code changes.

Flies a straight line, then fails motor 1 (front right) using SITL's own
SIM_ENGINE_FAIL / SIM_ENGINE_MUL parameters and logs the fall to impact.

This is the comparison baseline for the MAVLink-commanded kill built later. It
simulates a *hardware* failure the flight controller knows nothing about --
SIM_ENGINE_FAIL is applied in SITL_State.cpp before the physics backend runs, so
it never passes through the mixer. The commanded version will instead travel the
full path: MAVLink -> Copter -> AP_MotorsMatrix -> rc_write().

Straight-and-level before the cut, so the departure is unambiguous on video.

Run inside the container, with the venv active:
    python3 /workspace/sitl_drone/scripts/fly_fail.py
"""
import sys
import time

from pymavlink import mavutil

CONNECT = "tcp:127.0.0.1:5760"
TAKEOFF_ALT = 20.0      # metres -- high enough for a clear fall, low enough to frame
CRUISE_N = 40.0         # metres north, straight line
KILL_AFTER = 5.0        # seconds into the cruise leg before cutting the motor
MOTOR = 1               # 1 = front right (AP_MotorsMatrix.cpp:592)
GUIDED = 4
WALL_START = 0.0
SIM_START = None


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def request_streams(m, rate_hz=10):
    m.mav.request_data_stream_send(
        m.target_system, m.target_component,
        mavutil.mavlink.MAV_DATA_STREAM_ALL, rate_hz, 1)


def set_param(m, name, value):
    m.mav.param_set_send(m.target_system, m.target_component,
                         name.encode(), float(value),
                         mavutil.mavlink.MAV_PARAM_TYPE_REAL32)
    # Confirm, or a typo'd name fails silently and the drone just flies on.
    deadline = time.time() + 5
    while time.time() < deadline:
        msg = m.recv_match(type="PARAM_VALUE", blocking=True, timeout=1)
        if msg and msg.param_id.strip("\x00") == name:
            log(f"  {name} = {msg.param_value}")
            return True
    log(f"  WARNING: no confirmation for {name}")
    return False


def wait_ready(m, timeout=180):
    log("waiting for GPS lock and EKF...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = m.recv_match(type="GPS_RAW_INT", blocking=True, timeout=5)
        if msg and msg.fix_type >= 3:
            log(f"GPS 3D fix, {msg.satellites_visible} satellites")
            time.sleep(8)   # let the EKF settle before arming
            return True
    raise TimeoutError("no GPS fix")


def set_mode(m, mode_id, name):
    m.mav.set_mode_send(m.target_system,
                        mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
                        mode_id)
    deadline = time.time() + 10
    while time.time() < deadline:
        msg = m.recv_match(type="HEARTBEAT", blocking=True, timeout=2)
        if msg and msg.custom_mode == mode_id:
            log(f"mode -> {name}")
            return True
    raise TimeoutError(f"mode {name} not accepted")


def arm(m):
    m.mav.command_long_send(m.target_system, m.target_component,
                            mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
                            0, 1, 0, 0, 0, 0, 0, 0)
    m.motors_armed_wait()
    log("armed")


def takeoff(m, alt):
    log(f"takeoff to {alt} m")
    m.mav.command_long_send(m.target_system, m.target_component,
                            mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
                            0, 0, 0, 0, 0, 0, 0, alt)
    deadline = time.time() + 90
    while time.time() < deadline:
        msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=2)
        if msg:
            rel = msg.relative_alt / 1000.0
            if int(time.time() * 2) % 4 == 0:
                log(f"  climbing: {rel:.1f} m")
            if rel >= alt * 0.95:
                log(f"reached {rel:.1f} m")
                return
    raise TimeoutError("takeoff did not reach altitude")


def goto_ned(m, north, east, down):
    m.mav.set_position_target_local_ned_send(
        0, m.target_system, m.target_component,
        mavutil.mavlink.MAV_FRAME_LOCAL_NED,
        0b0000111111111000,
        north, east, down, 0, 0, 0, 0, 0, 0, 0, 0)


def main():
    global WALL_START, SIM_START
    WALL_START = time.time()
    m = mavutil.mavlink_connection(CONNECT)
    log(f"connecting to {CONNECT}")
    m.wait_heartbeat()
    log(f"heartbeat from system {m.target_system}")
    request_streams(m)

    # SITL keeps parameters in eeprom.bin ACROSS RESTARTS, so a failure injected
    # by a previous run is still armed at startup and the aircraft cannot take
    # off. Always clear it before flying.
    log("clearing any engine failure left over from a previous run")
    set_param(m, "SIM_ENGINE_FAIL", 0)
    set_param(m, "SIM_ENGINE_MUL", 1)

    first = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=10)
    if first:
        SIM_START = first.time_boot_ms

    wait_ready(m)
    set_mode(m, GUIDED, "GUIDED")
    arm(m)
    takeoff(m, TAKEOFF_ALT)

    log(f"cruising straight: {CRUISE_N} m north at {TAKEOFF_ALT} m")
    goto_ned(m, CRUISE_N, 0, -TAKEOFF_ALT)
    time.sleep(KILL_AFTER)

    log("")
    log(f"*** CUTTING MOTOR {MOTOR} (front right) ***")
    # SIM_ENGINE_FAIL is a bitmask: bit 0 = motor 1. SIM_ENGINE_MUL scales the
    # thrust of the failed motor(s); 0 = dead.
    set_param(m, "SIM_ENGINE_MUL", 0)
    set_param(m, "SIM_ENGINE_FAIL", 1 << (MOTOR - 1))
    log("")

    log("tracking the fall...")
    start = time.time()
    last_alt = None
    while time.time() - start < 45:
        msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=2)
        if not msg:
            continue
        rel = msg.relative_alt / 1000.0
        vz = msg.vz / 100.0
        if last_alt is None or abs(rel - last_alt) > 1.5:
            log(f"  alt {rel:6.1f} m   vz {vz:+5.1f} m/s")
            last_alt = rel
        if rel < 1.0:
            log(f"  IMPACT at t+{time.time()-start:.1f}s after the cut")
            break
    else:
        log("  still airborne after 45 s")

    time.sleep(3)

    # Sim clock vs wall clock, so the recorder can re-time the video. Must be a
    # DELTA: time_boot_ms counts from SITL's boot, which is well before this
    # script connects, so the absolute value overstates elapsed sim time badly.
    msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=5)
    if msg and SIM_START is not None:
        sim_s = (msg.time_boot_ms - SIM_START) / 1000.0
        wall_s = time.time() - WALL_START
        log(f"RTF_HINT sim={sim_s:.1f} wall={wall_s:.1f}")
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
