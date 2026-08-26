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

### How this work is done — learning is a goal, not a by-product

Ruslan's aim is to **understand ArduCopter's structure**, not just to produce a
working demo. The motor-kill exercise is a stepping stone toward a novel safety
function: **keeping the aircraft controllable on three motors after one fails.**

That changes the working style. For anything touching ArduPilot:

- **Explain before changing.** Say what the code does today, where the change
  goes, and why there rather than elsewhere.
- **Prefer steps Ruslan can do by hand.** Small, inspectable edits over
  scripted bulk changes; name the file and the function, don't just patch.
- **Favour understanding over shortcuts** when the two conflict. A slower route
  that shows the control path is worth more here than a clever one that hides it.

The three-motor recovery goal also informs design choices *now* — see §5 on why
the trigger should be a `MAV_CMD`.

### Phases

| # | Phase | State |
|---|---|---|
| 1 | Provision the build/sim environment | **Done** |
| 2 | ArduCopter SITL flying an iris quad in Gazebo, with visualisation | **Not started** (GUI plumbing done, unverified) |
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
- GZ env vars and the `Tools/autotest` PATH entry are baked into the **image** as
  `ENV` (2026-08-25), so they survive container recreation and are visible to
  non-interactive `docker exec`. Verified: `docker exec sitl_drone printenv
  GZ_SIM_SYSTEM_PLUGIN_PATH` returns the path with no login shell.

Nothing is blocked. The next action is Phase 2.

Rendering path added 2026-08-25 (`docker/run.sh` GUI wiring, `ffmpeg` +
`mesa-utils` in the image). Both `run.sh` code paths tested; the headless path
runs and `run.sh check` passes. **Not yet verified on screen** — that needs the
container recreated from a graphical session. See §4.

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
| [docker/run.sh](docker/run.sh) | `build` / `run` / `shell` / `check` / `gui-check` / `stop` wrapper; wires the GUI in when `DISPLAY` is set |
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

### Visualisation

This machine is **not** a headless server — an earlier assumption in
`docs/ENVIRONMENT_SETUP.md` §6 that turned out to be wrong. Verified 2026-08-25:
GNOME/Wayland session running, X sockets `:0` and `:1` present, Intel HD 630
(`00:02.0`) + NVIDIA GTX 1050 Ti (`01:00.0`, driver 580.173.02), `/dev/dri`
render nodes available. So `xvfb`/`x11vnc` are **not needed**; render for real.

`docker/run.sh` wires the GUI in automatically **when `DISPLAY` is set at
container-creation time** — X socket, `/dev/dri`, `DISPLAY`, plus
`xhost +SI:localuser:` for auth. With `DISPLAY` unset it silently omits all of
it and the container is headless as before. Two consequences:

- **The container must be created from a graphical session** on this machine.
  `./run.sh stop && ./run.sh run` from the desktop; recreating is required
  because Docker cannot add mounts to an existing container.
- `./run.sh gui-check` reports the OpenGL renderer inside the container — use it
  to tell working GL from a silent software fallback.

No Gazebo packages were needed for this: `libgz-gui8` and
`libgz-rendering8-ogre2` were already in the image via the `gz-harmonic`
metapackage. The container could always render; it just had no screen to reach.

**Why X auth is granted by user, not by cookie file.** GNOME/Wayland keeps the X
cookie in a per-session randomly-named file (`/run/user/1000/.mutter-Xwaylandauth.XXXXXX`),
too volatile to bind-mount. `xhost +SI:localuser:$(id -un)` is stable and
narrower than the usual `xhost +local:`.

**Why GPU access needs no group juggling.** logind puts an ACL on `/dev/dri/*`
granting `user:rusik` — uid 1000. The container user is also uid 1000, so the
ACL carries over. `run.sh` adds the `video`/`render` groups anyway as a fallback
for when no seat ACL is present.

**Rendering is software (llvmpipe), and that is fine — measured, not assumed.**
The monitors hang off the NVIDIA card (`10de:1c82`), so X hands the container an
NVIDIA DRM device; Mesa has no driver for it (`failed to load driver: nvidia-drm`,
`glx: failed to create dri3 screen`) and falls back to the llvmpipe software
rasteriser. Making that hardware-accelerated would need `nvidia-container-toolkit`
on the host to inject version-matched driver blobs (580.173.02).

**Not worth doing.** Measured 2026-08-25 on `iris_runway.sdf`:

| Config | Real-time factor |
|---|---|
| `gz sim` with GUI (llvmpipe) | 0.47 |
| `gz sim -s` headless, same world | 0.47–0.50 |

Identical — so rendering costs nothing measurable and the bottleneck is physics.
NVIDIA passthrough would buy nothing. (An earlier claim that the *Intel* iGPU
would serve was wrong for the same reason: the display is NVIDIA-driven.)

**Open: why is RTF only 0.47?** Half real time on an idle 8-core box. Not
blocking — Gazebo and SITL stay in lockstep, so the physics remain valid, demos
just take 2× wall clock. Suspects: the 1 ms physics step, or a
`real_time_update_rate` cap in the world file.

### Ports (loopback; increment with `sim_vehicle.py -I N`)### Ports (loopback; increment with `sim_vehicle.py -I N`)

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

**New message vs. new `MAV_CMD` — use `MAV_CMD`.** Decided 2026-08-25 (§6).
Both traverse the same plumbing the assignment is about; a `MAV_CMD` adds an
enum value to `ardupilotmega.xml` and a `case` in the Copter command handler,
carries up to 7 float params, and gets acknowledgement and retry for free via
`COMMAND_ACK`. A brand-new message ID means hand-rolling all of that. For the
three-motor-recovery goal the ack matters: a safety command must be *known* to
have arrived. Both still require rebuilding ArduCopter **and** pymavlink.

**Motor numbering — resolved 2026-08-25** against `AP_MotorsMatrix.cpp:592`
(`MOTOR_FRAME_TYPE_X`). `add_motors()` assigns `motor_num` from the array index,
so index = output channel − 1. Angles are degrees clockwise from the nose:

| Internal index | Output ch. | Angle | Position | Prop | Test order |
|---|---|---|---|---|---|
| 0 | SERVO1 | +45° | **front right** | CCW | 1 |
| 1 | SERVO2 | −135° | back left | CCW | 3 |
| 2 | SERVO3 | −45° | front left | CW | 4 |
| 3 | SERVO4 | +135° | back right | CW | 2 |

So "motor 1 = front right" is correct. **But output channel and motor-test order
are not the same mapping** — they agree only for motor 1. Channel 2 is back
left; test order 2 is back right. Use the **output-channel** convention (1–4 →
index 0–3), which is what users see in `RCOU` logs and in `MOT_` parameters, and
say so in the message's field documentation.

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
| Accept software rendering (llvmpipe); no NVIDIA passthrough | Measured: RTF is 0.47 with *and* without the GUI, so rendering is not the bottleneck and passthrough would gain nothing (§4). Supersedes an earlier row claiming the Intel iGPU would serve — wrong, the display is NVIDIA-driven |
| Trigger is a new **`MAV_CMD`**, not a new message ID | Same plumbing, but gets `COMMAND_ACK` retry/acknowledgement for free and carries 7 float params. For a safety command that must be known to have arrived, the ack is the deciding factor (§5) |
| Motor index uses the **output-channel** convention (1–4 → index 0–3) | What users see in `RCOU` logs and `MOT_` params. Motor-test order is a different mapping and agrees only for motor 1 (§5) |
| Explain-first working style on ArduPilot changes | Learning the ArduCopter structure is an explicit project goal, not a by-product (§1) |
| GUI wiring is conditional on `DISPLAY`, not a separate compose file | One code path serves both headless iteration and on-screen demo; nothing to forget to switch |
| `ffmpeg`/`mesa-utils` added as a late Dockerfile layer | Keeps the ~10-minute prereq layer cached; this router's apt DNS is flaky (§7) |
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
- ~~Env vars set in `~/.bashrc` are invisible to non-interactive `docker exec`~~
  — **fixed 2026-08-25** by moving them to `ENV` in the Dockerfile. Root cause
  was Ubuntu's `.bashrc` returning early when `PS1` is unset.
- **`/home/rusik` is not bind-mounted**, so anything `first-run.sh` writes to
  `~/.bashrc` is lost when the container is recreated — and recreating is now
  routine, since adding the X/GPU mounts requires it. Container-persistent state
  belongs in the image or on a bind mount, not in the container filesystem.
- `docker exec -it` fails with "cannot attach stdin to a TTY-enabled container"
  when stdin is not a terminal. `run.sh` now adds `-it` only when `[[ -t 0 ]]`,
  so `check` works from scripts and agents.
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
   `mode STABILIZE`, and `arm throttle` spinning props. Recreate the container
   from a graphical session first (`./run.sh stop && ./run.sh run`), then confirm
   with `./run.sh gui-check` that GL is hardware and not llvmpipe.
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

- Does the supervisor accept a `MAV_CMD` as "a new MAVLink message"? Decided to
  use one (§5); worth confirming, it is the only interpretive risk in the task.
- Why is Gazebo's RTF only 0.47 on an idle 8-core box? (§4)
- Is a live GUI required for the demo, or is a recording acceptable? (§4)

---

## 9. Changelog

| Date | Change |
|---|---|
| 2026-08-25 | `run.sh` now finds the desktop's X display over ssh, so GUI setup needs no physical session. Corrected §4: display is NVIDIA-driven and rendering is software, but measured RTF is identical with and without the GUI, so no passthrough. Resolved motor numbering from source (§5); chose `MAV_CMD` over a new message ID (§6); recorded the learning goal (§1) |
| 2026-08-25 | Fixed `run.sh` GUI path (unbound `DISPLAY` when headless); moved GZ env vars into the image so they survive container recreation and reach non-interactive `docker exec`; made `-it` conditional |
| 2026-08-25 | Wired the GUI into `docker/run.sh` (X socket, `/dev/dri`, `DISPLAY`, `xhost` auth) and added `ffmpeg` + `mesa-utils` to the image. Corrected §4: this machine has a display and GPUs, so `xvfb`/`x11vnc` are unnecessary |
| 2026-08-25 | Renamed `PROJECTS.md` → `PROJECT.md`; updated every reference in `CLAUDE.md`, `AGENTS.md`, `README.md` and `.gitignore` |
| 2026-08-25 | Assignment received; rewrote §1 around it. Reversed two decisions: a new MAVLink message is now required (not a param), and visualisation is now required (not headless-only). Phases re-cut from 5 to 6 |
| 2026-08-25 | Added `PROJECT.md` + `CLAUDE.md`; committed the `docker/` environment (Dockerfile, run.sh, first-run.sh, vendored prereq script) |
| 2026-08-25 | Environment verified end-to-end in the container; image rebuilt with `cppzmq-dev` baked in |
| 2026-08-25 | Initial commit: `docs/ENVIRONMENT_SETUP.md`, `scripts/setup_env.sh`, README with the mixer map |
