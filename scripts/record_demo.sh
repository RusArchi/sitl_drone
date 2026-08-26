#!/usr/bin/env bash
#
# Record the Phase 2 smoke flight: bring up Gazebo + SITL, capture the Gazebo
# window with ffmpeg while fly_demo.py flies the square, then stop cleanly.
#
# Run INSIDE the container (it needs DISPLAY, gz, ffmpeg and the venv):
#     docker exec sitl_drone /workspace/sitl_drone/scripts/record_demo.sh
#
# Output: /workspace/sitl_drone/recordings/<timestamp>.mp4  (on the host, in the
# repo, since /workspace/sitl_drone is the bind-mounted repo).
#
# Rendering happens on a private Xvfb display, NOT the desktop. The desktop is
# GNOME/Wayland and an XWayland root window has no readable pixels, so x11grab
# against it fails with BadMatch ("Cannot get the image data"). Xvfb's root
# window is an ordinary pixmap, so capture works and the geometry is fixed.
# Set VISIBLE=1 to render on the real desktop instead and skip recording.
#
set -euo pipefail

REPO=/workspace/sitl_drone
OUT_DIR="$REPO/recordings"
STAMP="$(date +%Y%m%d-%H%M%S)"
FLIGHT="${FLIGHT:-fly_demo.py}"       # which script in scripts/ to fly
TAG="${FLIGHT%.py}"
OUT="$OUT_DIR/${TAG}-$STAMP.mp4"
WORLD="${WORLD:-iris_runway.sdf}"
MODEL="${MODEL:-iris_with_gimbal}"   # entity to keep in frame
FPS="${FPS:-15}"

# Gazebo runs at RTF ~0.5 and rendering is software (llvmpipe), so a modest
# capture rate keeps ffmpeg from competing with the physics for CPU.

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

W=1280; H=800
mkdir -p "$OUT_DIR"

if [[ "${VISIBLE:-0}" == "1" ]]; then
    [[ -n "${DISPLAY:-}" ]] || { echo "VISIBLE=1 needs DISPLAY; recreate via run.sh" >&2; exit 1; }
    log "rendering on the desktop ($DISPLAY) — no recording"
else
    export DISPLAY=:99
    log "starting Xvfb on $DISPLAY (${W}x${H})"
    Xvfb "$DISPLAY" -screen 0 "${W}x${H}x24" >/tmp/xvfb.log 2>&1 &
    XVFB_PID=$!
    for _ in $(seq 1 30); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 1; done
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || { echo "Xvfb never came up" >&2; exit 1; }
fi

cleanup() {
    log "cleaning up"
    [[ -n "${FF_PID:-}" ]] && kill -INT "$FF_PID" 2>/dev/null && wait "$FF_PID" 2>/dev/null || true
    [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
    pkill -f 'sim_vehicle.py' 2>/dev/null || true
    pkill -f 'bin/arducopter' 2>/dev/null || true
    pkill -f 'gz sim' 2>/dev/null || true
    pkill -f 'gz-sim'  2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- fresh start
log "stopping anything already running"
pkill -f 'sim_vehicle.py' 2>/dev/null || true
pkill -f 'bin/arducopter' 2>/dev/null || true
pkill -f 'gz sim' 2>/dev/null || true
sleep 2

# ------------------------------------------------------------------- gazebo
# Order matters: Gazebo first, or the JSON link never forms (PROJECT.md
# §2 Current status).
log "starting Gazebo GUI ($WORLD)"
# --gui-config: strip the docked panels and toolbars so the whole window is
# render output, and start the camera high enough to see the aircraft.
# gui-record.config = wide shot for the square demo.
# gui-crash.config  = static side-on shot for the motor-failure run.
GUI_CFG="${GUI_CFG:-$REPO/docker/gz/gui-record.config}"
setsid gz sim -v2 -r --gui-config "$GUI_CFG" "$WORLD" >/tmp/gz_sim.log 2>&1 &

# Wait for the render window to actually exist before trying to capture it.
WIN=""
for _ in $(seq 1 60); do
    WIN="$(xdotool search --name 'Gazebo' 2>/dev/null | tail -1 || true)"
    [[ -n "$WIN" ]] && break
    sleep 1
done
[[ -n "$WIN" ]] || { echo "Gazebo window never appeared; see /tmp/gz_sim.log" >&2; exit 1; }

# Put it at a known place and size so the capture geometry is deterministic.
xdotool windowmove "$WIN" 0 0 windowsize "$WIN" "$W" "$H" windowactivate "$WIN" || true
sleep 3
log "gazebo window $WIN at 0,0 ${W}x${H}"

# --------------------------------------------------------------------- sitl
log "starting ArduCopter SITL"
# env -u DISPLAY: sim_vehicle.py opens the SITL console in an xterm when a
# display exists, and that window lands on top of the render view. SITL needs
# no display, so hide it from that process only.
setsid env -u DISPLAY bash -lc "source ~/ardupilot/venv-ardupilot/bin/activate && cd ~/ardupilot && \
    sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON --no-mavproxy" \
    >/tmp/sitl.log 2>&1 &

log "waiting for SITL to open its MAVLink port"
for _ in $(seq 1 90); do
    grep -q "Waiting for connection" /tmp/sitl.log 2>/dev/null && break
    sleep 1
done
sleep 5

# ---------------------------------------------------------------- recording
if [[ "${VISIBLE:-0}" == "1" ]]; then
    log "VISIBLE=1 — skipping capture"
    FF_PID=""
else
# Camera: without this the view sits at ground level and the iris is never in
# frame. follow keeps it centred for the whole flight; the offset puts the
# camera behind and above, which reads better than straight overhead.
if [[ "${FOLLOW:-0}" == "1" ]]; then
    log "following $MODEL"
    gz service -s /gui/follow --reqtype gz.msgs.StringMsg --reptype gz.msgs.Boolean \
        --timeout 3000 --req "data: \"$MODEL\"" >/dev/null 2>&1 || log "follow failed (non-fatal)"
    gz service -s /gui/follow/offset --reqtype gz.msgs.Vector3d --reptype gz.msgs.Boolean \
        --timeout 3000 --req "x: -6, y: 0, z: 2" >/dev/null 2>&1 || true
fi

# Re-assert size: the window is not always fully realised at first resize.
xdotool windowsize "$WIN" "$W" "$H" 2>/dev/null || true
sleep 2

log "recording -> $OUT"
ffmpeg -hide_banner -loglevel error -y \
    -f x11grab -framerate "$FPS" -video_size "${W}x${H}" -i "${DISPLAY}+0,0" \
    -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p \
    "$OUT" &
FF_PID=$!
fi
sleep 2

# ------------------------------------------------------------------- flight
log "flying the demo"
set +e
bash -lc "source ~/ardupilot/venv-ardupilot/bin/activate && python3 $REPO/scripts/$FLIGHT" \
    2>&1 | tee /tmp/flight_out.txt
FLIGHT_RC=${PIPESTATUS[0]}
set -e

sleep 3
log "stopping recording"
kill -INT "$FF_PID" 2>/dev/null || true
wait "$FF_PID" 2>/dev/null || true
FF_PID=""

if [[ "${VISIBLE:-0}" == "1" ]]; then
    log "flight finished (rc=$FLIGHT_RC), nothing recorded"
elif [[ -s "$OUT" ]]; then
    log "saved: $OUT ($(du -h "$OUT" | cut -f1))"
    # Gazebo is CPU-bound in DART at a 1 ms step and runs at RTF ~0.5, so the
    # wall-clock capture plays at half speed. The flight script reports SITL's
    # own clock -- which IS simulation time -- against wall time; re-time with
    # that. Raising the step to 2 ms reaches RTF ~0.97 but breaks SITL's JSON
    # link, so the correction is done in post (§10 Troubleshooting log).
    HINT="$(grep -o 'RTF_HINT sim=[0-9.]* wall=[0-9.]*' /tmp/flight_out.txt | tail -1 || true)"
    if [[ -n "$HINT" ]]; then
        RTF="$(python3 -c "
import re
m = re.search(r'sim=([0-9.]+) wall=([0-9.]+)', '''$HINT''')
s, w = float(m.group(1)), float(m.group(2))
print(f'{max(0.05, min(1.0, s/w)):.4f}')")"
        RT="${OUT%.mp4}-realtime.mp4"
        log "measured RTF $RTF — writing real-time version"
        if ffmpeg -hide_banner -loglevel error -y -i "$OUT" \
                -filter:v "setpts=${RTF}*PTS" -an "$RT" 2>/dev/null; then
            log "saved: $RT ($(du -h "$RT" | cut -f1))"
        else
            log "re-timing failed; the wall-clock capture is still valid"
        fi
    else
        log "no RTF_HINT from the flight script; skipping real-time version"
    fi
else
    echo "recording is empty — check the capture geometry" >&2
    exit 1
fi
exit "$FLIGHT_RC"
