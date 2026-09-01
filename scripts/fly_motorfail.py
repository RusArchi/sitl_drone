#!/usr/bin/env python3
"""
Phase 5/6: kill a motor with the custom MAVLink message and record the fall.

Flies a straight line, then sends MOTOR_FAILURE_SET (id 11070) to stop one
motor. Unlike the Phase 3 baseline (scripts/fly_fail.py), nothing here touches
SITL's simulation parameters -- the kill travels the full path the assignment is
about:

    pymavlink -> MAVLink -> GCS_MAVLINK_Copter::handle_message_motor_failure_set()
              -> AP_MotorsMulticopter::set_motor_failed()
              -> AP_MotorsMatrix::output_to_motors() -> rc_write() -> PWM

So the flight controller keeps computing what it wants that motor to do and
never learns it is being ignored, exactly as on real hardware with a dead ESC.

The vehicle echoes a STATUSTEXT when it handles the message. Under the
recorder's TELEM=1 that line appears in the MAVProxy pane beside the render,
which is what marks the moment of the kill on video.

Run inside the container, with the venv active:
    python3 /workspace/sitl_drone/scripts/fly_motorfail.py
"""
import os
import subprocess
import sys
import time

from pymavlink import mavutil

# `or` not a get() default: the recorder exports CONNECT unconditionally, so
# without TELEM it arrives as an empty string, and a get() default does not
# replace that (see scripts/fly_fail.py).
CONNECT = os.environ.get("CONNECT") or "tcp:127.0.0.1:5760"

TAKEOFF_ALT = float(os.environ.get("TAKEOFF_ALT", 4.0))    # metres
CRUISE_N = float(os.environ.get("CRUISE_N", 10.0))         # metres north
KILL_AFTER = float(os.environ.get("KILL_AFTER", 4.0))      # s into the cruise
CRUISE_SPEED = float(os.environ.get("CRUISE_SPEED", 2))    # m/s, 0 = default
MOTOR = int(os.environ.get("MOTOR", 1))   # 1 = front right (PROJECT.md §5)

# How the kill is issued.
#   module -- type `motorfail N` into the recorder's MAVProxy pane with xdotool,
#             so the video shows the command being given as well as the reply.
#             Falls back to `direct` if the pane is not there or the vehicle
#             does not answer.
#   direct -- send MOTOR_FAILURE_SET straight from this script.
# Same packet on the wire either way; only the sender differs.
KILL_VIA = os.environ.get("KILL_VIA", "direct")
TELEM_TITLE = os.environ.get("TELEM_TITLE", "MAVProxy telemetry")

# Enum values from ardupilotmega.xml. Written as literals rather than imported
# so a stale pymavlink shows up as a wrong number on the wire, not an
# ImportError halfway through a flight.
FAILURE_NONE = 0
FAILURE_STOPPED = 1

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
    deadline = time.time() + 5
    while time.time() < deadline:
        msg = m.recv_match(type="PARAM_VALUE", blocking=True, timeout=1)
        if msg and msg.param_id.strip("\x00") == name:
            log(f"  {name} = {msg.param_value}")
            return True
    log(f"  WARNING: no confirmation for {name}")
    return False


def clear_sim_failure(m):
    """Clear SITL's own engine failure before using ours.

    SITL keeps parameters in eeprom.bin across restarts, so a Phase 3 run leaves
    SIM_ENGINE_FAIL=1 / SIM_ENGINE_MUL=0 armed. The aircraft then cannot take
    off -- and worse, if it could, the crash on the video would be SITL's kill
    rather than the one under test. Verified 2026-09-02: this is exactly what
    blocked the first Phase 5 ground run.
    """
    log("clearing any SITL engine failure left from a previous run")
    set_param(m, "SIM_ENGINE_FAIL", 0)
    set_param(m, "SIM_ENGINE_MUL", 1)


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


def set_mode(m, mode_id, name, timeout=60):
    deadline = time.time() + timeout
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        m.mav.set_mode_send(m.target_system,
                            mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
                            mode_id)
        end = time.time() + 5
        while time.time() < end:
            msg = m.recv_match(type="HEARTBEAT", blocking=True, timeout=1)
            if msg and msg.custom_mode == mode_id:
                log(f"mode -> {name}" + (f" (attempt {attempt})" if attempt > 1 else ""))
                return True
        log(f"  mode {name} not accepted yet; retrying")
    raise TimeoutError(f"mode {name} not accepted after {timeout}s")


def arm(m, timeout=90):
    deadline = time.time() + timeout
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        m.mav.command_long_send(m.target_system, m.target_component,
                                mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
                                0, 1, 0, 0, 0, 0, 0, 0)
        end = time.time() + 5
        while time.time() < end:
            msg = m.recv_match(type=["HEARTBEAT", "COMMAND_ACK", "STATUSTEXT"],
                               blocking=True, timeout=1)
            if not msg:
                continue
            t = msg.get_type()
            if t == "STATUSTEXT" and ("PreArm" in msg.text or "Arm" in msg.text):
                log(f"  vehicle: {msg.text}")
            elif t == "HEARTBEAT" and (msg.base_mode &
                                       mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED):
                log(f"armed (attempt {attempt})")
                return
        log(f"  arm attempt {attempt} did not take; retrying")
    raise TimeoutError("could not arm")


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


def wait_for_kill(m, timeout=8):
    """Confirm the kill landed, by echo or by the aircraft departing.

    The STATUSTEXT echo is the direct evidence, but it can be missed: measured
    2026-09-02, a command typed into MAVProxy was accepted and acknowledged
    (`motorfail: sent motor 1 type 1 to 1/1` in the MAVProxy log) while this
    script, reading the same stream over the fan-out link, saw no STATUSTEXT in
    six seconds and issued a needless second kill.

    A quad with a dead motor departs immediately, so a descent rate past 2 m/s
    is independent proof. Accept either.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = m.recv_match(type=["STATUSTEXT", "GLOBAL_POSITION_INT"],
                           blocking=True, timeout=1)
        if not msg:
            continue
        if msg.get_type() == "STATUSTEXT" and "MOTOR_FAILURE_SET" in msg.text:
            log(f"  vehicle acknowledged: {msg.text}")
            return True
        if msg.get_type() == "GLOBAL_POSITION_INT" and msg.vz / 100.0 > 2.0:
            log(f"  aircraft is departing ({msg.vz / 100.0:+.1f} m/s) "
                f"-- the kill landed")
            return True
    return False


def type_into_mavproxy(command):
    """Type a command into the recorder's MAVProxy xterm, for the camera.

    Returns False if the pane is not present or xdotool is unavailable, so the
    caller can fall back to sending the message itself.

    xterm discards synthetic key events unless started with
    `XTerm*allowSendEvents:true`; record_demo.sh sets it. Without that this
    silently does nothing and the flight looks broken for no visible reason.
    """
    if not os.environ.get("DISPLAY"):
        log("  no DISPLAY, cannot type into MAVProxy")
        return False
    try:
        found = subprocess.run(["xdotool", "search", "--name", TELEM_TITLE],
                               capture_output=True, text=True, timeout=10)
        win = found.stdout.split()[-1] if found.stdout.split() else None
        if not win:
            log(f"  no window titled '{TELEM_TITLE}'")
            return False
        # A visible typing speed: the point is for a viewer to read it.
        subprocess.run(["xdotool", "type", "--window", win, "--delay", "80",
                        command], capture_output=True, timeout=30)
        subprocess.run(["xdotool", "key", "--window", win, "Return"],
                       capture_output=True, timeout=10)
        log(f"  typed into MAVProxy: {command}")
        return True
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"  could not type into MAVProxy: {exc}")
        return False


def send_motor_failure(m, motor, failure_type):
    """Send MOTOR_FAILURE_SET and wait for Copter's echo.

    The echo is the only acknowledgement there is -- a plain message gets no
    COMMAND_ACK, so without the STATUSTEXT there would be no way to tell a
    delivered packet from a dropped one.
    """
    m.mav.motor_failure_set_send(m.target_system, m.target_component,
                                 motor, failure_type)
    if wait_for_kill(m):
        return True
    log("  WARNING: no STATUSTEXT came back -- did the packet arrive?")
    return False


def kill_motor(m, motor):
    """Issue the kill, preferring the on-camera route when one is available."""
    if KILL_VIA == "module" and type_into_mavproxy(f"motorfail {motor}"):
        if wait_for_kill(m):
            return True
        log("  no echo from the typed command; falling back to a direct send")
    return send_motor_failure(m, motor, FAILURE_STOPPED)


def main():
    global WALL_START, SIM_START
    WALL_START = time.time()
    log(f"connecting to {CONNECT}")
    m = mavutil.mavlink_connection(CONNECT)
    m.wait_heartbeat()
    log(f"heartbeat from system {m.target_system}")
    request_streams(m)

    clear_sim_failure(m)

    first = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=10)
    if first:
        SIM_START = first.time_boot_ms

    if CRUISE_SPEED > 0:
        log(f"cruise speed -> {CRUISE_SPEED} m/s")
        set_param(m, "WPNAV_SPEED", CRUISE_SPEED * 100.0)

    wait_ready(m)
    set_mode(m, GUIDED, "GUIDED")
    arm(m)
    takeoff(m, TAKEOFF_ALT)

    log(f"cruising straight: {CRUISE_N} m north at {TAKEOFF_ALT} m")
    goto_ned(m, CRUISE_N, 0, -TAKEOFF_ALT)
    time.sleep(KILL_AFTER)

    log("")
    log(f"*** MOTOR_FAILURE_SET: stopping motor {MOTOR} (via {KILL_VIA}) ***")
    kill_motor(m, MOTOR)
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
        if last_alt is None or abs(rel - last_alt) > 1.0:
            log(f"  alt {rel:6.1f} m   vz {vz:+5.1f} m/s")
            last_alt = rel
        if rel < 0.5:
            log(f"  IMPACT at t+{time.time()-start:.1f}s after the kill")
            break
    else:
        log("  still airborne after 45 s")

    time.sleep(3)

    # Sim clock vs wall clock, so the recorder can re-time the video. Must be a
    # DELTA: time_boot_ms counts from SITL's boot, well before this script
    # connects (see scripts/fly_fail.py).
    msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=5)
    if msg and SIM_START is not None:
        sim_s = (msg.time_boot_ms - SIM_START) / 1000.0
        wall_s = time.time() - WALL_START
        log(f"RTF_HINT sim={sim_s:.1f} wall={wall_s:.1f}")
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
