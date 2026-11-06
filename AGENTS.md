# AGENTS.md

Notes for coding agents (and humans) working on this repository. User-facing docs: [README.md](README.md).

## What this is

Connect IQ (Monkey C) apps for the **Garmin Instinct 3 Solar** that control a GoPro (developed against a **HERO12 Black**) directly over BLE with the official **Open GoPro BLE API**. No phone, no Wi-Fi.

- Watch app + glance (`source/`, `manifest.xml`) and a data field (`datafield/`) that reuses `source/ble` and `source/common`.
- `tools/overlay.py`: burns FIT activity data into GoPro video (Python 3 + ffmpeg, no packages).

## Rule #1: verify, do not guess

Check protocol bytes, UUIDs and API behaviour against the primary sources before relying on them. If they disagree with this file, the sources win: fix this file.

- Open GoPro BLE spec: https://gopro.github.io/OpenGoPro/ and the machine-readable `references.json` (branch `gh-pages` of `gopro/OpenGoPro`). The spec has no versions any more: every operation lists the cameras that support it.
- Connect IQ API docs (`Toybox.BluetoothLowEnergy`): https://developer.garmin.com/connect-iq/api-docs/ and Core Topics → Bluetooth Low Energy.
- Device facts (screen, memory, fonts, part numbers): `compiler.json` / `simulator.json` of the device in the SDK's `Devices/` folder.

Places not yet verified on hardware are marked **[VERIFY]** here and in comments.

## Do not

- Hardcode UUIDs, command bytes or screen sizes without checking them against the docs.
- Send parallel BLE requests (one outstanding request at a time, see `BleQueue`).
- Add features beyond the current request.
- Commit the developer key (`developer_key.*`, git-ignored).
- Copy code from `ad220/gopro-remote-connectiq` (an earlier Connect IQ GoPro widget): it has no licence. Reading it for ideas is fine; this code is written from the Open GoPro spec.

## Build and test

- Connect IQ SDK 9.3.0+ via SDK Manager (active SDK in `%APPDATA%\Garmin\ConnectIQ\current-sdk.cfg`; `monkeyc` is not on `PATH`, `tools/build.ps1` finds it). Java, PowerShell.
- `./tools/build.ps1 [-Run] [-Test] [-DataField] [-Lean] [-Release]`. Builds use `-w -l 3` (strictest type checking): keep them warning-free.
  - The data field always builds with `-O 3`.
  - `-Lean` / `-Release` add `nolog.jungle` (excludes the `ble_log` annotation, so `BLE_LOGGING` is `false`). `-Release` also adds `-r` (no debug info) and builds the Store `.iq` with `monkeyc -e` for all part numbers in the manifest.
  - The optimizer drops log code only from a bare `if (BLE_LOGGING) { … }`. With `if (x && BLE_LOGGING)` the string stays in the binary (checked in the `.prg` bytes).
- Unit tests: `(:test)` functions in `source/test`, run by `build.ps1 -Test` in the simulator. The test runner starts the whole app for every test, so the output contains BLE log lines; they do not affect results. `GoProProtocol`, `PacketAssembler`, `RecordingWatch`, `Format` are pure logic: cover changes there with tests (packet examples from the spec).
- Python: `python -m unittest discover -s tools` (FIT fixtures are built byte by byte, plus end-to-end renders of generated clips).
- The root `monkey.jungle` sets `base.sourcePath = source`: the default would compile every `.mc` under the root, including the data field.

### Simulator

- Good for the UI only. BLE needs an external Nordic nRF52 board. Without it `onProfileRegister` never arrives (`BleManager` times out after 5 s and shows an error). In a data field `registerProfile` fails with `System Error: Failed invoking <symbol>` (the SDK's own BLE data field sample does the same).
- Profile registration survives app restarts in the simulator: after 3 runs `registerProfile` throws `Too Many Profiles`. `BleManager` treats that as registered. The watch does not do this.
- Layout checks without a camera: temporarily stub the `BleManager` getters (`getState`, `getError`, `isRecording`, …; for the field a `STUB_SCENARIO` constant and no `ble.start()`), build a separate `.prg` per state, then restore the files.
  - `tools/sim_capture.ps1` screenshots the simulator window, `tools/sim_key.ps1` presses a button, `tools/sim_menu.ps1 -List` / `-Id N` drives the simulator menu (language: Russian 6075, English 6064; data field layouts 1–4 fields: 6007–6011; IDs from SDK 9.3.0).
  - For Russian, the simulator language switch is enough.

## Device: Instinct 3 Solar

- Product ID `instinct3solar45mm` covers both 45 mm (`006-B4585-00`) and 50 mm (`006-B4759-00`), Tactical editions included. `instinct3solar50mm` does not exist (Garmin bug CIQQA-3813: the Store may treat 50 mm watches as incompatible; check after publishing).
- 176×176 monochrome MIP, black and white only (never use colour as the only signal). Round **subscreen** top right: `WatchUi.getSubscreen()`, in the simulator `x=113 y=0 w=62 h=62`.
- The visible screen is a semi-octagon: about 40 px cut at each end of the top and bottom rows, about 1 px less per row inwards (`SCREEN_CORNER` in `GoProField`).
- 5 buttons, no touch. Memory: watch app 128 KB, glance and data field 32 KB. At most 3 timers. `Toybox.Timer` is not available in a data field.
- Manifest: `minApiLevel="4.2.5"` (for `requestBond`), permission `BluetoothLowEnergy` (+ `FitContributor` for the field). The app is a `watch-app` with a glance (not the old widget type).

## Open GoPro protocol (BLE)

**Advertising:** 16-bit service UUID `0xFEA6` (scan filter). Name `GoPro XXXX` in the scan response. Manufacturer data, company `0xF202`: `[len][FF][F2 02][schema][status]…`, byte 12 = camera status, bit 0 = awake (processor on). Spec bit 2 = pairing mode, but HERO12 (firmware H23.01.02.40.00) does not set it. In practice `ScanResult.getDeviceName() == null` means pairing mode. The camera advertises for 8 h after going to sleep, and connecting wakes it. Parsing: `GoProProtocol.advertCameraStatus`.

**Characteristics** (`GP-XXXX` = `b5f9XXXX-aa8d-11e3-9046-0002a5d5c51b`): service `FEA6` with Command `0072` (write) / response `0073` (notify), Settings `0074` / `0075`, Query `0076` / `0077`. Service `GP-0090` with Net Mgmt `0091` / `0092`, only for Set Pairing State. The camera does not remember CCCDs: subscribe on **every** connection.

**Packets** (big endian, max 20 bytes per BLE packet): general 5-bit header `000LLLLL`; extended 13-bit `001LLLLL LLLLLLLL`; extended 16-bit `0x40 LL LL` (receive only); continuation `1000CCCC` with a counter wrapping at 0xF. Payload is TLV or protobuf (`P[0]` feature ID, `P[1]` action ID). `Characteristic.requestWrite` throws on more than 20 bytes: split long messages yourself.

**Commands** (Command `0072`, response `[hdr] [id] [status]`, status 0 success / 1 error / 2 invalid parameter):

- Shutter on / off: `03 01 01 01` / `03 01 01 00`. HiLight: `01 18` (only while recording). Sleep: `01 05`.
- Get Hardware Info `01 3C`: poll after connecting until success = camera ready. Response `3C 00` then `[len][value]` fields: model number (u32, HERO9 = 55, HERO10 = 57, HERO12 = 62), model name, board type, firmware, serial, AP SSID, AP MAC, … (`GoProProtocol.hardwareModel`).
- Load Preset Group `0x3E`: `04 3E 02 03 E8` video (1000), `…03 E9` photo (1001), `…03 EA` time lapse (1002). The parameter is 2 bytes (verified on HERO12, response `02 3E 00`). Current group = status 96.
- Set Local Date Time `0x0F` (HERO11+): `0C 0F 0A` + year u16, month, day, hour, minute, second, UTC offset in minutes i16, DST 0/1. Set Date Time `0x0D` (no zone, HERO9/10): `09 0D 07` + year u16, month, day, hour, minute, second. HERO9/10 (by model number) get `0x0D` directly; others get `0x0F`, and `0x0D` if `0x0F` fails.
- Set Camera Control EXTERNAL: `04 F1 69 08 02`, response `F1 E9 … 08 01`. Sent by the watch app only. HERO12 sometimes answers `08 00` (unknown); commands work either way. What it does to the camera's own buttons is **[VERIFY]**.
- Set Pairing State (first pairing, so the camera leaves its pairing screen): protobuf `03 01` in `GP-0091`, verified: `0E 03 01 08 00 12 08 "Instinct"` → `03 81 08 01`.

**Keep-alive:** operation `0x5B` in Settings `0074`: `03 5B 01 42`, response `02 5B 00`. Every **3 s** from connection, or the camera sleeps.

**Statuses** (TLV, 1-byte IDs): 8 Busy, 10 Encoding, 13 recording time, 70 battery %, 82 Ready, 96 preset group. Register for updates in Query `0076`: `06 53 08 0A 46 52 60`. First reply `[hdr] 53 <status> {id len value}…`, then pushes with query ID `0x93` that carry **only changed** statuses. Busy = 1 blocks only starting a recording (which also waits for Ready ≠ 0) and changing the group; stop, HiLight, keep-alive, time, Sleep and Camera Control are sent regardless (Busy is 1 while recording).

**Connection order:** scan (`FEA6`) → `pairDevice` → `requestBond` if not bonded → CCCDs on `0073`, `0075`, `0077`, `0092` → Get Hardware Info until success → register statuses → set the camera clock (only if not recording) → keep-alive. Reconnects use the stored bond and need no pairing mode. A camera factory reset (or *Reset Connections*) drops all pairings.

**Defensive parsing:** ignore unknown status IDs and TLV entries, never assume fixed lengths, ignore stray protobuf notifications with action ID `0xFF`. All statuses used here exist on all 10 cameras in the spec. Mission 1 / 1 Pro only have 2-byte status IDs (`0x16` / `0x56`) and do not work yet.

## Connect IQ BLE notes

- Register profiles with `registerProfile` **before** scanning, limit 3 profiles. Result in `onProfileRegister`.
- One registered `BleDelegate` per app. Only one BLE request in flight: `BleQueue` sends the next one after the previous callback. Writes use `WRITE_TYPE_WITH_RESPONSE`: `WRITE_TYPE_DEFAULT` means *without* response, so no `onCharacteristicWrite`.
- `requestBond()` only while connected and not bonded (else `InvalidRequestException`). `onEncryptionStatus` arrives after a new bond and on reconnects. On reconnect it can arrive after CCCD writes have started: do not wait for it.
- The bond persists (`isBonded()`, `getBondedDevices()` returns `ScanResult`s); `pairDevice` does not persist across app runs. The watch API cannot remove a bond; `unpairDevice` only stops the system's auto-reconnect.
- While a device is paired via `pairDevice`, the system reconnects it instantly after a drop, and that wakes a camera the user just switched off. So on a drop `BleManager` calls `unpairDevice` at once and rescans for the same camera (`isSameDevice`). It connects only if the advert says the camera is awake, ignoring adverts for the first 3 s. The app waits up to 2 min ("Camera off"), then shows START to wake it on purpose.
- Own camera only: connect to a camera this app has a bond with (`getBondedDevices` + `isSameDevice`), or to one in pairing mode, or to any camera if there are no bonds yet. Other GoPros nearby are skipped. **[VERIFY on the watch]** that `isSameDevice` against a bonded `ScanResult` recognises the own camera.
- Lost keys on the camera side: `onEncryptionStatus` != success or `STATUS_GATT_INSUFFICIENT_*` → error "Camera lost pairing".
- `Toybox.Timer` is unavailable in data fields, so `BleManager` / `BleQueue` keep deadlines on `System.getTimer()` checked by `tick()`. The host calls `tick()` once a second: the watch app from its `Timer`, the field from `compute()` (keep-alive every 3 ticks).
- Watch log: create an empty `GARMIN/APPS/LOGS/<PRG NAME>.TXT` and `System.println` output is appended there.

## Verified on hardware (Instinct 3 Solar 50 mm + HERO12 Black, Oct–Nov 2026)

- The full chain registerProfile → scan → pair → bond → CCCD → Get Hardware Info → statuses → time; record / stop; HiLight; keep-alive for 8+ minutes; mode switching; exit with sleep (the camera drops the link at once without answering Sleep; the app exits on the drop).
- Reconnect without waking: switching the camera off drops the link, the advert status goes `00`, the app waits; switching it on (`01`) reconnects and sets everything up again.
- Photo group: the camera sets Encoding = 1 while processing a photo, so `isRecording()` is always false in the photo group and START is ignored during processing.
- The data field: BLE works within 32 KB with logs, its own bond coexists with the app's, it does not wake the camera, timer start / stop records, manual laps in Hike give HiLights. Snowboard has no manual lap (by design, not needed). The camera switched off mid-recording and back on resumes recording by itself. The `gopro_recording` FIT field is present and matches the log.
- HERO12 writes true UTC into the MP4 `creation_time` (track timecode = local time of the camera's zone). Without clock sync its clock was about 32 s fast; Set Local Date Time fixes that.
- Text drawn up to the subscreen ring overlapped it by 1–2 px on the watch though not in the simulator: `ConnectView.drawClear` keeps 4 px away from the circle.

**Still [VERIFY] on the watch:** the changes listed under "own camera", data field loaded during auto-pause, Auto Lap HiLights, shutter retries, sleep after a photo, field layout in narrow cells, glance date, `compute()` while the field is not on the visible page, watch battery drain while scanning for a switched-off camera, DST in the UTC offset, whether `gopro_recording` shows in Garmin Connect for a sideloaded field.

## Watch app

- START record / stop (photo group: shoot), UP HiLight while recording, DOWN next preset group when not recording. Main screen: big REC / STOP or PHOTO, "Video · 85%". Subscreen: REC dot and recording time.
- BACK with a connected camera and no recording opens an exit menu: "Sleep camera" / "Keep it on". Sleep `01 05` → state `BLE_SLEEPING`, exit on the reply, on the drop or after 3 s. If a photo is still processing, Sleep waits for Encoding = 0 (up to 9 s). Otherwise BACK exits at once (`System.exit()`).
- Camera clock: set on every connection when not recording, offset from `System.getClockTime().timeZoneOffset`.

## Glance

- Never connects (it would wake the camera). Shows the last state the watch app saved (`source/glance/LastStatus.mc`, `Application.Storage` key `lastStatus`): name, battery, group, recording, time. Written by `ConnectView` on changes and in `onHide`.
- Three lines: `GoPro 1234` / mode or REC / `85% · 18:42` (date instead of time if not today). Glance area 164×61; the subscreen covers its right third.
- Glance code is `(:glance)`, its strings `scope="glance"`. `getInitialView` and `onStop` carry `:typecheck(disableGlanceCheck)`.

## Data field (`datafield/`)

Design decision: **camera on = filming**. The field never wakes the camera.

- Camera off: scan 30 s / pause 15 s, indefinitely, showing "Camera off". Connect only when the advert says awake (a camera in pairing mode is awake).
- Timer: `onTimerStart` → record; `onTimerStop` / `onTimerReset` → stop; `onTimerLap` → HiLight on every lap, Auto Lap included (by choice). Auto-pause (`onTimerPause` / `onTimerResume`) is ignored, except that a field loaded during auto-pause gets `onTimerPause` instead of `onTimerStart`, so the first such event with our timer stopped counts as a start.
- "Want recording" (`BleManager.setRecordingWanted`) is applied once per connection: a camera switched on mid-activity starts recording; a recording stopped with the camera's button is not restarted. A refused Set Shutter is retried with keep-alives, up to 3 times per connection.
- Before recording the field switches the camera to the video group once per connection; if that fails it records as is.
- Errors retry after 60 s (no buttons). Vibration logic in `source/common/RecordingWatch.mc`: 2 short = recording confirmed, 1 long = stopped, 3 long + "NOT REC" when the timer runs but the camera does not record (only if the camera was connected during this timer run; repeated every 2 min while connected, once when the link is lost; first warning after 15 s).
- FIT developer field `gopro_recording` (uint8, record messages): 1 recording, 0 not recording **or unknown** (no link).
- Layout: one or two lines in the largest font that fits, then a detail line (battery, "Pair again") in the smallest font if there is room. Fit is checked against the visible screen outline, not the cell rectangle. The cell position is derived from `getObscurityFlags()`, and a cell under the subscreen starts below it. The flags lie for the middle cells of the 4-field layout (marked bottom, end 28 px above the edge), so if nothing fits the outline the text is fitted to the cell. Narrow cells are 88 px wide.
- Memory (simulator, stubs): 25.2 of 28.5 KB with logs, 22.9 KB lean. If the field crashes on memory (`CIQ_LOG.YML` on the watch), use `-Lean`.
- The field is only offered for regular cells, not for the subscreen circle.

## Overlay tools (`tools/`)

- `fitfile.py`: minimal FIT parser, checked against Garmin's fit-javascript-sdk (compressed timestamps not supported; Garmin does not write them). Lap end = `start_time + total_elapsed_time` (lap `timestamp` equals `start_time` in Instinct 3 files).
- `overlay.py`: video start from MP4 `creation_time`. `--clock auto` tries the UTC and "local marked Z" readings and picks the one nearest to a `gopro_recording` start. `gauges.py` draws ASS vector gauges (10 Hz) and the mini map. `effects.py` builds speed-driven ffmpeg filters, one filter per 30 s window: a single expression for the whole clip made `perspective` quadratic. The vignette is a precomputed PNG mask.
- Slow-motion replays: `--replay-at`, else camera HiLights except Auto Lap marks (a mark belongs to the FIT lap ending 3 s before … 1 s after it; `lap_trigger` != 0 → skipped; `--replay-all-hilights` keeps them), else the top-speed moment.
- `gopromp4.py`: HiLights from `moov/udta/HMMT`, fallback GPMF `HLMT` (layout from third-party HERO7 analyses, **[VERIFY]** with a clip that has marks). Chapters `GX01…`, `GX02…` are found and rendered per file (the concat demuxer failed on seek).
- ffmpeg: one input per chapter, cut with `segment` / `asegment`; replays get their own CPU-decoded input (memory). The graph is passed as a file (`-/filter_complex`, ffmpeg 7+). Helper files go to a temp `overlay-*` folder, so any file name works. H.264 output is always 8-bit 4:2:0. `fps=<source>` at the end of the graph (after `setpts`/`concat`, `hevc_qsv` would not open otherwise).

## Architecture

```
source/
  GoProRemoteApp.mc      entry point, lifecycle, getGlanceView, 1 s timer → BleManager.tick()
  glance/                LastStatus (Storage), GoProGlanceView
  ble/
    BleManager.mc        scan, connect, bond, state machine, deadlines
    BleQueue.mc          one BLE request at a time
    GoProProtocol.mc     message building and parsing (no BLE/UI dependencies)
    GoProUuids.mc        service and characteristic UUIDs
    PacketAssembler.mc   multi-packet responses
    Logging.mc           BLE_LOGGING constant (chosen by annotation in the jungle)
  common/                Format (recording time), RecordingWatch (field warnings, pure logic)
  ui/                    ConnectView (+ subscreen), ConnectDelegate
  test/                  (:test) unit tests
resources/, resources-rus/   strings (English, Russian), launcher icon (tools/make_launcher_icon.py)
datafield/               manifest, monkey.jungle (reuses source/ble, source/common), GoProFieldApp, GoProField
nolog.jungle             switches BLE logs off (-Lean, -Release)
tools/                   build.ps1, sim_*.ps1, overlay.py (+ fitfile, gauges, effects, gopromp4), tests
```

Code comments are in English. UI strings exist in English and Russian; keep both in sync and short (narrow cells, octagonal screen).
