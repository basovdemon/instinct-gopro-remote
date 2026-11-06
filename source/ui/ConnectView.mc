import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Connection progress: one status line, plus camera name or the error reason under it.
class ConnectView extends WatchUi.View {

    private var _ble as BleManager;
    private var _savedStatus as String? = null;   // last camera status written for the glance

    function initialize(ble as BleManager) {
        View.initialize();
        _ble = ble;
    }

    // Room left around the subscreen circle: its bezel ring covers a pixel or two of the main
    // screen past the bounding box (seen on the watch).
    private const SUBSCREEN_MARGIN = 4;
    private const MAX_SHIFT = 16;

    // Centred text (justify CENTER | VCENTER), moved left just enough to stay clear of the
    // subscreen circle. Text far from it is drawn where asked.
    private function drawClear(dc as Dc, x as Number, y as Number, font as Graphics.FontType,
            text as String, justify as Number) as Void {
        var sub = WatchUi.getSubscreen();
        if (sub != null) {
            var bx = sub.x;
            var by = sub.y;
            var bw = sub.width;
            var bh = sub.height;
            if (bx != null && by != null && bw != null && bh != null) {
                var sx = bx + bw / 2;
                var sy = by + bh / 2;
                var r = (bw < bh ? bw : bh) / 2 + SUBSCREEN_MARGIN;
                var halfW = dc.getTextWidthInPixels(text, font) / 2;
                var halfH = dc.getFontHeight(font) / 2;
                for (var shift = 0; shift <= MAX_SHIFT; shift++) {
                    // Closest point of the text box to the circle's centre.
                    var px = clamp(sx, x - shift - halfW, x - shift + halfW);
                    var py = clamp(sy, y - halfH, y + halfH);
                    if ((px - sx) * (px - sx) + (py - sy) * (py - sy) >= r * r) {
                        x -= shift;
                        break;
                    }
                }
            }
        }
        dc.drawText(x, y, font, text, justify);
    }

    private function clamp(value as Number, low as Number, high as Number) as Number {
        return value < low ? low : (value > high ? high : value);
    }

    // Leaving the app: "last seen" for the glance is now, if the camera is still connected.
    function onHide() as Void {
        saveStatus(true);
    }

    function onUpdate(dc as Dc) as Void {
        saveStatus(false);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;
        var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        var detailFont = Graphics.FONT_XTINY;
        var lineGap = dc.getFontHeight(detailFont);

        if (_ble.getState() == BLE_READY) {
            drawRemote(dc, cx, cy, lineGap, detailFont, justify);
            drawSubscreen(dc, justify);
            return;
        }

        // The screen narrows towards the bottom, so a 4-line message starts half a line higher
        // (a full line would run into the subscreen).
        var keysLost = _ble.getState() == BLE_ERROR && _ble.getError() == BLE_ERROR_KEYS_LOST;
        var top = keysLost ? cy - lineGap / 2 : cy;

        drawClear(dc, cx, top - lineGap / 2, Graphics.FONT_SMALL, statusText(), justify);

        var detail = detailText();
        if (detail != null) {
            drawClear(dc, cx, top + lineGap, detailFont, detail, justify);
        }
        if (_ble.getState() == BLE_ERROR) {
            var line = 2;
            if (keysLost) {
                // Recovery needs a new pairing, so the camera must be in pairing mode before retrying.
                drawClear(dc, cx, top + line * lineGap, detailFont, WatchUi.loadResource(Rez.Strings.HintPairingMode) as String, justify);
                line++;
            }
            // START after "camera off" connects anyway, which wakes the camera.
            var hint = _ble.getError() == BLE_ERROR_CAMERA_OFF ? Rez.Strings.HintWake : Rez.Strings.HintRetry;
            drawClear(dc, cx, top + line * lineGap, detailFont, WatchUi.loadResource(hint) as String, justify);
        }
    }

    // Connected: big REC / STOP (PHOTO in the photo group), mode and battery below, then what the buttons do.
    private function drawRemote(dc as Dc, cx as Number, cy as Number, lineGap as Number,
            detailFont as Graphics.FontType, justify as Number) as Void {
        var recording = _ble.isRecording();
        var photo = _ble.getPresetGroup() == GoProProtocol.PRESET_GROUP_PHOTO;
        var big = recording ? Rez.Strings.StatusRecording : (photo ? Rez.Strings.StatusPhoto : Rez.Strings.StatusStopped);
        drawClear(dc, cx, cy - lineGap, Graphics.FONT_LARGE, WatchUi.loadResource(big) as String, justify);

        var status = modeAndBattery();
        if (status != null) {
            drawClear(dc, cx, cy + lineGap, detailFont, status, justify);
        }
        var hint = recording ? Rez.Strings.HintStop : (photo ? Rez.Strings.HintShoot : Rez.Strings.HintRecord);
        drawClear(dc, cx, cy + lineGap * 2, detailFont, WatchUi.loadResource(hint) as String, justify);
        var second = recording ? Rez.Strings.HintHilight : Rez.Strings.HintMode;
        drawClear(dc, cx, cy + lineGap * 3, detailFont, WatchUi.loadResource(second) as String, justify);
    }

    // "Video · 85%"; just the mode or "Battery 85%" while one of them is unknown.
    private function modeAndBattery() as String? {
        var group = _ble.getPresetGroup();
        var mode = null;
        if (group == GoProProtocol.PRESET_GROUP_VIDEO) {
            mode = Rez.Strings.ModeVideo;
        } else if (group == GoProProtocol.PRESET_GROUP_PHOTO) {
            mode = Rez.Strings.ModePhoto;
        } else if (group == GoProProtocol.PRESET_GROUP_TIMELAPSE) {
            mode = Rez.Strings.ModeTimelapse;
        }
        var battery = _ble.getBatteryPercent();
        if (mode == null) {
            return battery != null ? Lang.format(WatchUi.loadResource(Rez.Strings.BatteryFormat) as String, [battery]) : null;
        }
        var name = WatchUi.loadResource(mode) as String;
        return battery != null ? Lang.format(WatchUi.loadResource(Rez.Strings.ModeBatteryFormat) as String, [name, battery]) : name;
    }

    // The round subscreen (top right): an inverted disc with REC and the time while recording,
    // camera battery otherwise. Readable at a glance, and not only by color.
    private function drawSubscreen(dc as Dc, justify as Number) as Void {
        var sub = WatchUi.getSubscreen();
        if (sub == null) {
            return;
        }
        var x = sub.x;
        var y = sub.y;
        var w = sub.width;
        var h = sub.height;
        if (x == null || y == null || w == null || h == null) {
            return;
        }
        var sx = x + w / 2;
        var sy = y + h / 2;
        var r = (w < h ? w : h) / 2;

        if (_ble.isRecording()) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillCircle(sx, sy, r);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(sx, sy - r / 3, Graphics.FONT_XTINY, WatchUi.loadResource(Rez.Strings.StatusRecording) as String, justify);
            var seconds = _ble.getRecordingSeconds();
            if (seconds != null) {
                var font = seconds >= 3600 ? Graphics.FONT_XTINY : Graphics.FONT_TINY;
                dc.drawText(sx, sy + r / 4, font, Format.duration(seconds), justify);
            }
        } else {
            var battery = _ble.getBatteryPercent();
            if (battery != null) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(sx, sy, Graphics.FONT_TINY, battery + "%", justify);
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    }

    // Writes the camera status for the glance while connected, when it changed (or always, with force).
    // Done here rather than in the app class: that class also runs in the glance process,
    // which cannot reach BleManager.
    private function saveStatus(force as Boolean) as Void {
        if (_ble.getState() != BLE_READY) {
            return;
        }
        var name = _ble.getCameraName();
        var battery = _ble.getBatteryPercent();
        var group = _ble.getPresetGroup();
        var recording = _ble.isRecording();
        var key = name + "|" + battery + "|" + group + "|" + recording;
        if (!force && key.equals(_savedStatus)) {
            return;
        }
        _savedStatus = key;
        LastStatus.save(name, battery, group, recording);
    }

    private function statusText() as String {
        var state = _ble.getState();
        var id = Rez.Strings.StatusSearching;
        if (_ble.isReconnecting() && state != BLE_ERROR) {
            id = _ble.isCameraAsleep() ? Rez.Strings.StatusCameraOff : Rez.Strings.StatusReconnecting;
        } else if (state == BLE_ERROR && _ble.getError() == BLE_ERROR_CAMERA_OFF) {
            id = Rez.Strings.StatusCameraOff;
        } else if (state == BLE_CONNECTING) {
            id = Rez.Strings.StatusConnecting;
        } else if (state == BLE_BONDING || state == BLE_SUBSCRIBING || state == BLE_WAITING_CAMERA) {
            id = Rez.Strings.StatusPairing;
        } else if (state == BLE_READY) {
            id = Rez.Strings.StatusConnected;
        } else if (state == BLE_SLEEPING) {
            id = Rez.Strings.StatusSleeping;
        } else if (state == BLE_ERROR) {
            id = Rez.Strings.StatusError;
        }
        return WatchUi.loadResource(id) as String;
    }

    private function detailText() as String? {
        var state = _ble.getState();
        if (state == BLE_ERROR && _ble.getError() != BLE_ERROR_CAMERA_OFF) {
            return WatchUi.loadResource(errorText(_ble.getError())) as String;
        }
        if (state == BLE_ERROR) {
            return _ble.getCameraName();
        }
        if (_ble.isReconnecting()) {
            return _ble.getCameraName();
        }
        if (state == BLE_SCANNING || state == BLE_REGISTERING || state == BLE_IDLE) {
            return WatchUi.loadResource(Rez.Strings.HintPairingMode) as String;
        }
        return _ble.getCameraName();
    }

    private function errorText(error as BleError) as ResourceId {
        if (error == BLE_ERROR_NOT_FOUND) {
            return Rez.Strings.ErrorNotFound;
        } else if (error == BLE_ERROR_CONNECT) {
            return Rez.Strings.ErrorConnect;
        } else if (error == BLE_ERROR_BOND) {
            return Rez.Strings.ErrorBond;
        } else if (error == BLE_ERROR_NO_SERVICE || error == BLE_ERROR_NOTIFY) {
            return Rez.Strings.ErrorProtocol;
        } else if (error == BLE_ERROR_CAMERA_NOT_READY) {
            return Rez.Strings.ErrorCameraNotReady;
        } else if (error == BLE_ERROR_DISCONNECTED) {
            return Rez.Strings.ErrorDisconnected;
        } else if (error == BLE_ERROR_KEYS_LOST) {
            return Rez.Strings.ErrorKeysLost;
        }
        return Rez.Strings.ErrorBle;
    }
}
