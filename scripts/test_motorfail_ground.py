#!/usr/bin/env python3
"""Phase 5 ground test: prove MOTOR_FAILURE_SET actually changes the ESC output.

Takes off, samples SERVO_OUTPUT_RAW, fails a motor, samples again, restores it,
samples a third time. Reports the four channels at each stage.

This isolates "does the output change" from "does the aircraft fall". If the
commanded channel does not drop to MOT_PWM_MIN here, nothing about the flight
test will be informative.

Needs SITL running (Gazebo not required -- SITL's own physics is enough):
    sim_vehicle.py -v ArduCopter --no-mavproxy
    python3 /workspace/sitl_drone/scripts/test_motorfail_ground.py
"""
import os
import sys
import time

from pymavlink import mavutil

CONNECT = os.environ.get("CONNECT") or "tcp:127.0.0.1:5760"
MOTOR = int(os.environ.get("MOTOR", 3))
TAKEOFF_ALT = float(os.environ.get("TAKEOFF_ALT", 15.0))
GUIDED = 4

# Enum values from ardupilotmega.xml. Named literally rather than imported so a
# stale pymavlink shows up as a wrong number in the output, not an ImportError.
FAILURE_NONE = 0
FAILURE_STOPPED = 1


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def request_streams(m, rate_hz=10):
    m.mav.request_data_stream_send(
        m.target_system, m.target_component,
        mavutil.mavlink.MAV_DATA_STREAM_ALL, rate_hz, 1)


def sample_outputs(m, seconds=2.0):
    """Average each of the first four channels over a window.

    A single sample is misleading: the controller is constantly trimming, so
    two consecutive frames differ by tens of microseconds even in the hover.
    """
    sums = [0] * 4
    n = 0
    deadline = time.time() + seconds
    while time.time() < deadline:
        msg = m.recv_match(type="SERVO_OUTPUT_RAW", blocking=True, timeout=2)
        if not msg:
            continue
        sums[0] += msg.servo1_raw
        sums[1] += msg.servo2_raw
        sums[2] += msg.servo3_raw
        sums[3] += msg.servo4_raw
        n += 1
    if n == 0:
        raise TimeoutError("no SERVO_OUTPUT_RAW received")
    return [s / n for s in sums], n


def report(label, avgs, n):
    cells = "  ".join(f"ch{i+1} {v:7.1f}" for i, v in enumerate(avgs))
    log(f"{label:<22} {cells}   ({n} samples)")


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
    """Clear SITL's own engine failure before testing ours.

    SITL keeps parameters in eeprom.bin across restarts, so a Phase 3 run leaves
    SIM_ENGINE_FAIL=1 / SIM_ENGINE_MUL=0 armed. Two consequences: the aircraft
    cannot take off at all, and if it could, the kill being observed would be
    SITL's rather than the one travelling through rc_write().
    """
    log("clearing any SITL engine failure left from a previous run")
    set_param(m, "SIM_ENGINE_FAIL", 0)
    set_param(m, "SIM_ENGINE_MUL", 1)


def wait_ready(m, timeout=180):
    log("waiting for GPS lock...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = m.recv_match(type="GPS_RAW_INT", blocking=True, timeout=5)
        if msg and msg.fix_type >= 3:
            log(f"GPS 3D fix, {msg.satellites_visible} satellites")
            time.sleep(8)
            return True
    raise TimeoutError("no GPS fix")


def set_mode(m, mode_id, name, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        m.mav.set_mode_send(m.target_system,
                            mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
                            mode_id)
        end = time.time() + 5
        while time.time() < end:
            msg = m.recv_match(type="HEARTBEAT", blocking=True, timeout=1)
            if msg and msg.custom_mode == mode_id:
                log(f"mode -> {name}")
                return True
    raise TimeoutError(f"mode {name} not accepted")


def arm(m, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        m.mav.command_long_send(m.target_system, m.target_component,
                                mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
                                0, 1, 0, 0, 0, 0, 0, 0)
        end = time.time() + 5
        while time.time() < end:
            msg = m.recv_match(type="HEARTBEAT", blocking=True, timeout=1)
            if msg and (msg.base_mode &
                        mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED):
                log("armed")
                return
    raise TimeoutError("could not arm")


def takeoff(m, alt):
    log(f"takeoff to {alt} m")
    m.mav.command_long_send(m.target_system, m.target_component,
                            mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
                            0, 0, 0, 0, 0, 0, 0, alt)
    deadline = time.time() + 90
    while time.time() < deadline:
        msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=2)
        if msg and msg.relative_alt / 1000.0 >= alt * 0.95:
            log(f"reached {msg.relative_alt / 1000.0:.1f} m")
            return
    raise TimeoutError("takeoff did not reach altitude")


def send_failure(m, motor, failure_type):
    m.mav.motor_failure_set_send(m.target_system, m.target_component,
                                 motor, failure_type)
    # The vehicle echoes a STATUSTEXT from handle_message_motor_failure_set().
    deadline = time.time() + 5
    while time.time() < deadline:
        msg = m.recv_match(type="STATUSTEXT", blocking=True, timeout=1)
        if msg and "MOTOR_FAILURE_SET" in msg.text:
            log(f"  vehicle: {msg.text}")
            return True
    log("  WARNING: no STATUSTEXT came back")
    return False


def main():
    m = mavutil.mavlink_connection(CONNECT)
    log(f"connecting to {CONNECT}")
    m.wait_heartbeat()
    log(f"heartbeat from system {m.target_system}")
    request_streams(m)
    clear_sim_failure(m)

    wait_ready(m)
    set_mode(m, GUIDED, "GUIDED")
    arm(m)
    takeoff(m, TAKEOFF_ALT)

    log("settling in the hover...")
    time.sleep(5)

    before, n = sample_outputs(m)
    report("hover, all healthy", before, n)

    log(f"failing motor {MOTOR}")
    send_failure(m, MOTOR, FAILURE_STOPPED)
    time.sleep(2)
    during, n = sample_outputs(m)
    report(f"motor {MOTOR} stopped", during, n)

    log(f"restoring motor {MOTOR}")
    send_failure(m, MOTOR, FAILURE_NONE)
    time.sleep(2)
    after, n = sample_outputs(m)
    report("restored", after, n)

    # Verdict. The killed channel must sit at MOT_PWM_MIN (1000 by default) and
    # the others must rise -- the mixer is asking the survivors for more as the
    # aircraft loses attitude authority.
    idx = MOTOR - 1
    ok = True
    if during[idx] > 1005:
        log(f"FAIL: channel {MOTOR} is {during[idx]:.1f}, expected ~1000")
        ok = False
    if after[idx] < 1100:
        log(f"FAIL: channel {MOTOR} did not recover ({after[idx]:.1f})")
        ok = False
    # The survivors do NOT all rise. On a quad X the killed motor's diagonal
    # opposite must shed thrust to keep roll and pitch balanced, and the
    # stability patch scales the whole output down to preserve attitude
    # authority -- it trades thrust for control, by design. Measured 2026-09-02:
    # killing motor 3 (front left) drove motor 4 (back right) from 1601 to 1373
    # while motors 1 and 2 barely moved. So only report the spread, do not
    # judge it.
    spread = max(during) - min(v for i, v in enumerate(during) if i != idx)
    log(f"surviving channels span {spread:.1f} us "
        f"(the killed motor's diagonal opposite sheds the most)")

    log("PASS" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
