"""Burns watch activity data (speed, altitude, heart rate, ...) into a GoPro video.

    python tools/overlay.py GX010123.MP4 activity.fit            # writes GX010123.ass next to the video
    python tools/overlay.py GX010123.MP4 activity.fit --render   # and GX010123.overlay.mp4 via ffmpeg

The .ass file alone already works as subtitles: open the video in VLC or mpv with it to check
the timing before spending minutes on rendering.

Lining up the clocks: the video start is the MP4 creation_time. HERO12 writes real UTC there;
older GoPros are reported to write local time marked as UTC, so both readings are tried. If the
activity has our data field's "gopro_recording" track, the reading closest to a recording start
wins; otherwise UTC is assumed. --clock and --offset override; --offset also fixes a camera whose
clock was not set from the watch (it can be minutes off).

Needs ffprobe/ffmpeg on PATH. No Python packages.
"""

import argparse
import bisect
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import effects  # noqa: E402
import fitfile  # noqa: E402
import gauges  # noqa: E402
import gopromp4  # noqa: E402

RECORDING_FIELD = "gopro_recording"
# A recording start this close to a candidate video start confirms that reading of creation_time.
REC_MATCH_WINDOW = 60
# Interpolate between samples at most this far apart (Garmin "smart recording" skips seconds).
MAX_GAP = 10
# Without interpolation, use the nearest sample if it is this close.
NEAREST_WINDOW = 2
# The data field sets a HiLight on every lap, Auto Lap included; the mark reaches the camera over
# BLE a moment after the lap ends. A HiLight belongs to the lap whose end is nearest to it, from
# LAP_MARK_AFTER before to LAP_MARK_BEFORE after the mark (video and activity clocks agree to ~1 s).
LAP_MARK_AFTER = 3.0
LAP_MARK_BEFORE = 1.0


# --- video ---

def ffprobe_json(args):
    """ffprobe's JSON output. It is UTF-8 whatever the console code page: decoding it as cp1251
    crashed on a Cyrillic file name ("И" is byte 0x98 in UTF-8, undefined in cp1251)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json"] + args, check=True,
                         capture_output=True, encoding="utf-8", errors="replace").stdout
    return json.loads(out)


def probe_video(path):
    """creation_time (aware datetime, as written; None if the file has none), duration (s), width, height."""
    info = ffprobe_json(["-show_format", "-show_streams", path])
    video = next((s for s in info["streams"] if s.get("codec_type") == "video"), None)
    if video is None:
        raise SystemExit("%s: no video stream" % path)
    created = info["format"].get("tags", {}).get("creation_time") or video.get("tags", {}).get("creation_time")
    duration = float(info["format"].get("duration") or video.get("duration"))
    return parse_time(created) if created else None, duration, int(video["width"]), int(video["height"])


def parse_seconds(text):
    """"95", "1:35" or "0:01:35" -> seconds."""
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def parse_time(text):
    """ISO 8601 as ffprobe prints it ("2026-09-24T19:36:01.000000Z"), naive values read as UTC."""
    value = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value


# --- lining up ---

def recording_starts(activity):
    """Unix times where the data field saw the camera start recording (0 -> 1)."""
    starts = []
    previous = 0
    for time, value in activity.values(RECORDING_FIELD):
        if value and not previous:
            starts.append(time)
        previous = value or 0
    return starts


def local_offset(activity, around):
    """Seconds east of UTC: from the activity, else this computer's zone at that date."""
    if activity.local_offset is not None:
        return activity.local_offset
    return int(datetime.fromtimestamp(around).astimezone().utcoffset().total_seconds())


def choose_start(created, activity, clock="auto"):
    """Unix time of the first video frame and a line explaining the choice."""
    as_utc = created.timestamp()
    offset = local_offset(activity, as_utc)
    as_local = as_utc - offset   # creation_time was local wall-clock time marked as UTC
    if clock == "utc":
        return as_utc, "creation_time read as UTC (--clock utc)"
    if clock == "local":
        return as_local, "creation_time read as local time, UTC%+.1fh (--clock local)" % (offset / 3600)
    starts = recording_starts(activity)
    if starts and offset != 0:
        def distance(t):
            return min(abs(s - t) for s in starts)
        best = min((as_local, "local"), (as_utc, "UTC"), key=lambda c: distance(c[0]))
        if distance(best[0]) <= REC_MATCH_WINDOW:
            return best[0], "creation_time read as %s: %d s from a %s start in the activity" % (
                best[1], distance(best[0]), RECORDING_FIELD)
    # HERO12 writes real UTC (checked on a real clip against its FIT, AGENTS.md); older GoPros reportedly local time.
    return as_utc, "creation_time read as UTC (default; --clock local if the overlay is off by %+.1fh)" % (
        offset / 3600)


def lap_of(moment, laps):
    """The lap (fitfile.Lap) a HiLight at Unix time `moment` was set for, or None: the one whose end
    is nearest to it, from LAP_MARK_AFTER before to LAP_MARK_BEFORE after the mark."""
    near = [lap for lap in laps if -LAP_MARK_BEFORE <= moment - lap.time <= LAP_MARK_AFTER]
    return min(near, key=lambda lap: abs(moment - lap.time), default=None)


def auto_lap_marks(hilights, laps, start):
    """The HiLights (video seconds; start = Unix time of the first frame) that the data field set
    for an Auto Lap (lap_trigger time, distance, position, ...). Not among them: marks of a LAP
    button lap, marks with no lap (UP in the watch app), and laps with no lap_trigger recorded."""
    out = []
    for t in hilights:
        lap = lap_of(start + t, laps)
        if lap is not None and lap.trigger is not None and not lap.manual:
            out.append(t)
    return out


def clock(seconds):
    """Video time as m:ss."""
    return "%d:%02d" % (seconds // 60, seconds % 60)


# --- sampling ---

class Sampler:
    """Activity values at arbitrary times, linearly interpolated across short gaps."""

    def __init__(self, records):
        self._records = records
        self._times = [r.time for r in records]

    def value(self, name, t):
        times = self._times
        i = bisect.bisect_right(times, t)
        before = self._find(name, i - 1, -1, t)
        after = self._find(name, i, 1, t)
        if before is not None and after is not None:
            t0, v0 = times[before], getattr(self._records[before], name)
            t1, v1 = times[after], getattr(self._records[after], name)
            if t1 - t0 <= MAX_GAP:
                return v0 if t1 == t0 else v0 + (v1 - v0) * (t - t0) / (t1 - t0)
        nearest = min((j for j in (before, after) if j is not None), key=lambda j: abs(times[j] - t), default=None)
        if nearest is not None and abs(times[nearest] - t) <= NEAREST_WINDOW:
            return getattr(self._records[nearest], name)
        return None

    def _find(self, name, i, step, t):
        """Nearest index from i in direction step whose record has this value, within MAX_GAP of t."""
        times = self._times
        while 0 <= i < len(times) and abs(times[i] - t) <= MAX_GAP:
            if getattr(self._records[i], name) is not None:
                return i
            i += step
        return None


# --- subtitles ---

def ass_time(seconds):
    centis = int(round(seconds * 100))
    return "%d:%02d:%02d.%02d" % (centis // 360000, centis // 6000 % 60, centis // 100 % 60, centis % 100)


def overlay_text(sampler, t, offset, big):
    """Subtitle text for one moment, or None if the activity has no values then (e.g. a pause)."""
    lines = []
    speed = sampler.value("speed", t)
    if speed is not None:
        lines.append("{\\fs%d}%d{\\r} km/h" % (big, round(speed * 3.6)))
    details = []
    altitude = sampler.value("altitude", t)
    if altitude is not None:
        details.append("%d m" % round(altitude))
    heart_rate = sampler.value("heart_rate", t)
    if heart_rate is not None:
        details.append("%d bpm" % round(heart_rate))
    distance = sampler.value("distance", t)
    if distance is not None:
        details.append("%.2f km" % (distance / 1000))
    if details:
        lines.append("  ".join(details))
    if not lines:
        return None
    lines.append(datetime.fromtimestamp(t + offset, timezone.utc).strftime("%H:%M:%S"))
    return "\\N".join(lines)


def build_ass(activity, start, duration, width, height, offset, style="text"):
    """Subtitles for the video: style "text" is one event per second, "gauges" draws a speedometer
    and a heart rate panel (gauges.py). Also returns the video seconds that have activity data."""
    size = max(height // 22, 12)
    big = size * 2
    margin = height // 30
    lines = [
        "[Script Info]",
        "ScriptType: v4.00+",
        "PlayResX: %d" % width,
        "PlayResY: %d" % height,
        "ScaledBorderAndShadow: yes",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, "
        "Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, "
        "MarginL, MarginR, MarginV, Encoding",
        # White bold text, black outline, bottom left (alignment 1)
        "Style: Data,Arial,%d,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,%d,1,1,%d,%d,%d,1"
        % (size, max(size // 12, 2), margin, margin, margin),
        # Gauges: position and size come from override tags; thin outline keeps text readable on water.
        "Style: Gauge,Arial,%d,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,%d,0,7,0,0,0,1"
        % (size, max(height // 540, 1)),
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    sampler = Sampler(activity.records)
    data_seconds = []
    texts = []
    second = 0
    while second < duration:
        end = min(second + 1, duration)
        text = overlay_text(sampler, start + second, offset, big)
        if text is not None:
            texts.append("Dialogue: 0,%s,%s,Data,,0,0,0,,%s" % (ass_time(second), ass_time(end), text))
            data_seconds.append(second)
        second += 1
    if style == "gauges" and data_seconds:
        for layer, t0, t1, text in gauges.build(sampler, start, duration, width, height, offset,
                                                data_seconds[0], data_seconds[-1], activity.records):
            lines.append("Dialogue: %d,%s,%s,Gauge,,0,0,0,,%s" % (layer, ass_time(t0), ass_time(t1), text))
    else:
        lines += texts
    return "\n".join(lines) + "\n", data_seconds


# --- rendering ---

# Quality settings per encoder. HEVC at these levels keeps 4K GoPro footage close to the source at
# about a third of its bitrate (hevc_qsv 28: 14.5 Mbit/s vs 42 from the camera, checked by eye).
# hvc1 tag: QuickTime / iOS only play HEVC in MP4 with it.
# H.264 is for phones that do not play HEVC, so it must be 8-bit 4:2:0: from a 10-bit HERO12 video
# libx264 otherwise keeps 10 bits and writes "High 10", which phones do not play (checked on a
# generated 10-bit clip). h264_qsv takes only nv12 anyway; h264_nvenc would take p010 too.
ENCODERS = {
    "hevc_nvenc": ["-rc", "vbr", "-cq", "{q}", "-b:v", "0", "-tag:v", "hvc1"],   # not tried here: no NVIDIA
    "hevc_qsv": ["-global_quality", "{q}", "-tag:v", "hvc1"],
    "libx265": ["-crf", "{q}", "-preset", "fast", "-tag:v", "hvc1"],
    "h264_nvenc": ["-rc", "vbr", "-cq", "{q}", "-b:v", "0", "-pix_fmt", "yuv420p"],
    "h264_qsv": ["-global_quality", "{q}", "-pix_fmt", "nv12"],
    "libx264": ["-crf", "{q}", "-preset", "veryfast", "-pix_fmt", "yuv420p"],
}
DEFAULT_QUALITY = {"hevc_nvenc": 28, "hevc_qsv": 28, "libx265": 26, "h264_nvenc": 25, "h264_qsv": 25, "libx264": 20}
# Hardware HEVC first: libx265 is ~8x slower than real time on 4K here.
AUTO_ORDER = ["hevc_nvenc", "hevc_qsv", "libx265"]


def encoder_works(encoder):
    """Encodes one tiny frame: the build may list an encoder whose hardware is missing."""
    command = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=256x256:d=0.1", "-frames:v", "1",
               "-c:v", encoder, "-f", "null", "-"]
    return subprocess.run(command, capture_output=True).returncode == 0


def pick_encoder(requested):
    if requested != "auto":
        return requested
    for encoder in AUTO_ORDER:
        if encoder_works(encoder):
            return encoder
    return "libx264"


def encoder_args(encoder, quality):
    q = quality if quality is not None else DEFAULT_QUALITY.get(encoder)
    return [a.replace("{q}", str(q)) for a in ENCODERS.get(encoder, [])]


def probe_streams(path):
    """(frame rate as ffmpeg writes it, e.g. "30000/1001", has audio) for the filter graph."""
    streams = ffprobe_json(["-show_streams", path])["streams"]
    video = next(s for s in streams if s.get("codec_type") == "video")
    return video.get("r_frame_rate", "30/1"), any(s.get("codec_type") == "audio" for s in streams)


def render(inputs, graph_path, output, encoder, quality=None, extra_inputs=()):
    """Runs ffmpeg with the filter graph from graph_path (effects.graph), in that file's folder:
    the graph names the .ass files without a path (the subtitles filter wants C:\\... escaped otherwise).
    inputs: (file, seek, length, GPU decoding) per input, in the graph's input order; then
    extra_inputs (the mask)."""
    command = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-stats", "-y"]
    for path, seek, length, hwaccel in inputs:
        # -hwaccel auto: GPU decoding of 4K HEVC when available; frames come back to RAM for the filters.
        # Only for the long inputs: a GPU decoder took ~0.5 GB of memory in 4K here, a CPU one ~0.12 GB,
        # and a replay is a few seconds.
        # -ss/-t before -i: seek fast and stop decoding at the end of the part.
        command += (["-hwaccel", "auto"] if hwaccel else []) + [
            "-ss", effects.fmt_time(seek), "-t", effects.fmt_time(length), "-i", os.path.abspath(path)]
    for path in extra_inputs:
        command += ["-i", os.path.abspath(path)]
    command += ["-/filter_complex", os.path.basename(graph_path), "-map", "[vout]"]
    with open(graph_path, encoding="utf-8") as f:
        if "[aout]" in f.read():
            command += ["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"]
    # GoPro files also carry data tracks (timecode, telemetry); only picture and sound are mapped.
    # faststart: index at the front, so phones and browsers start playing before reading it all.
    command += ["-c:v", encoder] + encoder_args(encoder, quality) + ["-movflags", "+faststart", os.path.abspath(output)]
    print(subprocess.list2cmdline(command))
    if subprocess.run(command, cwd=os.path.dirname(os.path.abspath(graph_path))).returncode != 0:
        hint = "" if encoder == "libx264" else " (no %s on this computer? try --encoder libx264)" % encoder
        raise SystemExit("ffmpeg failed" + hint)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video")
    parser.add_argument("fit")
    parser.add_argument("--clock", choices=["auto", "local", "utc"], default="auto",
                        help="how to read the MP4 creation_time (default: auto)")
    parser.add_argument("--start", help="video start instead of creation_time, ISO 8601 with zone, "
                                        "e.g. 2026-09-24T22:36:01+03:00")
    parser.add_argument("--offset", type=float, default=0, help="seconds to add to the video start")
    parser.add_argument("--style", choices=["gauges", "text"], default="gauges",
                        help="gauges: speedometer dial + heart rate panel; text: plain lines")
    parser.add_argument("--render", action="store_true", help="burn the overlay in with ffmpeg")
    parser.add_argument("--effects", default="",
                        help="comma list of %s, or all: speed-driven looks and slowed replays "
                             "(of the camera's HiLight marks but those of Auto Laps, else of the top speed)"
                             % ", ".join(effects.ALL))
    parser.add_argument("--replay-at", type=lambda text: [parse_seconds(p) for p in text.split(",") if p.strip()],
                        help="slowmo replays these moments of the video instead (comma list of seconds or m:ss)")
    parser.add_argument("--replay-all-hilights", action="store_true",
                        help="slowmo replays the HiLights of Auto Laps too (by default only those of LAP "
                             "button laps and of the watch app's UP)")
    parser.add_argument("--encoder", default="auto",
                        help="ffmpeg video encoder; auto: hevc_nvenc, hevc_qsv, else libx265 (slow). "
                             "For phones that do not play HEVC: h264_qsv, h264_nvenc or libx264. "
                             "Also: %s" % ", ".join(e for e in ENCODERS if e not in AUTO_ORDER))
    parser.add_argument("--quality", type=int, help="encoder quality number (lower = better, bigger); "
                                                    "defaults: " + ", ".join("%s %d" % kv for kv in DEFAULT_QUALITY.items()))
    parser.add_argument("--height", type=int,
                        help="scale down to this height, e.g. 1080: ~4x faster effects and a smaller file than 4K")
    parser.add_argument("--full", action="store_true",
                        help="render the whole video, not only the part with activity data")
    parser.add_argument("--preview", type=float, help="render only N seconds")
    parser.add_argument("--from", dest="start_at", type=float,
                        help="render from this second of the video (with --preview: check one moment)")
    parser.add_argument("-o", "--output", help="rendered file (default: <video>.overlay.mp4)")
    args = parser.parse_args(argv)
    # Output to a pipe or file is in the console code page (cp1251 here): a file name or label
    # outside it ("♥", Polish letters) must not stop the script.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    for tool in ("ffprobe", "ffmpeg") if args.render else ("ffprobe",):
        if shutil.which(tool) is None:
            raise SystemExit("%s not found on PATH" % tool)

    # A long GoPro video comes as chapters GX01nnnn, GX02nnnn, ...: treat them as one video.
    files = gopromp4.chapters(args.video)
    created, duration, width, height = probe_video(files[0])
    hilights = gopromp4.hilights(files[0])
    chapter_starts = [0.0]   # video second where each chapter file begins
    for chapter in files[1:]:
        chapter_starts.append(duration)
        # HiLight times are taken as relative to their own chapter [VERIFY on a chaptered video with marks].
        hilights += [duration + t for t in gopromp4.hilights(chapter)]
        duration += probe_video(chapter)[1]
    if len(files) > 1:
        print("chapters: " + ", ".join(os.path.basename(p) for p in files))
    if hilights:
        print("HiLights at: " + ", ".join(clock(t) for t in hilights))
    size = None
    if args.height and args.height < height:
        # Everything below (subtitles, mask) is laid out for the output size.
        width, height = int(round(width * args.height / height / 2.0)) * 2, args.height
        size = (width, height)
    activity = fitfile.read_activity(args.fit)
    if not activity.records:
        raise SystemExit("%s: no records with a timestamp" % args.fit)
    if args.start:
        start, why = parse_time(args.start).timestamp(), "--start"
    elif created is None:
        raise SystemExit("%s: no creation_time tag; pass --start" % files[0])
    else:
        start, why = choose_start(created, activity, args.clock)
    start += args.offset
    offset = local_offset(activity, start)

    def show(t):
        return datetime.fromtimestamp(t + offset, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    first, last = activity.records[0].time, activity.records[-1].time
    print("video:    %s .. %s local (%s)" % (show(start), show(start + duration), why))
    print("activity: %s .. %s local, %d records, UTC%+.1fh" % (show(first), show(last), len(activity.records),
                                                                offset / 3600))
    starts = recording_starts(activity)
    if starts:
        print("recording starts in the activity: " + ", ".join(show(s)[11:] for s in starts))

    ass, data_seconds = build_ass(activity, start, duration, width, height, offset, args.style)
    if not data_seconds:
        raise SystemExit("the video does not overlap the activity; check --clock / --offset / --start")
    ass_path = os.path.splitext(args.video)[0] + ".ass"
    with open(ass_path, "w", encoding="utf-8") as f:
        f.write(ass)
    print("wrote %s: %d of %d seconds have data (%d..%d)" % (
        ass_path, len(data_seconds), int(duration + 0.999), data_seconds[0], data_seconds[-1]))

    if args.render:
        start_at, length = args.start_at, args.preview
        if start_at is None and length is None and not args.full:
            # Only the part with data, a second of margin on both sides.
            start_at = max(data_seconds[0] - 1, 0)
            length = min(data_seconds[-1] + 2, duration) - start_at
        start_at = start_at or 0
        length = min(length or duration, duration - start_at)

        fx = effects.parse(args.effects)
        fps, has_audio = probe_streams(files[0])
        sampler = Sampler(activity.records)
        top = effects.peak(sampler, start, start_at, start_at + length)
        series = effects.intensity(sampler, start, start_at, start_at + length, top[1] if top else 0) if top else []
        base = os.path.splitext(args.video)[0]
        output = args.output or base + ".overlay.mp4"

        # ffmpeg's helper files go to a folder of their own under plain names: the graph names them,
        # and a video name with , ' [ ] ; = (all allowed on Windows) broke the graph.
        work = tempfile.mkdtemp(prefix="overlay-")
        done = False
        try:
            with open(os.path.join(work, "overlay.ass"), "w", encoding="utf-8") as f:
                f.write(ass)
            replays = []
            if "slowmo" in fx:
                for n, (moment, text) in enumerate(replay_moments(args, hilights, activity, sampler, start,
                                                                  start_at, length, top), 1):
                    window = effects.replay_window(moment, start_at, length)
                    if not window:
                        continue
                    label = "replay%d.ass" % n
                    with open(os.path.join(work, label), "w", encoding="utf-8") as f:
                        f.write(effects.replay_ass(width, height, text, (window[1] - window[0]) * effects.REPLAY_SLOWDOWN))
                    replays.append((window[0], window[1], label))
                    print("replay %d: %.1f..%.1f s of the video (%s)" % (n, window[0], window[1], text))

            extra_inputs = []
            if "vignette" in fx:
                mask = os.path.join(work, "vignette.png")
                effects.make_vignette_mask(mask, width, height)
                extra_inputs.append(mask)
            # Each input reads from one chapter file: ffmpeg's concat demuxer could not seek reliably
            # ("could not seek to position 0.000" and the first chapter skipped).
            parts = effects.split_at(effects.segments(start_at, length, replays), chapter_starts[1:])
            feeds = effects.inputs(parts, chapter_starts[1:])
            inputs = []
            for t0, t1, members in feeds:
                i = max(n for n, s in enumerate(chapter_starts) if s <= t0 + 1e-6)
                inputs.append((files[i], t0 - chapter_starts[i], t1 - t0, parts[members[0]][2] is None))
            graph_path = os.path.join(work, "filters.txt")
            with open(graph_path, "w", encoding="utf-8") as f:
                f.write(effects.graph(fx, "overlay.ass", parts, fps, series, has_audio,
                                      mask_input=len(feeds) if extra_inputs else None, size=size, feeds=feeds))

            encoder = pick_encoder(args.encoder)
            print("encoder: %s %s; effects: %s" % (encoder, " ".join(encoder_args(encoder, args.quality)),
                                                   ", ".join(sorted(fx)) or "none"))
            render(inputs, graph_path, output, encoder, args.quality, extra_inputs)
            done = True
        finally:
            if done:
                shutil.rmtree(work, ignore_errors=True)
            else:
                print("ffmpeg's filter graph and subtitles are kept in %s" % work)
        print("wrote %s (%.0f MB)" % (output, os.path.getsize(output) / 2 ** 20))


def replay_moments(args, hilights, activity, sampler, start, start_at, length, top):
    """[(video second, label)] for slowmo: --replay-at if given; else the camera's HiLights in the
    rendered part, except those the data field set for an Auto Lap (unless --replay-all-hilights);
    else the top speed."""
    def speed_text(moment):
        speed = sampler.value("speed", start + moment)
        return "REPLAY" + ("  ·  %d km/h" % round(speed * 3.6) if speed is not None else "")
    if args.replay_at:
        return [(t, speed_text(t)) for t in args.replay_at]
    inside = [t for t in hilights if start_at <= t <= start_at + length]
    auto = [] if args.replay_all_hilights else auto_lap_marks(inside, activity.laps, start)
    for t in auto:
        print("HiLight at %s = Auto Lap, not replayed" % clock(t))
    marks = [t for t in inside if t not in auto]
    if marks:
        return [(t, speed_text(t)) for t in marks]
    if top:
        return [(top[0], "REPLAY  ·  MAX %d km/h" % round(top[1]))]
    return []


if __name__ == "__main__":
    main()
