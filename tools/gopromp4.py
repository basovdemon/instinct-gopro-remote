"""GoPro-specific bits of an MP4: HiLight marks and chapter files. No dependencies.

HiLights (HERO cameras, incl. HERO12): box moov/udta/HMMT = uint32 count, then up to 80 uint32
times in milliseconds from the start of the file, big endian, zero-padded. Checked on a HERO12
file with no HiLights (count 0, 320 zero bytes of room); a file with marks is still to check.

Second place, read only when HMMT has no marks: the GPMF box moov/udta/GPMF. Its KLV layout is
GoPro's (gpmf-parser README): 4-byte key, type char, structure size (1 byte), repeat (2 bytes,
big endian), data padded to 4 bytes; type 0 = nested KLVs; type '?' = structures laid out by the
TYPE string before them. The wakeboard HERO12 file (no marks) has a device there with DVID 'HLMT',
DVNM 'Highlights' and nothing else. Not in GoPro's docs, from other tools' notes only
[VERIFY on a HERO12 file with marks]: with marks that device holds an 'HLMT' array of structures,
time in milliseconds first, then in/out times, position, type ('MANL' = manual), confidence, score
(seen on a HERO7). Marks of every type are taken.

Chapters: GoPro splits long videos into GX01nnnn.MP4, GX02nnnn.MP4, ... (GH for H.264, GX for HEVC,
GS for 360): same nnnn, chapter number in the middle.
"""

import os
import re
import struct


def _boxes(f, start, end):
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        size, kind = struct.unpack(">I4s", f.read(8))
        header = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            return
        yield kind, pos + header, pos + size
        pos += size


def _find(f, start, end, path):
    """(body start, end) of the box at path (list of 4-byte kinds), or None."""
    for kind, body, box_end in _boxes(f, start, end):
        if kind == path[0]:
            return (body, box_end) if len(path) == 1 else _find(f, body, box_end, path[1:])
    return None


def _read_box(f, path):
    """Body of the box at path, or None."""
    f.seek(0, 2)
    found = _find(f, 0, f.tell(), path)
    if not found:
        return None
    f.seek(found[0])
    return f.read(found[1] - found[0])


def hilights(path):
    """HiLight times in seconds from the start of the file, sorted; [] if none.
    From moov/udta/HMMT; if that has none, from the GPMF box (see the module notes)."""
    with open(path, "rb") as f:
        data = _read_box(f, [b"moov", b"udta", b"HMMT"])
        times = _hmmt(data) if data else []
        if not times:
            data = _read_box(f, [b"moov", b"udta", b"GPMF"])
            times = _gpmf_hilights(data) if data else []
    return sorted(t for t in times if t > 0)


def _hmmt(data):
    if len(data) < 4:
        return []
    count = struct.unpack_from(">I", data)[0]
    count = min(count, (len(data) - 4) // 4)
    return [struct.unpack_from(">I", data, 4 + 4 * i)[0] / 1000.0 for i in range(count)]


# GPMF type char -> (size, struct code or None if not a number); gpmf-parser README, "Type".
_GPMF_TYPES = {
    "b": (1, "b"), "B": (1, "B"), "c": (1, None), "d": (8, "d"), "f": (4, "f"), "F": (4, None),
    "G": (16, None), "j": (8, "q"), "J": (8, "Q"), "l": (4, "i"), "L": (4, "I"), "q": (4, None),
    "Q": (8, None), "s": (2, "h"), "S": (2, "H"), "U": (16, None),
}


def _klvs(data):
    """(key, type, structure size, repeat, payload) of the GPMF KLVs at one level."""
    pos = 0
    while pos + 8 <= len(data):
        key, kind, size, repeat = struct.unpack_from(">4scBH", data, pos)
        if key == b"\0\0\0\0":
            return   # zero padding after the last KLV (the HERO12 box has ~25 KB of it)
        payload = data[pos + 8:pos + 8 + size * repeat]
        if len(payload) < size * repeat:
            return
        yield key, kind, size, repeat, payload
        pos += 8 + (size * repeat + 3) // 4 * 4


def _type_fields(text):
    """'LLLlllF[2]' -> ['L', 'L', 'L', 'l', 'l', 'l', 'F', 'F']: a TYPE string, arrays expanded;
    [] if it does not read."""
    fields = []
    i = 0
    while i < len(text):
        if text[i] == "[":
            close = text.find("]", i)
            if close < 0 or not text[i + 1:close].isdigit() or not fields:
                return []
            fields += fields[-1:] * (int(text[i + 1:close]) - 1)
            i = close + 1
        else:
            fields.append(text[i])
            i += 1
    return fields


def _gpmf_hilights(data):
    """Seconds from the first field of each 'HLMT' structure, searched through all nested KLVs;
    nothing from a layout we do not understand (better no replay than one of the wrong moment)."""
    times = []
    type_text = ""
    for key, kind, size, repeat, payload in _klvs(data):
        kind = kind.decode("latin-1")
        if kind == "\0":
            times += _gpmf_hilights(payload)
        elif key == b"TYPE" and kind == "c":
            type_text = payload.split(b"\0", 1)[0].decode("latin-1")
        elif key == b"HLMT":
            if kind == "?":
                fields = _type_fields(type_text)
            else:   # a plain type: size / type size values per structure
                fields = [kind] * (size // _GPMF_TYPES[kind][0]) if kind in _GPMF_TYPES else []
            if (not fields or any(c not in _GPMF_TYPES for c in fields)
                    or sum(_GPMF_TYPES[c][0] for c in fields) != size or _GPMF_TYPES[fields[0]][1] is None):
                continue
            code = ">" + _GPMF_TYPES[fields[0]][1]
            times += [struct.unpack_from(code, payload, n * size)[0] / 1000.0 for n in range(repeat)]
    return times


_CHAPTER = re.compile(r"^(G[A-Z])(\d\d)(\d{4})(\.mp4)$", re.IGNORECASE)


def chapters(path):
    """All chapter files of the video `path` belongs to, in order (just [path] if it is not one)."""
    folder, name = os.path.split(os.path.abspath(path))
    m = _CHAPTER.match(name)
    if not m:
        return [path]
    prefix, number, ext = m.group(1).upper(), m.group(3), m.group(4)
    found = []
    for other in os.listdir(folder):
        o = _CHAPTER.match(other)
        if o and o.group(1).upper() == prefix and o.group(3) == number:
            found.append((int(o.group(2)), os.path.join(folder, other)))
    return [p for _, p in sorted(found)] or [path]
