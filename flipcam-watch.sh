#!/usr/bin/env bash
# flipcam-watch.sh - feeds the "Flipped Cam" virtual camera.
#
# Environment (set by the systemd service):
#   FLIP_CAMERA    real camera path (a /dev/v4l/by-id/...-video-index0 symlink)
#   FLIP_LOOP_DEV  virtual camera device        (default /dev/video10)
#   FLIP_RES       capture size                 (default 1280x720)
#   FLIP_FPS       capture frame rate           (default 30)
#   FLIP_FILTER    ffmpeg video filter          (default hflip,vflip = rotate 180 degrees)
#   FLIP_ONDEMAND  1 = only open the real camera while an app is reading the virtual
#                  camera (camera light off otherwise); 0 = keep it open all the time
#
# Behaviour:
#   - Real camera missing (e.g. laptop undocked): no ffmpeg runs and "Flipped Cam" disappears
#     from app camera lists. The script polls for the camera and brings it back when it returns.
#   - On-demand mode: while the camera is present but nothing is using the virtual camera, a
#     black placeholder keeps "Flipped Cam" visible in app camera lists, and the real camera
#     stays closed (to avoid the camera light being on all the time).

set -u

CAM="${FLIP_CAMERA:?FLIP_CAMERA is not set}"
LOOP_DEV="${FLIP_LOOP_DEV:-/dev/video10}"
RES="${FLIP_RES:-1280x720}"
FPS="${FLIP_FPS:-30}"
FILTER="${FLIP_FILTER:-hflip,vflip}"
ONDEMAND="${FLIP_ONDEMAND:-1}"

POLL_SECS=2
IDLE_POLLS=3        # readers must be gone for this many polls before the real camera is closed

PID=""
STATE="none"        # none | real | idle

stop_ff() {
	if [ -n "$PID" ]; then
		kill "$PID" 2>/dev/null
		wait "$PID" 2>/dev/null
	fi
	PID=""
	STATE="none"
}
trap 'stop_ff; exit 0' TERM INT

start_real() {
	# Low-latency settings: no input buffering, no frame-threaded decode (which holds back
	# several frames), and a tiny queue between camera and filter so frames never pile up.
	ffmpeg -nostdin -hide_banner -loglevel warning \
		-fflags nobuffer -flags low_delay -thread_type slice -thread_queue_size 2 \
		-probesize 32 -analyzeduration 0 \
		-f v4l2 -input_format mjpeg -video_size "$RES" -framerate "$FPS" -i "$CAM" \
		-vf "$FILTER" -pix_fmt yuv420p -f v4l2 "$LOOP_DEV" &
	PID=$!
	STATE="real"
}

# The placeholder uses the same size and frame rate as the real camera, so the format an app
# negotiates while it is showing stays correct when the real picture takes over.
start_idle() {
	ffmpeg -nostdin -hide_banner -loglevel warning \
		-re -f lavfi -i "color=c=black:s=${RES}:r=${FPS}" \
		-pix_fmt yuv420p -f v4l2 "$LOOP_DEV" &
	PID=$!
	STATE="idle"
}

# Number of processes (other than our own ffmpeg) that have the virtual camera open.
# Works for Flatpak apps too, since they run as your user and show up in /proc.
count_readers() {
	local n=0 f p
	while IFS= read -r f; do
		p="${f#/proc/}"; p="${p%%/*}"
		[ "$p" != "$PID" ] && n=$((n + 1))
	done < <(find /proc/[0-9]*/fd -maxdepth 1 -lname "$LOOP_DEV" 2>/dev/null)
	echo "$n"
}

idle_count=0
while true; do
	# Notice if ffmpeg exited by itself (camera unplugged, etc.)
	if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
		wait "$PID" 2>/dev/null
		PID=""; STATE="none"
	fi

	cam_ok=0
	[ -e "$CAM" ] && cam_ok=1

	# No camera: run no ffmpeg at all. With exclusive_caps=1 the loopback then reports itself as
	# an output-only device, so "Flipped Cam" drops out of app camera lists until the camera returns.
	want="none"
	if [ "$cam_ok" = 1 ]; then
		want="real"
		if [ "$ONDEMAND" = 1 ]; then
			readers="$(count_readers)"
			if [ "$readers" -gt 0 ]; then idle_count=0; else idle_count=$((idle_count + 1)); fi
			if [ "$readers" -eq 0 ] && { [ "$STATE" != "real" ] || [ "$idle_count" -ge "$IDLE_POLLS" ]; }; then
				want="idle"
			fi
		fi
	fi

	if [ "$want" != "$STATE" ]; then
		stop_ff
		[ "$want" != "none" ] && "start_${want}"
	fi

	sleep "$POLL_SECS" &
	wait $! 2>/dev/null
done
