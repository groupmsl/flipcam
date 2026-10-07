# Flipcam

A tool for fliping/rotating a webcam in Linux. Do you have a webcam mounted upside-down? Then this is for you...

## Quick start (Debian/Ubuntu-based)

```bash
./install.sh
```

The script detects and lists cameras by name and asks which one to flip, for example:

```text
1) UGREEN Camera 4K: UGREEN Camera   [/dev/video4]
```

The installer then installs v4l2loopback and ffmpeg, loads the module at boot, installs and starts a systemd user service, and grants the Teams Flatpak device access. Simply pick **Flipped Cam** in Teams (restart Teams if it isn't listed).

The service refers to the camera by its name-based path under `/dev/v4l/by-id/` (built from the vendor, model and serial), not by `/dev/videoN`, so it keeps working when video numbers change between reboots or when other cameras are plugged in.

To skip the menu, pass a camera explicitly (a `/dev/videoN` node is converted to its name path):

```bash
./install.sh /dev/video4
```

## Flip modes

The default is `hflip,vflip`, a 180 degree rotation. That is the correct fix for a camera that is physically mounted upside down: the picture is flipped both ways, so text reads correctly.  Choose another mode with `FLIP_FILTER`, then re-run the script:

```bash
FLIP_FILTER=vflip ./install.sh
```

| FLIP_FILTER   | Effect                                                    |
|---------------|-----------------------------------------------------------|
| `hflip,vflip` | Rotate 180 degrees (default; fixes an upside-down camera) |
| `vflip`       | Flip top to bottom only (mirror image; left and right stay as they were) |
| `hflip`       | Mirror left to right only                                 |
| `transpose=1` | Rotate 90 degrees clockwise (output becomes portrait)     |
| `transpose=2` | Rotate 90 degrees counter-clockwise (output becomes portrait) |
| `null`        | No change                                                 |

Teams usually mirrors your own preview, so judge orientation by holding up text to the camera, or ask someone on the call.

## Undocking and docking

If the camera disappears (e.g. laptop undocked), the service stays running and waits quietly. While the camera is missing, no ffmpeg runs and "Flipped Cam" drops out of app camera lists. The service checks for the camera every 2 seconds, and "Flipped Cam" reappears within a few seconds of re-docking; no restart needed.

## Camera light (on-demand mode)

Reading from the camera is what turns the light on. By default (`FLIP_ONDEMAND=1`) the real camera is only opened while some app has "Flipped Cam" open. When nothing is using it, a black placeholder keeps "Flipped Cam" listed in apps and the real camera is closed, so the light stays off. The service checks every 2 seconds, and closes the camera about 6 seconds after the last app lets go.

Things to know:

* The light may blink on for a few seconds while an app probes the device list (e.g. opening Teams' camera settings).
* Switching from placeholder to real camera takes about a second. If Teams freezes after that switch, toggle video off and on, or turn on-demand off:

```bash
FLIP_ONDEMAND=0 ./install.sh
```

This keeps the camera open permanently (light always on).

* If the light never goes off, something else is holding "Flipped Cam" open. See what with:

```bash
find /proc/[0-9]*/fd -lname /dev/video10 2>/dev/null
```

## Lag and lip sync

The flipped camera adds a little delay compared with using the camera directly, because every frame is decoded, flipped and handed on. Since the delay is on the video only, it shows up as bad lip sync. The default settings are tuned to keep it small:

* 1280x720 by default (Teams typically sends 720p anyway). 1080p is over twice the work per frame. Use `FLIP_RES=1920x1080` to switch back, at the cost of more delay and CPU.
* ffmpeg runs with input buffering off, a two-frame queue and slice-threaded decoding, so frames are passed on as soon as they arrive instead of piling up.
* The virtual camera is created with `max_buffers=2`, the smallest queue, which keeps stale frames from building up between ffmpeg and the app.
* The idle placeholder runs at the same size and frame rate as the real camera.

If it still lags, work through these in order:

1. Is ffmpeg keeping up? While in a call, run `top` and look at the `ffmpeg` line. If it is near 100%, the machine is the bottleneck: lower the load with `FLIP_RES=640x480`, or `FLIP_FPS=15`.
2. Is on-demand mode involved? Try `FLIP_ONDEMAND=0 ./install.sh` and compare. If the lag disappears, the switch from placeholder to real camera is the cause; leave on-demand off.
3. Is it the room? This camera has `exposure_dynamic_framerate` on, which drops the frame rate in dim light (fewer frames = more delay). To pin it at full rate, at the cost of a darker picture in low light:

```bash
v4l2-ctl -d /dev/video4 --set-ctrl=exposure_dynamic_framerate=0
```

4. Measure it. Run a stopwatch on your phone, hold it in front of the camera, and open the virtual camera in a viewer so that the phone and the screen showing the phone are in one photo:

```bash
ffplay -fflags nobuffer -flags low_delay /dev/video10
```

   The difference between the real stopwatch and the one on screen is the total delay. For a baseline, stop the service (`systemctl --user stop flipcam.service`), view the camera directly with `ffplay -fflags nobuffer -flags low_delay /dev/v4l/by-id/<your camera>-video-index0`, and repeat. Start the service again afterwards.

If a small remaining delay is still noticeable, the microphone can be delayed to match the video instead (a PipeWire filter), which fixes lip sync without making the video any faster.

## Manual install

1. Copy `flipcam-watch.sh` to `~/.local/bin/` and `chmod +x` it
2. Copy `flipcam.service` to `~/.config/systemd/user/` and edit `FLIP_CAMERA`: run
   `ls -l /dev/v4l/by-id/` and use the symlink for your camera ending in `-video-index0`
3. Run:

```bash
sudo apt install v4l2loopback-dkms ffmpeg
echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf
echo 'options v4l2loopback devices=1 video_nr=10 card_label="Flipped Cam" exclusive_caps=1 max_buffers=2' | sudo tee /etc/modprobe.d/v4l2loopback.conf
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="Flipped Cam" exclusive_caps=1 max_buffers=2
systemctl --user daemon-reload
systemctl --user enable --now flipcam.service
```

## Tweaks

* Higher quality (more delay and CPU): `FLIP_RES=1920x1080 ./install.sh`
* See supported modes: `v4l2-ctl -d /dev/video4 --list-formats-ext`
* Two identical cameras with no serial number can share one by-id name. If the menu shows only one of them, use `/dev/v4l/by-path/` instead (it is tied to the USB port).
* Logs: `journalctl --user -u flipcam.service -e`

## Teams Flatpak not seeing the camera

```bash
flatpak list    # find the app ID
flatpak override --user --device=all <app-id>
```

## Manual uninstall

```bash
systemctl --user disable --now flipcam.service
rm ~/.config/systemd/user/flipcam.service ~/.local/bin/flipcam-watch.sh
sudo rm /etc/modules-load.d/v4l2loopback.conf /etc/modprobe.d/v4l2loopback.conf
sudo modprobe -r v4l2loopback
```
