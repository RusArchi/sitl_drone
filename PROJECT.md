# PROJECT.md — sitl_drone ground truth

> **This file is the single source of truth for the state of this project.**
> It is updated continuously as work happens. If this file and your memory
> disagree, this file wins. If this file and the code disagree, the code wins
> and *this file must be corrected in the same change*.
>
> Update rules: see [CLAUDE.md](CLAUDE.md).

**Last updated:** 2026-08-29
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
the new message reserves a `failure_type` field it does not yet use.

### Phases

| # | Phase | State |
|---|---|---|
| 1 | Provision the build/sim environment | **Done** |
| 2 | ArduCopter SITL flying an iris quad in Gazebo, with visualisation | **Done** 2026-08-26 |
| 3 | Baseline: kill a rotor with `SIM_ENGINE_FAIL` (no code change) | **Done** 2026-08-27 |
| 4 | Define the new message in `ardupilotmega.xml`; rebuild ArduCopter **and** pymavlink; prove round-trip | **In progress** — XML done 2026-08-29 |
| 5 | Handle it in Copter; propagate motor index down to the ESC output | **Not started** |
| 6 | Send from MAVProxy in flight; record takeoff → command → crash | **Not started** |

Phase 3 is not in the assignment. It is kept as a **sim-stack smoke test and
comparison baseline** — it proves the mixer→PWM→Gazebo chain works before any
patch exists, so a later failure can be attributed to the patch rather than the
environment.

## 2. Current status

**Phase 4 in progress — the message is defined; nothing is built against it yet.**

`MOTOR_FAILURE_SET` (id 11070) and the `MOTOR_FAILURE_TYPE` enum were added to
`ardupilotmega.xml` on 2026-08-29 — 16 lines, hand-written by Ruslan, the whole
protocol change. Verified by running mavgen over the edited dialect: it generates
cleanly, the field binds to the enum, and the message is 4 bytes with
**CRC-extra 97**. Captured as `patches/mavlink.patch` and the patch round-trip
tested (stash → apply → identical diff).

Nothing is compiled against it yet. Steps 2–4 of Phase 4 — waf build, pymavlink
reinstall, `handle_message()` case and the MAVProxy module — are open
(§8 Next actions).

### Resuming in a new session — read this first

The XML edit lives in `~/ardupilot/modules/mavlink`, a git submodule that **this
repo does not track**, and it is uncommitted there. Before doing anything else:

```bash
grep -c MOTOR_FAILURE ~/ardupilot/modules/mavlink/message_definitions/v1.0/ardupilotmega.xml
```

- **5** — the edit is present, carry on at §8 Next actions step 2.
- **0** — the tree was reset or the submodule updated. Restore it with
  `./scripts/apply_patches.sh`, then check again.

Then bring the sim up in the order below (Gazebo first), and note the build has
**not** been run since the XML changed, so `arducopter` in the container still
predates the new message.

**Phase 3 complete — a motor failure drops the aircraft, on video, with no code changes.**

Verified 2026-08-27: `scripts/fly_fail.py` takes off to 20 m, cruises 40 m north
in a straight line, then sets `SIM_ENGINE_FAIL=1` / `SIM_ENGINE_MUL=0` to kill
motor 1 (front right). The aircraft departs immediately and hits the ground 5.7 s
later, descent rate building to 18 m/s. Recorded to
`recordings/fly_fail-*.mp4`; frame analysis confirms the aircraft tracking
across the sky and then falling out of frame.

This is the **baseline**: `SIM_ENGINE_FAIL` is applied in `SITL_State.cpp` before
the physics backend, so it never passes through the mixer and the flight
controller never knows. The Phase 4–6 commanded kill must produce a comparable
departure while travelling the full path through `rc_write()`.

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

Next action is Phase 4 (§8 Next actions).

---

## 3. Repo layout

| Path | What it is |
|---|---|
| [README.md](README.md) | Short public-facing overview: goal, mixer map, run commands |
| [PROJECT.md](PROJECT.md) | **This file** — living ground truth |
| [CLAUDE.md](CLAUDE.md) | Rules for agents working in this repo |
| [AGENTS.md](AGENTS.md) | Pointer to CLAUDE.md, for agents that look for this filename |
| [docs/ENVIRONMENT_SETUP.md](docs/ENVIRONMENT_SETUP.md) | Full from-scratch provisioning reference (11 sections) |
| [scripts/fly_fail.py](scripts/fly_fail.py) | Phase 3: straight-line cruise, then kill motor 1 via `SIM_ENGINE_FAIL`, log the fall |
| [docker/gz/gui-crash.config](docker/gz/gui-crash.config) | Static side-on Gazebo camera for the failure run |
| [docker/gz/gui-crash-close.config](docker/gz/gui-crash-close.config) | Closer static side-on variant (camera 20 m off the line, not 38 m) |
| [scripts/tune_camera.sh](scripts/tune_camera.sh) | Open Gazebo and leave it open, for finding a camera angle by hand |
| [scripts/camera_pose.sh](scripts/camera_pose.sh) | Print the live GUI camera pose as a paste-ready `<camera_pose>` |
| [docker/gz/gui-crash-above.config](docker/gz/gui-crash-above.config) | Elevated diagonal camera over the crash zone |
| [scripts/record_demo.sh](scripts/record_demo.sh) | Bring up Gazebo + SITL on a private Xvfb display, record the flight to `recordings/*.mp4` |
| [docker/gz/gui-record.config](docker/gz/gui-record.config) | Minimal Gazebo GUI for recording — 3D view only, no docked panels |
| [scripts/make_patches.sh](scripts/make_patches.sh) | Capture the ArduPilot-tree changes into `patches/`; run after any edit there |
| [scripts/apply_patches.sh](scripts/apply_patches.sh) | Re-apply `patches/` to the ArduPilot tree after a fresh clone or a wiped submodule |
| `patches/mavlink.patch` | The `ardupilotmega.xml` change — `MOTOR_FAILURE_SET` + `MOTOR_FAILURE_TYPE` |
| `patches/BASE` | The two commits the patches were made against, so they can be rebased knowingly |
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

### Camera modes for recording

`scripts/record_demo.sh` takes `CAM_MODE`, which maps to Gazebo's five tracking
modes published on the `/gui/track` topic:

| `CAM_MODE` | Mode | Behaviour |
|---|---|---|
| `static` (default) | — | Camera stays at the `gui-config` pose |
| `track` | `TRACK` (1) | Camera stays put, pans/tilts to keep the vehicle centred |
| `follow` | `FOLLOW` (2) | Rigid **body-frame** offset — whips around on a tumble |
| `free_look` | `FOLLOW_FREE_LOOK` (3) | Follows position, does not inherit orientation |
| `look_at` | `FOLLOW_LOOK_AT` (4) | Follows **and** always aims at the vehicle |

`CAM_OFFSET` (e.g. `x: -7, y: -3, z: 2`) and `CAM_PGAIN` tune the chase. Higher
pgain tightens tracking; at the default 0.8 the camera lags badly behind a
falling aircraft. Verified 2026-08-27: `look_at` keeps the vehicle in frame
through the tumble, where plain `follow` loses it completely.

### Running a recording — all the knobs

Everything is environment variables on `scripts/record_demo.sh`; nothing needs
editing to change a flight or a shot.

```bash
# Copy-paste as-is. Do NOT add trailing comments after the backslashes: a line
# continuation must be the last character on the line, and a comment after it
# breaks the command into fragments ("docker exec requires at least 2 arguments",
# then "command not found: -e" for every remaining line).
docker exec \
  -e FLIGHT=fly_fail.py \
  -e TELEM=1 \
  -e CAM_POSE="3.7 12.2 4.6 0 0.41 -2.58" \
  -e TAKEOFF_ALT=4 \
  -e CRUISE_N=10 \
  -e CRUISE_SPEED=2 \
  -e KILL_AFTER=4 \
  -e MOTOR=1 \
  -e CAM_MODE=static \
  -e GUI_CFG=/workspace/sitl_drone/docker/gz/gui-crash-above.config \
  sitl_drone /workspace/sitl_drone/scripts/record_demo.sh
```

| Variable | Meaning |
|---|---|
| `FLIGHT` | `fly_demo.py` (square) or `fly_fail.py` (motor cut) |
| `TELEM` | `1` adds the MAVProxy pane; canvas becomes 1920x1080 |
| `CAM_POSE` | `x y z roll pitch yaw`, metres and **radians** |
| `TAKEOFF_ALT` | metres |
| `CRUISE_N` | metres north; **negative flies south** |
| `CRUISE_SPEED` | m/s (sets `WPNAV_SPEED`); `0` = ArduPilot default |
| `KILL_AFTER` | seconds into the cruise before the motor is cut |
| `MOTOR` | 1-4, output-channel numbering; 1 = front right |
| `CAM_MODE` | `static` \| `track` \| `follow` \| `free_look` \| `look_at` |
| `GUI_CFG` | which `docker/gz/*.config` to render with |

Each run gets its own directory, `recordings/<flight>-<timestamp>/`:

| File | What it is |
|---|---|
Every file carries the run id, so a video sent on its own is still identifiable:

| File | Written by | Contents |
|---|---|---|
| `<id>.mp4` | `ffmpeg` capturing the Xvfb framebuffer | wall-clock video |
| `<id>-realtime.mp4` | `ffmpeg` re-encode | the same, re-timed by the measured RTF |
| `<id>-run.txt` | `record_demo.sh` | every parameter the run was given, plus start/finish times |
| `<id>-flight.log` | `scripts/fly_*.py` stdout | our own script: params set, takeoff, the motor cut, the fall |
| `<id>-mavproxy.log` | MAVProxy session | what the *vehicle* said — `AP:` messages, `COMMAND_ACK`s (only with `TELEM=1`) |
| `<id>-sitl.log` | `sim_vehicle.py` | waf build output and SITL launch |
| `<id>-ArduCopter.log` | the `arducopter` binary | flight-controller console: JSON link setup, EKF, physics backend |
| `<id>-gz_sim.log` | `gz sim` | Gazebo warnings, plugin loading, SDF parse messages |

The logs used to be written to `/tmp` and overwritten by the next run, so a
recording could not be explained afterwards. `run.txt` is written before
anything can fail, so even an aborted run says what it was.

**Framing rules of thumb, learned the hard way:**

- **World axes:** `+X` is north, `+Y` is east, `+Z` is up. Camera `yaw 0` looks
  along `+X`; `+pitch` looks **down**. The Gazebo origin grid spans about ±10 m,
  so "where the grid ends" is roughly 10 m out.
- **Fly toward where the camera is pointing.** `CRUISE_N` is positive-north and
  negative-south; which one keeps the aircraft on screen depends entirely on the
  camera's yaw. Check against the pose you are using rather than assuming.
- **A downward-pitched camera cannot see an aircraft above it.** With the camera
  at 4.6 m and a 8 m cruise, the aircraft sits above the top of frame. Either fly
  below the camera height or raise the camera.
- **Height separates the aircraft from the skyline.** A camera only a few metres
  above the cruise altitude puts it exactly on the horizon, where it vanishes.

### Setting a camera angle by hand

1. From a terminal **on the machine's desktop**:
   `docker exec -it sitl_drone /workspace/sitl_drone/scripts/tune_camera.sh`
   This opens Gazebo and leaves it open. Do **not** use `record_demo.sh` for
   this — it traps EXIT and kills Gazebo when the flight ends, so the window
   disappears while you are still aiming it.
2. `docker exec sitl_drone /workspace/sitl_drone/scripts/camera_pose.sh` prints the
   current pose, converted from Gazebo's quaternion into the `x y z roll pitch yaw`
   that `<camera_pose>` wants.
3. Either paste the `<camera_pose>` line into a `docker/gz/*.config`, or pass the
   numbers straight in: `CAM_POSE="22 -14 22 0 0.71 2.28"`.

Round-trip verified 2026-08-27: a config pose of `22 -14 22 0 0.715 2.279` reads
back identically.

### Recording telemetry alongside the sim

`TELEM=1` widens the canvas to 1920x1080 and puts a live MAVProxy terminal beside
Gazebo, so one recording carries the aircraft, the telemetry and any typed
command. **MAVProxy owns SITL's TCP link and fans out over UDP to the flight
script** (`CONNECT=udp:127.0.0.1:14551`), which is the standard ArduPilot
arrangement — see §7 Gotchas for the three wrong ways to wire this.

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
| 1 | New `<message>` id **11070** + `MOTOR_FAILURE_TYPE` enum | `modules/mavlink/message_definitions/v1.0/ardupilotmega.xml`. **Done 2026-08-29** |
| 2 | C headers | regenerated automatically by waf's `mavgen` task (`Tools/ardupilotwaf/mavgen.py`) — editing the XML and rebuilding is enough |
| 3 | Python side (MAVProxy / script) | **rebuild required** — a new msgid changes the wire format, so the venv's PyPI `pymavlink` must be replaced by one generated from the edited XML (§7 Gotchas) |
| 4 | Copter receives it | `ArduCopter/GCS_MAVLink_Copter.cpp:1179` `GCS_MAVLINK_Copter::handle_message()` — add a `case` to the `msg.msgid` switch, as `SET_ATTITUDE_TARGET` does at line 1184. Unhandled ids fall through to the base class and are **silently dropped** |
| 5 | Stored state | new setter on `AP_MotorsMatrix` / `AP_MotorsMulticopter` |
| 6 | **Applied to ESC output** | `AP_Motors/AP_MotorsMatrix.cpp:180`, the `rc_write()` call inside `output_to_motors()` |
| 7 | SITL: PWM → physics | `AP_HAL_SITL/SITL_State.cpp:287` `_simulator_servos()` (no change needed) |

**Injection point (step 6).** `rc_write()` inside `output_to_motors()` is *after*
spool state, slew limiting and thrust linearisation, so a zero written there is a
genuine final ESC command that the stability patch cannot rescale. This is the
"command to the ESC drivers" the assignment names, and it is identical on real
hardware — which is the point.

**Message definition (step 1) — DONE 2026-08-29.** This is what is in the file,
not a proposal. `MOTOR_FAILURE_TYPE` sits at the end of the `<enums>` block,
`MOTOR_FAILURE_SET` at the end of `<messages>`:

```xml
<enum name="MOTOR_FAILURE_TYPE">
  <description>Type of failure to inject on a motor output.</description>
  <entry name="MOTOR_FAILURE_TYPE_NONE" value="0">
    <description>Restore normal output.</description>
  </entry>
  <entry name="MOTOR_FAILURE_TYPE_STOPPED" value="1">
    <description>Force the output to zero.</description>
  </entry>
</enum>

<message id="11070" name="MOTOR_FAILURE_SET">
  <description>Fail and stop the chosen single motor (zero the speed command to ESC)</description>
  <field type="uint8_t" name="target_system">System ID.</field>
  <field type="uint8_t" name="target_component">Component ID.</field>
  <field type="uint8_t" name="motor">Motor to fail, 1 to 4, matching SERVO1 to SERVO4</field>
  <field type="uint8_t" name="failure_type" enum="MOTOR_FAILURE_TYPE">Motor stopped or restored</field>
</message>
```

Generated properties, measured not assumed: **4-byte payload, CRC-extra 97**.
Both numbers are the check for step 3 — the C build and pymavlink must agree on
them or the message is silently dropped (§7 Gotchas).

**Why id 11070 and not 11061.** 11061 was the first free number, but the file
leaves gaps between families deliberately — `ESC_TELEMETRY_1_TO_4` took 11030 and
its four later siblings landed at 11040–11044 because the room was there.
11070 starts a clean block instead of crowding `NAMED_VALUE_STRING` at 11060.
Note this is a **local** allocation: upstream ArduPilot does not know about it,
so a vehicle on upstream firmware would not agree what 11070 means.

**Why `motor` is a plain `uint8_t` and not a position enum.** FR/FL/RR/RL only
maps cleanly on a quad **X**. On a quad plus the same four outputs are
front/right/back/left; on a hexa or octa the names run out. Encoding a frame
assumption in the wire format would be locked in by the protocol — bad for the
three-motor recovery goal (§1 Mission). Nothing in MAVLink does this: there is no
`FRONT_RIGHT` in any of the nineteen dialect files, and the one motor-related
enum, `MOTOR_TEST_ORDER` in `common.xml`, is about test sequencing. Friendly
names belong in the MAVProxy module, translating `fr` → `1` before sending.

**Why `failure_type` is an enum and not a boolean.** MAVLink has no `bool` wire
type at all — booleans are `uint8_t` carrying 0/1, and `common.xml` provides
`MAV_BOOL` for the convention. Not used here because `failure_type` needs a third
value (partial thrust) as soon as the recovery work starts, and a field
documented as a boolean cannot grow one without breaking readers.

**New message vs. new `MAV_CMD` — use a NEW MESSAGE.** Decided 2026-08-27,
reversing the 2026-08-25 choice of `MAV_CMD`. The assignment says "create a new
MAVLink message", and Ruslan confirmed that is the requirement. A `MAV_CMD` is
*not* a new message — it is a new numbered value carried inside the existing
`COMMAND_LONG`. The engineering argument for `MAV_CMD` is recorded below and
still stands on its merits, but the requirement decides it.

**Superseded reasoning, kept because the trade-off is real:**
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

**Sending from MAVProxy (step 3) — a custom module is REQUIRED.** Verified
2026-08-27: MAVProxy has **no** command that sends an arbitrary message.
`mavproxy_cmdlong.py` provides `long`, which encodes a `COMMAND_LONG` and nothing
else; there is no generic equivalent. So the only way to send `MOTOR_FAILURE_SET`
from a MAVProxy terminal — which is what the assignment asks for — is a small
module registering `motorfail <1-4>`. This reverses the earlier note calling such
a module "sugar": that was written when the trigger was a `MAV_CMD`, and it does
not survive the switch to a real message. Build it in Phase 4, not Phase 6.

### How telemetry reaches a GCS

Relevant to Phase 4–6: the same channel carries the new message, and the same
trap catches scripts.

Two different things arrive at a GCS:

- **`STATUSTEXT`** — event text the firmware emits from `gcs().send_text()`
  (`AP: PreArm: Accels inconsistent`). Fires on events; no rate to configure.
- **Periodic streams** — ArduPilot pushing messages on a timer, governed by the
  `SRx_` parameters, one set per MAVLink channel, each a rate in Hz. Defined in
  `libraries/GCS_MAVLink/GCS_MAVLink_Parameters.cpp`.

| Parameter | Streams |
|---|---|
| `SRx_RAW_SENS` | `RAW_IMU`, `SCALED_IMU2/3`, `SCALED_PRESSURE`, `AIRSPEED` |
| `SRx_EXT_STAT` | `SYS_STATUS`, `POWER_STATUS`, `GPS_RAW_INT`, `NAV_CONTROLLER_OUTPUT` |
| `SRx_RC_CHAN` | `SERVO_OUTPUT_RAW`, `RC_CHANNELS` |
| `SRx_POSITION` | `GLOBAL_POSITION_INT`, `LOCAL_POSITION_NED` |
| `SRx_EXTRA1` | `ATTITUDE`, `SIMSTATE`, `AHRS2`, `ESC_TELEMETRY`, `PID_TUNING` |
| `SRx_EXTRA2` | `VFR_HUD` |
| `SRx_EXTRA3` | `AHRS`, `SYSTEM_TIME`, `WIND`, `RANGEFINDER` |

Rates get set three ways: the `SRx_` parameters (persistent), the legacy
`REQUEST_DATA_STREAM`, or per-message `MAV_CMD_SET_MESSAGE_INTERVAL`.

**The trap:** ArduPilot only sends periodic telemetry to a GCS that asked for it.
MAVProxy asks automatically; a raw pymavlink script does not. Omitting the
request makes a script hang waiting for `GPS_RAW_INT` that is never sent, which
looks exactly like a broken simulator — `fly_fail.py` calls
`request_streams()` for this reason.

A command sent *to* the vehicle (the Phase 4 message) needs none of this. But a
message reporting state *back* — a motor-failure status, say — would be added to
one of these stream groups and inherit the machinery above.

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
| ~~Use a `MAV_CMD` rather than a new message id~~ **Reversed 2026-08-27** | Chosen for the free `COMMAND_ACK` and zero pymavlink rebuild. But a `MAV_CMD` is a value inside `COMMAND_LONG`, not a new message, and the assignment asks for a new message. Requirement beats convenience. Cost: pymavlink **must** be regenerated, since a new message id changes the wire format and CRC-extra |
| Message `MOTOR_FAILURE_SET`, id **11070**, in `ardupilotmega.xml` | Defined in `ardupilotmega.xml` rather than a private dialect because that is what waf's mavgen and MAVProxy already load — no dialect plumbing to get wrong. 11070 rather than the first-free 11061 because the file leaves gaps between message families on purpose, so a new message starts a clean block instead of crowding `NAMED_VALUE_STRING` at 11060. Locally allocated — upstream does not know it (§5 Technical ground truth) |
| `motor` is a plain `uint8_t` output channel, not an FR/FL/RR/RL enum | Position names only map on a quad X and run out on a hexa/octa. A frame assumption in the wire format would be locked in by the protocol, which is wrong for the three-motor goal. Friendly names go in the MAVProxy module instead (§5 Technical ground truth) |
| `failure_type` is a `MOTOR_FAILURE_TYPE` enum, not a boolean | MAVLink has no `bool` wire type, and `MAV_BOOL` would not survive adding partial thrust as a third value (§5 Technical ground truth) |
| ArduPilot-tree changes mirrored as `patches/`, regenerated by a script | `modules/mavlink` is a submodule on a detached HEAD that this repo does not track; `git submodule update` discards uncommitted work there without warning. Round-trip tested 2026-08-29 (§3 Repo layout) |
| A custom MAVProxy `motorfail` module is required, not optional | MAVProxy can only send an arbitrary `COMMAND_LONG` (`long`), never an arbitrary message. With a real message id there is no other way to send it from a MAVProxy terminal, which the assignment requires. Reverses the earlier "sugar, not a requirement" note (§5 Technical ground truth) |
| Land the message in `handle_message()`, not a command handler | A new message id is dispatched by `msg.msgid`, not through `COMMAND_LONG`. Unhandled ids fall through to `GCS_MAVLINK::handle_message()` and vanish without a word, so the `case` is what makes receipt observable at all (§5 Technical ground truth) |
| Kill one motor by index (1–4), not a bitmask | Matches the assignment's payload. A bitmask is a superset and can come later if useful |
| Keep `rc_write()` as the injection point | Unchanged by the reversal above — only the *trigger* changed, not where the zero is applied |
| ArduPilot + plugin as **bind-mounted host clones**, not baked into the image | Sources, venv and build artifacts persist and stay usable by host-side tooling |
| Vendored `install-prereqs-ubuntu.sh` into `docker/` | Avoids a redundant multi-GB clone at image-build time; this router's DNS chokes on parallel submodule fetches |
| No ROS / ROS 2 | The plugin talks to SITL directly over UDP; ROS only matters for ROS-side control |
| ~~Headless by default (`gz sim -s`)~~ **Reversed 2026-08-25** | The assignment requires the drone visualised during the demo. Headless stays useful for iteration, but the deliverable needs rendering — see §4 Environment |
| Accept software rendering (llvmpipe); no NVIDIA passthrough | Measured: RTF is 0.47 with *and* without the GUI, so rendering is not the bottleneck and passthrough would gain nothing (§4 Environment). Supersedes an earlier row claiming the Intel iGPU would serve — wrong, the display is NVIDIA-driven |
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

- **SITL parameters persist in `eeprom.bin` across restarts.** An injected
  `SIM_ENGINE_FAIL` from a previous run is still armed on the next boot, and the
  aircraft simply refuses to take off with no obvious explanation. Flight scripts
  must clear it before flying — `fly_fail.py` does.
- **`/gui/follow` holds a BODY-frame offset.** The moment the aircraft tumbles
  the camera whips around with it and the vehicle leaves frame entirely. Fine for
  level flight, useless for a crash. Use `CAM_MODE=look_at` instead — see below.
- **Gazebo's camera modes live on the `/gui/track` TOPIC, not a service.**
  gz-gui 8 ships `gz.msgs.CameraTrack` and the `/gui/track` string inside
  `libCameraTracking.so`, but advertises **no** matching service, so
  `gz service -s /gui/track` just times out. Publish to the topic instead:
  `gz topic -t /gui/track -m gz.msgs.CameraTrack -p 'track_mode: 4, ...'`.
  Confirm with `gz topic -e -t /gui/currently_tracked`.
- **`time_boot_ms` counts from SITL boot, not from script start.** Using it
  directly to measure elapsed sim time overstates it badly; take a delta.

- **Wiring a second MAVLink client has three dead ends.** A SITL TCP port takes
  exactly one client, so a telemetry pane cannot simply share 5760 with the
  flight script. Of the spare ports SITL advertises, **5762 refuses connections**
  and **5763 connects but never streams** (`link 1 down`). `--out` is a *MAVProxy*
  option, so it silently does nothing under `--no-mavproxy`. And letting
  `sim_vehicle.py` start MAVProxy fails here — it runs it in the foreground of a
  shell with no TTY, so MAVProxy exits at once and takes the sim down
  (`SIM_VEHICLE: MAVProxy exited / Killing tasks`). What works: start MAVProxy
  yourself in an xterm owning `tcp:5760` with `--out 127.0.0.1:14551`, and point
  the flight script at that UDP port.
- **Camera height, not distance, is what makes the aircraft visible.** A camera
  only a few metres above the cruise altitude puts the aircraft exactly on the
  horizon, where it disappears into the skyline at any distance.
- **Narrowing `<horizontal_fov>` renders a blank grey scene** with no error
  logged. The telephoto approach to framing does not work in gz-gui 8.
- **A custom `--gui-config` silently disables mouse camera control** unless it
  includes `InteractiveViewControl`. The plugin draws no panel, so leaving it out
  of a "minimal" config looks harmless — but orbit, pan and zoom all stop
  working, which reads as a broken GUI rather than a missing plugin.
- **`xdotool` cannot drive Gazebo's viewport on Xvfb.** Synthetic mouse events do
  not reach the Qt render widget, so camera interaction cannot be verified
  headlessly — the stock config ignores them exactly like a custom one does.

- **The MAVLink XML schema validator fails on the pristine file.** `mavgen` with
  validation on rejects `ardupilotmega.xml` at the `<superseded>` element in
  message `RADIO` (id 166) — `SCHEMAV_ELEMENT_CONTENT`. Verified 2026-08-29 on
  the unmodified file, so it is **not** caused by local edits. waf builds fine.
  When hand-running mavgen to check an edit, pass `validate=False` or the error
  looks like your fault.
- **A backslash in a `<description>` becomes an escape sequence.** mavgen puts
  descriptions verbatim into Python `"""docstrings"""`, so `stopped\restored`
  produced a real carriage return (0x0d) in the generated help text. Use `/` or
  a word.
- **XML indentation in the dialect files is convention, not schema** — nothing
  will ever error on it. `ardupilotmega.xml` uses **2 spaces per nesting level**:
  2 for `<enums>`/`<messages>`, 4 for `<enum>`/`<message>`, 6 for
  `<entry>`/`<field>`, 8 for a `<description>` inside an entry.

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
3. **Phase 4** — four steps, in order. Each is separately verifiable on purpose:
   the characteristic failure here is *silent*, so testing only at the end leaves
   four possible causes instead of one.

   1. ~~Add `MOTOR_FAILURE_SET` + `MOTOR_FAILURE_TYPE` to `ardupilotmega.xml`~~
      **Done 2026-08-29** (§5 Technical ground truth). Captured in `patches/`.

   2. **Generate the C headers.** waf runs mavgen as part of the build, so this
      is just a build — but to watch mavgen on its own first, generate into a
      scratch directory and read what it writes:

      ```bash
      docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \
        python3 -m pymavlink.tools.mavgen --lang=C --wire-protocol=2.0 \
          --validate=False -o /tmp/hdr \
          ~/ardupilot/modules/mavlink/message_definitions/v1.0/ardupilotmega.xml'
      ```

      `--validate=False` is required: the schema validator fails on the
      **pristine** file, not because of local edits (§7 Gotchas).

      Then the real build:

      ```bash
      docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \
        cd ~/ardupilot && ./waf copter'
      ```

      **Verify:** `MAVLINK_MSG_ID_MOTOR_FAILURE_SET 11070` and `..._CRC 97` in
      `build/sitl/libraries/GCS_MAVLink/include/mavlink/v2.0/ardupilotmega/mavlink_msg_motor_failure_set.h`.

   3. **Regenerate pymavlink into the venv**, replacing the PyPI copy:

      ```bash
      docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \
        MAVLINK_DIALECT=ardupilotmega pip install --force-reinstall \
          ~/ardupilot/modules/mavlink/pymavlink'
      ```

      `setup.py` copies the XML out of `../message_definitions` and runs mavgen at
      install time, so it picks the edit up on its own. `MAVLINK_DIALECT` narrows
      generation to one dialect instead of all nineteen, twice each.

      **Verify — the step that actually matters:** Python's `crc_extra` for 11070
      must equal the C `_CRC` define. Both must read **97**. If they differ,
      everything downstream compiles, runs, looks correct and does nothing.

   4. **Make receipt visible.** A `case` in `GCS_MAVLINK_Copter::handle_message()`
      whose body is only a `GCS_SEND_TEXT`, plus a `motorfail` MAVProxy module
      kept in this repo (`load_module()` tries `MAVProxy.modules.mavproxy_<name>`
      then plain `<name>`, so a file on `PYTHONPATH` works — nothing to write
      into site-packages). **Verify:** type `motorfail 3`, see the text come
      back. **No motor behaviour yet.**
4. **Phase 5** — resolve the motor-numbering question (§5 Technical ground truth), add the setter and the
   `rc_write()` check, rebuild. Verify motor N and only motor N goes to zero.
5. **Phase 6** — fly, send `motorfail 3` in Stabilize, record takeoff → command →
   crash. Log `RATE`, `ATT`, `MOTB`, `RCOU`; keep the video and the `.bin`.

Run `scripts/make_patches.sh` after **every** edit to the ArduPilot tree — that
tree is not version-controlled here, and its `modules/mavlink` submodule can be
wiped by a `git submodule update` without warning (§3 Repo layout).

### Open questions

- ~~Does the supervisor accept a `MAV_CMD` as "a new MAVLink message"?~~
  **Closed 2026-08-27** — moot. The project builds a genuine new message
  (`MOTOR_FAILURE_SET`, id 11070), so the interpretive risk is gone.
- ~~Why is Gazebo's RTF only 0.47?~~ **Answered 2026-08-27** — CPU-bound in DART at the world's 1 ms step (`gz sim` sits at ~240% CPU). The world already asks for `real_time_factor 1.0`, so nothing is throttling it. A 2 ms step reaches RTF ~0.97 but **breaks SITL's JSON link** — arming never completes — so the step stays at 1 ms and the video is re-timed in post instead.
- Is a live GUI required for the demo, or is a recording acceptable? (§4 Environment)

---

## 9. Changelog

| Date | Change |
|---|---|
| 2026-08-29 | **Phase 4 step 1 done** — `MOTOR_FAILURE_SET` (id 11070) and the `MOTOR_FAILURE_TYPE` enum added to `ardupilotmega.xml` by hand; 4-byte payload, CRC-extra 97, verified by running mavgen over the edited dialect. Added `patches/` with `make_patches.sh` / `apply_patches.sh`, round-trip tested. Recorded three new §7 Gotchas: the validator fails on the pristine file, a backslash in a `<description>` becomes an escape, and the indentation convention |
| 2026-08-28 | Added §11 Glossary — one table defining the MAVLink, ArduPilot and Gazebo terms this file uses, so they are not re-explained inline. Placed at the end to avoid renumbering 43 cross-references |
| 2026-08-27 | Each recording is now a self-contained directory — video, real-time cut, `run.txt` manifest, flight/MAVProxy/SITL/Gazebo logs |
| 2026-08-27 | `set_mode` now retries (a single attempt raced the EKF and killed runs with "mode GUIDED not accepted"); added `CRUISE_SPEED`; documented every recording knob and the framing rules |
| 2026-08-27 | Planned Phase 4 and purged the `MAV_CMD` assumption from §1 Mission, §5 Technical ground truth, §6 Decisions and §8 Next actions — the 2026-08-27 reversal had been recorded but not propagated. Fixed the landing point to `handle_message()`, confirmed id 11061 free, and established that a MAVProxy module is required, not optional |
| 2026-08-27 | Restored `InteractiveViewControl` to the GUI configs (its absence froze the camera) and added `tune_camera.sh`, which leaves Gazebo open for setting an angle by hand |
| 2026-08-27 | `TELEM=1` records a live MAVProxy pane beside Gazebo. Added `camera_pose.sh` and `CAM_POSE` for setting angles by hand, plus an elevated diagonal crash camera |
| 2026-08-27 | Added `CAM_MODE` to `record_demo.sh` exposing Gazebo's five camera-tracking modes; `look_at` keeps the aircraft framed through the tumble. Fixed the RTF measurement to use a delta — now reports ~0.57 and writes a real-time cut |
| 2026-08-27 | Phase 3 done: `fly_fail.py` kills motor 1 in flight via `SIM_ENGINE_FAIL`, recorded. Reversed the `MAV_CMD` decision — the assignment requires a genuinely new message. Answered the RTF question and added post-hoc re-timing |
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

### 2026-08-27 — the drone would not take off, and nothing said why

- **Believed:** the Phase 3 script had a bug in its takeoff logic. It reached
  `arming...`, armed successfully, commanded takeoff to 20 m and then simply
  timed out — and the same script had reached 40 m minutes earlier.
- **Actually:** SITL stores parameters in `eeprom.bin` and **keeps them across
  restarts**. The previous run had set `SIM_ENGINE_FAIL=1`, so motor 1 was still
  dead when the next run started. The aircraft was trying to take off on three
  motors from the ground. Nothing in the MAVLink stream said so, because from
  the flight controller's point of view nothing was wrong.
- **Lesson:** a simulator with persistent state is not a fresh simulator. When a
  run mutates configuration, the next run inherits it — reset injected faults at
  the start of every script rather than assuming a clean boot.

### 2026-08-27 — chose engineering convenience over the stated requirement

- **Believed:** a `MAV_CMD` was the better route than a new message id — it gets
  `COMMAND_ACK` for free, carries 7 params, and needs no pymavlink rebuild. It
  was recorded as a decision in §6 Decisions with that reasoning.
- **Actually:** the assignment says "create a new MAVLink message". A `MAV_CMD`
  is a numbered value inside the existing `COMMAND_LONG` — it is not a new
  message, and the plumbing it skips is exactly the plumbing the exercise is
  about. Ruslan had to say so directly before it was reversed.
- **Lesson:** when a requirement is explicit, a cheaper alternative is a
  suggestion, not a decision. Surface the trade-off and let the person holding
  the requirement choose; do not record the convenient option as settled.

### 2026-08-27 — a reversal recorded in one place, left standing in six others

- **Believed:** reversing the `MAV_CMD` decision was done. It was written up in
  §5 Technical ground truth, struck through in §6 Decisions, logged in §10
  Troubleshooting log and added to §9 Changelog — four places, which felt
  thorough.
- **Actually:** §6 Decisions still carried a *live* row asserting the opposite
  ("Trigger is a new `MAV_CMD`, not a new message ID") two rows below the row
  striking it out. §1 Mission still pointed at "why the trigger should be a
  `MAV_CMD`". §5 Technical ground truth still said the Python side needed no
  rebuild, still named `handle_command_int_packet()` as the landing point, and
  still called the MAVProxy module "sugar, not a requirement" — the last two
  being wrong in a way that would have cost real time in Phase 4. A new msgid is
  dispatched by `msg.msgid` in `handle_message()`, and MAVProxy cannot send an
  arbitrary message at all. Ruslan had to ask for the cleanup.
- **Lesson:** a reversal is not applied until every line that *depended* on the
  old choice is found, not just the line that stated it. Grep the whole file for
  the rejected term before calling it done — the dangerous leftovers are the
  downstream consequences, which do not mention the decision by name and read as
  ordinary facts.

---

## 11. Glossary

Terms used throughout this file. **All of these are real vocabulary** — from
MAVLink, ArduPilot or Gazebo — not descriptions invented here. If an explanation
elsewhere in this file uses a word that is not in this table and not in the code,
it is a paraphrase and should be treated as such.

| Term | Meaning | Where it lives |
|---|---|---|
| **Dialect** | One XML file defining MAVLink messages. Dialects include each other: `ardupilotmega.xml` includes `common.xml`, which includes `minimal.xml`. ArduPilot builds `ardupilotmega`, so it gets all three | `modules/mavlink/message_definitions/v1.0/` |
| **msgid** | The message's number on the wire. `HEARTBEAT` is 0; ours is 11070. Distinct from a `MAV_CMD` value, which is a number *inside* `COMMAND_LONG` and not a message at all | `<message id="…">` |
| **CRC-extra** | A checksum byte derived from a message's name, field types and field order, mixed into every packet. Two builds generated from different XML disagree on it, and the receiver **drops the packet silently**. The Phase 4 trap (§7 Gotchas) | generated `_CRC` define |
| **mavgen** | MAVLink's code generator. Turns the XML into C headers and Python modules. Run by waf for C, by `pip install` for pymavlink | `Tools/ardupilotwaf/mavgen.py` |
| **pymavlink** | The Python MAVLink library. The venv's copy is from PyPI and knows nothing of local XML edits until reinstalled from `modules/mavlink/pymavlink` | `venv-ardupilot/…/pymavlink` |
| **SITL** | Software In The Loop — ArduPilot's real flight code compiled for the PC, with simulated sensors instead of hardware | `libraries/AP_HAL_SITL/` |
| **Mixer** | The step turning one roll/pitch/yaw/thrust demand into four per-motor thrusts, using the frame's motor table | `AP_MotorsMatrix::output_armed_stabilizing()` |
| **Stability patch** | The mixer's rescaling when a demand cannot be met — it trades thrust for attitude control. Why the motor kill goes *downstream* of it (§6 Decisions) | same function |
| **Spool state** | The armed/disarmed ramp — ground idle, spooling up, throttle unlimited. Motors do not jump to a commanded value | `AP_MotorsMulticopter` |
| **Thrust linearisation** | Correcting for thrust rising roughly with the *square* of motor speed, so a 50% demand gives 50% thrust rather than 25% | `AP_MotorsMulticopter` |
| **`rc_write()`** | The last line of flight code to touch a motor output before it becomes PWM. The kill injection point (§5 Technical ground truth) | `AP_Motors_Class.cpp:96` |
| **PWM** | The pulse width, ~1000–2000 µs, that a real ESC reads as a throttle command. What SITL ships to Gazebo instead of a wire | `SITL_State.cpp` |
| **Motor index vs. test order** | Two different 1–4 numberings. This project uses the **output-channel** one (1–4 → `SERVO1`–`SERVO4`). They agree only for motor 1 (§5 Technical ground truth) | `AP_MotorsMatrix.cpp:592` |
| **JSON backend** | The UDP link carrying servo outputs to Gazebo and vehicle state back. Ports 9002/9003 (§4 Environment) | `--model JSON` |
| **RTF** | Real-time factor. Gazebo's sim-seconds per wall-second; 0.47 here, and physics-bound (§4 Environment) | Gazebo |

### 2026-08-28 — the documented command could not be run

- **Believed:** the recording command written into PROJECT.md was ready to
  copy-paste. It had a comment beside each option explaining what it did.
- **Actually:** the comments came *after* the backslash line-continuations. A
  continuation has to be the last character on the line, so the shell ended the
  command at the first line and ran every following line on its own — `docker
  exec` complained about missing arguments, then nine `command not found: -e`.
  Ruslan hit this verbatim.
- **Lesson:** an example in documentation is code. If it is presented as
  copy-pasteable it has to be pasted and run at least once. Explanatory comments
  belong above the block or in a table beside it, never inside a continued
  command.

### 2026-08-28 — a "minimal" GUI config froze the camera

- **Believed:** the custom `--gui-config` files contained everything needed to
  render. They had been used for a dozen recordings without trouble.
- **Actually:** they omitted `InteractiveViewControl`, which is what implements
  orbit, pan and zoom. It draws no panel, so dropping it from a minimal config
  looked like removing clutter — but it silently disables all mouse camera
  control. Ruslan found it by trying to move the view and finding it dead.
- **Lesson:** when trimming a config down to essentials, "draws nothing" is not
  the same as "does nothing". Check what a component *does* before deciding it
  is decoration. Recording-only configs still get used interactively.

### 2026-08-28 — left a dead run going for seven minutes

- **Believed:** the recording had been launched, so reporting "I'll tell you when
  it finishes" was enough.
- **Actually:** a full run takes about ninety seconds, which was already known.
  The run was dead within the first minute — stale `ffmpeg` and flight processes
  from earlier attempts were still alive, and their cleanup traps run a global
  `pkill -f 'gz sim'`, which killed the new run's Gazebo. Ruslan waited seven
  minutes before asking. There were also 107 zombie processes, because the
  container's PID 1 is `sleep`, which never reaps orphans.
- **Cost:** seven minutes of the user's time, and the failure was self-inflicted.
- **Lesson:** if the expected duration of a background job is known, check at
  that duration. And a cleanup trap that pattern-kills by process name is not
  safe when runs can overlap — it will kill someone else's simulator.

### 2026-08-28 — a commit message described work that was not in the commit

- **Believed:** the commit that abandoned the telephoto camera had removed
  `gui-crash-tele.config`. The message said "Drops gui-crash-tele.config".
- **Actually:** the `rm` never made it into the staged change and the file stayed
  tracked. It was found days later, still present.
- **Lesson:** the commit message is a claim about the diff. Read the diff before
  describing it — `git status` after `git add` costs nothing and would have shown
  the deletion missing.

### 2026-08-28 — turned one measurement into a rule

- **Believed:** `CRUISE_N` had to be negative for the aircraft to stay in frame,
  and this was written into the framing notes as a rule.
- **Actually:** it held only for one particular camera pose. Which direction
  keeps the aircraft on screen follows the camera's yaw. Ruslan, who could see
  the screen, said the right value was positive.
- **Lesson:** a value measured under one configuration is a data point, not a
  rule. State the relationship that produced it and the check to make, so it
  survives a changed setup.
