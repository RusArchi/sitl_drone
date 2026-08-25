# Environment Setup — ArduCopter SITL + Gazebo motor-control testbed

Prep list for provisioning a machine to build ArduPilot SITL, run it against Gazebo,
and patch the multicopter mixer.

Everything below was checked against **ArduPilot master @ `cbe0c39`** and the
**ArduPilot/ardupilot_gazebo** README as of 2026-08-25.

---

## 0. Target platform

| Item | Choice | Notes |
|---|---|---|
| OS | **Ubuntu 24.04 LTS (noble)** | 22.04 (jammy) also fine. Both are supported by ArduPilot's prereq script *and* by the Gazebo Harmonic apt repo. |
| Gazebo | **Harmonic (LTS)** | `libgz-sim8-dev`. Garden (`libgz-sim7-dev`) also works; Harmonic is what the plugin README recommends. |
| Python | 3.10+ (system) | The prereq script builds a venv on 23.04+ — see §3. |
| Arch | x86_64 | arm64 works but Gazebo binary packages are thinner. |

### Resources

- **Disk: ~15 GB free.** ArduPilot with submodules ≈ 2 GB, build output ≈ 1–2 GB,
  Gazebo + models ≈ 3 GB, apt cache and toolchain the rest.
- **RAM: 4 GB min, 8 GB comfortable.** `./waf copter -j$(nproc)` is the peak.
- **CPU: 4+ cores.** Build is the only heavy part; SITL itself is light.
- **GPU / OpenGL:** only needed if you render. See §6 on headless.

---

## 1. Base system packages

```bash
sudo apt update
sudo apt install -y \
  git git-lfs ca-certificates curl wget gnupg lsb-release \
  build-essential ccache g++ gawk make cmake pkg-config \
  python3 python3-dev python3-pip python3-venv python3-setuptools \
  screen tmux xterm rsync unzip
```

`ccache` matters: ArduPilot rebuilds are frequent when you're iterating on the mixer,
and it cuts a full rebuild from minutes to seconds.

---

## 2. ArduPilot source

```bash
cd ~
git clone --recurse-submodules https://github.com/ArduPilot/ardupilot.git
cd ardupilot
git submodule update --init --recursive
```

> Submodules are **not optional** — the build fails without them.
> Budget time: the initial clone is a few GB.

---

## 3. ArduPilot toolchain + Python deps

Let ArduPilot's own script do this; it is the source of truth and handles the
distro-specific branches.

```bash
cd ~/ardupilot
Tools/environment_install/install-prereqs-ubuntu.sh -y
. ~/.profile
```

**Gotcha — the venv.** On Ubuntu 23.04 and newer (so 24.04), the script does *not*
pip-install into the system Python (PEP 668 blocks it). It creates a virtualenv,
preferring in this order:

1. `~/ardupilot/venv-ardupilot`
2. `~/ardupilot/venv`
3. `~/ardupilot/.venv`
4. otherwise `~/venv-ardupilot`

`MAVProxy`, `pymavlink`, `dronecan` etc. live **inside that venv**. Any shell — or
any agent — that runs `sim_vehicle.py` or a pymavlink script must activate it first:

```bash
source ~/venv-ardupilot/bin/activate     # adjust path per the list above
```

Put that in the service/profile that launches SITL, or the agent will get
`ModuleNotFoundError: No module named 'pymavlink'` and it will look mysterious.

What the script installs, for reference:

- apt: `build-essential ccache g++ gawk git make wget valgrind screen python3-pexpect astyle`,
  `libtool libxml2-dev libxslt1-dev python3-dev python3-pip python3-setuptools
  python3-numpy python3-pyparsing python3-psutil`, SFML/CSFML libs, `xterm xfonts-base`
- pip: `lxml pymavlink pyserial MAVProxy geocoder empy==3.3.4 ptyprocess dronecan
  flake8 junitparser wsproto tabulate` (+ `matplotlib scipy opencv-python pyyaml` on some paths)

It also appends the ArduPilot `Tools/autotest` dir to `PATH` in `~/.profile` — that's
what puts `sim_vehicle.py` on the path.

---

## 4. Gazebo Harmonic

Not in Ubuntu's default repos — add the OSRF repo:

```bash
sudo curl -sSL https://packages.osrfoundation.org/gazebo.gpg \
  -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] \
http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/gazebo-stable.list >/dev/null

sudo apt update
sudo apt install -y gz-harmonic
```

Verify:

```bash
gz sim --versions      # expect 8.x
```

---

## 5. ardupilot_gazebo plugin

This is the bridge. It is a **separate repo** from ArduPilot and speaks ArduPilot's
SITL **JSON** backend over UDP.

```bash
# build deps (Harmonic → libgz-sim8-dev; Garden → libgz-sim7-dev)
sudo apt install -y libgz-sim8-dev rapidjson-dev
sudo apt install -y libopencv-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
                    gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-gl

cd ~
git clone https://github.com/ArduPilot/ardupilot_gazebo
cd ardupilot_gazebo
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo
make -j$(nproc)
```

### Environment variables (required — add to `~/.bashrc`)

```bash
export GZ_SIM_SYSTEM_PLUGIN_PATH=$HOME/ardupilot_gazebo/build:$GZ_SIM_SYSTEM_PLUGIN_PATH
export GZ_SIM_RESOURCE_PATH=$HOME/ardupilot_gazebo/models:$HOME/ardupilot_gazebo/worlds:$GZ_SIM_RESOURCE_PATH
```

Without these, `gz sim -r iris_runway.sdf` will start but the drone will sit inert —
the plugin never loads and there is no loud error. It's the #1 setup failure.

---

## 6. Headless operation (likely, on a home server)

Gazebo's `ogre2` renderer wants OpenGL. Two options:

**A. Server-only (recommended).** Skips rendering entirely. Physics still runs, so
motor kill tests work fine — you just can't see it.

```bash
gz sim -v4 -s -r iris_runway.sdf     # -s = server only
```

**B. Full GUI over a virtual display**, if you want video/screenshots or camera sensors:

```bash
sudo apt install -y xvfb x11vnc mesa-utils libgl1-mesa-dri
# then run gazebo under: xvfb-run -s "-screen 0 1280x1024x24" gz sim ...
```

Note `sim_vehicle.py --map --console` also opens GUI windows (wxPython/pygame).
On a headless box, drop those flags:

```bash
sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON --no-mavproxy
```

...or keep MAVProxy but headless with `--out` to forward MAVLink to your workstation.

---

## 7. Ground station / telemetry tooling

| Tool | Install | Why |
|---|---|---|
| **MAVProxy** | via prereq script (in venv) | Live `param set MOT_KILL_MASK 2` during flight — the on-demand trigger. |
| **pymavlink** | via prereq script (in venv) | The automated test script: arm, takeoff, kill motor, log. |
| **MAVExplorer** | ships with MAVProxy | Plot dataflash logs — `RATE`, `ATT`, `MOTB`, `RCOU` messages. |
| **QGroundControl** | optional, AppImage | Only if you want a GUI GCS from your workstation. Not needed on the server. |
| **mavlink-router** | optional, `apt install mavlink-router` or build | Fan out one SITL MAVLink stream to several consumers. Handy once you have both a GCS and a test script attached. |

Extra Python for log analysis / plotting (into the same venv):

```bash
source ~/venv-ardupilot/bin/activate
pip install matplotlib numpy pandas scipy
```

---

## 8. Ports to leave open (all loopback by default)

| Port | Direction | Purpose |
|---|---|---|
| **9002/udp** | SITL → Gazebo | Servo/PWM output to the physics model (`SIM_OUT_PORT`) |
| **9003/udp** | Gazebo → SITL | State feedback: pose, IMU, etc. (`SIM_IN_PORT`) |
| 5760/tcp | SITL → GCS | Primary MAVLink |
| 5762/5763 tcp | SITL → GCS | Additional MAVLink instances |
| 5501/udp | SITL | FlightGear view (unused here) |
| 9005/udp | SITL | IRLock (the `gazebo-iris` frame enables it) |

Defaults confirmed in `libraries/AP_HAL_SITL/SITL_cmdline.cpp:260-262` and
`libraries/SITL/SIM_JSON.h:63`. If you run multiple SITL instances (`-I 1`, `-I 2`),
these increment — leave a block of ~20 ports free.

---

## 9. First build + smoke test

```bash
cd ~/ardupilot
source ~/venv-ardupilot/bin/activate
./waf configure --board sitl
./waf copter -j$(nproc)
```

Then, two terminals:

```bash
# terminal 1
gz sim -v4 -s -r iris_runway.sdf

# terminal 2
cd ~/ardupilot
sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON --console
```

### Verification checklist

The environment is ready when all of these pass:

- [ ] `gz sim --versions` → `8.x`
- [ ] `ls ~/ardupilot_gazebo/build/libArduPilotPlugin.so` exists
- [ ] `echo $GZ_SIM_SYSTEM_PLUGIN_PATH` is non-empty in a **fresh** shell
- [ ] `./waf copter` completes; `build/sitl/bin/arducopter` exists
- [ ] `sim_vehicle.py` prints `JSON control interface set to 127.0.0.1:9002`
- [ ] SITL reaches `EKF3 IMU0 is using GPS` / GPS lock, and `mode STABILIZE` is accepted
- [ ] In MAVProxy: `arm throttle` succeeds and the Gazebo iris propellers spin
- [ ] `param set SIM_ENGINE_FAIL 2` + `param set SIM_ENGINE_MUL 0` visibly kills a rotor

That last one is the real end-to-end proof — it exercises the full
mixer → PWM → `_simulator_servos()` → JSON → Gazebo chain with **zero code changes**,
and it's the baseline the `MOT_KILL_MASK` work gets compared against.

---

## 10. Nice-to-haves for the development loop

```bash
sudo apt install -y gdb lcov gcovr clangd bear ripgrep jq
```

- `gdb` — SITL is a normal binary; `sim_vehicle.py -D` runs it under gdb. Invaluable
  for breakpointing `AP_MotorsMatrix::output_to_motors()`.
- `clangd` + `bear` — working IDE navigation across ArduPilot's large tree.
- `ripgrep` — `rg` beats `grep -r` badly on a repo this size.

---

## 11. Things deliberately NOT needed

Skip these; they cost time and disk for no benefit here:

- **ROS / ROS 2** — the ardupilot_gazebo plugin talks directly to SITL over UDP.
  ROS is only needed if you later want ROS-side control.
- **ARM cross-compilers** (`g++-arm-linux-gnueabihf`) — SITL is a native x86 build.
  The prereq script installs them anyway; harmless.
- **Real hardware / flight controller** — not until the SITL test passes.
- **`gazebo-classic` / `gazebo11`** — end-of-life, and the plugin targets modern `gz-sim`.
  Do not mix; the `gazebo11` and `gz-harmonic` packages conflict.
