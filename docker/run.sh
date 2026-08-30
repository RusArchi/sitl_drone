#!/usr/bin/env bash
#
# Build and run the sitl_drone environment container.
#
#   ./run.sh          — build image (if needed) + start detached container
#   ./run.sh shell    — open an interactive shell in the running container
#   ./run.sh check    — run the repo's --check inside the container
#   ./run.sh gui-check— verify OpenGL works inside the container
#   ./run.sh stop     — stop and remove the container
#
# GUI: if DISPLAY is set when the container is created, the X socket, the GPU
# device nodes and DISPLAY are wired in, so `gz sim` can render from inside.
# Run it from a graphical session on this machine. Headless still works — the
# GUI bits are simply omitted when DISPLAY is unset.
#
# Repos are bind-mounted from the host (~/ardupilot, ~/ardupilot_gazebo,
# ~/Projects/sitl_drone) so sources, patches, venv, and build artifacts
# persist on the host and stay usable by host-side agents.
#
set -euo pipefail

IMAGE="sitl_drone:latest"
NAME="sitl_drone"

do_build() {
    docker build -t "$IMAGE" "$(dirname "$0")"
}

# Collect the docker args needed for on-screen rendering. Empty if there is no
# display, so the same code path serves headless use.
#
# Auth: this desktop is GNOME/Wayland, so the X cookie lives in a per-session
# randomly-named file under /run/user/1000 — too volatile to bind-mount. Grant
# access by user instead; it is narrower than the usual `xhost +local:`.
#
# GPU: logind puts an ACL on /dev/dri/* granting uid 1000. The container user is
# also uid 1000, so the ACL carries over and no group juggling is needed. The
# video/render groups are added anyway, for when no seat ACL is present.
# Find a usable local X display. Prefers an inherited DISPLAY; otherwise probes
# the seat's display directly, which is what makes GUI setup work over ssh.
#
# GNOME/Wayland keeps the X cookie in a per-session randomly-named file under
# /run/user/UID. It is readable by the session owner, so an ssh login as the same
# user can authenticate to the running desktop and hand out access with xhost.
detect_display() {
    if [[ -n "${DISPLAY:-}" ]]; then echo "$DISPLAY"; return 0; fi
    command -v xdpyinfo >/dev/null 2>&1 || return 1
    # Try EVERY cookie, not just the first. GNOME leaves stale
    # .mutter-Xwaylandauth.* files behind across logins, so `head -1` can pick a
    # dead one and report the display unreachable when it is perfectly fine --
    # which is exactly what made the desktop appear to "disappear" mid-session.
    local cookie d
    for d in :0 :1; do
        [[ -S /tmp/.X11-unix/X${d#:} ]] || continue
        for cookie in /run/user/"$(id -u)"/.mutter-Xwaylandauth.*; do
            [[ -f "$cookie" ]] || continue
            if XAUTHORITY="$cookie" DISPLAY="$d" timeout 5 xdpyinfo >/dev/null 2>&1; then
                echo "$d"; return 0
            fi
        done
    done
    return 1
}

# Grant the container's user access to the X server. Granting by user identity is
# stable across sessions, unlike the randomly-named cookie file, and is narrower
# than the usual `xhost +local:`. Local socket connections are identified by
# SO_PEERCRED, and the container user shares uid 1000, so it matches.
gui_auth() {
    local disp="$1" cookie
    command -v xhost >/dev/null 2>&1 || return 0
    # Same reason as detect_display: try them all, the first may be stale.
    for cookie in /run/user/"$(id -u)"/.mutter-Xwaylandauth.*; do
        [[ -f "$cookie" ]] || continue
        XAUTHORITY="$cookie" DISPLAY="$disp" xhost "+SI:localuser:$(id -un)" >/dev/null 2>&1 && return 0
    done
    return 0
}

# Collect the docker args needed for on-screen rendering. Emits nothing when no
# display is reachable, so the same code path serves headless use.
#
# GPU: logind puts an ACL on /dev/dri/* granting uid 1000. The container user is
# also uid 1000, so the ACL carries over and no group juggling is needed. The
# video/render groups are added anyway, for when no seat ACL is present.
# GPU passthrough, independent of the desktop display. Recording renders on the
# container's own Xvfb, so it needs the GPU even when no desktop X is reachable
# -- putting this inside gui_args() would silently leave headless runs on
# llvmpipe, which is exactly the ~1 fps case this is meant to fix.
#
# NVIDIA_DRIVER_CAPABILITIES must include `graphics`: the default is
# `utility,compute`, enough for nvidia-smi and CUDA but NOT for OpenGL.
# Install the toolkit with scripts/setup_gpu.sh.
gpu_args() {
    docker info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null \
        | grep -qw nvidia || return 0
    printf '%s\n' --gpus all \
        -e NVIDIA_DRIVER_CAPABILITIES=graphics,compute,utility \
        -e NVIDIA_VISIBLE_DEVICES=all
}

gui_args() {
    local disp
    disp="$(detect_display)" || return 0
    gui_auth "$disp"

    local args=(-e "DISPLAY=$disp" -e "QT_X11_NO_MITSHM=1")
    [[ -d /tmp/.X11-unix ]] && args+=(-v /tmp/.X11-unix:/tmp/.X11-unix:ro)
    if [[ -d /dev/dri ]]; then
        args+=(--device /dev/dri)
        local g
        for g in video render; do
            g="$(getent group "$g" | cut -d: -f3)"
            [[ -n "$g" ]] && args+=(--group-add "$g")
        done
    fi
    printf '%s\n' "${args[@]}"
}

do_run() {
    docker build -t "$IMAGE" "$(dirname "$0")" || true

    local gui=() gpu=()
    mapfile -t gui < <(gui_args)
    mapfile -t gpu < <(gpu_args)
    if [[ ${#gpu[@]} -gt 0 ]]; then
        echo "nvidia runtime detected — GPU rendering enabled"
    else
        echo "no nvidia runtime — software rendering (llvmpipe, ~1 fps); see scripts/setup_gpu.sh"
    fi
    if [[ ${#gui[@]} -gt 0 ]]; then
        echo "display ${gui[1]#DISPLAY=} reachable — wiring X socket and GPU in"
    else
        echo "no reachable X display — container will be headless (gz sim -s only)."
        echo "  Needs a logged-in desktop session on this machine; ssh alone is fine."
    fi

    # Timezone: the image is Etc/UTC, so every timestamp written inside the
    # container -- run ids, log lines, run.txt -- came out 3 hours behind local
    # time. Follow the HOST's zone rather than baking one into the image, so this
    # stays right if the machine moves.
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)"

    docker run -d --name "$NAME" \
        --network host \
        -e "TZ=$tz" \
        -v /etc/localtime:/etc/localtime:ro \
        ${gui[@]+"${gui[@]}"} \
        ${gpu[@]+"${gpu[@]}"} \
        -v "$HOME/ardupilot:/home/rusik/ardupilot" \
        -v "$HOME/ardupilot_gazebo:/home/rusik/ardupilot_gazebo" \
        -v "$(dirname "$0")/..:/workspace/sitl_drone" \
        -v sitl_drone-ccache:/home/rusik/.ccache \
        -w /home/rusik \
        "$IMAGE"
}

# -it is only valid when stdin is a terminal; without this, `check` fails from
# scripts and CI with "cannot attach stdin to a TTY-enabled container".
TTY=()
[[ -t 0 ]] && TTY=(-it)

case "${1:-run}" in
    build) do_build ;;
    run)
        if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
            echo "container '$NAME' already exists — use './run.sh shell'"
        else
            do_run
        fi
        ;;
    shell)
        docker exec -it "$NAME" bash -l
        ;;
    gui-check)
        d="$(detect_display 2>/dev/null || true)"
        [[ -n "$d" ]] && gui_auth "$d"
        docker exec "${TTY[@]+"${TTY[@]}"}" "$NAME" bash -lc \
            'echo "DISPLAY=${DISPLAY:-<unset>}"; glxinfo -B 2>&1 | grep -E "OpenGL renderer|OpenGL version|direct rendering" \
             || echo "no GL — recreate the container from a graphical session (./run.sh stop && ./run.sh run)"'
        ;;
    check)
        docker exec "${TTY[@]+"${TTY[@]}"}" "$NAME" bash -lc \
            'source ~/ardupilot/venv-ardupilot/bin/activate 2>/dev/null; /workspace/sitl_drone/scripts/setup_env.sh --check'
        ;;
    stop)
        docker rm -f "$NAME"
        ;;
    *) echo "usage: $0 [build|run|shell|check|gui-check|stop]" >&2; exit 1 ;;
esac
