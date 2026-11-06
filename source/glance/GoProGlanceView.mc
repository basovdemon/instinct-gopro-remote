import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// Glance: the camera as last seen by the app, in three lines:
//   GoPro 1234
//   Video          (or REC)
//   85% · 18:42    (when it was last seen; "85% · 3 Nov" if not today)
// The round subscreen covers the right part of the glance down to about its last line, so the
// first two lines stay short and the long one goes last.
(:glance)
class GoProGlanceView extends WatchUi.GlanceView {

    function initialize() {
        GlanceView.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var status = LastStatus.load();
        var lines = status != null
            ? [title(status), mode(status), batteryAndTime(status)]
            : [WatchUi.loadResource(Rez.Strings.GlanceTitle) as String, WatchUi.loadResource(Rez.Strings.GlanceNoData) as String];
        var height = dc.getHeight();
        var font = dc.getFontHeight(Graphics.FONT_GLANCE) * 3 <= height ? Graphics.FONT_GLANCE : Graphics.FONT_XTINY;
        var justify = Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER;
        for (var i = 0; i < lines.size(); i++) {
            var text = lines[i];
            if (text != null) {
                dc.drawText(0, height * (2 * i + 1) / 6, font, text, justify);
            }
        }
    }

    private function title(status as StatusDictionary) as String {
        var name = status["name"];
        return name instanceof String ? name : WatchUi.loadResource(Rez.Strings.GlanceTitle) as String;
    }

    private function mode(status as StatusDictionary) as String? {
        var recording = status["rec"];
        if (recording instanceof Boolean && recording) {
            return WatchUi.loadResource(Rez.Strings.StatusRecording) as String;
        }
        // Same IDs as GoProProtocol.PRESET_GROUP_*; repeated so the glance does not load the protocol module.
        var group = status["group"];
        if (!(group instanceof Number)) {
            return null;
        }
        if (group == 1000) {
            return WatchUi.loadResource(Rez.Strings.ModeVideo) as String;
        } else if (group == 1001) {
            return WatchUi.loadResource(Rez.Strings.ModePhoto) as String;
        } else if (group == 1002) {
            return WatchUi.loadResource(Rez.Strings.ModeTimelapse) as String;
        }
        return null;
    }

    private function batteryAndTime(status as StatusDictionary) as String {
        var text = "";
        var battery = status["battery"];
        if (battery instanceof Number) {
            text = battery + "%";
        }
        var time = status["time"];
        if (time instanceof Number) {
            // FORMAT_MEDIUM: the month as a short name in the watch's language ("3 Nov").
            var info = Gregorian.info(new Time.Moment(time), Time.FORMAT_MEDIUM);
            // Not from today: the date, so yesterday's "REC · 09:15" does not look like today's.
            var when = time >= Time.today().value()
                ? info.hour.format("%02d") + ":" + info.min.format("%02d")
                : info.day + " " + info.month;
            text += (text.length() > 0 ? " · " : "") + when;
        }
        return text;
    }
}
