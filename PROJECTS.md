# PROJECTS.md — sitl_drone ground truth

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

Fly ArduCopter (ArduPilot) in a Gazebo simulation and add a hook into the
multicopter mixer that commands an **individual motor to zero on demand**, in
flight, while in Stabilize mode — then record the resulting departure.

Success is a reproducible experiment, not a shipped feature.

### Phases

| # | Phase | State |
|---|---|---|
| 1 | Provision the build/sim environment | **Done** |
| 2 | Get ArduCopter SITL flying an iris quad in Gazebo | **Not started** |
| 3 | Baseline: kill a rotor with `SIM_ENGINE_FAIL` (no code change) | **Not started** |
| 4 | Patch the mixer: `MOT_KILL_MASK` per-motor kill | **Not started** |
| 5 | Trigger in flight, in Stabilize; log and analyse the departure | **Not started** |

---

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

---

## 3. Repo layout

| Path | What it is |
|---|---|
| [README.md](README.md) | Short public-facing overview: goal, mixer map, run commands |
| [PROJECTS.md](PROJECTS.md) | **This file** — living ground truth |
| [CLAUDE.md](CLAUDE.md) | Rules for agents working in this repo |
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

### Planned patch (Phase 4)

- **Injection point:** `output_to_motors()`, at the `rc_write()` call
  (`AP_MotorsMatrix.cpp:180`). This is *after* spool state, slew limiting and
  thrust linearisation, so a zero written here is a genuine final command that the
  stability patch cannot rescale.
- **Trigger:** a new `MOT_KILL_MASK` bitmask parameter. Next free index in
  `AP_MotorsMulticopter`'s `var_info` is **46** (45 is `IDLE_SEC`). Settable live
  over MAVLink — no new protocol work needed.

### Baseline that needs no code (Phase 3)

ArduPilot already kills a motor in-sim via `SIM_ENGINE_FAIL` (bitmask) +
`SIM_ENGINE_MUL`, applied at `SITL_State.cpp:331-341` — *before*
`sitl_model->update_model()`, so it reaches the Gazebo JSON backend too.

That simulates a **hardware** failure the flight controller knows nothing about.
It is the right smoke test for the sim stack before any ArduPilot patch, and the
comparison baseline for `MOT_KILL_MASK`.

---

## 6. Decisions

| Decision | Why |
|---|---|
| Gazebo **Harmonic** (`libgz-sim8-dev`), not Garden or gazebo-classic | What the plugin README recommends; classic is EOL and its packages conflict with `gz-harmonic` |
| Kill at `rc_write()`, not in `output_armed_stabilizing()` | Downstream of the stability patch, so the mixer can't compensate the zero away |
| `MOT_KILL_MASK` bitmask param, not a new MAVLink message | Params are already settable live over MAVLink; zero protocol work |
| ArduPilot + plugin as **bind-mounted host clones**, not baked into the image | Sources, venv and build artifacts persist and stay usable by host-side tooling |
| Vendored `install-prereqs-ubuntu.sh` into `docker/` | Avoids a redundant multi-GB clone at image-build time; this router's DNS chokes on parallel submodule fetches |
| No ROS / ROS 2 | The plugin talks to SITL directly over UDP; ROS only matters for ROS-side control |
| Headless by default (`gz sim -s`) | Physics still runs, so motor-kill tests are valid without a GPU |

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

---

## 8. Next actions

1. **Phase 2** — bring up the full loop: `gz sim -v4 -s -r iris_runway.sdf` in one
   shell, `sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON` in another.
   Confirm `JSON control interface set to 127.0.0.1:9002`, EKF/GPS lock,
   `mode STABILIZE`, and `arm throttle` spinning props.
2. **Phase 3** — `param set SIM_ENGINE_FAIL 2` + `param set SIM_ENGINE_MUL 0` in
   flight. Record the departure. This is the baseline.
3. **Phase 4** — implement `MOT_KILL_MASK` at `AP_MotorsMatrix.cpp:180`; keep the
   patch as a tracked diff in this repo.
4. **Phase 5** — automate the run with a pymavlink script; log `RATE`, `ATT`,
   `MOTB`, `RCOU`; compare Phase 3 vs Phase 4 departures.

---

## 9. Changelog

| Date | Change |
|---|---|
| 2026-08-25 | Added `PROJECTS.md` + `CLAUDE.md`; committed the `docker/` environment (Dockerfile, run.sh, first-run.sh, vendored prereq script) |
| 2026-08-25 | Environment verified end-to-end in the container; image rebuilt with `cppzmq-dev` baked in |
| 2026-08-25 | Initial commit: `docs/ENVIRONMENT_SETUP.md`, `scripts/setup_env.sh`, README with the mixer map |
