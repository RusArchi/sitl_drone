#!/usr/bin/env bash
#
# Provision a machine for the ArduCopter SITL + Gazebo motor-control testbed.
# Mirrors docs/ENVIRONMENT_SETUP.md. Ubuntu 22.04 (jammy) / 24.04 (noble).
#
# Usage:
#   ./setup_env.sh          # full install
#   ./setup_env.sh --check  # verify an existing install, change nothing
#
# Do NOT run as root; it sudos where it needs to.

set -euo pipefail

ARDUPILOT_DIR="${ARDUPILOT_DIR:-$HOME/ardupilot}"
GAZEBO_PLUGIN_DIR="${GAZEBO_PLUGIN_DIR:-$HOME/ardupilot_gazebo}"
GZ_SIM_DEV_PKG="${GZ_SIM_DEV_PKG:-libgz-sim8-dev}"   # 8 = Harmonic, 7 = Garden
JOBS="$(nproc)"

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

# --------------------------------------------------------------------------
# Locate the venv the ArduPilot prereq script creates (23.04+ / PEP 668).
# Mirrors the search order in Tools/environment_install/install-prereqs-ubuntu.sh.
# --------------------------------------------------------------------------
find_venv() {
    local c
    for c in "$ARDUPILOT_DIR/venv-ardupilot" "$ARDUPILOT_DIR/venv" \
             "$ARDUPILOT_DIR/.venv" "$HOME/venv-ardupilot"; do
        [[ -f "$c/bin/activate" ]] && { echo "$c"; return 0; }
    done
    return 1
}

# --------------------------------------------------------------------------
# --check
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--check" ]]; then
    info "Verifying environment"
    rc=0

    if command -v gz >/dev/null 2>&1; then
        ok "gz sim $(gz sim --versions 2>/dev/null | head -1)"
    else
        fail "gz not on PATH"; rc=1
    fi

    if [[ -f "$GAZEBO_PLUGIN_DIR/build/libArduPilotPlugin.so" ]]; then
        ok "ArduPilot Gazebo plugin built"
    else
        fail "missing $GAZEBO_PLUGIN_DIR/build/libArduPilotPlugin.so"; rc=1
    fi

    if [[ -n "${GZ_SIM_SYSTEM_PLUGIN_PATH:-}" ]]; then
        ok "GZ_SIM_SYSTEM_PLUGIN_PATH set"
    else
        fail "GZ_SIM_SYSTEM_PLUGIN_PATH unset (source ~/.bashrc, or re-login)"; rc=1
    fi

    if [[ -n "${GZ_SIM_RESOURCE_PATH:-}" ]]; then
        ok "GZ_SIM_RESOURCE_PATH set"
    else
        fail "GZ_SIM_RESOURCE_PATH unset"; rc=1
    fi

    if [[ -f "$ARDUPILOT_DIR/build/sitl/bin/arducopter" ]]; then
        ok "arducopter SITL binary built"
    else
        fail "SITL binary not built — run ./waf configure --board sitl && ./waf copter"; rc=1
    fi

    if venv="$(find_venv)"; then
        ok "python venv at $venv"
        if "$venv/bin/python" -c 'import pymavlink' 2>/dev/null; then
            ok "pymavlink importable"
        else
            fail "pymavlink not importable inside venv"; rc=1
        fi
    else
        warn "no ArduPilot venv found — fine on 22.04 where pip installs --user"
        python3 -c 'import pymavlink' 2>/dev/null \
            && ok "pymavlink importable (system python)" \
            || { fail "pymavlink not importable"; rc=1; }
    fi

    [[ $rc -eq 0 ]] && info "Environment OK" || info "Environment INCOMPLETE"
    exit $rc
fi

if [[ $EUID -eq 0 ]]; then
    fail "Do not run this as root. It will sudo where needed."
    exit 1
fi

# --------------------------------------------------------------------------
# 1. base packages
# --------------------------------------------------------------------------
info "Installing base packages"
sudo apt-get update
sudo apt-get install -y \
    git git-lfs ca-certificates curl wget gnupg lsb-release \
    build-essential ccache g++ gawk make cmake pkg-config \
    python3 python3-dev python3-pip python3-venv python3-setuptools \
    screen tmux xterm rsync unzip \
    gdb ripgrep jq

# --------------------------------------------------------------------------
# 2. ArduPilot source
# --------------------------------------------------------------------------
if [[ -d "$ARDUPILOT_DIR/.git" ]]; then
    info "ArduPilot already cloned at $ARDUPILOT_DIR — updating submodules"
    git -C "$ARDUPILOT_DIR" submodule update --init --recursive
else
    info "Cloning ArduPilot into $ARDUPILOT_DIR"
    git clone --recurse-submodules https://github.com/ArduPilot/ardupilot.git "$ARDUPILOT_DIR"
fi

# --------------------------------------------------------------------------
# 3. ArduPilot toolchain + python deps
# --------------------------------------------------------------------------
info "Running ArduPilot prereq installer (this takes a while)"
( cd "$ARDUPILOT_DIR" && Tools/environment_install/install-prereqs-ubuntu.sh -y )

# --------------------------------------------------------------------------
# 4. Gazebo Harmonic
# --------------------------------------------------------------------------
if command -v gz >/dev/null 2>&1; then
    info "Gazebo already installed: $(gz sim --versions 2>/dev/null | head -1)"
else
    info "Installing Gazebo Harmonic from the OSRF repository"
    sudo curl -sSL https://packages.osrfoundation.org/gazebo.gpg \
        -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/gazebo-stable.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y gz-harmonic
fi

# --------------------------------------------------------------------------
# 5. ardupilot_gazebo plugin
# --------------------------------------------------------------------------
info "Installing plugin build dependencies"
sudo apt-get install -y "$GZ_SIM_DEV_PKG" rapidjson-dev
sudo apt-get install -y libopencv-dev libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-bad \
    gstreamer1.0-libav gstreamer1.0-gl

if [[ -d "$GAZEBO_PLUGIN_DIR/.git" ]]; then
    info "ardupilot_gazebo already cloned — pulling"
    git -C "$GAZEBO_PLUGIN_DIR" pull --ff-only || warn "pull skipped (local changes?)"
else
    info "Cloning ardupilot_gazebo"
    git clone https://github.com/ArduPilot/ardupilot_gazebo "$GAZEBO_PLUGIN_DIR"
fi

info "Building ardupilot_gazebo"
mkdir -p "$GAZEBO_PLUGIN_DIR/build"
( cd "$GAZEBO_PLUGIN_DIR/build" \
  && cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  && make -j"$JOBS" )

# --------------------------------------------------------------------------
# 6. environment variables
# --------------------------------------------------------------------------
info "Registering Gazebo environment variables in ~/.bashrc"
MARKER="# >>> ardupilot_gazebo env >>>"
if grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
    ok "already present in ~/.bashrc"
else
    cat >> "$HOME/.bashrc" <<EOF

$MARKER
export GZ_SIM_SYSTEM_PLUGIN_PATH=$GAZEBO_PLUGIN_DIR/build:\$GZ_SIM_SYSTEM_PLUGIN_PATH
export GZ_SIM_RESOURCE_PATH=$GAZEBO_PLUGIN_DIR/models:$GAZEBO_PLUGIN_DIR/worlds:\$GZ_SIM_RESOURCE_PATH
# <<< ardupilot_gazebo env <<<
EOF
    ok "appended to ~/.bashrc"
fi
export GZ_SIM_SYSTEM_PLUGIN_PATH="$GAZEBO_PLUGIN_DIR/build:${GZ_SIM_SYSTEM_PLUGIN_PATH:-}"
export GZ_SIM_RESOURCE_PATH="$GAZEBO_PLUGIN_DIR/models:$GAZEBO_PLUGIN_DIR/worlds:${GZ_SIM_RESOURCE_PATH:-}"

# --------------------------------------------------------------------------
# 7. build SITL
# --------------------------------------------------------------------------
info "Building ArduCopter SITL"
if venv="$(find_venv)"; then
    # shellcheck disable=SC1091
    source "$venv/bin/activate"
    ok "activated venv $venv"
else
    warn "no venv found; using system python"
fi
( cd "$ARDUPILOT_DIR" && ./waf configure --board sitl && ./waf copter -j"$JOBS" )

# --------------------------------------------------------------------------
# 8. log-analysis extras
# --------------------------------------------------------------------------
info "Installing log-analysis python packages"
python3 -m pip install --upgrade matplotlib numpy pandas scipy \
    || warn "pip install failed — activate the ArduPilot venv and retry"

info "Done. Open a new shell (or 'source ~/.bashrc'), then run: $0 --check"
