"""Tests for fitfile.py and overlay.py:  python -m unittest discover -s tools -v

FIT fixtures are built byte by byte here, following the layout in fitfile.py's docstring.
The end-to-end test renders a tiny generated video and needs ffmpeg on PATH (skipped otherwise).
"""

import argparse
import contextlib
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import effects  # noqa: E402
import fitfile  # noqa: E402
import gopromp4  # noqa: E402
import make_launcher_icon  # noqa: E402
import overlay  # noqa: E402


def box(kind, body):
    return struct.pack(">I4s", 8 + len(body), kind) + body


def hmmt(times_ms, room=80):
    """GoPro HiLight box: count, then room for 80 millisecond times, zero-padded."""
    times = list(times_ms) + [0] * (room - len(times_ms))
    return box(b"HMMT", struct.pack(">I", len(times_ms)) + b"".join(struct.pack(">I", t) for t in times))


def add_hilights(path, times_ms):
    """Puts an HMMT box into moov/udta of an MP4 that ffmpeg wrote (moov last, after mdat, so
    growing it moves no media data)."""
    with open(path, "rb") as f:
        data = f.read()
    pos = 0
    while pos < len(data):
        size, kind = struct.unpack_from(">I4s", data, pos)
        if kind == b"moov":
            moov = data[pos + 8:pos + size]
            out, p = b"", 0
            added = False
            while p < len(moov):
                s, k = struct.unpack_from(">I4s", moov, p)
                child = moov[p:p + s]
                if k == b"udta":
                    child = box(b"udta", child[8:] + hmmt(times_ms))
                    added = True
                out += child
                p += s
            if not added:
                out += box(b"udta", hmmt(times_ms))
            data = data[:pos] + box(b"moov", out) + data[pos + size:]
            break
        pos += size
    with open(path, "wb") as f:
        f.write(data)


def gpmf(key, kind, size, repeat, payload):
    """One GPMF KLV: key, type char, structure size, repeat (big endian), payload padded to 4 bytes."""
    return struct.pack(">4scBH", key, kind, size, repeat) + payload + b"\0" * (-len(payload) % 4)


def hlmt_device(times_ms, type_text=b"LLLlllFLL", struct_size=36):
    """udta GPMF's HiLights device. No marks: as in the wakeboard HERO12 file (DVID + DVNM only).
    Marks: HLMT structures as other tools describe them (time, in, out, lat, lon, alt, type,
    confidence, score); unverified on a real HERO12 file with marks."""
    body = gpmf(b"DVID", b"F", 4, 1, b"HLMT") + gpmf(b"DVNM", b"c", 10, 1, b"Highlights")
    if times_ms:
        records = b"".join(struct.pack(">IIIiii4sII", t, max(t - 1000, 0), t + 1000, 0, 0, 0, b"MANL", 100, 100)
                           for t in times_ms)
        body += gpmf(b"TYPE", b"c", len(type_text), 1, type_text) + gpmf(b"HLMT", b"?", struct_size, len(times_ms), records)
    return gpmf(b"DEVC", b"\0", 1, len(body), body)


def gpmf_box(*devices):
    """moov/udta/GPMF: a settings device, then the given ones, then zero padding like the camera's."""
    body = gpmf(b"DVID", b"L", 4, 1, struct.pack(">I", 1)) + gpmf(b"MINF", b"c", 1, 12, b"HERO12 Black")
    return box(b"GPMF", gpmf(b"DEVC", b"\0", 1, len(body), body) + b"".join(devices) + b"\0" * 256)


UINT8, SINT32, UINT16, UINT32, STRING, ENUM = 0x02, 0x85, 0x84, 0x86, 0x07, 0x00

# 2026-09-24T19:36:00Z, an activity in UTC+3
T0 = int(datetime(2026, 9, 24, 19, 36, 0, tzinfo=timezone.utc).timestamp())
TZ = 3 * 3600


def fit_time(unix):
    return unix - fitfile.FIT_EPOCH


def fit_file(*messages):
    body = b"".join(messages)
    return struct.pack("<BBHI4sH", 14, 0x20, 2100, len(body), b".FIT", 0) + body + b"\0\0"


def definition(local, global_number, fields, little=True, developer_fields=()):
    header = 0x40 | local | (0x20 if developer_fields else 0)
    out = bytes([header, 0, 0 if little else 1]) + struct.pack("<H" if little else ">H", global_number)
    out += bytes([len(fields)]) + b"".join(bytes(f) for f in fields)
    if developer_fields:
        out += bytes([len(developer_fields)]) + b"".join(bytes(f) for f in developer_fields)
    return out


def data(local, fmt, *values, little=True):
    return bytes([local]) + struct.pack(("<" if little else ">") + fmt, *values)


def developer_header():
    """developer_data_id + field_description for our data field's gopro_recording (uint8)."""
    return (definition(0, fitfile.MESG_DEVELOPER_DATA_ID, [(3, 1, UINT8)])
            + data(0, "B", 0)
            + definition(1, fitfile.MESG_FIELD_DESCRIPTION, [(0, 1, UINT8), (1, 1, UINT8), (2, 1, UINT8), (3, 16, STRING)])
            + data(1, "BBB16s", 0, 0, 0x02, b"gopro_recording"))


RECORD_FIELDS = [(253, 4, UINT32), (2, 2, UINT16), (3, 1, UINT8), (5, 4, UINT32), (6, 2, UINT16)]


def record(t, altitude_m, heart_rate, distance_m, speed_ms, recording):
    return data(2, "IHBIHB", fit_time(t), int((altitude_m + 500) * 5), heart_rate, int(distance_m * 100),
                int(speed_ms * 1000), recording)


LAP_FIELDS = [(253, 4, UINT32), (2, 4, UINT32), (7, 4, UINT32), (24, 1, ENUM)]
TIME, DISTANCE, SESSION_END = 1, 2, 7   # lap_trigger values; 0 = manual


def lap_messages(*laps):
    """Lap messages from (end, start, trigger), Unix seconds: timestamp = end, as the profile says."""
    out = definition(5, fitfile.MESG_LAP, LAP_FIELDS)
    for end, start, trigger in laps:
        out += data(5, "IIIB", fit_time(int(end)), fit_time(start), int(round((end - start) * 1000)), trigger)
    return out


def activity_fixture(recording_from=10, seconds=30, laps=()):
    """30 s of samples, 1 Hz; speed = t m/s, the camera records from second 10; laps: lap_messages()."""
    messages = [developer_header(),
                definition(2, fitfile.MESG_RECORD, RECORD_FIELDS, developer_fields=[(0, 1, 0)])]
    for s in range(seconds):
        messages.append(record(T0 + s, 1000 + s, 120 + s, s * 10, s, 1 if s >= recording_from else 0))
    if laps:
        messages.append(lap_messages(*laps))
    messages.append(definition(3, fitfile.MESG_ACTIVITY, [(253, 4, UINT32), (5, 4, UINT32)]))
    messages.append(data(3, "II", fit_time(T0 + seconds), fit_time(T0 + seconds) + TZ))
    return fit_file(*messages)


def make_clip(path, seconds, created=None, size="320x240", pix_fmt="yuv420p", extra=()):
    """A generated test video; created: Unix time for creation_time (UTC), None for no tag."""
    command = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=%g:size=%s:rate=10" % (seconds, size)]
    if created is not None:
        command += ["-metadata", "creation_time=" + datetime.fromtimestamp(created, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")]
    subprocess.run(command + ["-pix_fmt", pix_fmt] + list(extra) + [path], check=True)


def probe(path, entries):
    """ffprobe -show_entries value(s) as text."""
    return subprocess.run(["ffprobe", "-v", "error", "-show_entries", entries, "-of", "default=nw=1:nk=1", path],
                          check=True, capture_output=True, encoding="utf-8").stdout.split()


class FitFileTest(unittest.TestCase):

    def test_record_values_are_scaled(self):
        activity = fitfile.parse_activity(activity_fixture())
        self.assertEqual(len(activity.records), 30)
        r = activity.records[5]
        self.assertEqual(r.time, T0 + 5)
        self.assertAlmostEqual(r.altitude, 1005)
        self.assertEqual(r.heart_rate, 125)
        self.assertAlmostEqual(r.distance, 50)
        self.assertAlmostEqual(r.speed, 5)

    def test_developer_field_and_local_offset(self):
        activity = fitfile.parse_activity(activity_fixture())
        self.assertEqual(activity.local_offset, TZ)
        values = activity.values("gopro_recording")
        self.assertEqual(values[9], (T0 + 9, 0))
        self.assertEqual(values[10], (T0 + 10, 1))

    def test_invalid_values_are_none(self):
        body = (definition(2, fitfile.MESG_RECORD, RECORD_FIELDS)
                + data(2, "IHBIH", fit_time(T0), 0xFFFF, 0xFF, 0xFFFFFFFF, 0xFFFF))
        r = fitfile.parse_activity(fit_file(body)).records[0]
        self.assertIsNone(r.altitude)
        self.assertIsNone(r.heart_rate)
        self.assertIsNone(r.distance)
        self.assertIsNone(r.speed)

    def test_big_endian_enhanced_fields_and_position(self):
        fields = [(253, 4, UINT32), (73, 4, UINT32), (78, 4, UINT32), (0, 4, SINT32), (1, 4, SINT32)]
        body = (definition(4, fitfile.MESG_RECORD, fields, little=False)
                + data(4, "IIIii", fit_time(T0), 12345, (2500 + 500) * 5, 2 ** 30, -(2 ** 29), little=False))
        r = fitfile.parse_activity(fit_file(body)).records[0]
        self.assertAlmostEqual(r.speed, 12.345)
        self.assertAlmostEqual(r.altitude, 2500)
        self.assertAlmostEqual(r.lat, 90)
        self.assertAlmostEqual(r.lon, -45)

    def test_chained_files(self):
        first = fit_file(definition(2, fitfile.MESG_RECORD, RECORD_FIELDS) + data(2, "IHBIH", fit_time(T0 + 1), 0, 0, 0, 0))
        second = fit_file(definition(2, fitfile.MESG_RECORD, RECORD_FIELDS) + data(2, "IHBIH", fit_time(T0), 0, 0, 0, 0))
        times = [r.time for r in fitfile.parse_activity(first + second).records]
        self.assertEqual(times, [T0, T0 + 1])

    def test_not_fit(self):
        with self.assertRaises(ValueError):
            fitfile.parse_activity(b"\x0e\x20\x34\x08\x00\x00\x00\x00.MP4\x00\x00")

    def test_laps(self):
        activity = fitfile.parse_activity(activity_fixture(laps=[
            (T0 + 20.5, T0 + 10, 0), (T0 + 10, T0, DISTANCE), (T0 + 29, T0 + 20, SESSION_END)]))
        self.assertEqual([(lap.time, lap.start, lap.trigger, lap.manual) for lap in activity.laps], [
            (T0 + 10, T0, DISTANCE, False), (T0 + 20.5, T0 + 10, 0, True), (T0 + 29, T0 + 20, SESSION_END, False)])
        self.assertEqual(len(activity.records), 30)

    def test_lap_end_from_start_and_elapsed_time(self):
        # As in the Instinct 3 files from Garmin Connect: timestamp = start_time, the end is start + elapsed.
        body = (definition(5, fitfile.MESG_LAP, LAP_FIELDS)
                + data(5, "IIIB", fit_time(T0), fit_time(T0), 3142155, SESSION_END)
                # Only a timestamp and an invalid trigger: the timestamp is the end, trigger unknown.
                + definition(6, fitfile.MESG_LAP, [(253, 4, UINT32), (24, 1, ENUM)])
                + data(6, "IB", fit_time(T0 + 5000), 0xFF))
        laps = fitfile.parse_activity(fit_file(body)).laps
        self.assertAlmostEqual(laps[0].time, T0 + 3142.155)
        self.assertEqual((laps[1].time, laps[1].start, laps[1].trigger, laps[1].manual), (T0 + 5000, None, None, False))

    def test_header_without_crc_and_array_field(self):
        # 12-byte header (no header CRC); a 2-byte heart rate array: its first value is used.
        fields = [(253, 4, UINT32), (3, 2, UINT8)]
        body = definition(2, fitfile.MESG_RECORD, fields) + data(2, "IBB", fit_time(T0), 150, 151)
        file = struct.pack("<BBHI4s", 12, 0x20, 2100, len(body), b".FIT") + body + b"\0\0"
        self.assertEqual(fitfile.parse_activity(file).records[0].heart_rate, 150)

    def test_truncated_and_compressed_timestamp(self):
        good = activity_fixture()
        with self.assertRaises(ValueError):
            fitfile.parse_activity(good[:len(good) // 2])
        with self.assertRaises(ValueError):
            fitfile.parse_activity(fit_file(definition(2, fitfile.MESG_RECORD, RECORD_FIELDS) + bytes([0x80 | 0x20])))


class OverlayTest(unittest.TestCase):

    def setUp(self):
        self.activity = fitfile.parse_activity(activity_fixture())

    def test_recording_starts(self):
        self.assertEqual(overlay.recording_starts(self.activity), [T0 + 10])

    def test_clock_auto_picks_reading_next_to_recording_start(self):
        # Camera wrote local time marked as UTC: 22:36:10 "Z" for 19:36:10 UTC.
        local_label = datetime.fromtimestamp(T0 + 10 + TZ, timezone.utc)
        start, why = overlay.choose_start(local_label, self.activity)
        self.assertEqual(start, T0 + 10)
        self.assertIn("local", why)
        # Camera wrote real UTC.
        start, why = overlay.choose_start(datetime.fromtimestamp(T0 + 11, timezone.utc), self.activity)
        self.assertEqual(start, T0 + 11)
        self.assertIn("UTC", why)

    def test_clock_defaults_to_utc_without_recording_track(self):
        # HERO12 writes real UTC (real clip vs FIT, see AGENTS.md).
        activity = fitfile.parse_activity(activity_fixture(recording_from=1000))
        start, why = overlay.choose_start(datetime.fromtimestamp(T0, timezone.utc), activity)
        self.assertEqual(start, T0)
        self.assertIn("default", why)

    def test_clock_forced(self):
        created = datetime.fromtimestamp(T0 + TZ, timezone.utc)
        self.assertEqual(overlay.choose_start(created, self.activity, "utc")[0], T0 + TZ)
        self.assertEqual(overlay.choose_start(created, self.activity, "local")[0], T0)

    def test_sampler_interpolates_and_respects_gaps(self):
        records = [fitfile.Record(T0, speed=2.0), fitfile.Record(T0 + 4, speed=6.0), fitfile.Record(T0 + 30, speed=1.0)]
        sampler = overlay.Sampler(records)
        self.assertAlmostEqual(sampler.value("speed", T0 + 1), 3.0)
        self.assertAlmostEqual(sampler.value("speed", T0 + 5), 6.0)    # nearest, 1 s away
        self.assertIsNone(sampler.value("speed", T0 + 15))            # 11 s from any sample
        self.assertIsNone(sampler.value("altitude", T0 + 1))

    def test_encoder_args(self):
        self.assertEqual(overlay.encoder_args("hevc_qsv", None), ["-global_quality", "28", "-tag:v", "hvc1"])
        self.assertEqual(overlay.encoder_args("libx264", 23), ["-crf", "23", "-preset", "veryfast", "-pix_fmt", "yuv420p"])
        self.assertEqual(overlay.encoder_args("mpeg4", None), [])
        self.assertEqual(overlay.pick_encoder("libx264"), "libx264")
        # H.264 is for phones: always 8-bit 4:2:0 (a 10-bit source made libx264 write High 10).
        for encoder in ("libx264", "h264_qsv", "h264_nvenc"):
            self.assertIn("-pix_fmt", overlay.encoder_args(encoder, None))

    def test_auto_lap_marks(self):
        start = T0 + 100   # the video starts here; HiLights are video seconds
        laps = [fitfile.Lap(T0 + 110, trigger=DISTANCE),         # auto, mark 1.5 s later
                fitfile.Lap(T0 + 120, trigger=0),                # LAP button, mark 0.5 s later
                fitfile.Lap(T0 + 130, trigger=TIME),             # auto, mark 0.8 s *before* (clocks ~1 s apart)
                fitfile.Lap(T0 + 140, trigger=DISTANCE),         # auto 2.8 s before a mark ...
                fitfile.Lap(T0 + 142.5, trigger=0),              # ... that a LAP button lap is nearer to
                fitfile.Lap(T0 + 150, trigger=None),             # trigger not recorded
                fitfile.Lap(T0 + 160, trigger=DISTANCE)]         # auto, mark 4 s later: too far
        hilights = [11.5, 20.5, 29.2, 42.8, 50.3, 64, 75]       # 75: no lap at all (UP in the app)
        self.assertEqual(overlay.auto_lap_marks(hilights, laps, start), [11.5, 29.2])
        self.assertIsNone(overlay.lap_of(start + 75, laps))
        self.assertEqual(overlay.lap_of(start + 42.8, laps).trigger, 0)

    def test_replay_moments(self):
        sampler = overlay.Sampler(self.activity.records)
        activity = fitfile.Activity(self.activity.records, TZ, [fitfile.Lap(T0 + 8, trigger=DISTANCE),
                                                                fitfile.Lap(T0 + 13.5, trigger=0)])

        def moments(*flags, hilights=(4.0, 9.0)):
            args = argparse.Namespace(replay_at=None, replay_all_hilights=False)
            for flag in flags:
                setattr(args, *flag)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                got = overlay.replay_moments(args, list(hilights), activity, sampler, T0 + 5, 0, 12, (11.0, 57.6))
            return [t for t, _ in got], out.getvalue()

        # 4 s = T0 + 9: an Auto Lap ended 1 s before; 9 s = T0 + 14: the LAP button lap.
        self.assertEqual(moments(), ([9.0], "HiLight at 0:04 = Auto Lap, not replayed\n"))
        self.assertEqual(moments(("replay_all_hilights", True))[0], [4.0, 9.0])
        # Only Auto Lap marks: the top speed instead, as without marks.
        self.assertEqual(moments(hilights=[4.0])[0], [11.0])
        self.assertEqual(moments(hilights=[])[0], [11.0])
        self.assertEqual(moments(("replay_at", [2.0, 3.0]))[0], [2.0, 3.0])

    def test_ass_time(self):
        self.assertEqual(overlay.ass_time(0), "0:00:00.00")
        self.assertEqual(overlay.ass_time(3725.5), "1:02:05.50")

    def test_build_ass(self):
        ass, data_seconds = overlay.build_ass(self.activity, T0 + 25, 10, 1920, 1080, TZ)
        # Seconds 25..31 of the activity (29 + 2 s nearest window); the rest is past its end.
        self.assertEqual(data_seconds, list(range(7)))
        self.assertIn("PlayResX: 1920", ass)
        self.assertIn("Dialogue: 0,0:00:00.00,0:00:01.00,Data,,0,0,0,,{\\fs98}90{\\r} km/h\\N1025 m  145 bpm  0.25 km\\N22:36:25", ass)


class GoProMp4Test(unittest.TestCase):

    def test_hilights_from_hmmt(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "GX010001.MP4")
            moov = box(b"moov", box(b"mvhd", b"\0" * 100) + box(b"udta", box(b"FIRM", b"H23.01") + hmmt([62000, 1500])))
            with open(path, "wb") as f:
                f.write(box(b"ftyp", b"mp41") + box(b"mdat", b"\0" * 32) + moov)
            self.assertEqual(gopromp4.hilights(path), [1.5, 62.0])

    def test_no_hilights(self):
        # As in a real HERO12 file without marks: count 0, 320 zero bytes.
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "clip.mp4")
            with open(path, "wb") as f:
                f.write(box(b"ftyp", b"mp41") + box(b"moov", box(b"udta", hmmt([]))))
            self.assertEqual(gopromp4.hilights(path), [])
            with open(path, "wb") as f:
                f.write(box(b"ftyp", b"mp41") + box(b"moov", box(b"mvhd", b"\0" * 100)))
            self.assertEqual(gopromp4.hilights(path), [])

    def write_mp4(self, folder, moov):
        path = os.path.join(folder, "clip.mp4")
        with open(path, "wb") as f:
            f.write(box(b"ftyp", b"mp41") + box(b"mdat", b"\0" * 32) + moov)
        return path

    def test_hilights_from_gpmf_when_hmmt_has_none(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_mp4(folder, box(b"moov", box(b"udta", hmmt([]) + gpmf_box(hlmt_device([3500, 1200])))))
            self.assertEqual(gopromp4.hilights(path), [1.2, 3.5])
            # HMMT stays the main source: with marks there, GPMF is not read.
            path = self.write_mp4(folder, box(b"moov", box(b"udta", hmmt([800]) + gpmf_box(hlmt_device([3500])))))
            self.assertEqual(gopromp4.hilights(path), [0.8])

    def test_gpmf_without_marks_or_with_an_unknown_layout(self):
        with tempfile.TemporaryDirectory() as folder:
            # As in the wakeboard HERO12 file: the HiLights device is there, empty.
            path = self.write_mp4(folder, box(b"moov", box(b"udta", hmmt([]) + gpmf_box(hlmt_device([])))))
            self.assertEqual(gopromp4.hilights(path), [])
            # TYPE that does not add up to the structure size: not read rather than misread.
            path = self.write_mp4(folder, box(b"moov", box(b"udta", gpmf_box(hlmt_device([3500], type_text=b"LLL")))))
            self.assertEqual(gopromp4.hilights(path), [])
            path = self.write_mp4(folder, box(b"moov", box(b"udta", gpmf_box(hlmt_device([3500], type_text=b"FLLlllLLL")))))
            self.assertEqual(gopromp4.hilights(path), [])
            # Plain uint32 milliseconds (not seen yet, but a valid GPMF form).
            path = self.write_mp4(folder, box(b"moov", box(b"udta", gpmf_box(gpmf(b"HLMT", b"L", 4, 2, struct.pack(">II", 700, 2700))))))
            self.assertEqual(gopromp4.hilights(path), [0.7, 2.7])

    def test_box_sizes(self):
        with tempfile.TemporaryDirectory() as folder:
            # 64-bit size on moov (size field 1), udta running to the end of the file (size field 0).
            udta = struct.pack(">I4s", 0, b"udta") + hmmt([2000])
            body = box(b"mvhd", b"\0" * 100) + udta
            path = self.write_mp4(folder, struct.pack(">I4sQ", 1, b"moov", 16 + len(body)) + body)
            self.assertEqual(gopromp4.hilights(path), [2.0])
            # A box claiming less than its own header: reading stops, no exception.
            path = self.write_mp4(folder, box(b"moov", struct.pack(">I4s", 4, b"udta") + b"\0" * 16))
            self.assertEqual(gopromp4.hilights(path), [])
            # Count larger than the room: only the room is read.
            data = struct.pack(">I", 1000) + struct.pack(">II", 1500, 2500)
            path = self.write_mp4(folder, box(b"moov", box(b"udta", box(b"HMMT", data))))
            self.assertEqual(gopromp4.hilights(path), [1.5, 2.5])

    def test_chapters(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ("GX020042.MP4", "GX010042.MP4", "GX010043.MP4", "GH010042.MP4", "notes.mp4"):
                open(os.path.join(folder, name), "wb").close()
            got = [os.path.basename(p) for p in gopromp4.chapters(os.path.join(folder, "GX020042.MP4"))]
            self.assertEqual(got, ["GX010042.MP4", "GX020042.MP4"])
            self.assertEqual(gopromp4.chapters(os.path.join(folder, "notes.mp4")), [os.path.join(folder, "notes.mp4")])


class GaugesTest(unittest.TestCase):

    def test_track_map_fits_the_corner_box(self):
        import gauges
        # An L-shaped track: 0.01 deg north, then 0.01 deg east, around 51 N.
        records = [fitfile.Record(T0 + i, lat=51.0 + 0.001 * min(i, 10), lon=17.0 + 0.001 * max(i - 10, 0))
                   for i in range(21)]
        shapes, project = gauges.track_map(records, T0, 5, 15, 1920, 1080)
        self.assertEqual(len(shapes), 3)                       # box, whole track, part in the video
        for lat, lon in ((51.0, 17.0), (51.01, 17.0), (51.01, 17.01)):
            x, y = project(lat, lon)
            self.assertTrue(1920 - 40 - 260 <= x <= 1920 - 40, x)
            self.assertTrue(40 <= y <= 40 + 260, y)
        self.assertLess(project(51.01, 17.0)[1], project(51.0, 17.0)[1])   # north is up
        self.assertIsNone(gauges.track_map([fitfile.Record(T0)], T0, 0, 1, 1920, 1080))

    def test_polyline_goes_there_and_back(self):
        import gauges
        text = gauges.polyline([(0, 0), (10, 0), (10, 10)], 2, gauges.WHITE)
        self.assertIn("m 0.0 0.0 l 10.0 0.0 10.0 10.0 10.0 0.0", text)
        self.assertIn(r"\1a&HFF&", text)                      # no fill, outline only


class EffectsTest(unittest.TestCase):

    def test_segments_with_several_replays(self):
        self.assertEqual(effects.segments(0, 30, [(18, 21, "b"), (8, 11, "a")]),
                         [(0, 11, None), (8, 11, "a"), (11, 21, None), (18, 21, "b"), (21, 30, None)])
        self.assertEqual(effects.segments(5, 10), [(5, 15, None)])
        # A replay ending at the very end of the part: nothing after it.
        self.assertEqual(effects.segments(0, 10, [(7, 10, "a")]), [(0, 10, None), (7, 10, "a")])

    def test_split_at_chapter_boundaries(self):
        parts = [(0, 11, None), (8, 11, "a"), (11, 30, None)]
        self.assertEqual(effects.split_at(parts, [10, 20]),
                         [(0, 10, None), (10, 11, None), (8, 10, "a"), (10, 11, "a"), (11, 20, None), (20, 30, None)])

    def test_parse(self):
        self.assertEqual(effects.parse("all"), set(effects.ALL))
        self.assertEqual(effects.parse("zoom, slowmo"), {"zoom", "slowmo"})
        self.assertEqual(effects.parse(""), set())
        with self.assertRaises(SystemExit):
            effects.parse("blur")

    def test_expression_skips_zero_parts_and_escapes_commas(self):
        series = [(0, 0.0), (0.5, 0.0), (1.0, 0.5), (1.5, 1.0)]
        expr = effects.expression(series, "t")
        self.assertEqual(expr, "(gte(t\\,0.5)*lt(t\\,1)*(0.000+1.0000*(t-0.5))+gte(t\\,1)*lt(t\\,1.5)*(0.500+1.0000*(t-1)))")
        self.assertEqual(effects.expression([(0, 0.0), (1, 0.0)], "t"), "0")

    @unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg")
    def test_long_expression_is_accepted_by_ffmpeg(self):
        # 10 minutes of riding: a flat sum this long failed to parse ("Error when parsing the expression").
        series = [(i * 0.5, 0.5 + 0.4 * ((i % 7) / 7.0)) for i in range(1200)]
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "graph.txt")
            with open(path, "w") as f:
                f.write("[0:v]eq=contrast=1+0.1*(%s):eval=frame:enable=%s[v]"
                        % (effects.expression(series, "t"), effects.during(effects.active(series))))
            r = subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=black:s=64x64:d=0.5",
                                "-/filter_complex", path, "-map", "[v]", "-f", "null", "-"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr[:300])

    def test_bands_and_enable_spans(self):
        series = [(0, 0.0), (0.5, 0.0), (1.0, 0.5), (1.5, 1.0), (2.0, 1.0), (2.5, 0.0)]
        self.assertEqual(effects.active(series), [(0.5, 2.5)])
        # Interval midpoints 0.25, 0.75, 1.0, 0.5 at 4 levels -> 1, 3, 4, 2
        self.assertEqual(effects.bands(series, 4), {1: [(0.5, 1.0)], 3: [(1.0, 1.5)], 4: [(1.5, 2.0)], 2: [(2.0, 2.5)]})
        self.assertEqual(effects.during([(1, 2), (3, 4)]), "(gte(t\\,1)*lt(t\\,2)+gte(t\\,3)*lt(t\\,4))")
        self.assertEqual(effects.during([]), "0")

    def test_expression_within(self):
        series = [(0, 0.5), (0.5, 0.5), (1.0, 1.0), (1.5, 0.0)]
        self.assertEqual(effects.expression(series, "t", (0.6, 0.9)),
                         "gte(t\\,0.5)*lt(t\\,1)*(0.500+1.0000*(t-0.5))")
        self.assertEqual(effects.expression(series, "t", (5, 6)), "0")

    def test_windows_split_the_spans(self):
        spans = [(5, 27.5), (32.5, 100)]
        got = effects.windows(spans, 0, 100)
        self.assertEqual([(a, b) for a, b, _ in got], [(5, 35), (35, 65), (65, 95), (95, 100)])
        self.assertEqual(got[0][2], [(5, 27.5), (32.5, 35)])
        # Together the windows' spans are the spans, so one window filter at most works on a frame.
        joined = []
        for _, _, inside in got:
            for a, b in inside:
                if joined and joined[-1][1] == a:
                    joined[-1] = (joined[-1][0], b)
                else:
                    joined.append((a, b))
        self.assertEqual(joined, spans)
        self.assertEqual(effects.windows(spans, 28, 31), [])
        self.assertEqual(effects.windows(spans, 40, 41), [(40, 41, [(40, 41)])])
        # An hour of riding: no more than WINDOWS_MAX filters, longer windows instead.
        hour = effects.windows([(0, 3600)], 0, 3600)
        self.assertLessEqual(len(hour), effects.WINDOWS_MAX)
        self.assertEqual((hour[0][0], hour[-1][1]), (0, 3600))

    def test_graph_keeps_each_zoom_expression_short(self):
        # 5 minutes of riding. perspective re-parses its expressions on every frame: one expression
        # for all of 10 minutes cost ~0.15 s a frame.
        series = [(i * 0.5, 0.5 + 0.4 * ((i % 7) / 7.0)) for i in range(601)]
        text = effects.graph({"zoom", "saturation"}, "o.ass", [(0, 300, None)], "30", series, has_audio=False)
        filters = [f for f in re.split(r"(?<!\\),", text) if f.startswith("perspective=")]
        self.assertEqual(len(filters), 300 // effects.WINDOW)
        # 30 s = 60 pieces, and 2 more on each side (WINDOW_MARGIN), in each of the 8 corner coordinates.
        self.assertEqual({f.count("gte(") for f in filters}, {8 * 62 + 1, 8 * 64 + 1})
        self.assertEqual(len([f for f in re.split(r"(?<!\\),", text) if f.startswith("eq=")]), 10)
        # An hour: WINDOWS_MAX filters.
        series = [(i * 0.5, 0.5) for i in range(7201)]
        text = effects.graph({"zoom"}, "o.ass", [(0, 3600, None)], "30", series, has_audio=False)
        self.assertEqual(text.count("perspective="), effects.WINDOWS_MAX)

    def test_inputs_one_per_chapter_and_replay(self):
        parts = effects.split_at(effects.segments(0, 30, [(8, 11, "a"), (18, 21, "b")]), [15])
        self.assertEqual(parts, [(0, 11, None), (8, 11, "a"), (11, 15, None), (15, 21, None), (18, 21, "b"), (21, 30, None)])
        self.assertEqual(effects.inputs(parts, [15]),
                         [(0, 15, [0, 2]), (8, 11, [1]), (15, 30, [3, 5]), (18, 21, [4])])
        text = effects.graph(set(), "o.ass", parts, "30", [], feeds=effects.inputs(parts, [15]))
        self.assertIn("[0:v]setpts=PTS+0/TB[c0]", text)
        self.assertIn("[c0]ass=o.ass,segment=timestamps=11[s0][s2]", text)
        self.assertIn("[2:a]asetpts=PTS+15/TB,asegment=timestamps=21[r3][r5]", text)
        self.assertIn("[p0][q0][p1][q1][p2][q2][p3][q3][p4][q4][p5][q5]concat=n=6", text)
        self.assertEqual(effects.fmt_time(10800.25), "10800.25")
        self.assertEqual(effects.fmt_time(3.0), "3")

    @unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg")
    def test_zoom_windows_render_the_same(self):
        # The same frames, bit for bit, whether zoom / saturation come as one filter or as many
        # short windows; with a replay input that starts inside a window.
        series = [(i * 0.5, 0.0 if 3 <= i * 0.5 <= 4.5 else 0.3 + 0.6 * ((i % 5) / 5.0)) for i in range(25)]
        parts = [(0, 7, None), (4, 7, "r.ass"), (7, 12, None)]
        sums = []
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, "r.ass"), "w") as f:
                f.write(effects.replay_ass(96, 64, "R", 1))
            for window in (1000, 1.5):
                old = effects.WINDOW
                effects.WINDOW = window
                try:
                    text = effects.graph({"zoom", "saturation"}, "r.ass", parts, "10", series, has_audio=False)
                finally:
                    effects.WINDOW = old
                with open(os.path.join(folder, "g.txt"), "w") as f:
                    f.write(text)
                command = ["ffmpeg", "-v", "error"]
                for t0, t1, _ in effects.inputs(parts):
                    command += ["-ss", str(t0), "-t", str(t1 - t0), "-f", "lavfi", "-i", "testsrc=duration=12:size=96x64:rate=10"]
                r = subprocess.run(command + ["-/filter_complex", "g.txt", "-map", "[vout]", "-f", "framemd5", "-"],
                                   cwd=folder, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr[:300])
                sums.append([line.split(",")[-1] for line in r.stdout.splitlines() if not line.startswith("#")])
                self.assertEqual(text.count("perspective="), 2 if window == 1000 else 7 + 3)
        # 12 s at 10 fps, and the 3 s replay 2.5 times slower.
        self.assertAlmostEqual(len(sums[0]), 120 + 75, delta=2)
        self.assertEqual(sums[0], sums[1])

    def test_parse_seconds(self):
        self.assertEqual(overlay.parse_seconds("95"), 95)
        self.assertEqual(overlay.parse_seconds("11:42"), 702)
        self.assertEqual(overlay.parse_seconds("0:01:35.5"), 95.5)

    def test_peak_and_replay_window(self):
        sampler = overlay.Sampler(fitfile.parse_activity(activity_fixture()).records)
        t, kmh = effects.peak(sampler, T0, 0, 29)
        self.assertAlmostEqual(t, 29, delta=0.1)          # speed = t m/s in the fixture
        self.assertAlmostEqual(kmh, 29 * 3.6, delta=0.5)
        self.assertEqual(effects.replay_window(20, 0, 30), (18, 21))
        self.assertEqual(effects.replay_window(29.5, 0, 30), (27.5, 30))
        self.assertIsNone(effects.replay_window(0.2, 0, 0.5))


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "needs ffmpeg")
class RenderTest(unittest.TestCase):

    def test_render_generated_video(self):
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, "clip.mp4")
            fit = os.path.join(folder, "activity.fit")
            # A 3 s clip whose creation_time is local time marked as UTC, like GoPro cameras write it.
            created = datetime.fromtimestamp(T0 + 12 + TZ, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=10",
                            "-metadata", "creation_time=" + created, "-pix_fmt", "yuv420p", video], check=True)
            with open(fit, "wb") as f:
                f.write(activity_fixture())
            overlay.main([video, fit, "--render", "--encoder", "libx264", "--preview", "2"])
            self.assertTrue(os.path.exists(os.path.join(folder, "clip.ass")))
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                  os.path.join(folder, "clip.overlay.mp4")], check=True, capture_output=True, text=True)
            self.assertAlmostEqual(float(out.stdout), 2.0, delta=0.2)
            # A piece from the middle: --from seeks, subtitles stay on the original timeline.
            piece = os.path.join(folder, "piece.mp4")
            overlay.main([video, fit, "--render", "--encoder", "libx264", "--from", "1", "--preview", "1.5", "-o", piece])
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", piece],
                                 check=True, capture_output=True, text=True)
            self.assertAlmostEqual(float(out.stdout), 1.5, delta=0.2)

    def test_render_keeps_only_part_with_data(self):
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, "early.mp4")
            fit = os.path.join(folder, "activity.fit")
            # Starts 4 s before the activity (UTC creation_time): data from video second 2
            # (2 s nearest-sample window), so the render keeps 1..6 s = 5 s.
            created = datetime.fromtimestamp(T0 - 4, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=6:size=320x240:rate=10",
                            "-metadata", "creation_time=" + created, "-pix_fmt", "yuv420p", video], check=True)
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000))
            overlay.main([video, fit, "--render", "--encoder", "libx264"])
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                  os.path.join(folder, "early.overlay.mp4")], check=True, capture_output=True, text=True)
            self.assertAlmostEqual(float(out.stdout), 5.0, delta=0.2)

    def test_render_with_all_effects_and_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, "fast.mp4")
            fit = os.path.join(folder, "activity.fit")
            # 8 s from second 20 of the activity (speed 20..28 m/s, top at the end), with sound.
            created = datetime.fromtimestamp(T0 + 20, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=8:size=320x240:rate=10",
                            "-f", "lavfi", "-i", "sine=duration=8", "-metadata", "creation_time=" + created,
                            "-pix_fmt", "yuv420p", "-shortest", video], check=True)
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000))
            overlay.main([video, fit, "--render", "--encoder", "libx264", "--effects", "all"])
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type:format=duration",
                                  "-of", "default=nw=1", os.path.join(folder, "fast.overlay.mp4")],
                                 check=True, capture_output=True, text=True).stdout
            # 8 s + the replay: peak at the end -> 6..8 s replayed 2.5x slower = +5 s
            self.assertIn("codec_type=video", out)
            self.assertIn("codec_type=audio", out)
            duration = float(out.split("duration=")[1].split()[0])
            self.assertAlmostEqual(duration, 8 + 2 * effects.REPLAY_SLOWDOWN, delta=0.5)

    def test_render_chapters_as_one_video(self):
        with tempfile.TemporaryDirectory() as folder:
            first, second = os.path.join(folder, "GX010007.MP4"), os.path.join(folder, "GX020007.MP4")
            fit = os.path.join(folder, "activity.fit")
            created = datetime.fromtimestamp(T0 + 5, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            for path, seconds in ((first, 3), (second, 2)):
                subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi",
                                "-i", "testsrc=duration=%d:size=320x240:rate=10" % seconds,
                                "-metadata", "creation_time=" + created, "-pix_fmt", "yuv420p", path], check=True)
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000))
            overlay.main([second, fit, "--render", "--encoder", "libx264"])   # any chapter finds the others
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                  os.path.join(folder, "GX020007.overlay.mp4")], check=True, capture_output=True, text=True)
            self.assertAlmostEqual(float(out.stdout), 5.0, delta=0.3)

    def test_render_replays_hilights(self):
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, "GX010008.MP4")
            fit = os.path.join(folder, "activity.fit")
            created = datetime.fromtimestamp(T0 + 5, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=12:size=320x240:rate=10",
                            "-metadata", "creation_time=" + created, "-pix_fmt", "yuv420p", video], check=True)
            add_hilights(video, [4000, 9000])
            self.assertEqual(gopromp4.hilights(video), [4.0, 9.0])
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000))
            overlay.main([video, fit, "--render", "--encoder", "libx264", "--effects", "slowmo"])
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                  os.path.join(folder, "GX010008.overlay.mp4")], check=True, capture_output=True, text=True)
            # 12 s + two replays of 3 s (2 before, 1 after the mark) at 2.5x = 12 + 2 * 7.5
            self.assertAlmostEqual(float(out.stdout), 12 + 2 * 3 * effects.REPLAY_SLOWDOWN, delta=0.6)

    def test_render_skips_auto_lap_hilights(self):
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, "GX010009.MP4")
            fit = os.path.join(folder, "activity.fit")
            make_clip(video, 12, T0 + 5)
            # Marks at 4 s (T0 + 9) and 9 s (T0 + 14): an Auto Lap (by distance) ended at T0 + 8,
            # a LAP button lap at T0 + 13.5.
            add_hilights(video, [4000, 9000])
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000, laps=[(T0 + 8, T0, DISTANCE), (T0 + 13.5, T0 + 8, 0),
                                                                    (T0 + 29, T0 + 14, SESSION_END)]))
            with contextlib.redirect_stdout(io.StringIO()) as log:
                overlay.main([video, fit, "--render", "--encoder", "libx264", "--effects", "slowmo"])
            self.assertIn("HiLight at 0:04 = Auto Lap, not replayed", log.getvalue())
            output = os.path.join(folder, "GX010009.overlay.mp4")
            self.assertAlmostEqual(float(probe(output, "format=duration")[0]), 12 + 3 * effects.REPLAY_SLOWDOWN, delta=0.6)
            with contextlib.redirect_stdout(io.StringIO()):
                overlay.main([video, fit, "--render", "--encoder", "libx264", "--effects", "slowmo", "--replay-all-hilights"])
            self.assertAlmostEqual(float(probe(output, "format=duration")[0]), 12 + 2 * 3 * effects.REPLAY_SLOWDOWN, delta=0.6)

    def test_odd_file_name(self):
        # Cyrillic ("И" is 0x98 in UTF-8, undefined in cp1251: decoding ffprobe's output as cp1251
        # crashed), a character outside cp1251 in what is printed, and , ' [ ] ; = that broke the
        # filter graph when the .ass name went into it. Run as a separate process so that stdout
        # is a pipe in the console code page.
        name = "Иван ♥, [1]; a=b'c"
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, name + ".mp4")
            fit = os.path.join(folder, "activity.fit")
            make_clip(video, 4, T0 + 20)
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000))
            env = {k: v for k, v in os.environ.items() if k not in ("PYTHONIOENCODING", "PYTHONUTF8")}
            r = subprocess.run([sys.executable, os.path.join(TOOLS, "overlay.py"), video, fit, "--render",
                                "--encoder", "libx264", "--effects", "slowmo,vignette"], capture_output=True, env=env)
            self.assertEqual(r.returncode, 0, r.stdout.decode("utf-8", "replace")[-500:] + r.stderr.decode("utf-8", "replace")[-500:])
            self.assertEqual(float(probe(os.path.join(folder, name + ".overlay.mp4"), "format=duration")[0]) > 4, True)
            # ffmpeg's helper files (graph, replay label, mask) are gone; the subtitles stay for players.
            self.assertEqual(sorted(os.listdir(folder)), sorted(["activity.fit", name + ".ass", name + ".mp4", name + ".overlay.mp4"]))

    def test_start_without_creation_time(self):
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, "untagged.mp4")
            fit = os.path.join(folder, "activity.fit")
            make_clip(video, 3, None, extra=["-map_metadata", "-1"])
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000))
            self.assertIsNone(overlay.probe_video(video)[0])
            with self.assertRaises(SystemExit) as error, contextlib.redirect_stdout(io.StringIO()):
                overlay.main([video, fit])
            self.assertIn("pass --start", str(error.exception))
            start = datetime.fromtimestamp(T0 + 10, timezone.utc).isoformat()
            with contextlib.redirect_stdout(io.StringIO()) as log:
                overlay.main([video, fit, "--start", start])
            self.assertIn("(--start)", log.getvalue())
            self.assertIn("3 of 3 seconds have data", log.getvalue())

    def test_h264_from_10_bit_video_is_8_bit(self):
        # HERO12 can record 10-bit HEVC; libx264 kept the 10 bits (High 10), which phones do not play.
        with tempfile.TemporaryDirectory() as folder:
            video = os.path.join(folder, "ten.mp4")
            fit = os.path.join(folder, "activity.fit")
            make_clip(video, 2, T0 + 5, pix_fmt="yuv420p10le", extra=["-c:v", "libx264"])
            self.assertEqual(probe(video, "stream=profile"), ["High", "10"])
            with open(fit, "wb") as f:
                f.write(activity_fixture(recording_from=1000))
            with contextlib.redirect_stdout(io.StringIO()):
                overlay.main([video, fit, "--render", "--encoder", "libx264"])
            self.assertEqual(probe(os.path.join(folder, "ten.overlay.mp4"), "stream=profile,pix_fmt"), ["High", "yuv420p"])


class LauncherIconTest(unittest.TestCase):

    def test_default_path_and_same_bytes(self):
        repo = os.path.dirname(TOOLS)
        icon = os.path.join(repo, "resources", "drawables", "launcher_icon.png")
        self.assertEqual(make_launcher_icon.DEFAULT_PATH, icon)
        if not os.path.exists(icon):
            self.skipTest("no icon in the repo")
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "icon.png")
            make_launcher_icon.main(path)
            with open(path, "rb") as a, open(icon, "rb") as b:
                self.assertEqual(a.read(), b.read())


if __name__ == "__main__":
    unittest.main()
