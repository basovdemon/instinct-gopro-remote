"""Minimal FIT activity reader: the fields the video overlay needs, no dependencies.

Layout checked against Garmin's FIT SDK (fit-javascript-sdk: decoder.js, fit.js, profile.js):
- file header: size (12|14), protocol, profile (u16), data size (u32), ".FIT", [crc u16]
- record header: bit7 = compressed timestamp, bit6 = definition, bit5 = developer fields,
  bits0-3 = local message type
- definition: reserved, architecture (0 = little endian), global message (u16), field count,
  3 bytes per field (number, size, base type), then developer fields if bit5
- timestamps are seconds since 1989-12-31T00:00:00Z
"""

import struct
from dataclasses import dataclass, field
from typing import Optional

FIT_EPOCH = 631065600  # 1989-12-31T00:00:00Z as a Unix timestamp

MESG_LAP = 19
MESG_RECORD = 20
MESG_ACTIVITY = 34
MESG_FIELD_DESCRIPTION = 206
MESG_DEVELOPER_DATA_ID = 207

FIELD_TIMESTAMP = 253
LAP_START_TIME = 2
LAP_TOTAL_ELAPSED_TIME = 7   # uint32, ms (scale 1000), pauses included
LAP_TRIGGER = 24          # enum lap_trigger (profile.js): 0 manual, 1 time, 2 distance,
LAP_TRIGGER_MANUAL = 0    # 3..6 position_*, 7 session_end, 8 fitness_equipment

# base type number -> (struct code, invalid value); size comes from the field definition
_BASE_TYPES = {
    0x00: ("B", 0xFF),                 # enum
    0x01: ("b", 0x7F),                 # sint8
    0x02: ("B", 0xFF),                 # uint8
    0x03: ("h", 0x7FFF),               # sint16
    0x04: ("H", 0xFFFF),               # uint16
    0x05: ("i", 0x7FFFFFFF),           # sint32
    0x06: ("I", 0xFFFFFFFF),           # uint32
    0x07: (None, None),                # string
    0x08: ("f", None),                 # float32
    0x09: ("d", None),                 # float64
    0x0A: ("B", 0x00),                 # uint8z
    0x0B: ("H", 0x0000),               # uint16z
    0x0C: ("I", 0x00000000),           # uint32z
    0x0D: ("B", 0xFF),                 # byte
    0x0E: ("q", 0x7FFFFFFFFFFFFFFF),   # sint64
    0x0F: ("Q", 0xFFFFFFFFFFFFFFFF),   # uint64
    0x10: ("Q", 0x0000000000000000),   # uint64z
}
_BASE_TYPE_MASK = 0x1F

# record field number -> (name, scale, offset)
_RECORD_FIELDS = {
    0: ("lat", None, 0),          # semicircles, converted below
    1: ("lon", None, 0),
    2: ("altitude", 5, 500),
    3: ("heart_rate", 1, 0),
    5: ("distance", 100, 0),
    6: ("speed", 1000, 0),
    73: ("enhanced_speed", 1000, 0),
    78: ("enhanced_altitude", 5, 500),
}
_SEMICIRCLES_TO_DEGREES = 180.0 / 2 ** 31


@dataclass
class Record:
    """One activity sample. Values are SI units (m, m/s), None when the device did not record them."""
    time: int                      # Unix seconds, UTC
    speed: Optional[float] = None
    altitude: Optional[float] = None
    distance: Optional[float] = None
    heart_rate: Optional[int] = None
    lat: Optional[float] = None
    lon: Optional[float] = None
    developer: dict = field(default_factory=dict)   # developer field name -> value


@dataclass
class Lap:
    """One lap message: when it ended and what ended it (Auto Lap or the LAP button)."""
    time: float                    # Unix seconds, UTC: end of the lap
    start: Optional[int] = None    # Unix seconds, UTC
    trigger: Optional[int] = None  # LAP_TRIGGER_MANUAL for the LAP button; None if not recorded

    @property
    def manual(self):
        return self.trigger == LAP_TRIGGER_MANUAL


@dataclass
class Activity:
    records: list
    local_offset: Optional[int] = None   # seconds east of UTC, from the activity message
    laps: list = field(default_factory=list)   # Lap, by end time

    def values(self, name):
        """(time, value) pairs of a developer field, e.g. our data field's "gopro_recording"."""
        return [(r.time, r.developer[name]) for r in self.records if name in r.developer]


@dataclass
class _Definition:
    global_number: int
    little_endian: bool
    fields: list            # (number, size, base type)
    developer_fields: list  # (number, size, developer data index)


def read_activity(path):
    with open(path, "rb") as f:
        return parse_activity(f.read())


def parse_activity(data):
    records = []
    laps = []
    local_offset = None
    pos = 0
    # A file may hold several FIT files back to back (chained); read them all.
    while pos + 12 <= len(data):
        header_size = data[pos]
        if header_size not in (12, 14) or data[pos + 8:pos + 12] != b".FIT":
            raise ValueError("not a FIT file (bad header at byte %d)" % pos)
        data_size = struct.unpack_from("<I", data, pos + 4)[0]
        start = pos + header_size
        end = start + data_size
        if end > len(data):
            raise ValueError("truncated FIT file")
        offset = _parse_messages(data, start, end, records, laps)
        if offset is not None:
            local_offset = offset
        pos = end + 2   # CRC, not checked
    records.sort(key=lambda r: r.time)
    laps.sort(key=lambda lap: lap.time)
    return Activity(records, local_offset, laps)


def _parse_messages(data, pos, end, records, laps):
    definitions = {}
    developer_names = {}   # (developer data index, field number) -> (name, base type)
    local_offset = None
    while pos < end:
        header = data[pos]
        pos += 1
        if header & 0x80:
            # Garmin devices do not write these; Garmin's own JS SDK does not decode them either.
            raise ValueError("compressed timestamp records are not supported")
        local_type = header & 0x0F
        if header & 0x40:
            pos, definitions[local_type] = _parse_definition(data, pos, bool(header & 0x20))
            continue
        definition = definitions.get(local_type)
        if definition is None:
            raise ValueError("data message for undefined local type %d" % local_type)
        values = {}
        for number, size, base_type in definition.fields:
            values[number] = _read_value(data, pos, size, base_type, definition.little_endian)
            pos += size
        developer = {}
        for number, size, index in definition.developer_fields:
            name, base_type = developer_names.get((index, number), ("dev_%d_%d" % (index, number), 0x0D))
            developer[name] = _read_value(data, pos, size, base_type, definition.little_endian)
            pos += size

        if definition.global_number == MESG_RECORD:
            record = _make_record(values, developer)
            if record is not None:
                records.append(record)
        elif definition.global_number == MESG_FIELD_DESCRIPTION:
            index, number, base_type, name = values.get(0), values.get(1), values.get(2), values.get(3)
            if None not in (index, number, base_type, name):
                developer_names[(index, number)] = (name, base_type & _BASE_TYPE_MASK)
        elif definition.global_number == MESG_LAP:
            lap = _make_lap(values)
            if lap is not None:
                laps.append(lap)
        elif definition.global_number == MESG_ACTIVITY:
            timestamp, local_timestamp = values.get(FIELD_TIMESTAMP), values.get(5)
            if timestamp is not None and local_timestamp is not None:
                local_offset = local_timestamp - timestamp
    return local_offset


def _parse_definition(data, pos, has_developer_fields):
    little_endian = data[pos + 1] == 0
    global_number = struct.unpack_from("<H" if little_endian else ">H", data, pos + 2)[0]
    count = data[pos + 4]
    pos += 5
    fields = []
    for _ in range(count):
        fields.append((data[pos], data[pos + 1], data[pos + 2] & _BASE_TYPE_MASK))
        pos += 3
    developer_fields = []
    if has_developer_fields:
        count = data[pos]
        pos += 1
        for _ in range(count):
            developer_fields.append((data[pos], data[pos + 1], data[pos + 2]))
            pos += 3
    return pos, _Definition(global_number, little_endian, fields, developer_fields)


def _read_value(data, pos, size, base_type, little_endian):
    """One value, or None if invalid. Arrays (size larger than the type) return their first element."""
    raw = data[pos:pos + size]
    code, invalid = _BASE_TYPES.get(base_type, ("B", None))
    if code is None:
        text = raw.split(b"\0", 1)[0]
        return text.decode("utf-8", "replace") if text else None
    type_size = struct.calcsize(code)
    if size < type_size:
        return None
    value = struct.unpack_from(("<" if little_endian else ">") + code, raw)[0]
    if invalid is not None and value == invalid:
        return None
    if code in "fd" and value != value:   # NaN
        return None
    return value


def _make_lap(values):
    """The lap's end is start_time + total_elapsed_time when both are there: the profile calls the
    timestamp "lap end time", but the Instinct 3 files from Garmin Connect (wake, 2026-09-30) have
    timestamp = start_time in their one lap (and in the session)."""
    timestamp, start, elapsed = values.get(FIELD_TIMESTAMP), values.get(LAP_START_TIME), values.get(LAP_TOTAL_ELAPSED_TIME)
    if start is not None and elapsed is not None:
        end = start + FIT_EPOCH + elapsed / 1000.0
    elif timestamp is not None:
        end = timestamp + FIT_EPOCH
    else:
        return None
    return Lap(end, start + FIT_EPOCH if start is not None else None, values.get(LAP_TRIGGER))


def _make_record(values, developer):
    timestamp = values.get(FIELD_TIMESTAMP)
    if timestamp is None:
        return None
    record = Record(time=timestamp + FIT_EPOCH, developer=developer)
    scaled = {}
    for number, (name, scale, offset) in _RECORD_FIELDS.items():
        raw = values.get(number)
        if raw is None:
            continue
        scaled[name] = raw * _SEMICIRCLES_TO_DEGREES if scale is None else raw / scale - offset
    # Enhanced fields have more range; prefer them when present.
    record.speed = scaled.get("enhanced_speed", scaled.get("speed"))
    record.altitude = scaled.get("enhanced_altitude", scaled.get("altitude"))
    record.distance = scaled.get("distance")
    heart_rate = scaled.get("heart_rate")
    record.heart_rate = int(heart_rate) if heart_rate is not None else None
    record.lat = scaled.get("lat")
    record.lon = scaled.get("lon")
    return record
