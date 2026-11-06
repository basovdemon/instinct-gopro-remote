import Toybox.Lang;

module Format {

    // Recording time for the subscreen: m:ss below an hour, h:mm:ss above.
    function duration(seconds as Number) as String {
        var h = seconds / 3600;
        var m = (seconds % 3600) / 60;
        var s = seconds % 60;
        if (h > 0) {
            return h + ":" + m.format("%02d") + ":" + s.format("%02d");
        }
        return m + ":" + s.format("%02d");
    }
}
