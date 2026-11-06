import Toybox.Activity;
import Toybox.Attention;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// The field itself: activity timer events drive the camera, the field shows its state.
// Start / resume -> record, stop -> stop, lap (manual or Auto Lap) -> HiLight. Auto-pause is ignored, so a lift
// or a traffic light does not cut the video.
class GoProField extends WatchUi.DataField {

    // Largest first; the first one that fits the cell is used.
    private const FONTS = [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY];
    private const PADDING = 4;
    // The visible screen narrows towards its top and bottom edges (semi-octagon): this many pixels
    // are cut off each side at the edge row, about one less per row inwards (measured in the simulator).
    private const SCREEN_CORNER = 40;

    // Developer field in the activity's FIT records: 1 while the camera records, 0 otherwise.
    // Marks where each video starts and ends in the activity, for lining up GPS data with video.
    private const FIT_FIELD_RECORDING = 0;

    private var _ble as BleManager;
    private var _recordingField as FitContributor.Field;
    private var _watch as RecordingWatch = new RecordingWatch();
    private var _timerRunning as Boolean = false;   // auto-pause keeps it running, as for the camera

    // Set by onUpdate for place(): the screen, the cell's position on it, first cell row free of the subscreen.
    private var _screenWidth as Number = 0;
    private var _screenHeight as Number = 0;
    private var _cellX as Number = 0;
    private var _cellY as Number = 0;
    private var _areaTop as Number = 0;
    private var _useOutline as Boolean = true;      // false: fit within the cell only

    function initialize(ble as BleManager) {
        DataField.initialize();
        _ble = ble;
        _recordingField = createField("gopro_recording", FIT_FIELD_RECORDING, FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD});
        _recordingField.setData(0);
    }

    // Once a second while the activity is open: the BLE manager's clock (no Timer in data fields).
    function compute(info as Activity.Info) as Void {
        _ble.tick();
        var connected = _ble.getState() == BLE_READY;
        var recording = connected && _ble.isRecording();
        _recordingField.setData(recording ? 1 : 0);
        buzz(_watch.update(System.getTimer() / 1000, _timerRunning, connected, recording));
    }

    // Also called right after the field loads if the timer is already running.
    function onTimerStart() as Void {
        _timerRunning = true;
        _ble.setRecordingWanted(true);
    }

    function onTimerStop() as Void {
        _timerRunning = false;
        _ble.setRecordingWanted(false);
    }

    function onTimerReset() as Void {
        _timerRunning = false;
        _ble.setRecordingWanted(false);
    }

    // Auto-pause keeps the camera recording. But a field loaded during an auto-pause gets
    // onTimerPause instead of onTimerStart (SDK docs), and the timer counts as running for us.
    function onTimerPause() as Void {
        if (!_timerRunning) {
            onTimerStart();
        }
    }

    function onTimerResume() as Void {
        onTimerPause();
    }

    // Distinct patterns, felt through a sleeve: two short = recording, one long = stopped,
    // three long = the timer runs but the camera does not record.
    private function buzz(event as Number) as Void {
        if (event == RecordingWatch.EVENT_NONE || !(Attention has :vibrate)) {
            return;
        }
        var pattern;
        if (event == RecordingWatch.EVENT_STARTED) {
            pattern = [new Attention.VibeProfile(100, 150), new Attention.VibeProfile(0, 150), new Attention.VibeProfile(100, 150)];
        } else if (event == RecordingWatch.EVENT_STOPPED) {
            pattern = [new Attention.VibeProfile(100, 600)];
        } else {
            pattern = [new Attention.VibeProfile(100, 500), new Attention.VibeProfile(0, 300),
                new Attention.VibeProfile(100, 500), new Attention.VibeProfile(0, 300), new Attention.VibeProfile(100, 500)];
        }
        Attention.vibrate(pattern);
    }

    // Every lap marks a HiLight, Auto Lap included: the owner wants those marks too (2026-11-04).
    function onTimerLap() as Void {
        _ble.hilight();
    }

    function onUpdate(dc as Dc) as Void {
        var background = getBackgroundColor();
        var foreground = background == Graphics.COLOR_BLACK ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(foreground, background);
        dc.clear();

        // Cells do not know where they are on the screen: the edges they touch tell (centred otherwise).
        var settings = System.getDeviceSettings();
        _screenWidth = settings.screenWidth;
        _screenHeight = settings.screenHeight;
        var flags = getObscurityFlags();
        var w = dc.getWidth();
        var h = dc.getHeight();
        _cellX = (flags & OBSCURE_LEFT) != 0 ? 0 : (_screenWidth - w) / ((flags & OBSCURE_RIGHT) != 0 ? 1 : 2);
        _cellY = (flags & OBSCURE_TOP) != 0 ? 0 : (_screenHeight - h) / ((flags & OBSCURE_BOTTOM) != 0 ? 1 : 2);
        // A cell that starts just under the subscreen (not one that holds it): text goes below it.
        _areaTop = 0;
        var subscreen = (WatchUi has :getSubscreen) ? WatchUi.getSubscreen() : null;
        var subX = subscreen != null ? subscreen.x : null;
        var subY = subscreen != null ? subscreen.y : null;
        if (subscreen != null && subX != null && subY != null && (flags & OBSCURE_TOP) == 0 && _cellX + w > subX) {
            var below = subY + subscreen.height - _cellY;
            if (below > 0 && below < h / 4) {
                _areaTop = below;
            }
        }

        // The main text in the largest font that fits, on one line or on two (split at the space):
        // Russian text does not fit a half-width cell on one line even in the smallest font.
        // First within the screen outline; the cell position behind it is a guess (a cell flagged
        // "bottom" may end above the screen edge), so if nothing fits, just within the cell.
        var main = mainText();
        var two = split(main);
        var texts = [main] as Array<String>;
        var smallest = FONTS[FONTS.size() - 1];
        var fonts = null as Array<Graphics.FontType>?;
        for (var pass = 0; pass < 2 && fonts == null; pass++) {
            _useOutline = pass == 0;
            for (var i = 0; i < FONTS.size(); i++) {
                var font = FONTS[i];
                if (place(dc, texts, [font] as Array<Graphics.FontType>, false)) {
                    fonts = [font] as Array<Graphics.FontType>;
                    break;
                }
                if (two != null && place(dc, two, [font, font] as Array<Graphics.FontType>, false)) {
                    texts = two;
                    fonts = [font, font] as Array<Graphics.FontType>;
                    break;
                }
            }
        }
        if (fonts == null) {
            fonts = [smallest] as Array<Graphics.FontType>;   // nothing fits: clipped
        }

        // The detail (battery, "pair again") in the smallest font under it, on one or two lines,
        // only if everything still fits.
        var detail = detailText();
        if (detail != null) {
            var options = [[detail] as Array<String>] as Array<Array<String> >;
            var detailTwo = split(detail);
            if (detailTwo != null) {
                options.add(detailTwo);
            }
            for (var i = 0; i < options.size(); i++) {
                var t = texts.slice(0, texts.size());
                var f = fonts.slice(0, fonts.size());
                for (var j = 0; j < options[i].size(); j++) {
                    t.add(options[i][j]);
                    f.add(smallest);
                }
                if (place(dc, t, f, false)) {
                    texts = t;
                    fonts = f;
                    break;
                }
            }
        }
        place(dc, texts, fonts, true);
    }

    // The text as two lines split at its first space, or null without a space.
    private function split(text as String) as Array<String>? {
        var space = text.find(" ");
        if (space == null) {
            return null;
        }
        return [text.substring(0, space) as String, text.substring(space + 1, text.length()) as String];
    }

    // Lines centred one under another in the cell, each centred in the visible part of its rows.
    // Returns whether all of them fit; draw = true draws them anyway.
    private function place(dc as Dc, texts as Array<String>, fonts as Array<Graphics.FontType>, draw as Boolean) as Boolean {
        var total = 0;
        for (var i = 0; i < fonts.size(); i++) {
            total += dc.getFontHeight(fonts[i]);
        }
        var y = _areaTop + (dc.getHeight() - _areaTop - total) / 2;
        var fits = y >= _areaTop;
        for (var i = 0; i < texts.size(); i++) {
            var lineHeight = dc.getFontHeight(fonts[i]);
            // The glyphs leave about a sixth of the line empty above and below.
            var x = visibleX(dc, y + lineHeight / 6, y + lineHeight - 1 - lineHeight / 6);
            fits = fits && dc.getTextWidthInPixels(texts[i], fonts[i]) <= x[1] - x[0];
            if (draw) {
                dc.drawText((x[0] + x[1]) / 2, y + lineHeight / 2, fonts[i], texts[i],
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            } else if (!fits) {
                return false;
            }
            y += lineHeight;
        }
        return fits;
    }

    // [left, right] x in the cell for text in cell rows top..bottom: PADDING from the cell's sides,
    // 1 px from the screen outline.
    private function visibleX(dc as Dc, top as Number, bottom as Number) as Array<Number> {
        var left = PADDING;
        var right = dc.getWidth() - PADDING;
        if (!_useOutline) {
            return [left, right];
        }
        // Distance of the row nearest to the screen's top or bottom edge.
        var edge = _cellY + top;
        var fromBottom = _screenHeight - 1 - _cellY - bottom;
        if (fromBottom < edge) {
            edge = fromBottom;
        }
        var inset = (edge < SCREEN_CORNER ? SCREEN_CORNER - edge : 0) + 1;
        if (inset - _cellX > left) {
            left = inset - _cellX;
        }
        if (_screenWidth - inset - _cellX < right) {
            right = _screenWidth - inset - _cellX;
        }
        return [left, right];
    }

    private function mainText() as String {
        var state = _ble.getState();
        if (state == BLE_READY) {
            if (!_ble.isRecording()) {
                // The timer runs, the camera is on, but nothing is being filmed: say it loudly.
                return string(_watch.isWarning() ? Rez.Strings.StatusNotRecording : Rez.Strings.StatusStopped);
            }
            var seconds = _ble.getRecordingSeconds();
            var rec = string(Rez.Strings.StatusRecording);
            return seconds != null ? rec + " " + Format.duration(seconds) : rec;
        }
        if (state == BLE_ERROR) {
            return string(Rez.Strings.StatusError);
        }
        // Waiting for an advert: the field does not wake the camera, so it is off (or out of range).
        if (state == BLE_SCANNING || _ble.isCameraAsleep()) {
            return string(Rez.Strings.StatusCameraOff);
        }
        return string(Rez.Strings.StatusConnecting);
    }

    private function detailText() as String? {
        var state = _ble.getState();
        if (state == BLE_READY) {
            var battery = _ble.getBatteryPercent();
            return battery != null ? battery + "%" : null;
        }
        var error = _ble.getError();
        if (state == BLE_ERROR && (error == BLE_ERROR_KEYS_LOST || error == BLE_ERROR_BOND)) {
            return string(Rez.Strings.ErrorPairing);
        }
        return null;
    }

    private function string(id as ResourceId) as String {
        return WatchUi.loadResource(id) as String;
    }
}
