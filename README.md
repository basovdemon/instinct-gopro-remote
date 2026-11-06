# Instinct GoPro Remote

Control a GoPro from a **Garmin Instinct 3 Solar** watch directly over Bluetooth Low Energy, using the official [Open GoPro](https://gopro.github.io/OpenGoPro/) BLE API. No phone, no Wi-Fi.

Two Connect IQ apps share one BLE core:

- **Watch app** (`GoProRemote`): a remote with buttons, plus a glance.
- **Data field** (`GoProField`): records video together with the activity timer of any native activity (snowboard, hike, bike, …).

Plus `tools/overlay.py`: burns speed, heart rate, distance and a mini map from the activity FIT file into the video.

> **Status:** a personal project. Tested on an Instinct 3 Solar 50 mm with a HERO12 Black. Not in the Connect IQ Store yet: install by sideloading (below).

## Features

### Watch app

- START starts / stops recording, UP sets a HiLight while recording, DOWN switches video / photo / time lapse (START then takes a photo).
- Camera battery and mode on screen; REC indicator and recording time in the round subscreen.
- Sets the camera clock from the watch on every connection (so video and activity line up).
- Reconnects on its own after a drop, but does not wake a camera you have just switched off.
- BACK asks whether to put the camera to sleep on exit.
- Glance: the last camera state the app saw (name, mode, battery, when). The glance never connects: that would wake the camera.

### Data field

"Camera on = filming": the field never wakes the camera, so you choose whether to film with the camera's own power button.

- Activity timer start → record, stop → stop. Auto-pause is ignored, so a lift or a traffic light does not cut the video.
- Every lap (manual and Auto Lap) → HiLight.
- Two short vibrations when the camera confirms recording, one long when it stops. Three long ones and "NOT REC" when the timer runs but the camera does not record (repeated every 2 minutes while connected).
- Writes a `gopro_recording` developer field (1 = recording, 0 = not recording or unknown) into the activity FIT file: `overlay.py` uses it to find the clips.
- Add it to a **regular** cell of an activity data screen: Connect IQ fields are not offered for the cell in the subscreen circle.

## Compatibility

**Watches:** Instinct 3 Solar 45 mm and 50 mm, including Tactical editions (one Connect IQ product, `instinct3solar45mm`). Needs Connect IQ API 4.2.5 (BLE bonding).

**Cameras** (checked against the Open GoPro spec; only HERO12 Black tested on real hardware):

| Camera | Status |
|---|---|
| HERO12 Black | tested |
| HERO11 Black, HERO11 Black Mini, HERO13 Black | should work, not tested |
| HERO9 Black, HERO10 Black | should work; the clock is set without a time zone (`0x0D`); HERO9 rejects "camera control" in the app (harmless) |
| MAX 2 | everything is in the spec, but presets of a 360 camera may behave differently; not tested |
| LIT HERO | recording works; HiLight and sleep are not supported by the camera |
| Mission 1, Mission 1 Pro | **does not work yet**: they need 2-byte status IDs |
| HERO8 and older | no Open GoPro, does not work |

## Install (sideload)

1. Build the `.prg` files (see [Building](#building)) or take them from a release.
2. Connect the watch over USB. It shows up as an MTP device, not a drive: copy `GoProRemote.prg` and/or `GoProField.prg` into `GARMIN/APPS`.
3. **Pair:** put the camera into pairing mode (HERO12: *Preferences → Connections → Connect Device → Quik App*), then open the app on the watch (or start an activity with the field). The app and the field pair separately: do it once for each.

After that the camera does not need pairing mode again.

- **Switching to another camera:** put the new one into pairing mode, the app pairs with it. The watch API cannot remove a bond, so the old camera stays known; to make a camera forget the watch use *Preferences → Connections → Reset Connections* on the GoPro (this removes all its pairings, the phone's too).
- If the camera does not connect while a phone is connected to it, disconnect the phone.
- Logs: create an empty file `GARMIN/APPS/LOGS/GOPROREMOTE.TXT` (or `GOPROFIELD.TXT`) and the app appends its BLE log there. Release builds have no log.

## Building

Requirements:

- [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 9.3.0 or newer via the SDK Manager, with current device files (Instinct 3 Solar).
- Java (for the compiler), PowerShell (for `tools/build.ps1`).
- A developer key in the repository root (git-ignored):

  ```
  openssl genrsa -out developer_key.pem 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
  ```

  Keep a backup: Store updates must be signed with the same key, and a lost key cannot be recovered.

```powershell
./tools/build.ps1                      # bin/GoProRemote.prg
./tools/build.ps1 -Run                 # build and run in the simulator (log goes to the console)
./tools/build.ps1 -Test                # unit tests in the simulator
./tools/build.ps1 -DataField           # bin/GoProField.prg
./tools/build.ps1 -DataField -Lean     # the field without logs (~2 KB less memory)
./tools/build.ps1 -Release             # Store package bin/GoProRemote.iq + bin/GoProRemote-release.prg
./tools/build.ps1 -DataField -Release  # the same for the field
```

The simulator is fine for the UI. BLE in the simulator needs an external Nordic nRF52 board, so BLE is tested on the watch.

Python tests for the tools: `python -m unittest discover -s tools`.

## Video overlay (`tools/overlay.py`)

Python 3 and ffmpeg/ffprobe 7+ on `PATH`; no Python packages.

```
python tools/overlay.py GX010123.MP4 activity.fit            # writes GX010123.ass next to the video
python tools/overlay.py GX010123.MP4 activity.fit --render   # and renders GX010123.overlay.mp4
```

- Get the activity FIT from Garmin Connect (*Export Original*) or from the watch (`GARMIN/Activity`).
- Gauges: speedometer, heart rate, distance, time, mini map. `--style text` for plain subtitles.
- `--effects vignette,zoom,saturation,slowmo` (or `all`): effects follow the speed; `slowmo` replays HiLight moments at 0.4x (Auto Lap marks are skipped unless `--replay-all-hilights`).
- Chaptered clips (`GX01…`, `GX02…`) are joined automatically.
- The clocks are matched via the MP4 `creation_time` and the `gopro_recording` track; `--offset`, `--clock`, `--start` override. `--from N --preview M` renders a short piece to check the timing.
- `python tools/overlay.py --help` for the rest.

## Privacy

The apps talk only to the camera over BLE. They collect and send nothing. The data field writes the `gopro_recording` flag into your own activity file.

## Contributing

Issues and pull requests are welcome, especially reports from other cameras (HERO9–11, HERO13) with a log. [AGENTS.md](AGENTS.md) describes the architecture, the protocol details and what was verified on hardware.

## Disclaimer

Not affiliated with, endorsed by or sponsored by GoPro, Inc. or Garmin Ltd. GoPro, HERO and HiLight are trademarks of GoPro, Inc.; Garmin, Instinct and Connect IQ are trademarks of Garmin Ltd. or its subsidiaries. Built from the public [Open GoPro](https://github.com/gopro/OpenGoPro) specification (MIT).

## License

[MIT](LICENSE)
