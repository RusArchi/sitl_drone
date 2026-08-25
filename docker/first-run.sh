#!/usr/bin/env bash
#
# One-time provisioning INSIDE the sitl_drone container, against the
# bind-mounted host clones. Idempotent — safe to re-run.
#
# Mirrors docs/ENVIRONMENT_SETUP.md §3 (venv), §5 (plugin build),
# §7 (SITL build), §7-extras (python log-analysis deps).
#
set -euo pipefail

ARDUPILOT_DIR="${ARDUPILOT_DIR:-$HOME/ardupilot}"
GAZEBO_PLUGIN_DIR="${GAZEBO_PLUGIN_DIR:-$HOME/ardupilot_gazebo}"

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; exit 1; }

[[ $EUID -ne 0 ]] || fail "run as 'rusik', not root"
[[ -d "$ARDUPILOT_DIR/.git" ]] || fail "$ARDUPILOT_DIR missing (bind mount?)"
[[ -d "$GAZEBO_PLUGIN_DIR/.git" ]] || fail "$GAZEBO_PLUGIN_DIR missing (bind mount?)"

# ---------------------------------------------------------------- 1. venv
# PEP 668 (24.04): MAVProxy/pymavlink must live in a venv. The official
# prereq script prefers ~/ardupilot/venv-ardupilot — recreate that contract
# against the mounted tree so it persists on the host.
if [[ -f "$ARDUPILOT_DIR/venv-ardupilot/bin/activate" ]]; then
    ok "venv already exists at $ARDUPILOT_DIR/venv-ardupilot"
else
    info "Creating ArduPilot venv (venv-ardupilot)"
    python3 -m venv "$ARDUPILOT_DIR/venv-ardupilot"
fi
# shellcheck disable=SC1091
source "$ARDUPILOT_DIR/venv-ardupilot/bin/activate"

info "Installing python deps into the venv (MAVProxy, pymavlink, dronecan...)"
pip install --upgrade pip wheel
pip install lxml pymavlink pyserial MAVProxy geocoder empy==3.3.4 \
    ptyprocess dronecan flake8 junitparser wsproto tabulate \
    future lxml matplotlib scipy pyyaml
ok "python deps installed"

# ~Docs §3: the official script appends autotest to PATH via ~/.profile;
# provide it in the container's bashrc too.
PROFILE="$HOME/.bashrc"
MARKER="# >>> ardupilot autotest PATH >>>"
if ! grep -qF "$MARKER" "$PROFILE" 2>/dev/null; then
    {
        echo ""
        echo "$MARKER"
        echo "export PATH=$ARDUPILOT_DIR/Tools/autotest:\$PATH"
        echo "# <<< ardupilot autotest PATH <<<"
    } >> "$PROFILE"
    ok "autotest PATH added to ~/.bashrc"
else
    ok "autotest PATH already in ~/.bashrc"
fi

# ---------------------------------------------------------- 2. plugin build
info "Building ardupilot_gazebo plugin (RelWithDebInfo)"
mkdir -p "$GAZEBO_PLUGIN_DIR/build"
( cd "$GAZEBO_PLUGIN_DIR/build" \
    && cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && make -j"$(nproc)" )
[[ -f "$GAZEBO_PLUGIN_DIR/build/libArduPilotPlugin.so" ]] \
    && ok "plugin built: libArduPilotPlugin.so" \
    || fail "plugin build did not produce libArduPilotPlugin.so"

# ------------------------------------------------------- 3. env vars (bashrc)
info "Registering GZ env vars in ~/.bashrc"
MARKER2="# >>> ardupilot_gazebo env >>>"
if ! grep -qF "$MARKER2" "$PROFILE" 2>/dev/null; then
    {
        echo ""
        echo "$MARKER2"
        echo "export GZ_SIM_SYSTEM_PLUGIN_PATH=$GAZEBO_PLUGIN_DIR/build:\$GZ_SIM_SYSTEM_PLUGIN_PATH"
        echo "export GZ_SIM_RESOURCE_PATH=$GAZEBO_PLUGIN_DIR/models:$GAZEBO_PLUGIN_DIR/worlds:\$GZ_SIM_RESOURCE_PATH"
        echo "# <<< ardupilot_gazebo env <<<"
    } >> "$PROFILE"
    ok "GZ env vars appended to ~/.bashrc"
else
    ok "GZ env vars already in ~/.bashrc"
fi
export GZ_SIM_SYSTEM_PLUGIN_PATH="$GAZEBO_PLUGIN_DIR/build:${GZ_SIM_SYSTEM_PLUGIN_PATH:-}"
export GZ_SIM_RESOURCE_PATH="$GAZEBO_PLUGIN_DIR/models:$GAZEBO_PLUGIN_DIR/worlds:${GZ_SIM_RESOURCE_PATH:-}"

# ----------------------------------------------------------- 4. SITL build
info "Building ArduCopter SITL (waf, board sitl)"
( cd "$ARDUPILOT_DIR" \
    && ./waf configure --board sitl \
    && ./waf copter -j"$(nproc)" )
[[ -x "$ARDUPILOT_DIR/build/sitl/bin/arducopter" ]] \
    && ok "SITL binary built: build/sitl/bin/arducopter" \
    || fail "waf build did not produce build/sitl/bin/arducopter"

# --------------------------------------------------- 5. log-analysis extras
info "Installing log-analysis python packages into the venv"
pip install matplotlib numpy pandas scipy || echo "[warn] pip extras failed"

ok "first-run provisioning complete"
echo
echo "Next: run the environment check inside the container:"
echo "  docker exec -it sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && /workspace/sitl_drone/scripts/setup_env.sh --check'"
