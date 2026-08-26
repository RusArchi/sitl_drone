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
  explicitly not the exercise (see §6 Decisions).
- **Visualisation is required.** Headless-only is no longer sufficient for the
  deliverable (see §4 Environment).

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

The three-motor recovery goal also informs design choices *now* — see §5 Technical ground truth on why
the trigger should be a `MAV_CMD`.

### Phases

| # | Phase | State |
|---|---|---|
| 1 | Provision the build/sim environment | **Done** |
| 2 | ArduCopter SITL flying an iris quad in Gazebo, with visualisation | **Done** 2026-08-26 |
| 3 | Baseline: kill a rotor with `SIM_ENGINE_FAIL` (no code change) | **Not started** |
| 4 | Define the new `MAV_CMD`; handle it in Copter; prove round-trip | **Not started** |
| 5 | Handle it in Copter; propagate motor index down to the ESC output | **Not started** |
| 6 | Send from MAVProxy in flight; record takeoff → command → crash | **Not started** |

Phase 3 is not in the assignment. It is kept as a **sim-stack smoke test and
comparison baseline** — it proves the mixer→PWM→Gazebo chain works before any
patch exists, so a later failure can be attributed to the patch rather than the
environment.

## 2. Current status

**Phase 2 complete — the iris flies in Gazebo under scripted control.**

Verified 2026-08-26: `scripts/fly_demo.py` connects to SITL, waits for GPS (3D
fix in ~16 s), arms in GUIDED, takes off to 15 m, flies a 20 m square via
`SET_POSITION_TARGET_LOCAL_NED`, lands and disarms. The Gazebo GUI renders it
live on the desktop. That exercises the entire chain the motor-kill work will
modify: mixer → PWM → `_simulator_servos()` → JSON → `ardupilot_gazebo` → physics.

Environment (verified 2026-08-25, unchanged):

- Container `sitl_drone` (`ubuntu:24.04`) with `~/ardupilot`, `~/ardupilot_gazebo`,
  the repo and a ccache volume bind-mounted.
- `docker/run.sh check` → **Environment OK** — gz sim 8.15.0, plugin built,
  `arducopter` built, venv present, `pymavlink` importable.
- GZ env vars and the `Tools/autotest` PATH entry are baked into the **image** as
  `ENV`, so they survive container recreation and reach non-interactive
  `docker exec`.
- GUI wiring is live: `run.sh` finds the desktop's X display even over ssh.
  Rendering is software (llvmpipe) and that is fine — see §4 Environment.

### How to bring the sim up

Order matters — Gazebo first, then SITL, or the JSON link never forms.

```bash
docker exec -d sitl_drone bash -lc 'setsid gz sim -v2 -r iris_runway.sdf > /tmp/gz_sim.log 2>&1'
docker exec -d sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && cd ~/ardupilot && \
    setsid sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON --no-mavproxy > /tmp/sitl.log 2>&1'
docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \
    python3 /workspace/sitl_drone/scripts/fly_demo.py'
```

Next action is Phase 3 (§8 Next actions).

---

## 3. Repo layout

| Path | What it is |
|---|---|
| [README.md](README.md) | Short public-facing overview: goal, mixer map, run commands |
| [PROJECT.md](PROJECT.md) | **This file** — living ground truth |
| [CLAUDE.md](CLAUDE.md) | Rules for agents working in this repo |
| [AGENTS.md](AGENTS.md) | Pointer to CLAUDE.md, for agents that look for this filename |
| [docs/ENVIRONMENT_SETUP.md](docs/ENVIRONMENT_SETUP.md) | Full from-scratch provisioning reference (11 sections) |
| [scripts/record_demo.sh](scripts/record_demo.sh) | Bring up Gazebo + SITL on a private Xvfb display, record the flight to `recordings/*.mp4` |
| [docker/gz/gui-record.config](docker/gz/gui-record.config) | Minimal Gazebo GUI for recording — 3D view only, no docked panels |
| [scripts/setup_env.sh](scripts/setup_env.sh) | Host provisioner; `--check` verifies without changing anything |
| [scripts/fly_demo.py](scripts/fly_demo.py) | Phase 2 smoke flight: arm, take off, fly a square, land. Scripted, no sticks |
| [docker/Dockerfile](docker/Dockerfile) | Reproducible Ubuntu 24.04 build/sim image |
| [docker/run.sh](docker/run.sh) | `build` / `run` / `shell` / `check` / `gui-check` / `stop` wrapper; wires the GUI in when `DISPLAY` is set |
| [docker/first-run.sh](docker/first-run.sh) | One-time in-container provisioning against the bind-mounted clones (idempotent) |
| [docker/install-prereqs-ubuntu.sh](docker/install-prereqs-ubuntu.sh) | Vendored copy of ArduPilot's official prereq script (see §6 Decisions) |
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
`docs/ENVIRONMENT_SETUP.md` §6 (Headless operation) that turned out to be wrong. Verified 2026-08-25:
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
| 1 | New `MAV_CMD` enum value | `modules/mavlink/message_definitions/v1.0/ardupilotmega.xml`, in the `MAV_CMD` enum |
| 2 | C headers | regenerated automatically by waf's `mavgen` task (`Tools/ardupilotwaf/mavgen.py`) — editing the XML and rebuilding is enough |
| 3 | Python side (MAVProxy / script) | **no rebuild needed** — `COMMAND_LONG` already exists, so stock pymavlink can send the new id as a number. Regenerate only to get the *name* |
| 4 | Copter receives it | `ArduCopter/GCS_MAVLink_Copter.cpp:470` `handle_command_int_packet()` — add a `case`, exactly as `MAV_CMD_DO_MOTOR_TEST` does at line 487 |
| 5 | Stored state | new setter on `AP_MotorsMatrix` / `AP_MotorsMulticopter` |
| 6 | **Applied to ESC output** | `AP_Motors/AP_MotorsMatrix.cpp:180`, the `rc_write()` call inside `output_to_motors()` |
| 7 | SITL: PWM → physics | `AP_HAL_SITL/SITL_State.cpp:287` `_simulator_servos()` (no change needed) |

**Injection point (step 6).** `rc_write()` inside `output_to_motors()` is *after*
spool state, slew limiting and thrust linearisation, so a zero written there is a
genuine final ESC command that the stability patch cannot rescale. This is the
"command to the ESC drivers" the assignment names, and it is identical on real
hardware — which is the point.

**Command definition (step 1).** Add an entry to the `MAV_CMD` enum in
`ardupilotmega.xml`. `param1` = motor number 1–4 (output-channel convention,
see below); leave `param2` free for a later failure *mode* (hard stop, partial
thrust) once the three-motor recovery work starts. `MAV_CMD_USER_1..5`
(31010–31014, already in `common.xml`) are reserved for exactly this kind of
experiment and need **no XML edit at all** — worth using for the first
round-trip test before committing to a named command.

**New message vs. new `MAV_CMD` — use `MAV_CMD`.** Decided 2026-08-25 (§6 Decisions).
Both traverse the same plumbing the assignment is about; a `MAV_CMD` adds an
enum value to `ardupilotmega.xml` and a `case` in the Copter command handler,
carries up to 7 float params, and gets acknowledgement and retry for free via
`COMMAND_ACK`. A brand-new message ID means hand-rolling all of that. For the
three-motor-recovery goal the ack matters: a safety command must be *known* to
have arrived.

**Rebuild cost differs, and this is the deciding practical point.** A new
*message* changes the wire format — new msgid and CRC-extra — so pymavlink
**must** be regenerated or the message is silently dropped. A new `MAV_CMD` is
just a number inside the existing `COMMAND_LONG`/`COMMAND_INT` payload, so the
format is unchanged and **stock pymavlink can send it today**; regenerating only
buys the human-readable name. Either way ArduCopter itself must be rebuilt.
Verified 2026-08-26.

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

**Sending from MAVProxy (step 3).** MAVProxy's built-in `long` command sends an
arbitrary `COMMAND_LONG`, so `long <cmd-id> <motor>` works with **no custom
module and no pymavlink rebuild**. A small MAVProxy module registering
`motorfail <1-4>` is nicer to demo but is sugar, not a requirement.

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
| ~~Headless by default (`gz sim -s`)~~ **Reversed 2026-08-25** | The assignment requires the drone visualised during the demo. Headless stays useful for iteration, but the deliverable needs rendering — see §4 Environment |
| Accept software rendering (llvmpipe); no NVIDIA passthrough | Measured: RTF is 0.47 with *and* without the GUI, so rendering is not the bottleneck and passthrough would gain nothing (§4 Environment). Supersedes an earlier row claiming the Intel iGPU would serve — wrong, the display is NVIDIA-driven |
| Trigger is a new **`MAV_CMD`**, not a new message ID | Same plumbing, but gets `COMMAND_ACK` retry/acknowledgement for free and carries 7 float params. For a safety command that must be known to have arrived, the ack is the deciding factor (§5 Technical ground truth) |
| Motor index uses the **output-channel** convention (1–4 → index 0–3) | What users see in `RCOU` logs and `MOT_` params. Motor-test order is a different mapping and agrees only for motor 1 (§5 Technical ground truth) |
| Explain-first working style on ArduPilot changes | Learning the ArduCopter structure is an explicit project goal, not a by-product (§1 Mission) |
| GUI wiring is conditional on `DISPLAY`, not a separate compose file | One code path serves both headless iteration and on-screen demo; nothing to forget to switch |
| `ffmpeg`/`mesa-utils` added as a late Dockerfile layer | Keeps the ~10-minute prereq layer cached; this router's apt DNS is flaky (§7 Gotchas) |
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

- **Nothing streams over MAVLink until you ask.** ArduPilot only sends periodic
  telemetry to a GCS that requested it. MAVProxy does this for you, so with
  `--no-mavproxy` and a raw pymavlink connection, `recv_match(type="GPS_RAW_INT")`
  blocks forever and looks exactly like a dead simulator. Send
  `request_data_stream_send(..., MAV_DATA_STREAM_ALL, 4, 1)` after the heartbeat.
- **`FRAME_CLASS`/`FRAME_TYPE` can come up unset**, and pre-arm then fails with
  `Arm: Motors: Check frame class and type`. Set `FRAME_CLASS=1` (quad) and
  `FRAME_TYPE=1` (X). These two are what select the `MOTOR_FRAME_TYPE_X` motor
  table at `AP_MotorsMatrix.cpp:592` — i.e. they populate the very mixer this
  project modifies.
- **Start Gazebo before SITL.** The JSON link does not form the other way round.

- **Screen capture of the desktop does not work.** The desktop is GNOME/Wayland;
  an XWayland root window has no readable pixels, so `ffmpeg -f x11grab` against
  the real display fails with `BadMatch` / "Cannot get the image data" and writes
  a 262-byte file. Record against a private **Xvfb** display instead — its root
  window is an ordinary pixmap. `wf-recorder` is not an alternative here: it
  needs `wlr-screencopy`, which is a wlroots protocol that mutter does not
  implement (GNOME uses xdg-desktop-portal + PipeWire).
- **`sim_vehicle.py` opens an xterm when `DISPLAY` is set**, and it lands on top
  of the render view. SITL needs no display — launch it with `env -u DISPLAY`.
- **Gazebo's `/gui/screenshot` service returns `data: true` and writes nothing.**
  Do not trust the boolean; check for the file.

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

1. ~~**Phase 2**~~ — done 2026-08-26, see §2 Current status.
2. **Phase 3** — `param set SIM_ENGINE_FAIL 2` + `param set SIM_ENGINE_MUL 0` in
   flight. Confirm the sim stack reacts. Baseline recorded.
3. **Phase 4** — add the message to `ardupilotmega.xml` (ID 11061), rebuild
   ArduCopter, **and** reinstall pymavlink from the submodule (§7 Gotchas). Prove
   round-trip: MAVProxy sends, SITL logs receipt. No motor behaviour yet.
4. **Phase 5** — resolve the motor-numbering question (§5 Technical ground truth), add the setter and the
   `rc_write()` check, rebuild. Verify motor N and only motor N goes to zero.
5. **Phase 6** — fly, send `motorfail 3` in Stabilize, record takeoff → command →
   crash. Log `RATE`, `ATT`, `MOTB`, `RCOU`; keep the video and the `.bin`.

Keep the ArduPilot changes as a tracked patch in this repo — the ArduPilot tree
itself is not version-controlled here (§3 Repo layout).

### Open questions

- Does the supervisor accept a `MAV_CMD` as "a new MAVLink message"? Decided to
  use one (§5 Technical ground truth); worth confirming, it is the only interpretive risk in the task.
- Why is Gazebo's RTF only 0.47 on an idle 8-core box? (§4 Environment)
- Is a live GUI required for the demo, or is a recording acceptable? (§4 Environment)

---

## 9. Changelog

| Date | Change |
|---|---|
| 2026-08-27 | Added `scripts/record_demo.sh` + a minimal Gazebo GUI config; the Phase 2 flight is now recorded to `recordings/*.mp4`. Added `xvfb`, `xdotool`, `x11-utils` to the image |
| 2026-08-26 | **Phase 2 done** — `scripts/fly_demo.py` flies the iris in Gazebo end to end (arm, takeoff, square, land). Added §10 troubleshooting log |
| 2026-08-25 | `run.sh` now finds the desktop's X display over ssh, so GUI setup needs no physical session. Corrected §4 Environment: display is NVIDIA-driven and rendering is software, but measured RTF is identical with and without the GUI, so no passthrough. Resolved motor numbering from source (§5 Technical ground truth); chose `MAV_CMD` over a new message ID (§6 Decisions); recorded the learning goal (§1 Mission) |
| 2026-08-25 | Fixed `run.sh` GUI path (unbound `DISPLAY` when headless); moved GZ env vars into the image so they survive container recreation and reach non-interactive `docker exec`; made `-it` conditional |
| 2026-08-25 | Wired the GUI into `docker/run.sh` (X socket, `/dev/dri`, `DISPLAY`, `xhost` auth) and added `ffmpeg` + `mesa-utils` to the image. Corrected §4 Environment: this machine has a display and GPUs, so `xvfb`/`x11vnc` are unnecessary |
| 2026-08-25 | Renamed `PROJECTS.md` → `PROJECT.md`; updated every reference in `CLAUDE.md`, `AGENTS.md`, `README.md` and `.gitignore` |
| 2026-08-25 | Assignment received; rewrote §1 Mission around it. Reversed two decisions: a new MAVLink message is now required (not a param), and visualisation is now required (not headless-only). Phases re-cut from 5 to 6 |
| 2026-08-25 | Added `PROJECT.md` + `CLAUDE.md`; committed the `docker/` environment (Dockerfile, run.sh, first-run.sh, vendored prereq script) |
| 2026-08-25 | Environment verified end-to-end in the container; image rebuilt with `cppzmq-dev` baked in |
| 2026-08-25 | Initial commit: `docs/ENVIRONMENT_SETUP.md`, `scripts/setup_env.sh`, README with the mixer map |

---

## 10. Troubleshooting log — wrong turns and what they cost

Mistakes, false diagnoses and dead ends, kept so they are not repeated. Each
entry: what was believed, what was actually true, and the lesson. **This section
is append-only** — unlike the rest of the file, history here *is* the value.

### 2026-08-26 — "Gazebo crashed" (it never did)

- **Believed:** Gazebo had died, because `pgrep -c "gz sim"` returned 0.
- **Actually:** it had been running for 16 minutes and was visible on the monitor
  the whole time. `pgrep` matches the process *name*, and `gz` is a Ruby script,
  so its `comm` is `ruby`. The pattern could never match.
- **Cost:** a false diagnosis that a second mistake was then built on.
- **Lesson:** use `pgrep -f` / `ps -eo args` to match command lines. And when a
  process check disagrees with what a human can see on screen, the check is wrong.

### 2026-08-26 — Started a second Gazebo server on top of a working one

- **Believed:** restarting Gazebo would restore the JSON link.
- **Actually:** the first server was still running, so two `ArduPilotPlugin`
  instances contended for UDP 9002/9003. This *broke* a link that had been fine.
- **Cost:** the working state was destroyed and had to be rebuilt.
- **Lesson:** before restarting anything, prove the old instance is gone. A
  remedy applied to a misdiagnosis is worse than no remedy.

### 2026-08-26 — "No GPS lock" blamed on the simulator

- **Believed:** SITL was not receiving physics from Gazebo.
- **Actually:** `fly_demo.py` never requested MAVLink data streams. ArduPilot
  sends periodic telemetry only to a GCS that asked; MAVProxy normally does it.
  With `--no-mavproxy`, `GPS_RAW_INT` simply never arrived.
- **Cost:** two failed flight attempts and a long detour into the sim stack.
- **Lesson:** a silent timeout waiting for a message is as likely to mean *nobody
  asked for it* as *the producer is broken*. Check the subscription first — it is
  cheaper than the alternative.

### 2026-08-25 — `run.sh` aborted with "DISPLAY: unbound variable"

- **Believed:** the GUI wiring was complete after the path with a display worked.
- **Actually:** `gui_args` emitted a blank line when `DISPLAY` was unset, so
  `mapfile` built a *one-element* array rather than an empty one; the
  "display detected" branch ran and dereferenced unset `$DISPLAY` under `set -u`.
- **Cost:** the user hit the crash, not the author.
- **Lesson:** test the branch you cannot personally exercise. "It worked for me"
  covers exactly one path.

### 2026-08-25 — "Render on the Intel iGPU"

- **Believed:** with two GPUs present, Mesa would drive the Intel one.
- **Actually:** the monitors hang off the NVIDIA card, so X hands the container
  an NVIDIA DRM device that Mesa cannot drive — it falls back to llvmpipe. The
  Intel path was never reachable.
- **Lesson:** which GPU *exists* is not which GPU *drives the display*. Check the
  pci id the GL client is actually handed.

### 2026-08-25 — `glxgears` offered as evidence

- **Believed:** 2492 FPS on llvmpipe meant software rendering was fine for Gazebo.
- **Actually:** meaningless — `glxgears` draws trivial geometry. The number that
  settled it was Gazebo's own real-time factor, identical (0.47) with and without
  the GUI, which showed rendering was not the bottleneck at all.
- **Lesson:** benchmark the real workload. A synthetic number that happens to
  support the conclusion is not support.

### 2026-08-25 — Premature recommendation of `nvidia-container-toolkit`

- **Believed:** hardware acceleration was needed, so the host needed the toolkit.
- **Actually:** measurement showed rendering costs nothing here. Caught before
  acting, but the recommendation had already been made in writing.
- **Lesson:** measure before recommending a host-level change.

### 2026-08-25 — Wait loop reported success immediately

- **Believed:** `out=$(grep -c ... || echo 0)`; `[ "$out" != "0" ]` detects a match.
- **Actually:** `grep -c` prints `0` *and* exits non-zero, so `|| echo 0` appended
  a second line. `out` became `"0\n0"`, never equal to `"0"`, so the loop exited
  on the first iteration claiming success.
- **Lesson:** in a `$(cmd || fallback)`, the fallback *appends* to output that was
  already produced. Use `grep -q` and test the exit status.

### 2026-08-25 — PROJECT.md not updated in the same change

- **Believed:** documenting the GPU findings could follow the code commit.
- **Actually:** CLAUDE.md requires the update in the same change, and the user had
  to ask. §4 Environment and §6 Decisions sat wrong in the meantime, which is worse than absent.
- **Lesson:** the rule exists because stale ground truth actively misleads. Apply
  it to one's own findings, not just to code changes.

### 2026-08-27 — the flight recording came out as a 262-byte file

- **Believed:** with `ffmpeg` in the image and a reachable X display, capturing
  the Gazebo window with `-f x11grab -i :0+0,0` would just work. The display had
  already been proven usable — `run.sh gui-check` rendered through it, and
  Gazebo's window really was on screen.
- **Actually:** the desktop is GNOME/**Wayland**. Gazebo was showing through
  XWayland, and an XWayland root window holds no readable pixels, so every frame
  grab failed with `BadMatch` ("Cannot get the image data ... error_code:8") and
  ffmpeg wrote a 262-byte container with no video. The flight itself completed
  perfectly, which made it look like a recording bug rather than an X one.
  Fixed by rendering to a private **Xvfb** display, whose root window is a plain
  pixmap, and capturing that.
- **Lesson:** "the display works" is not the same as "the display is readable".
  Rendering *to* a surface and reading pixels *back* are different capabilities,
  and Wayland deliberately removes the second one for X clients. When capture is
  needed, control the display server rather than borrowing the user's.

### 2026-08-27 — three takes recorded before anything useful was in frame

- **Believed:** once capture worked, the recording was done.
- **Actually:** the first usable take showed an empty runway with SITL's xterm
  covering a quarter of it; the second showed Gazebo's docked Entity Tree and
  Component Inspector occupying half the frame; the third framed the scene but
  left the aircraft a few pixels wide. Each needed a separate fix — `env -u
  DISPLAY` for the xterm, a stripped `--gui-config` for the panels, and
  `/gui/follow` with a tight offset for the framing.
- **Lesson:** verify the *content* of an artefact, not just that it was produced.
  A 21 MB mp4 and a 2 MB mp4 both look like success from the shell; only pulling
  a frame out and looking at it showed the difference. Extract and inspect one
  frame before declaring a recording done.
