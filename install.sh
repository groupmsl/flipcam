#!/usr/bin/env bash
# Creates a virtual webcam ("Flipped Cam") that shows your real webcam flipped, and sets it up
# to start automatically at login.
#
# Usage:  bash ./install.sh [camera]
#   No argument: lists your cameras by name and asks which one to flip.
#   With argument: a /dev/v4l/by-id/... path, or a /dev/videoN node (it is converted to
#   its by-id name path automatically).
#
# Keep flipcam-watch.sh in the same folder as this script; it is installed to ~/.local/bin.
#
# Options (environment variables):
#   FLIP_FILTER    hflip,vflip (default, rotate 180) | vflip | hflip | transpose=1 | transpose=2
#   FLIP_ONDEMAND  1 (default) = open the real camera only while an app is using
#                  "Flipped Cam", so the camera light stays off otherwise
#                  0 = keep the camera open all the time
#   FLIP_RES, FLIP_FPS   capture size / frame rate (default 1280x720 at 30; lower = less lag)
#
# Run as your normal user (not with sudo); it calls sudo itself where needed.

set -euo pipefail
shopt -s nullglob

LOOP_NR=10
LABEL="Flipped Cam"
RES="${FLIP_RES:-1280x720}"
FPS="${FLIP_FPS:-30}"
FILTER="${FLIP_FILTER:-hflip,vflip}"     # rotate 180 degrees. See README for other modes.
ONDEMAND="${FLIP_ONDEMAND:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Camera selection -------------------------------------------------------------------------
# Each camera is identified by its /dev/v4l/by-id/...-video-index0 symlink. These paths contain
# the vendor/model name (and serial, when the camera has one) and do not change between reboots
# or USB ports, unlike /dev/videoN. "index0" is the actual video capture node; index1 and up are
# usually metadata nodes.

CAM_PATHS=()
CAM_NAMES=()
CAM_NODES=()

for link in /dev/v4l/by-id/*-video-index0; do
	node="$(readlink -f "$link")"
	base="$(basename "$node")"
	name="$(cat "/sys/class/video4linux/$base/name" 2>/dev/null || echo "$base")"
	# Skip our own virtual camera if it already exists.
	[ "$name" = "$LABEL" ] && continue
	CAM_PATHS+=("$link")
	CAM_NAMES+=("$name")
	CAM_NODES+=("$node")
done

CAM="${1:-}"

if [ -n "$CAM" ]; then
	# Argument given: if it is a /dev/videoN node, map it to its by-id name path.
	if [[ "$CAM" == /dev/video* ]]; then
		resolved=""
		for i in "${!CAM_NODES[@]}"; do
			if [ "${CAM_NODES[$i]}" = "$(readlink -f "$CAM")" ]; then
				resolved="${CAM_PATHS[$i]}"
			fi
		done
		if [ -n "$resolved" ]; then
			CAM="$resolved"
		else
			echo "!! No by-id name path found for $CAM; using $CAM directly (this may change between reboots)."
		fi
	fi
else
	if [ "${#CAM_PATHS[@]}" -eq 0 ]; then
		echo "!! No cameras found under /dev/v4l/by-id/."
		echo "   Check that your camera is plugged in (ls -l /dev/v4l/by-id/ /dev/v4l/by-path/),"
		echo "   or pass a device explicitly:  bash install.sh /dev/video4"
		exit 1
	fi

	echo "Cameras found:"
	echo
	for i in "${!CAM_PATHS[@]}"; do
		printf "  %d) %s   [%s]\n" "$((i + 1))" "${CAM_NAMES[$i]}" "${CAM_NODES[$i]}"
	done
	echo

	while true; do
		read -rp "Which camera do you want to flip? [1-${#CAM_PATHS[@]}]: " choice
		if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#CAM_PATHS[@]}" ]; then
			CAM="${CAM_PATHS[$((choice - 1))]}"
			echo "Selected: ${CAM_NAMES[$((choice - 1))]}"
			break
		fi
		echo "Please enter a number between 1 and ${#CAM_PATHS[@]}."
	done
fi

echo
echo "==> Using camera: $CAM"
echo "==> Virtual camera: /dev/video${LOOP_NR} (\"$LABEL\")"
echo "==> Filter: $FILTER   On-demand: $ONDEMAND"

if [ ! -f "$SCRIPT_DIR/flipcam-watch.sh" ]; then
	echo "!! flipcam-watch.sh not found next to this script ($SCRIPT_DIR). Keep the files together."
	exit 1
fi

# Install dependencies (Debian/Ubuntu). Adjust for other distros
if command -v apt >/dev/null 2>&1; then
	echo "==> Installing v4l2loopback and ffmpeg"
	sudo apt install -y v4l2loopback-dkms ffmpeg v4l-utils
else
	echo "!! apt not found. Install v4l2loopback (kernel module) and ffmpeg with your package manager, then re-run."
	exit 1
fi

# Make the loopback module load at boot, with the right options
echo "==> Configuring v4l2loopback to load at boot"
echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf >/dev/null
echo "options v4l2loopback devices=1 video_nr=${LOOP_NR} card_label=\"${LABEL}\" exclusive_caps=1 max_buffers=2" \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf >/dev/null

# Load it now (reload if already loaded with different options)
# Stop any previous version of the service first so it isn't holding the device.
systemctl --user stop flipcam.service 2>/dev/null || true
if lsmod | grep -q '^v4l2loopback'; then
	sudo modprobe -r v4l2loopback || echo "!! Could not unload v4l2loopback (in use?). Reboot to apply options."
fi
sudo modprobe v4l2loopback devices=1 video_nr=${LOOP_NR} card_label="${LABEL}" exclusive_caps=1 max_buffers=2

# Install watcher script and systemd user service
echo "==> Installing watcher script and systemd user service"
install -Dm755 "$SCRIPT_DIR/flipcam-watch.sh" "$HOME/.local/bin/flipcam-watch.sh"

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/flipcam.service" <<EOF
[Unit]
Description=Flip webcam into virtual camera
# Never give up restarting (e.g. while the laptop is undocked).
StartLimitIntervalSec=0

[Service]
Environment="FLIP_CAMERA=${CAM}"
Environment="FLIP_LOOP_DEV=/dev/video${LOOP_NR}"
Environment="FLIP_RES=${RES}"
Environment="FLIP_FPS=${FPS}"
Environment="FLIP_FILTER=${FILTER}"
Environment="FLIP_ONDEMAND=${ONDEMAND}"
ExecStart=%h/.local/bin/flipcam-watch.sh
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable flipcam.service
systemctl --user restart flipcam.service

# Give Teams Flatpak access to camera devices (if installed)
if command -v flatpak >/dev/null 2>&1; then
	APP="$(flatpak list --app --columns=application 2>/dev/null | grep -i teams | head -n1 || true)"
	if [ -n "$APP" ]; then
		echo "==> Granting device access to $APP"
		flatpak override --user --device=all "$APP"
		echo "    Restart Teams for this to take effect."
	fi
fi

echo
echo "Done. In Teams, choose \"${LABEL}\" as your camera."
echo "The service reads from: $CAM"
echo "Check the service with:  systemctl --user status flipcam.service"
echo "Filter in use: ${FILTER}. If the picture looks wrong, re-run with e.g. FLIP_FILTER=vflip (see README)."
if [ "$ONDEMAND" = 1 ]; then
	echo "On-demand mode: the real camera only turns on while an app is using \"${LABEL}\"."
	echo "If that misbehaves, re-run with FLIP_ONDEMAND=0 to keep the camera open all the time."
fi
