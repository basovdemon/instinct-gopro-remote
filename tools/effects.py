"""Speed-driven video effects for overlay.py, built as one ffmpeg filter graph.

- zoom, saturation: strength follows speed. ffmpeg cannot read our data, so speed becomes a
  piecewise-linear expression of time (only the parts where it is non-zero), evaluated per frame.
- vignette: ffmpeg's vignette filter re-evaluated per frame is ~12x slower than decoding 4K, so a
  darkening mask (one PNG, made once) is overlaid instead, in VIGNETTE_LEVELS strengths, each
  switched on only where the speed falls into its band.
- Filters are enabled only while there is speed (timeline 'enable'), so idle parts cost nothing.
- zoom and saturation come as one filter per time window (WINDOW seconds), each enabled only in
  its window and holding only that window's expression. perspective re-parses its expressions on
  every frame, so one expression for the whole ride made the cost grow with the square of its
  length (2 min of riding: 95 s instead of 1 s on a small test frame).
- slowmo: moments are replayed slowed down right after they happen: the camera's HiLight marks
  (set from the watch with UP / LAP; overlay.py leaves out those of Auto Laps), or the ones you
  choose, or else the top speed. Each replay has an input of its own, the rest of the video one
  per chapter file, cut at the replays by 'segment' (see inputs()).

The graph is long (terms per half second of riding), so overlay.py passes it to ffmpeg from a
file (-/filter_complex, ffmpeg 7+).
"""

import math
import subprocess

ALL = ("vignette", "zoom", "saturation", "slowmo")

SAMPLE = 0.5            # seconds between intensity samples
SMOOTH = 1.0            # moving-average window, seconds: keeps the effects from flickering
LOW_KMH = 10.0          # below this, no effect
VIGNETTE_LEVELS = 6     # mask strengths; steps of 1/6 are hard to see on moving water
ZOOM = 0.05             # fraction cropped from each side at full speed
SATURATION = 0.45       # added saturation at full speed
CONTRAST = 0.10         # added contrast at full speed
REPLAY_BEFORE = 2.0     # seconds of the replay before the moment
REPLAY_AFTER = 1.0      # and after it
REPLAY_SLOWDOWN = 2.5   # 0.4x speed
# Zoom / saturation windows. perspective parses 8 expressions per frame (~0.12 ms per half-second
# term on this computer, ~7 ms for a 30 s window) and keeps a lookup table per filter (16 bytes a
# pixel: 130 MB in 4K), so longer rides get longer windows rather than more filters.
WINDOW = 30.0
WINDOWS_MAX = 12
# Each window's expression also covers this much on both sides: perspective's time is counted in
# frames, which can run a frame or two apart from the timestamps that 'enable' looks at; and the
# windows of an input reach this far past it (a seeked input can start a frame early).
WINDOW_MARGIN = 1.0


def parse(text):
    names = [n.strip() for n in (text or "").split(",") if n.strip()]
    if names == ["all"]:
        return set(ALL)
    unknown = [n for n in names if n not in ALL]
    if unknown:
        raise SystemExit("unknown effect(s): %s; choose from %s or all" % (", ".join(unknown), ", ".join(ALL)))
    return set(names)


def intensity(sampler, start, t0, t1, top_kmh):
    """[(video second, 0..1)] every SAMPLE seconds: speed between LOW_KMH and top_kmh, smoothed."""
    raw = []
    t = t0
    while t <= t1 + 1e-9:
        window = [sampler.value("speed", start + t + d) for d in (-SMOOTH / 2, -SMOOTH / 4, 0, SMOOTH / 4, SMOOTH / 2)]
        known = [v * 3.6 for v in window if v is not None]
        kmh = sum(known) / len(known) if known else 0.0
        raw.append((round(t, 3), min(max((kmh - LOW_KMH) / max(top_kmh - LOW_KMH, 1.0), 0.0), 1.0)))
        t += SAMPLE
    return raw


def _escape(expr):
    # Commas inside filter options must be escaped for the filter graph parser.
    return expr.replace(",", "\\,")


def _sum(terms):
    """a+b+c+... as a balanced tree of parentheses. ffmpeg's expression parser refuses a flat sum
    of more than ~50-100 terms (nesting limit); a balanced tree of 1000 terms is fine (checked)."""
    if not terms:
        return "0"
    if len(terms) == 1:
        return terms[0]
    middle = len(terms) // 2
    return "(%s+%s)" % (_sum(terms[:middle]), _sum(terms[middle:]))


def expression(series, var, within=None):
    """Piecewise-linear ffmpeg expression of `var` through the series; zero where both ends are zero.
    within=(a, b): only the pieces that overlap a..b (the expression is zero elsewhere)."""
    terms = []
    for (ta, ka), (tb, kb) in zip(series, series[1:]):
        if ka < 0.005 and kb < 0.005:
            continue
        if within and (tb <= within[0] or ta >= within[1]):
            continue
        slope = (kb - ka) / (tb - ta)
        terms.append("gte(%s,%g)*lt(%s,%g)*(%.3f+%.4f*(%s-%g))" % (var, ta, var, tb, ka, slope, var, ta))
    return _escape(_sum(terms))


def bands(series, levels):
    """{level 1..levels: [(t0, t1)]}: where the intensity, rounded to 1/levels, equals that level."""
    out = {}
    for (ta, ka), (tb, kb) in zip(series, series[1:]):
        level = int(round((ka + kb) / 2 * levels))
        if level <= 0:
            continue
        spans = out.setdefault(level, [])
        if spans and abs(spans[-1][1] - ta) < 1e-6:
            spans[-1] = (spans[-1][0], tb)
        else:
            spans.append((ta, tb))
    return out


def active(series):
    """[(t0, t1)] where the intensity is above zero."""
    spans = []
    for (ta, ka), (tb, kb) in zip(series, series[1:]):
        if ka < 0.005 and kb < 0.005:
            continue
        if spans and abs(spans[-1][1] - ta) < 1e-6:
            spans[-1] = (spans[-1][0], tb)
        else:
            spans.append((ta, tb))
    return spans


def during(spans, var="t"):
    """enable= expression: true inside any of the spans."""
    return _escape(_sum(["gte(%s,%g)*lt(%s,%g)" % (var, a, var, b) for a, b in spans]))


def windows(spans, t0, t1):
    """[(from, to, spans inside)]: the spans within t0..t1 cut into consecutive windows of WINDOW
    seconds (longer if more than WINDOWS_MAX would be needed); windows without spans are left out.
    The windows' spans together are exactly the spans within t0..t1, so one window filter at most
    is enabled on any frame."""
    inside = [(max(a, t0), min(b, t1)) for a, b in spans if b > t0 and a < t1]
    if not inside:
        return []
    first, last = inside[0][0], inside[-1][1]
    size = max(WINDOW, math.ceil((last - first) / WINDOWS_MAX))
    out = []
    n = 0
    while first + n * size < last - 1e-9:
        # Both edges from the same formula: a window starts exactly where the previous one ends.
        a, b = first + n * size, min(first + (n + 1) * size, last)
        part = [(max(x, a), min(y, b)) for x, y in inside if y > a and x < b]
        if part:
            out.append((a, b, part))
        n += 1
    return out


def make_vignette_mask(path, width, height):
    """Black PNG whose alpha grows towards the corners (0 in the middle, 255 far out)."""
    # Corners reach ~85 % black at full strength: darker reads as a black frame, not as speed.
    alpha = "255*min(0.85,pow(hypot(X-W/2,(Y-H/2)*W/H)/hypot(W/2,W/2),2.5)*1.3)"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=black:s=%dx%d:d=1" % (width, height),
                    "-vf", "format=rgba,geq=r=0:g=0:b=0:a='%s'" % _escape(alpha), "-frames:v", "1", path], check=True)


def peak(sampler, start, t0, t1):
    """(video second, km/h) of the top speed, or None."""
    best = None
    t = t0
    while t <= t1:
        v = sampler.value("speed", start + t)
        if v is not None and (best is None or v > best[1]):
            best = (t, v)
        t = round(t + 0.1, 6)
    return (best[0], best[1] * 3.6) if best else None


def replay_ass(width, height, text, length):
    """Label shown over the replay (top left: the mini-map has the top right): its own subtitles
    on the replay's timeline."""
    size = max(height // 16, 12)
    return "\n".join([
        "[Script Info]", "ScriptType: v4.00+", "PlayResX: %d" % width, "PlayResY: %d" % height, "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, "
        "Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, "
        "MarginL, MarginR, MarginV, Encoding",
        "Style: Replay,Arial,%d,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,1,1,0,0,100,100,0,0,1,%d,2,7,%d,%d,%d,1"
        % (size, max(size // 14, 2), height // 20, height // 20, height // 20),
        "", "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
        "Dialogue: 0,0:00:00.00,%s,Replay,,0,0,0,,{\\fad(200,200)}%s" % (
            "0:%02d:%05.2f" % (int(length) // 60, length % 60), text),
    ]) + "\n"


def segments(start_at, length, replays=()):
    """[(from, to, replay label .ass or None)] video seconds to play in order: the rendered part,
    with each replay (from, to, label) spliced in right after its moment."""
    end = start_at + length
    parts = []
    done = start_at
    for r0, r1, label in sorted(replays, key=lambda r: r[1]):
        if r1 <= done:
            continue   # overlaps the previous replay's end: skip rather than go back in time
        if r1 - done > 0.05:
            parts.append((done, r1, None))
        parts.append((r0, r1, label))
        done = r1
    if end - done > 0.05 or not parts:
        parts.append((done, end, None))
    return parts


def split_at(parts, boundaries):
    """Cuts parts at the given video seconds (where GoPro chapter files meet), so that each part
    reads from one file. A replay cut in two shows its label twice; chapters are ~10+ min long."""
    out = []
    for t0, t1, label in parts:
        edges = [t0] + [b for b in sorted(boundaries) if t0 < b < t1] + [t1]
        out += [(a, b, label) for a, b in zip(edges, edges[1:]) if b - a > 0.02]
    return out


def inputs(parts, boundaries=()):
    """[(from, to, [part indices])]: the decoder inputs that feed the parts, in the order of their
    first part. A replay reads its own input. The parts between the replays come from one input per
    chapter file (boundaries: where the files meet), cut by ffmpeg's segment filter: decoders are
    the memory hogs (~0.5 GB each for 4K with -hwaccel), one per part was 10 GB with 9 replays."""
    out = []
    main = {}   # chapter number -> index in out
    for i, (t0, t1, label) in enumerate(parts):
        chapter = sum(1 for b in boundaries if b <= t0 + 1e-6)
        if label is None and chapter in main:
            j = main[chapter]
            out[j] = (out[j][0], t1, out[j][2] + [i])   # segments() keeps these back to back
            continue
        if label is None:
            main[chapter] = len(out)
        out.append((t0, t1, [i]))
    return out


def fmt_time(seconds):
    """Seconds for a filter option, to the millisecond ("%g" keeps only 6 digits: 10800.25 -> 10800.2)."""
    return ("%.3f" % seconds).rstrip("0").rstrip(".")


def graph(effects, ass_name, parts, fps, series, has_audio=True, mask_input=None, size=None, feeds=None):
    """filter_complex text with outputs [vout] (and [aout]).

    parts: (from, to, replay label .ass or None) in playing order (segments, split_at).
    feeds: the inputs (from, to, [part indices]) as inputs() makes them; overlay.py opens input j
    seeked to feeds[j]. Seeking restarts timestamps at 0, so frames are shifted back to the
    original video time first: the subtitles, the intensity expressions and the cuts between
    parts use that timeline. Splitting one decoded stream with 'split' made ffmpeg buffer 4K
    frames until it ran out of memory; 'segment' passes each frame on once, to one part.
    mask_input: input index of the vignette mask PNG (needed for "vignette").
    size: (width, height) to scale to, or None to keep the source size.
    """
    feeds = inputs(parts) if feeds is None else feeds
    lines = []
    spans = active(series)
    levels = bands(series, VIGNETTE_LEVELS) if "vignette" in effects and mask_input is not None else {}
    overlays = []   # (input index, level, spans inside the input)
    for j, (t0, t1, _) in enumerate(feeds):
        for level in sorted(levels):
            inside = [(max(a, t0), min(b, t1)) for a, b in levels[level] if b > t0 and a < t1]
            if inside:
                overlays.append((j, level, inside))
    if overlays:
        lines.append("[%d:v]format=rgba,split=%d%s" % (
            mask_input, len(overlays), "".join("[m%d]" % n for n in range(len(overlays)))))

    for j, (t0, t1, members) in enumerate(feeds):
        label = parts[members[0]][2]
        chain = ["setpts=PTS+%s/TB" % fmt_time(t0)]
        if size:
            # Smaller output: scale first so every filter below works on fewer pixels.
            chain.append("scale=%d:%d" % size)
        # A seeked input can start a frame before t0: the windows reach a little past the input.
        moving = windows(spans, t0 - WINDOW_MARGIN, t1 + WINDOW_MARGIN)
        if "zoom" in effects:
            for a, b, inside in moving:
                # perspective has no time variable: frame count / fps, plus where this input was seeked to.
                z = "%g*(%s)" % (ZOOM, expression(series, "(%s+in/(%s))" % (fmt_time(t0), fps),
                                                  (a - WINDOW_MARGIN, b + WINDOW_MARGIN)))
                near, far = "W*%s" % z, "W*(1-%s)" % z
                top, bottom = "H*%s" % z, "H*(1-%s)" % z
                chain.append("perspective=x0=%s:y0=%s:x1=%s:y1=%s:x2=%s:y2=%s:x3=%s:y3=%s:eval=frame:enable=%s"
                             % (near, top, far, top, near, bottom, far, bottom, during(inside)))
        if "saturation" in effects:
            for a, b, inside in moving:
                k = expression(series, "t", (a - WINDOW_MARGIN, b + WINDOW_MARGIN))
                chain.append("eq=saturation=1+%g*(%s):contrast=1+%g*(%s):eval=frame:enable=%s"
                             % (SATURATION, k, CONTRAST, k, during(inside)))
        current = "c%d" % j
        lines.append("[%d:v]%s[%s]" % (j, ",".join(chain), current))
        for n, (feed, level, inside) in enumerate(overlays):
            if feed != j:
                continue
            # Fade the single mask frame once, then repeat it in memory on this input's timeline.
            lines.append("[m%d]colorchannelmixer=aa=%g,format=yuva420p,loop=loop=-1:size=1,setpts=%s/TB+N/(%s)/TB[l%d]"
                         % (n, level / float(VIGNETTE_LEVELS), fmt_time(t0), fps, n))
            lines.append("[%s][l%d]overlay=shortest=1:format=yuv420:enable=%s[o%d]" % (current, n, during(inside), n))
            current = "o%d" % n
        tail = "ass=" + ass_name
        if label is not None:
            # atempo takes 0.5..2 per instance: 0.4x = 0.5 * 0.8
            lines.append("[%s]%s,setpts=(PTS-STARTPTS)*%g,fps=%s,ass=%s[p%d]"
                         % (current, tail, REPLAY_SLOWDOWN, fps, label, members[0]))
            if has_audio:
                lines.append("[%d:a]asetpts=PTS-STARTPTS,atempo=0.5,atempo=%g[q%d]"
                             % (j, 1 / REPLAY_SLOWDOWN / 0.5, members[0]))
        elif len(members) == 1:
            lines.append("[%s]%s,setpts=PTS-STARTPTS[p%d]" % (current, tail, members[0]))
            if has_audio:
                lines.append("[%d:a]asetpts=PTS-STARTPTS[q%d]" % (j, members[0]))
        else:
            # Cut where each later part starts; every piece restarts at 0 for concat.
            cuts = "|".join(fmt_time(parts[m][0]) for m in members[1:])
            lines.append("[%s]%s,segment=timestamps=%s%s" % (current, tail, cuts, "".join("[s%d]" % m for m in members)))
            lines += ["[s%d]setpts=PTS-STARTPTS[p%d]" % (m, m) for m in members]
            if has_audio:
                lines.append("[%d:a]asetpts=PTS+%s/TB,asegment=timestamps=%s%s"
                             % (j, fmt_time(t0), cuts, "".join("[r%d]" % m for m in members)))
                lines += ["[r%d]asetpts=PTS-STARTPTS[q%d]" % (m, m) for m in members]

    # The encoder needs a known frame rate; after setpts / concat the graph no longer reports one
    # (hevc_qsv refused to open), so the output ends with fps at the source rate.
    pads = "".join("[p%d]%s" % (i, "[q%d]" % i if has_audio else "") for i in range(len(parts)))
    lines.append("%sconcat=n=%d:v=1:a=%d[vc]%s" % (pads, len(parts), 1 if has_audio else 0, "[aout]" if has_audio else ""))
    lines.append("[vc]fps=%s[vout]" % fps)
    return ";\n".join(lines)


def replay_window(moment, start_at, length):
    """(from, to) around the moment, kept inside the rendered part; None if it does not fit."""
    r0 = max(moment - REPLAY_BEFORE, start_at)
    r1 = min(moment + REPLAY_AFTER, start_at + length)
    return (round(r0, 2), round(r1, 2)) if r1 - r0 >= 1.0 else None
