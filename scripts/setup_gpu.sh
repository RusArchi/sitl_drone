#!/usr/bin/env bash
#
# Install NVIDIA's container toolkit so the sitl_drone container can render on
# the GPU instead of in software.
#
#   sudo ./scripts/setup_gpu.sh          # install + configure + verify
#   sudo ./scripts/setup_gpu.sh --check  # verify only, change nothing
#
# WHY THIS IS NEEDED
#
# Gazebo's GUI currently renders at about 1 frame per second. That is not a
# capture problem -- the recordings honestly contain ~1 fps of motion, with the
# rest duplicate frames -- and it is not resolution: 1280x800 and 3840x2160 both
# measure ~1 fps. It is because rendering falls back to llvmpipe, Mesa's CPU
# rasteriser.
#
# The reason it falls back: this desktop's displays are driven by the NVIDIA
# card, so X hands the container an NVIDIA DRM device. Mesa has no driver for
# NVIDIA hardware, so it gives up and rasterises on the CPU. The Intel iGPU
# cannot help, because the display is not attached to it.
#
# NVIDIA's userspace GL driver is a proprietary blob that must match the host
# kernel module version EXACTLY (580.173.02 here). It cannot simply be installed
# inside the container -- it would drift from the host and break. The container
# toolkit solves this by injecting the host's own driver libraries into the
# container at start time, which is what `--gpus all` then uses.
#
# WHAT THIS CHANGES ON THE HOST
#   - adds NVIDIA's apt repository and its signing key
#   - installs the nvidia-container-toolkit package
#   - registers the `nvidia` runtime in /etc/docker/daemon.json
#   - restarts the docker daemon (running containers are NOT removed, but they
#     do stop and start again)
#
set -euo pipefail

KEYRING=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
LIST=/etc/apt/sources.list.d/nvidia-container-toolkit.list

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; exit 1; }

verify() {
    info "Verifying GPU access from a container"
    local rc=0

    if docker info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null | grep -qw nvidia; then
        ok "docker knows the 'nvidia' runtime"
    else
        fail "docker has no 'nvidia' runtime — run this script without --check first"
    fi

    # compute path: proves the driver is injected at all
    if docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L 2>/dev/null | head -1; then
        ok "nvidia-smi works inside a container"
    else
        fail "nvidia-smi failed inside a container"
    fi

    # graphics path: this is the one that matters for Gazebo. compute can work
    # while OpenGL does not, if NVIDIA_DRIVER_CAPABILITIES omits 'graphics'.
    if docker image inspect sitl_drone:latest >/dev/null 2>&1; then
        local r
        r="$(docker run --rm --gpus all \
                -e NVIDIA_DRIVER_CAPABILITIES=graphics,compute,utility \
                sitl_drone:latest bash -lc 'glxinfo -B 2>/dev/null | grep -m1 "OpenGL renderer"' || true)"
        if [[ -n "$r" ]]; then
            echo "    $r"
            if grep -qi llvmpipe <<<"$r"; then
                warn "still llvmpipe — GL is NOT hardware accelerated"
                rc=1
            else
                ok "hardware OpenGL renderer inside the container"
            fi
        else
            warn "glxinfo produced nothing (needs a display; run docker/run.sh gui-check instead)"
        fi
    else
        warn "sitl_drone:latest image not found — skipping the OpenGL check"
    fi
    return $rc
}

[[ "${1:-}" == "--check" ]] && { verify; exit $?; }

[[ $EUID -eq 0 ]] || fail "run with sudo"
command -v nvidia-smi >/dev/null || fail "no nvidia-smi — install the NVIDIA driver first"
command -v docker >/dev/null || fail "docker not found"

info "Host GPU"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

# ------------------------------------------------------------------ repo
# NVIDIA's repo is distribution-independent (stable/deb/$arch), so it is correct
# on Ubuntu 26.04 even though no 26.04-specific repo exists.
if [[ -f "$LIST" && -f "$KEYRING" ]]; then
    ok "NVIDIA container toolkit repo already configured"
else
    info "Adding the NVIDIA container toolkit repository"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o "$KEYRING"
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=$KEYRING] https://#g" \
        > "$LIST"
    ok "repo added"
fi

info "Installing nvidia-container-toolkit"
apt-get update
apt-get install -y nvidia-container-toolkit
ok "installed: $(dpkg -s nvidia-container-toolkit | awk '/^Version:/{print $2}')"

# --------------------------------------------------------------- configure
info "Registering the nvidia runtime with docker"
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
ok "docker restarted"

verify || warn "GPU is available but OpenGL is not accelerated yet — see the note below"

cat <<'NEXT'

Next steps (as your normal user, NOT root):

  cd ~/Projects/sitl_drone/docker
  ./run.sh stop && ./run.sh run      # recreate so the container picks up the GPU
  ./run.sh gui-check                 # expect an NVIDIA renderer, not llvmpipe

Then re-record. If the renderer line still says llvmpipe, the GPU is reaching the
container but the graphics capability is not enabled -- check that run.sh passes
NVIDIA_DRIVER_CAPABILITIES=graphics (compute alone is not enough for OpenGL).
NEXT
