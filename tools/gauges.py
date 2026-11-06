"""Sports-style gauges as ASS vector drawings: a speedometer dial and a heart rate panel.

Every shape is a polygon computed here in screen pixels and drawn with {\\an7\\pos(0,0)\\p1}:
with that, libass takes drawing coordinates as frame coordinates (checked on a test frame).
Moving parts are redrawn every STEP seconds; consecutive identical events are merged.
"""

import math

STEP = 0.1                  # needle / arc refresh, seconds
SWEEP_START = 135.0         # 0 km/h: bottom left (degrees clockwise from +x, screen y down)
SWEEP = 270.0               # to bottom right through the top
MIN_SCALE_KMH = 30


def ass_color(r, g, b):
    return "&H%02X%02X%02X&" % (b, g, r)


WHITE = ass_color(255, 255, 255)
DARK = ass_color(20, 20, 20)
NEEDLE = ass_color(255, 122, 0)
_SPEED_STOPS = [(0.0, (46, 204, 113)), (0.55, (241, 196, 15)), (1.0, (231, 76, 60))]   # green, yellow, red


def speed_color(fraction):
    fraction = min(max(fraction, 0.0), 1.0)
    for (f0, c0), (f1, c1) in zip(_SPEED_STOPS, _SPEED_STOPS[1:]):
        if fraction <= f1:
            k = (fraction - f0) / (f1 - f0)
            return ass_color(*(round(a + (b - a) * k) for a, b in zip(c0, c1)))
    return ass_color(*_SPEED_STOPS[-1][1])


def _point(cx, cy, r, degrees):
    a = math.radians(degrees)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def polygon(points):
    first, rest = points[0], points[1:]
    return "m %.1f %.1f l %s" % (first[0], first[1], " ".join("%.1f %.1f" % p for p in rest))


def circle(cx, cy, r, steps=48):
    return polygon([_point(cx, cy, r, 360.0 * i / steps) for i in range(steps)])


def ring(cx, cy, r_inner, r_outer, a0, a1):
    """Band between two radii from angle a0 to a1 (clockwise), as one polygon."""
    steps = max(int(abs(a1 - a0) / 3), 1)
    outer = [_point(cx, cy, r_outer, a0 + (a1 - a0) * i / steps) for i in range(steps + 1)]
    inner = [_point(cx, cy, r_inner, a1 - (a1 - a0) * i / steps) for i in range(steps + 1)]
    return polygon(outer + inner)


def bar(x, y, w, h):
    return polygon([(x, y), (x + w, y), (x + w, y + h), (x, y + h)])


def shape(drawing, color, alpha=0):
    return "{\\an7\\pos(0,0)\\p1\\bord0\\shad0\\1c%s\\1a&H%02X&}%s{\\p0}" % (color, alpha, drawing)


def label(x, y, size, text, color=WHITE, align=5, bold=True):
    return "{\\an%d\\pos(%.0f,%.0f)\\fs%d\\b%d\\1c%s}%s" % (align, x, y, size, 1 if bold else 0, color, text)


def scale_max(speeds_kmh):
    top = max(speeds_kmh, default=0)
    return max(MIN_SCALE_KMH, int(math.ceil(top / 10.0)) * 10)


class _Timeline:
    """Collects (layer, start, end, text) and merges a layer's consecutive identical texts."""

    def __init__(self):
        self.events = []
        self._open = {}

    def put(self, key, layer, t0, t1, text):
        current = self._open.get(key)
        if current and current[3] == text and abs(current[2] - t0) < 1e-6:
            current[2] = t1
            return
        if current:
            self.events.append(tuple(current))
        self._open[key] = [layer, t0, t1, text] if text is not None else None

    def close(self):
        for current in self._open.values():
            if current:
                self.events.append(tuple(current))
        self._open = {}
        return sorted(self.events, key=lambda e: (e[1], e[0]))


MAP_POINTS = 300    # track points drawn; more only adds bytes to the .ass


def polyline(points, width, color, alpha=0):
    """An open line through the points: a zero-area path (there and back) drawn by its outline only."""
    path = polygon(points + points[-2:0:-1])
    return "{\\an7\\pos(0,0)\\p1\\bord%.1f\\shad0\\1a&HFF&\\3c%s\\3a&H%02X&}%s{\\p0}" % (width, color, alpha, path)


def track_map(records, start, first, last, width, height):
    """Mini-map in the top right corner: (static shapes, project(lat, lon) -> (x, y)), or None
    without positions. The whole activity is drawn dim, the part inside the video bright."""
    points = [(r.time, r.lat, r.lon) for r in records if r.lat is not None and r.lon is not None]
    if len(points) < 2:
        return None
    k = height / 1080.0
    size, margin, pad = 260 * k, 40 * k, 18 * k
    # Equirectangular around the middle latitude: fine for a few kilometres.
    shrink = math.cos(math.radians(sum(p[1] for p in points) / len(points)))
    xs = [p[2] * shrink for p in points]
    ys = [-p[1] for p in points]
    span = max(max(xs) - min(xs), max(ys) - min(ys), 1e-9)
    scale = (size - 2 * pad) / span
    left = width - margin - size + pad + (size - 2 * pad - (max(xs) - min(xs)) * scale) / 2
    top = margin + pad + (size - 2 * pad - (max(ys) - min(ys)) * scale) / 2
    min_x, min_y = min(xs), min(ys)

    def project(lat, lon):
        return left + (lon * shrink - min_x) * scale, top + (-lat - min_y) * scale

    def thin(ps):
        step = max(1, len(ps) // MAP_POINTS)
        return [project(p[1], p[2]) for p in ps[::step]] + [project(ps[-1][1], ps[-1][2])]

    shapes = [shape(bar(width - margin - size, margin, size, size), DARK, 0x60),
              polyline(thin(points), 2 * k, WHITE, 0xA0)]
    inside = [p for p in points if start + first <= p[0] <= start + last + 1]
    if len(inside) >= 2:
        shapes.append(polyline(thin(inside), 3.5 * k, WHITE))
    return shapes, project


def build(sampler, start, duration, width, height, offset, first, last, records=()):
    """ASS events (layer, start s, end s, text) for video seconds first..last (inclusive).
    records: the activity's records, for the mini-map (skipped without positions)."""
    from datetime import datetime, timezone

    k = height / 1080.0
    margin = 40 * k
    r = 190 * k
    cx, cy = margin + r, height - margin - r
    t_end = min(last + 1, duration)

    times = []
    t = float(first)
    while t < t_end - 1e-9:
        times.append(t)
        t = round(t + STEP, 6)
    speeds = {t: sampler.value("speed", start + t) for t in times}
    hrs = [sampler.value("heart_rate", start + t) for t in times]
    vmax = scale_max([v * 3.6 for v in speeds.values() if v is not None])
    hr_known = [h for h in hrs if h is not None]
    hr_lo, hr_hi = (min(hr_known), max(hr_known)) if hr_known else (0, 1)

    def angle(kmh):
        return SWEEP_START + SWEEP * min(max(kmh / vmax, 0.0), 1.0)

    line = _Timeline()
    # Static dial: background, dim track, ticks, numbers, unit.
    static = [shape(circle(cx, cy, r), DARK, 0x60),
              shape(ring(cx, cy, 0.80 * r, 0.92 * r, SWEEP_START, SWEEP_START + SWEEP), WHITE, 0xC0)]
    for kmh in range(0, vmax + 1, 5):
        major = kmh % 10 == 0
        a = angle(kmh)
        w = (2.5 if major else 1.2) * k
        p0, p1 = _point(cx, cy, (0.64 if major else 0.70) * r, a), _point(cx, cy, 0.76 * r, a)
        nx, ny = -math.sin(math.radians(a)) * w, math.cos(math.radians(a)) * w
        static.append(shape(polygon([(p0[0] + nx, p0[1] + ny), (p1[0] + nx, p1[1] + ny),
                                     (p1[0] - nx, p1[1] - ny), (p0[0] - nx, p0[1] - ny)]), WHITE))
        if major:
            lx, ly = _point(cx, cy, 0.50 * r, a)
            static.append(label(lx, ly, int(24 * k), str(kmh)))
    static.append(label(cx, cy + 0.62 * r, int(26 * k), "km/h", bold=False))
    mini_map = track_map(records, start, first, last, width, height)
    if mini_map:
        static += mini_map[0]
    for i, text in enumerate(static):
        line.put(("static", i), 0, first, t_end, text)

    # Heart rate / distance / clock panel to the right of the dial.
    px = cx + r + 30 * k
    bar_w, bar_h = 300 * k, 14 * k
    peak = 0.0
    for i, t in enumerate(times):
        t1 = min(round(t + STEP, 6), t_end)
        v = speeds[t]
        if v is not None:
            kmh = v * 3.6
            fraction = kmh / vmax
            a = angle(kmh)
            peak = max(peak, kmh)
            line.put("fill", 1, t, t1, shape(ring(cx, cy, 0.80 * r, 0.92 * r, SWEEP_START, a), speed_color(fraction))
                     if kmh > 0.5 else None)
            tip = _point(cx, cy, 0.90 * r, a)
            base_l = _point(cx, cy, 12 * k, a - 90)
            base_r = _point(cx, cy, 12 * k, a + 90)
            tail = _point(cx, cy, 0.12 * r, a + 180)
            line.put("needle", 2, t, t1, shape(polygon([tip, base_l, tail, base_r]), NEEDLE))
            line.put("hub", 3, t, t1, shape(circle(cx, cy, 16 * k, 24), DARK))
            line.put("speed", 3, t, t1, label(cx, cy + 0.36 * r, int(64 * k), "%d" % round(kmh)))
            pa = angle(peak)
            m0, m1, m2 = _point(cx, cy, 0.95 * r, pa), _point(cx, cy, 1.03 * r, pa - 3), _point(cx, cy, 1.03 * r, pa + 3)
            line.put("peak", 2, t, t1, shape(polygon([m0, m1, m2]), WHITE))
        else:
            for key in ("fill", "needle", "hub", "speed", "peak"):
                line.put(key, 0, t, t1, None)

        hr = hrs[i]
        if hr is not None:
            fraction = (hr - hr_lo) / (hr_hi - hr_lo) if hr_hi > hr_lo else 0.5
            line.put("hr", 1, t, t1, label(px, cy - 0.10 * r, int(48 * k), "♥ %d" % round(hr), speed_color(fraction),
                                           align=1))
            line.put("hr-track", 1, t, t1, shape(bar(px, cy + 0.02 * r, bar_w, bar_h), WHITE, 0xC0))
            line.put("hr-bar", 2, t, t1, shape(bar(px, cy + 0.02 * r, max(bar_w * fraction, 2 * k), bar_h),
                                               speed_color(fraction)))
        else:
            for key in ("hr", "hr-track", "hr-bar"):
                line.put(key, 0, t, t1, None)

        distance = sampler.value("distance", start + t)
        line.put("distance", 1, t, t1, label(px, cy + 0.42 * r, int(36 * k), "%.2f km" % (distance / 1000), align=1)
                 if distance is not None else None)
        clock = datetime.fromtimestamp(int(start + t + offset), timezone.utc).strftime("%H:%M:%S")
        line.put("clock", 1, t, t1, label(px, cy + 0.72 * r, int(30 * k), clock, align=1, bold=False))

        if mini_map:
            lat, lon = sampler.value("lat", start + t), sampler.value("lon", start + t)
            dot = None
            if lat is not None and lon is not None:
                # Rounded to whole pixels, so a standing rider is one long event, not ten a second.
                x, y = mini_map[1](lat, lon)
                dot = "{\\an7\\pos(0,0)\\p1\\bord%.1f\\shad0\\1c%s\\3c%s}%s{\\p0}" % (
                    2 * k, NEEDLE, WHITE, circle(round(x), round(y), 8 * k, 16))
            line.put("dot", 3, t, t1, dot)
    return line.close()
