# sitl_drone

ArduCopter (ArduPilot) flying in a Gazebo simulation, with a hook into the
multicopter mixer to command an individual motor to zero on demand while in
Stabilize mode.

## Status

Environment prep only. No ArduPilot patches yet.

Current state, decisions and next actions live in **[PROJECT.md](PROJECT.md)** —
that file is the project's ground truth and is kept up to date as work happens.

## Goal

1. Get ArduCopter SITL flying an iris quad in Gazebo.
2. Locate the final motor mixer in ArduPilot and add a controlled per-motor kill.
3. Trigger it in flight, in Stabilize, and record the resulting departure.

## Where the mixer is

Verified against ArduPilot master `cbe0c39`.

The Stabilize control chain, top to bottom:

| Stage | Location |
|---|---|
| Mode — stick input → attitude targets | `ArduCopter/mode_stabilize.cpp` |
| Attitude/rate PIDs → normalised r/p/y/thrust | `AC_AttitudeControl_Multi::rate_controller_run()` |
| Fixed output pipeline | `AP_MotorsMulticopter::output()` |
| **Mixer core** — per-motor thrust + stability patch | `libraries/AP_Motors/AP_MotorsMatrix.cpp:213` `output_armed_stabilizing()` |
| **Spool / slew / thrust-linearisation → PWM** | `libraries/AP_Motors/AP_MotorsMatrix.cpp:143` `output_to_motors()` |
| Last flight-code touch → SRV_Channels | `libraries/AP_Motors/AP_Motors_Class.cpp:96` `AP_Motors::rc_write()` |
| SITL: PWM → physics backend | `libraries/AP_HAL_SITL/SITL_State.cpp:287` `_simulator_servos()` |

Planned injection point: **`output_to_motors()`, at the `rc_write()` call
(`AP_MotorsMatrix.cpp:180`)** — after spool state, slew limiting and thrust
linearisation, so the zero is a genuine final command rather than something the
stability patch can rescale.

Planned trigger: a **new MAVLink message** carrying a motor index 1-4, sendable
from a MAVProxy terminal and handled in
`ArduCopter/GCS_MAVLink_Copter.cpp:1179`. The protocol work is deliberate - see
[PROJECT.md](PROJECT.md) §1.

## Baseline that needs no code

ArduPilot can already kill a motor in the simulator via `SIM_ENGINE_FAIL` (bitmask)
and `SIM_ENGINE_MUL`, applied in `SITL_State.cpp:331-341` — which runs *before*
`sitl_model->update_model()`, so it reaches the Gazebo JSON backend too. That
simulates a *hardware* failure the flight controller knows nothing about, and is the
right smoke test for the sim stack before any ArduPilot patch.

## Setup

See **[docs/ENVIRONMENT_SETUP.md](docs/ENVIRONMENT_SETUP.md)** for the full list.

```bash
./scripts/setup_env.sh          # provision (Ubuntu 22.04 / 24.04)
./scripts/setup_env.sh --check  # verify, changes nothing
```

## Run

```bash
# terminal 1 — physics ( -s = headless server only )
gz sim -v4 -s -r iris_runway.sdf

# terminal 2 — flight controller
cd ~/ardupilot && sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON --console
```
