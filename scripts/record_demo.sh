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
# One self-contained directory per run: video, the real-time cut, the flight
# script's own output, the MAVProxy session, and the SITL/Gazebo logs. Keeping
# them together means a recording can still be explained weeks later -- the logs
# used to land in /tmp and be overwritten by the next run.
# Every file carries the run id, not just the directory: a video sent to someone
# on its own still has to be identifiable, and "video.mp4" is not.
RUN_ID="${TAG}-$STAMP"
RUN_DIR="$OUT_DIR/$RUN_ID"
OUT="$RUN_DIR/$RUN_ID.mp4"
FLIGHT_LOG="$RUN_DIR/$RUN_ID-flight.log"
MAVPROXY_LOG="$RUN_DIR/$RUN_ID-mavproxy.log"
WORLD="${WORLD:-iris_runway.sdf}"
MODEL="${MODEL:-iris_with_gimbal}"   # entity to keep in frame
FPS="${FPS:-15}"

# Gazebo runs at RTF ~0.5 and rendering is software (llvmpipe), so a modest
# capture rate keeps ffmpeg from competing with the physics for CPU.

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Canvas size. RES sets the render resolution, e.g. RES=2560x1440 or RES=3840x2160.
#
# Rendering is software (llvmpipe -- the desktop is NVIDIA-driven and Mesa cannot
# use it, see §4 Environment), so resolution is paid for in CPU by both Gazebo and
# the x264 encoder, and Gazebo is already CPU-bound at RTF ~0.5. Higher settings
# work; they make the sim slower in wall-clock, which the post-hoc re-timing then
# corrects. Measure before committing to 4K.
#
# TELEM=1 reserves a column on the right for the MAVProxy terminal, so Gazebo gets
# a 4:3-ish slice of the canvas rather than the whole of it.
RES="${RES:-1280x800}"
W="${RES%x*}"; H="${RES#*x}"
if [[ "${TELEM:-0}" == "1" ]]; then
    # widen the canvas by a telemetry column unless RES already allows for one
    TELEM_COL="${TELEM_COL:-640}"
    GZ_W=$W; GZ_H=$H
    W=$(( W + TELEM_COL ))
else
    GZ_W=$W; GZ_H=$H
fi
mkdir -p "$RUN_DIR"

# Written before anything can fail, so even an aborted run says what it was.
{
    echo "run:        $TAG"
    echo "started:    $(date -Is)"
    echo "flight:     $FLIGHT"
    echo "world:      $WORLD"
    echo "gui config: ${GUI_CFG:-<default>}"
    echo "cam pose:   ${CAM_POSE:-<from gui config>}"
    echo "cam mode:   ${CAM_MODE:-static}"
    echo "telemetry:  ${TELEM:-0}"
    echo
    echo "flight parameters (as passed; blank means the script default)"
    echo "  TAKEOFF_ALT=${TAKEOFF_ALT:-}"
    echo "  CRUISE_N=${CRUISE_N:-}"
    echo "  CRUISE_SPEED=${CRUISE_SPEED:-}"
    echo "  KILL_AFTER=${KILL_AFTER:-}"
    echo "  MOTOR=${MOTOR:-}"
} > "$RUN_DIR/$RUN_ID-run.txt"

if [[ "${VISIBLE:-0}" == "1" ]]; then
    [[ -n "${DISPLAY:-}" ]] || { echo "VISIBLE=1 needs DISPLAY; recreate via run.sh" >&2; exit 1; }
    log "rendering on the desktop ($DISPLAY) — no recording"
else
    export DISPLAY=:99
    # A dead Xvfb leaves /tmp/.X99-lock behind and the next one refuses to start
    # ("Server is already active"), so the run either fails outright or silently
    # keeps a PREVIOUS server's resolution and RES looks ignored. Clear stale
    # state first, but only when nothing is actually listening on :99.
    # pgrep matches ZOMBIES too, and this container's PID 1 is `sleep`, which
    # never reaps them -- so a defunct Xvfb made this guard think a server was
    # live, the lock survived, and every later run died with "Server is already
    # active for display 99". Count only processes in a non-Z state.
    if ! ps -e -o stat=,comm= | awk '$2 == "Xvfb" && $1 !~ /Z/ {found=1} END {exit !found}'; then
        rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
    fi
    log "starting Xvfb on $DISPLAY (${W}x${H}; gazebo ${GZ_W}x${GZ_H})"
    Xvfb "$DISPLAY" -screen 0 "${W}x${H}x24" >/tmp/xvfb.log 2>&1 &
    XVFB_PID=$!
    for _ in $(seq 1 30); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 1; done
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || { echo "Xvfb never came up" >&2; exit 1; }
fi

cleanup() {
    log "cleaning up"
    # SITL and Gazebo write to /tmp and get overwritten by the next run; keep a
    # copy beside the video while it still corresponds to this flight.
    for f in /tmp/sitl.log /tmp/gz_sim.log /tmp/ArduCopter.log; do
        [[ -f "$f" ]] && cp -f "$f" "$RUN_DIR/$RUN_ID-$(basename "$f")" 2>/dev/null || true
    done
    [[ -n "${FF_PID:-}" ]] && kill -INT "$FF_PID" 2>/dev/null && wait "$FF_PID" 2>/dev/null || true
    [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
    pkill -f 'sim_vehicle.py' 2>/dev/null || true
    pkill -f 'bin/arducopter' 2>/dev/null || true
    pkill -f 'gz sim' 2>/dev/null || true
    pkill -f 'gz-sim'  2>/dev/null || true
    pkill -f 'mavproxy.py' 2>/dev/null || true
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

# CAM_POSE overrides the camera_pose baked into that config, so an angle can be
# handed in without editing a file:
#     CAM_POSE="22 -14 22 0 0.71 2.28"
# Get the numbers for a view you like by flying the GUI camera with the mouse and
# running scripts/camera_pose.sh, which prints them in exactly this order.
# The config also hard-codes <window><width>/<height>. Those must track RES or
# Gazebo keeps its default window on a larger canvas and the rest of the capture
# is solid black -- the render simply never fills the frame, which looks like a
# broken recording rather than a sizing problem.
GEN_CFG="/tmp/gui-generated.config"
sed -E -e "s|<width>[0-9]+</width>|<width>${GZ_W}</width>|" \
       -e "s|<height>[0-9]+</height>|<height>${GZ_H}</height>|" \
       "$GUI_CFG" > "$GEN_CFG"
if [[ -n "${CAM_POSE:-}" ]]; then
    sed -i -E "s|<camera_pose>[^<]*</camera_pose>|<camera_pose>${CAM_POSE}</camera_pose>|" "$GEN_CFG"
    log "camera pose overridden: $CAM_POSE"
fi
GUI_CFG="$GEN_CFG"
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
xdotool windowmove "$WIN" 0 0 windowsize "$WIN" "$GZ_W" "$GZ_H" windowactivate "$WIN" || true
sleep 3
log "gazebo window $WIN at 0,0 ${GZ_W}x${GZ_H}"

# --------------------------------------------------------------------- sitl
log "starting ArduCopter SITL"
# SITL always runs headless with --no-mavproxy. env -u DISPLAY matters: with a
# display, sim_vehicle.py opens the SITL console in an xterm right on top of the
# render view.
#
# Letting sim_vehicle.py start MAVProxy instead does not work here -- it runs it
# in the foreground of a shell with no TTY, so MAVProxy exits immediately and
# takes the whole sim down ("SIM_VEHICLE: MAVProxy exited / Killing tasks").
# Under TELEM we therefore start our own MAVProxy in an xterm below.
setsid env -u DISPLAY bash -lc "source ~/ardupilot/venv-ardupilot/bin/activate && cd ~/ardupilot && \
    sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON --no-mavproxy" \
    >/tmp/sitl.log 2>&1 &

# Wait for the port to actually ACCEPT a connection, not merely for a hopeful
# line in the log. sim_vehicle.py prints "Waiting for connection" before the
# socket is bound, so grepping for it starts MAVProxy too early: it gets
# ECONNREFUSED, gives up despite --force-connected, and the flight script then
# waits forever for a heartbeat that will never arrive.
log "waiting for SITL to accept connections on 5760"
SITL_UP=0
for _ in $(seq 1 120); do
    if (echo > /dev/tcp/127.0.0.1/5760) 2>/dev/null; then SITL_UP=1; break; fi
    sleep 1
done
[[ "$SITL_UP" == "1" ]] || { echo "SITL never opened 5760; see /tmp/sitl.log" >&2; exit 1; }
log "  SITL is listening"
sleep 3

# ------------------------------------------------------------------ telemetry
# MAVProxy attaches to a SPARE SITL port. 5760 belongs to the flight script -- two
# clients on one TCP port fight over the stream. SITL advertises 5762 and 5763 for
# SERIAL1/SERIAL2, but only 5763 actually accepts connections here (5762 refuses),
# so that is the default. MAVProxy prints every STATUSTEXT the vehicle emits and
# accepts typed commands, which is what makes the custom-message demo legible.
if [[ "${TELEM:-0}" == "1" ]]; then
    # MAVProxy owns SITL's TCP link (a SITL TCP port accepts a single client) and
    # fans out to the flight script over UDP. That is the standard ArduPilot
    # arrangement and it is what lets one recording show the aircraft, the live
    # telemetry, and any command typed at the MAV> prompt.
    FANOUT="${FANOUT_PORT:-14551}"
    log "starting MAVProxy (owns tcp:5760, fans out to udp:127.0.0.1:$FANOUT)"
    # Scale the font with the canvas. A fixed 9pt font is legible at 1280x800 but
    # unreadable once the recording is 4K -- the terminal keeps the same character
    # count while every character shrinks relative to the frame.
    TELEM_FS="${TELEM_FS:-$(( H / 90 ))}"
    (( TELEM_FS < 9 )) && TELEM_FS=9
    log "  telemetry font ${TELEM_FS}pt for ${H}px tall canvas"
    setsid xterm -geometry 80x64+${GZ_W}+0 -fa Monospace -fs "$TELEM_FS" \
        -bg black -fg green -title "MAVProxy telemetry" \
        -e bash -lc "source ~/ardupilot/venv-ardupilot/bin/activate && \
            mavproxy.py --master tcp:127.0.0.1:5760 --out 127.0.0.1:$FANOUT \
                        --force-connected 2>&1 | tee \"$MAVPROXY_LOG\"" \
        >/dev/null 2>&1 &

    TWIN=""
    for _ in $(seq 1 25); do
        TWIN="$(xdotool search --name 'MAVProxy telemetry' 2>/dev/null | tail -1 || true)"
        [[ -n "$TWIN" ]] && break
        sleep 1
    done
    if [[ -n "$TWIN" ]]; then
        xdotool windowmove "$TWIN" "$GZ_W" 0 2>/dev/null || true
        log "telemetry pane at ${GZ_W},0"
    else
        log "telemetry pane did not appear (see $MAVPROXY_LOG)"
    fi
    export CONNECT="udp:127.0.0.1:$FANOUT"
    # Confirm MAVProxy actually linked; a dead link here strands the flight
    # script waiting for a heartbeat with no clue why.
    for _ in $(seq 1 30); do
        grep -q "Detected vehicle" "$MAVPROXY_LOG" 2>/dev/null && break
        sleep 1
    done
    if grep -q "Detected vehicle" "$MAVPROXY_LOG" 2>/dev/null; then
        log "  MAVProxy linked to the vehicle"
    else
        log "  WARNING: MAVProxy has not detected the vehicle (see $MAVPROXY_LOG)"
    fi
fi

# ---------------------------------------------------------------- recording
if [[ "${VISIBLE:-0}" == "1" ]]; then
    log "VISIBLE=1 — skipping capture"
    FF_PID=""
else
# Camera: without this the view sits at ground level and the iris is never in
# frame. follow keeps it centred for the whole flight; the offset puts the
# camera behind and above, which reads better than straight overhead.
# Camera mode. Gazebo offers five, via the /gui/track TOPIC (not a service --
# gz-gui 8 ships the CameraTrack message but advertises no matching service):
#
#   static    leave the camera at the gui-config pose
#   track     camera stays put and pans/tilts to keep the vehicle centred (1)
#   follow    rigid BODY-frame offset (2) -- whips around once the vehicle
#             tumbles, which is why the first crash take was empty sky
#   free_look follows position, does not inherit orientation (3)
#   look_at   follows AND always aims at the vehicle (4) -- best for a crash
#
case "${CAM_MODE:-static}" in
    static)    CAM_ID="" ;;
    track)     CAM_ID=1 ;;
    follow)    CAM_ID=2 ;;
    free_look) CAM_ID=3 ;;
    look_at)   CAM_ID=4 ;;
    *) echo "unknown CAM_MODE '${CAM_MODE}'" >&2; exit 1 ;;
esac

if [[ -n "$CAM_ID" ]]; then
    OFF="${CAM_OFFSET:-x: -10, y: 0, z: 4}"
    log "camera mode ${CAM_MODE} on $MODEL (offset: $OFF)"
    if [[ "$CAM_ID" == "1" ]]; then
        REQ="track_mode: $CAM_ID, track_target: {name: \"$MODEL\"}"
    else
        REQ="track_mode: $CAM_ID, follow_target: {name: \"$MODEL\"}, follow_offset: {$OFF}, follow_pgain: ${CAM_PGAIN:-0.8}"
    fi
    timeout 8 gz topic -t /gui/track -m gz.msgs.CameraTrack -p "$REQ" >/dev/null 2>&1 \
        || log "camera mode command failed (non-fatal)"
    sleep 2
    CONFIRM="$(timeout 5 gz topic -e -t /gui/currently_tracked 2>/dev/null | grep -m1 track_mode || true)"
    log "  gazebo reports: ${CONFIRM:-<no confirmation>}"
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
bash -lc "source ~/ardupilot/venv-ardupilot/bin/activate && CONNECT=\"${CONNECT:-}\" python3 $REPO/scripts/$FLIGHT" \
    2>&1 | tee "$FLIGHT_LOG"
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
    HINT="$(grep -o 'RTF_HINT sim=[0-9.]* wall=[0-9.]*' "$FLIGHT_LOG" | tail -1 || true)"
    if [[ -n "$HINT" ]]; then
        RTF="$(python3 -c "
import re
m = re.search(r'sim=([0-9.]+) wall=([0-9.]+)', '''$HINT''')
s, w = float(m.group(1)), float(m.group(2))
print(f'{max(0.05, min(1.0, s/w)):.4f}')")"
        RT="$RUN_DIR/$RUN_ID-realtime.mp4"
        log "measured RTF $RTF — writing real-time version"
        # setpts compresses the timeline, but ffmpeg keeps the OUTPUT frame rate
        # at the input's, so it silently drops the surplus frames -- a 919-frame
        # capture came out as 365. Raise the output rate by the same factor to
        # keep every frame; that is also what makes the re-timed cut smoother
        # than the raw one rather than choppier.
        RT_FPS="$(python3 -c "print(min(60, max(15, round($FPS / $RTF))))")"
        log "  re-timed output at ${RT_FPS} fps (keeps every captured frame)"
        if ffmpeg -hide_banner -loglevel error -y -i "$OUT" \
                -filter:v "setpts=${RTF}*PTS" -r "$RT_FPS" -an "$RT" 2>/dev/null; then
            log "saved: $RT ($(du -h "$RT" | cut -f1))"
        else
            log "re-timing failed; the wall-clock capture is still valid"
        fi
    else
        log "no RTF_HINT from the flight script; skipping real-time version"
    fi
    echo "finished:   $(date -Is)" >> "$RUN_DIR/$RUN_ID-run.txt"
    log "run directory: $RUN_DIR"
    ls -1 "$RUN_DIR" | sed 's/^/    /' 
else
    echo "recording is empty — check the capture geometry" >&2
    exit 1
fi
exit "$FLIGHT_RC"
