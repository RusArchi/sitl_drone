# PROJECT.md — sitl_drone ground truth

> **This file is the single source of truth for the state of this project.**
> It is updated continuously as work happens. If this file and your memory
> disagree, this file wins. If this file and the code disagree, the code wins
> and *this file must be corrected in the same change*.
>
> Update rules: see [CLAUDE.md](CLAUDE.md).

**Last updated:** 2026-08-25
**Branch:** `claude/ardupilot-motor-control-gazebo-84hfq8`
**Upstream:** https://github.com/RusArchi/sitl_drone

---

## 1. Mission

### The assignment, as given

Received 2026-08-25 (translated from Hebrew; original wording preserved in intent).
This is the authoritative statement of what the project must deliver.

**Build:**

1. Bring up an ArduCopter SITL with a drone model and a physics simulator
   (e.g. Gazebo).
2. Create a **new MAVLink message**, sendable from a MAVProxy terminal, that
   carries a number **1–4**.
3. In the ArduCopter code, propagate that number all the way down into the
   command to the **simulated ESC drivers** (identical to the real ones as far as
   the code is concerned) and cause the failure of the motor identified by that
   number.

**Demonstrate:**

1. Takeoff in SITL with the drone **visualised** in an environment.
2. Sending the command.
3. The drone **crashes**, because the motor named in the message stopped working.

### What that means in practice

The exercise is the **plumbing**: message definition → MAVProxy → MAVLink parser →
Copter message handler → motors library → ESC output. A shortcut that reaches the
same physical outcome without traversing that chain misses the point of the task.

Two consequences worth stating up front, because both reverse earlier assumptions:

- A **new MAVLink message is required.** Setting an existing parameter is
  explicitly not the exercise (see §6).
- **Visualisation is required.** Headless-only is no longer sufficient for the
  deliverable (see §4).

### Phases

| # | Phase | State |
|---|---|---|
| 1 | Provision the build/sim environment | **Done** |
| 2 | ArduCopter SITL flying an iris quad in Gazebo, with visualisation | **Not started** |
| 3 | Baseline: kill a rotor with `SIM_ENGINE_FAIL` (no code change) | **Not started** |
| 4 | Define the new MAVLink message; regenerate C headers + pymavlink | **Not started** |
| 5 | Handle it in Copter; propagate motor index down to the ESC output | **Not started** |
| 6 | Send from MAVProxy in flight; record takeoff → command → crash | **Not started** |

Phase 3 is not in the assignment. It is kept as a **sim-stack smoke test and
comparison baseline** — it proves the mixer→PWM→Gazebo chain works before any
patch exists, so a later failure can be attributed to the patch rather than the
environment.

## 2. Current status

**Phase 1 complete — environment provisioned and verified. No ArduPilot patches yet.**

Verified working as of 2026-08-25:

- Docker container `sitl_drone` (image `sitl_drone:latest`, `ubuntu:24.04`) running.
- Bind mounts live: `~/ardupilot`, `~/ardupilot_gazebo`, `~/Projects/sitl_drone`,
  plus a named `sitl_drone-ccache` volume.
- `scripts/setup_env.sh --check` reports **Environment OK** — gz sim 8.15.0,
  `libArduPilotPlugin.so` built, `arducopter` SITL binary built, venv present,
  `pymavlink` importable.
- GZ env vars and the ArduPilot `Tools/autotest` PATH entry are in the container's
  `~/.bashrc` (interactive shells only — Ubuntu's `.bashrc` has an early PS1 guard,
  so non-interactive `docker exec` does **not** get them; use `bash -lc` or
  `docker/run.sh check`, which exports them inline).

Nothing is blocked. The next action is Phase 2.

Note: the environment was provisioned for **headless** operation. The assignment
requires visualisation, so Phase 2 must also stand up a rendering path — see §4.

---

## 3. Repo layout

| Path | What it is |
|---|---|
| [README.md](README.md) | Short public-facing overview: goal, mixer map, run commands |
| [PROJECT.md](PROJECT.md) | **This file** — living ground truth |
| [CLAUDE.md](CLAUDE.md) | Rules for agents working in this repo |
| [AGENTS.md](AGENTS.md) | Pointer to CLAUDE.md, for agents that look for this filename |
| [docs/ENVIRONMENT_SETUP.md](docs/ENVIRONMENT_SETUP.md) | Full from-scratch provisioning reference (11 sections) |
| [scripts/setup_env.sh](scripts/setup_env.sh) | Host provisioner; `--check` verifies without changing anything |
| [docker/Dockerfile](docker/Dockerfile) | Reproducible Ubuntu 24.04 build/sim image |
| [docker/run.sh](docker/run.sh) | `build` / `run` / `shell` / `check` / `stop` wrapper |
| [docker/first-run.sh](docker/first-run.sh) | One-time in-container provisioning against the bind-mounted clones (idempotent) |
| [docker/install-prereqs-ubuntu.sh](docker/install-prereqs-ubuntu.sh) | Vendored copy of ArduPilot's official prereq script (see §6) |
| `docker/Tools/completion/completion.bash` | Vendored; the prereq script above requires it to exist |

**Not in this repo:** the ArduPilot source itself and the `ardupilot_gazebo`
plugin. Both are separate clones at `~/ardupilot` and `~/ardupilot_gazebo` on the
host, bind-mounted into the container. Patches to the mixer will live in *those*
trees; this repo tracks the patch, the tooling and the findings.

---

## 4. Environment

### Two ways in, same tree

| | Host | Container |
|---|---|---|
| Provision | `./scripts/setup_env.sh` | `docker/run.sh run` then `first-run.sh` |
| Verify | `./scripts/setup_env.sh --check` | `docker/run.sh check` |
| Shell | — | `docker exec -it sitl_drone bash` (interactive → env loaded) |

The container uses `--network host` and a uid/gid-1000 `rusik` user matching the
host, so build artifacts written through the bind mounts stay usable host-side.

### Visualisation (required by the assignment — not yet set up)

The environment currently runs headless (`gz sim -s`), which was fine for physics
but does not satisfy demo deliverable #1. Options, in preference order:

1. **`gz sim` GUI on a machine with a display.** Simplest if one is available.
2. **`xvfb-run` + `x11vnc`** on the headless box, recording the virtual display.
   `docs/ENVIRONMENT_SETUP.md` §6 option B already lists the packages.
3. **Gazebo video-recording** of the crash, if a live view is impractical.

The container runs `--network host` and has no display wired in; whichever option
is chosen needs `DISPLAY` plumbing added to `docker/run.sh`.

### Ports (loopback; increment with `sim_vehicle.py -I N`)

`9002/udp` SITL→Gazebo servos · `9003/udp` Gazebo→SITL state ·
`5760/tcp` primary MAVLink · `5762`/`5763` extra · `9005/udp` IRLock.

### The venv trap

Ubuntu 24.04 is PEP 668, so MAVProxy/pymavlink live in
`~/ardupilot/venv-ardupilot`, **not** system Python. Any shell or agent running
`sim_vehicle.py` or a pymavlink script must `source` it first, or it gets a
mysterious `ModuleNotFoundError`.

---

## 5. Technical ground truth

Verified against ArduPilot master **`cbe0c39`**. Re-verify line numbers before
relying on them — upstream moves.

### Stabilize control chain, top to bottom

| Stage | Location |
|---|---|
| Mode — stick input → attitude targets | `ArduCopter/mode_stabilize.cpp` |
| Attitude/rate PIDs → normalised r/p/y/thrust | `AC_AttitudeControl_Multi::rate_controller_run()` |
| Fixed output pipeline | `AP_MotorsMulticopter::output()` |
| **Mixer core** — per-motor thrust + stability patch | `AP_Motors/AP_MotorsMatrix.cpp:213` `output_armed_stabilizing()` |
| **Spool / slew / thrust-linearisation → PWM** | `AP_Motors/AP_MotorsMatrix.cpp:143` `output_to_motors()` |
| Last flight-code touch → SRV_Channels | `AP_Motors/AP_Motors_Class.cpp:96` `AP_Motors::rc_write()` |
| SITL: PWM → physics backend | `AP_HAL_SITL/SITL_State.cpp:287` `_simulator_servos()` |

### Planned implementation (Phases 4–5)

The signal path the assignment asks for, end to end:

| # | Link in the chain | Where |
|---|---|---|
| 1 | New message definition | `modules/mavlink/message_definitions/v1.0/ardupilotmega.xml` |
| 2 | C headers | regenerated automatically by waf's `mavgen` task (`Tools/ardupilotwaf/mavgen.py`) — editing the XML and rebuilding is enough |
| 3 | Python encoder for MAVProxy | **not** automatic — see the pymavlink gotcha in §7 |
| 4 | Copter receives it | `ArduCopter/GCS_MAVLink_Copter.cpp:1179` `GCS_MAVLINK_Copter::handle_message()` — already a switch that falls through to `GCS_MAVLINK::handle_message()` |
| 5 | Stored state | new setter on `AP_MotorsMatrix` / `AP_MotorsMulticopter` |
| 6 | **Applied to ESC output** | `AP_Motors/AP_MotorsMatrix.cpp:180`, the `rc_write()` call inside `output_to_motors()` |
| 7 | SITL: PWM → physics | `AP_HAL_SITL/SITL_State.cpp:287` `_simulator_servos()` (no change needed) |

**Injection point (step 6).** `rc_write()` inside `output_to_motors()` is *after*
spool state, slew limiting and thrust linearisation, so a zero written there is a
genuine final ESC command that the stability patch cannot rescale. This is the
"command to the ESC drivers" the assignment names, and it is identical on real
hardware — which is the point.

**Message definition (step 1).** ArduPilot's dialect currently uses IDs up to
`11060`; the ArduPilot-reserved range runs to 11999, so the next free ID is
**11061**. Payload: one `uint8_t` motor index, 1–4. Worth adding a target
system/component field to match MAVLink convention.

**Open question — literal new message vs. a new `MAV_CMD`.** The assignment says
"a new MAVLink message", which reads literally as a new message ID. The cheaper
route is a new `MAV_CMD` enum value carried inside the existing `COMMAND_LONG`.
Plan for the literal reading: it is the more instructive plumbing exercise and
unambiguously satisfies the ask. Confirm with the supervisor if time is tight.

**Trap — motor numbering (step 5→6).** The user-facing 1–4 is not necessarily
`_thrust_rpyt_out[0..3]`. ArduPilot's motor-test ordering, the frame's motor
map, and the servo channel index are three different numberings for a quad-X.
Verify which one "motor 1" means before wiring the index straight through, and
record the answer here.

**Sending from MAVProxy (step 3).** A custom message needs a way to be typed at
the MAVProxy prompt. Cleanest is a small MAVProxy module registering a
`motorfail <1-4>` command. It must run against a pymavlink built from the *same*
modified XML.

### Baseline that needs no code (Phase 3)

ArduPilot already kills a motor in-sim via `SIM_ENGINE_FAIL` (bitmask) +
`SIM_ENGINE_MUL`, applied at `SITL_State.cpp:331-341` — *before*
`sitl_model->update_model()`, so it reaches the Gazebo JSON backend too.

That simulates a **hardware** failure the flight controller knows nothing about.
It is the right smoke test for the sim stack before any ArduPilot patch, and the
comparison baseline for the commanded kill built in Phases 4–5.

---

## 6. Decisions

| Decision | Why |
|---|---|
| Gazebo **Harmonic** (`libgz-sim8-dev`), not Garden or gazebo-classic | What the plugin README recommends; classic is EOL and its packages conflict with `gz-harmonic` |
| Kill at `rc_write()`, not in `output_armed_stabilizing()` | Downstream of the stability patch, so the mixer can't compensate the zero away |
| ~~`MOT_KILL_MASK` bitmask param, not a new MAVLink message~~ **Reversed 2026-08-25** | The assignment requires a new MAVLink message carrying a motor index 1–4. The protocol work *is* the exercise, not overhead to be avoided |
| Kill one motor by index (1–4), not a bitmask | Matches the assignment's payload. A bitmask is a superset and can come later if useful |
| Keep `rc_write()` as the injection point | Unchanged by the reversal above — only the *trigger* changed, not where the zero is applied |
| ArduPilot + plugin as **bind-mounted host clones**, not baked into the image | Sources, venv and build artifacts persist and stay usable by host-side tooling |
| Vendored `install-prereqs-ubuntu.sh` into `docker/` | Avoids a redundant multi-GB clone at image-build time; this router's DNS chokes on parallel submodule fetches |
| No ROS / ROS 2 | The plugin talks to SITL directly over UDP; ROS only matters for ROS-side control |
| ~~Headless by default (`gz sim -s`)~~ **Reversed 2026-08-25** | The assignment requires the drone visualised during the demo. Headless stays useful for iteration, but the deliverable needs rendering — see §4 |
| Keep Phase 3 (`SIM_ENGINE_FAIL` baseline) despite it not being in the assignment | Proves the sim stack independently, so a Phase 5 failure is attributable to the patch and not the environment |

---

## 7. Gotchas already paid for

Do not rediscover these.

- `ubuntu:24.04` ships a uid-1000 `ubuntu` user — `userdel` it before creating `rusik`.
- The vendored prereq script needs `USER=rusik` and the `SKIP_AP_GIT_CHECK` /
  `SKIP_AP_GRAPHIC_ENV` / `SKIP_AP_COMPLETION_ENV` flags; it also requires
  `Tools/completion/completion.bash` to exist, hence the second `COPY`. Cleaning up
  `/tmp/ardupilot` needs `sudo` because `COPY`'d files are root-owned.
- The package is **`cppzmq-dev`**, not `libcppzmq-dev` — needed for the
  `gz-transport13` CMake target.
- `pip` during image build hits flaky PyPI DNS on this router; its retries usually
  save it. `pexpect` was missing from the venv and had to be installed after.
- The ccache volume came up root-owned and had to be `chown`ed to `rusik` once.
- Env vars set in `~/.bashrc` are invisible to non-interactive `docker exec` —
  Ubuntu's `.bashrc` returns early when `PS1` is unset.
- Without `GZ_SIM_SYSTEM_PLUGIN_PATH` / `GZ_SIM_RESOURCE_PATH`, `gz sim` starts
  fine and the drone just sits inert — **no error is printed**. #1 setup failure.

Anticipated, not yet hit (Phases 4–5):

- **pymavlink will not know the new message.** The venv's pymavlink comes from
  PyPI (`venv-ardupilot/lib/python3.12/site-packages/pymavlink`), while waf
  regenerates only the *C* headers from the edited XML. MAVProxy will fail to
  encode the message until pymavlink is reinstalled from
  `~/ardupilot/modules/mavlink/pymavlink` built against the same modified XML.
  Symptom to expect: the C++ side compiles and looks correct, but nothing can
  send the message. Both sides must be generated from one XML or the CRC-extra
  bytes disagree and the message is silently dropped.

---

## 8. Next actions

1. **Phase 2** — bring up the full loop: `gz sim -v4 -r iris_runway.sdf` in one
   shell, `sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON` in another.
   Confirm `JSON control interface set to 127.0.0.1:9002`, EKF/GPS lock,
   `mode STABILIZE`, and `arm throttle` spinning props. Settle the visualisation
   path (§4) here, not at demo time.
2. **Phase 3** — `param set SIM_ENGINE_FAIL 2` + `param set SIM_ENGINE_MUL 0` in
   flight. Confirm the sim stack reacts. Baseline recorded.
3. **Phase 4** — add the message to `ardupilotmega.xml` (ID 11061), rebuild
   ArduCopter, **and** reinstall pymavlink from the submodule (§7). Prove
   round-trip: MAVProxy sends, SITL logs receipt. No motor behaviour yet.
4. **Phase 5** — resolve the motor-numbering question (§5), add the setter and the
   `rc_write()` check, rebuild. Verify motor N and only motor N goes to zero.
5. **Phase 6** — fly, send `motorfail 3` in Stabilize, record takeoff → command →
   crash. Log `RATE`, `ATT`, `MOTB`, `RCOU`; keep the video and the `.bin`.

Keep the ArduPilot changes as a tracked patch in this repo — the ArduPilot tree
itself is not version-controlled here (§3).

### Open questions

- Literal new MAVLink message, or a new `MAV_CMD` inside `COMMAND_LONG`? (§5)
- Which numbering does "motor 1–4" mean — motor-test order, frame motor map, or
  servo channel? (§5)
- Is a live GUI required for the demo, or is a recording acceptable? (§4)

---

## 9. Changelog

| Date | Change |
|---|---|
| 2026-08-25 | Renamed `PROJECTS.md` → `PROJECT.md`; updated every reference in `CLAUDE.md`, `AGENTS.md`, `README.md` and `.gitignore` |
| 2026-08-25 | Assignment received; rewrote §1 around it. Reversed two decisions: a new MAVLink message is now required (not a param), and visualisation is now required (not headless-only). Phases re-cut from 5 to 6 |
| 2026-08-25 | Added `PROJECT.md` + `CLAUDE.md`; committed the `docker/` environment (Dockerfile, run.sh, first-run.sh, vendored prereq script) |
| 2026-08-25 | Environment verified end-to-end in the container; image rebuilt with `cppzmq-dev` baked in |
| 2026-08-25 | Initial commit: `docs/ENVIRONMENT_SETUP.md`, `scripts/setup_env.sh`, README with the mixer map |
