#!/usr/bin/env bash
#
# Record a flight with Gazebo's OWN video recorder, in lockstep.
#
# Why this exists: every scripted capture path samples the screen on a timer, so
# when the GUI redraws slowly most frames are duplicates -- our best automated
# recording holds ~1.4 unique frames per second. Gazebo's recorder takes frames
# from the render output instead, so nothing is ever captured twice, and
# use_sim_time stamps them on the simulation clock so playback speed is right
# with no re-timing.
#
# It does NOT use lockstep. Lockstep would make the GUI wait for each frame, but
# the ArduPilot plugin already blocks the server waiting on SITL packets, and the
# two deadlock -- choosing mp4 froze the GUI outright.
#
# It cannot be started from a script: the recorder is a GUI button and Qt refuses
# synthetic clicks (xdotool, XSendEvent and key events were all rejected). So you
# click it, twice, and this script does everything else.
#
#   ./scripts/record_lockstep.sh          # from the host, over ssh is fine
#
set -euo pipefail

REPO_HOST="$(cd "$(dirname "$0")/.." && pwd)"
REPO=/workspace/sitl_drone
CFG="$REPO/docker/gz/gui-crash-rec.config"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$REPO_HOST/recordings/lockstep-$STAMP"

: "${WORLD:=iris_runway.sdf}"
: "${FLIGHT:=fly_fail.py}"
# RES is the window size in LOGICAL pixels. This display is HiDPI at 2x, so the
# window comes out twice this on screen -- 2560x1600 became 5120x2166 and spilled
# off a 5504x2304 screen. The recorder captures device pixels, so 1280x800 here
# still yields a 2560x1600 video.
: "${RES:=1280x800}"
: "${CAM_POSE:=3.7 12.2 4.6 0 0.41 -2.58}"
: "${TAKEOFF_ALT:=4}"; : "${CRUISE_N:=10}"; : "${CRUISE_SPEED:=2}"; : "${KILL_AFTER:=4}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;33m>>> %s\033[0m\n' "$*"; }

d() { docker exec sitl_drone bash -lc "$1"; }

log "unlocking the desktop session (the GUI must be on a real display)"
S="$(loginctl list-sessions --no-legend | awk '$4=="seat0"{print $1}' | head -1)"
[[ -n "$S" ]] || { echo "no graphical session on seat0 — log in at the machine first" >&2; exit 1; }
loginctl unlock-session "$S" 2>/dev/null || true

log "clearing anything left running"
# The bracket trick matters: these run via `bash -lc '<the whole string>'`, so the
# shell's OWN command line contains every pattern. A plain `pkill -f "gz sim"`
# therefore matches that shell and kills it, docker exec returns non-zero, and
# set -e aborts this script with no output. "[g]z sim" matches the target but
# not the literal pattern text.
d 'pkill -9 -f "[g]z sim" ; pkill -9 -f "[a]rducopter" ; pkill -9 -f "[s]im_vehicle" ; pkill -9 -f "[x]wd" ; true'
sleep 2
d 'rm -f ~/ign_recording.mp4 ~/ign_recording.ogv'

# Window size must match RES or Gazebo keeps its default and the rest is black.
log "starting Gazebo on the desktop display (hardware OpenGL)"
d "sed -E 's|<width>[0-9]+</width>|<width>${RES%x*}</width>|; s|<height>[0-9]+</height>|<height>${RES#*x}</height>|; s|<camera_pose>[^<]*</camera_pose>|<camera_pose>${CAM_POSE}</camera_pose>|' '$CFG' > /tmp/lockstep.config"
docker exec -d sitl_drone bash -lc 'setsid gz sim -v1 -r --gui-config /tmp/lockstep.config '"$WORLD"' >/tmp/gz_lockstep.log 2>&1 </dev/null'

for _ in $(seq 1 60); do
    d 'xdotool search --name "Gazebo Sim" >/dev/null 2>&1' && break
    sleep 1
done
log "Gazebo window is up"

log "starting ArduCopter SITL"
docker exec -d sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && cd ~/ardupilot && setsid env -u DISPLAY sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON --no-mavproxy >/tmp/sitl.log 2>&1 </dev/null'
log "waiting for SITL to accept connections (a source change triggers a rebuild, ~3 min)"
for _ in $(seq 1 300); do
    d '(echo > /dev/tcp/127.0.0.1/5760) 2>/dev/null' && break
    sleep 1
done
log "SITL is up"

cat <<'BANNER'

--------------------------------------------------------------------------
  ON THE MACHINE'S SCREEN, in the Gazebo window:

    1. Click the small grey square near the TOP-LEFT of the 3D view
       (hovering it shows the tooltip "Record Video").
    2. In the menu that opens, choose  mp4.

  Recording is now running. The simulation may slow down; that is fine.
--------------------------------------------------------------------------
BANNER
read -r -p "Press Enter here once you have clicked mp4... " _

step "flying $FLIGHT"
docker exec -e TAKEOFF_ALT="$TAKEOFF_ALT" -e CRUISE_N="$CRUISE_N" \
    -e CRUISE_SPEED="$CRUISE_SPEED" -e KILL_AFTER="$KILL_AFTER" sitl_drone \
    bash -lc "source ~/ardupilot/venv-ardupilot/bin/activate && python3 $REPO/scripts/$FLIGHT" || true

cat <<'BANNER'

--------------------------------------------------------------------------
  Click the SAME grey square again to STOP recording.

  Gazebo then opens a SAVE dialog. It is running inside the container, so
  the paths it shows are the CONTAINER's filesystem, not yours. Save
  anywhere -- the default /home/rusik is fine, any name will do. This
  script searches for whatever you saved and copies it out.

  Finalising the file can take several seconds after you hit Save.
--------------------------------------------------------------------------
BANNER
read -r -p "Press Enter here once you have saved the file... " _

log "collecting the recording"
mkdir -p "$OUT_DIR"
sleep 3

# The stop button opens a save dialog rather than writing a fixed path, so the
# file's name and location are whatever was typed. Find the newest video the
# container has written since this run started instead of assuming a name.
REC="$(docker exec sitl_drone bash -lc \
    'find / -xdev \( -name "*.mp4" -o -name "*.ogv" \) -newermt "-45 minutes" 2>/dev/null \
     | grep -v /workspace/ | xargs -r ls -t 2>/dev/null | head -1' || true)"

if [[ -n "$REC" ]]; then
    DEST="$OUT_DIR/lockstep-$STAMP.${REC##*.}"
    docker cp "sitl_drone:$REC" "$DEST"
    docker exec sitl_drone bash -lc "rm -f '$REC'" || true
    log "saved: $DEST   (was $REC inside the container)"

    # Unique frames, not total: a capture that samples the screen duplicates
    # frames, and only unique ones are motion the viewer sees.
    tot=$(ffmpeg -y -v info -i "$DEST" -an -f null - 2>&1 | grep -oE 'frame=\s*[0-9]+' | tail -1 | grep -oE '[0-9]+')
    uniq=$(ffmpeg -y -v info -i "$DEST" -vf mpdecimate -an -f null - 2>&1 | grep -oE 'frame=\s*[0-9]+' | tail -1 | grep -oE '[0-9]+')
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DEST" | cut -d. -f1)
    printf '    %sx%s  %ss  total %s  unique %s\n' \
        "$(ffprobe -v error -show_entries stream=width -of csv=p=0 "$DEST")" \
        "$(ffprobe -v error -show_entries stream=height -of csv=p=0 "$DEST")" \
        "$dur" "$tot" "$uniq"
    python3 -c "print(f'    -> {int($uniq)/max(1,int($dur)):.1f} unique fps (xwd managed 1.4, Xvfb 0.8)')"
else
    echo "no video found inside the container." >&2
    echo "If the save dialog is still open, save it and re-run just the copy:" >&2
    echo "  docker exec sitl_drone bash -lc 'ls -t ~/*.mp4 | head -1'" >&2
fi

log "shutting the simulation down"
d 'pkill -9 -f "[g]z sim" ; pkill -9 -f "[a]rducopter" ; pkill -9 -f "[s]im_vehicle" ; true'
