import Toybox.Lang;
import Toybox.Test;

// Feeds RecordingWatch one observation per second from `from` to `to` (inclusive) and returns
// the events as "second:event" pairs, e.g. "3:1 20:3".
function watchEvents(watch as RecordingWatch, from as Number, to as Number,
        timer as Boolean, connected as Boolean, recording as Boolean) as String {
    var out = "";
    for (var t = from; t <= to; t++) {
        var event = watch.update(t, timer, connected, recording);
        if (event != RecordingWatch.EVENT_NONE) {
            out += (out.length() > 0 ? " " : "") + t + ":" + event;
        }
    }
    return out;
}

(:test)
function recordingWatchStartStop(logger as Logger) as Boolean {
    var w = new RecordingWatch();
    Test.assertEqual(watchEvents(w, 0, 2, true, true, false), "");
    Test.assertEqual(watchEvents(w, 3, 5, true, true, true), "3:1");     // started
    Test.assertEqual(watchEvents(w, 6, 7, false, true, false), "6:2");   // stopped with the timer
    Test.assert(!w.isWarning());
    return true;
}

(:test)
function recordingWatchSilentWhenCameraNeverOn(logger as Logger) as Boolean {
    // Timer runs for 10 minutes, the camera never connects: the owner chose not to film.
    var w = new RecordingWatch();
    Test.assertEqual(watchEvents(w, 0, 600, true, false, false), "");
    return true;
}

(:test)
function recordingWatchWarnsAndRepeatsWhenConnectedButNotRecording(logger as Logger) as Boolean {
    // Connected at the start but recording never begins (e.g. card full): warn after 15 s, then every 120 s.
    var w = new RecordingWatch();
    Test.assertEqual(watchEvents(w, 0, 300, true, true, false), "15:3 135:3 255:3");
    Test.assert(w.isWarning());
    // Recording starts: started event, warning cleared.
    Test.assertEqual(watchEvents(w, 301, 302, true, true, true), "301:1");
    Test.assert(!w.isWarning());
    return true;
}

(:test)
function recordingWatchWarnsOnceWhenLinkLost(logger as Logger) as Boolean {
    var w = new RecordingWatch();
    Test.assertEqual(watchEvents(w, 0, 10, true, true, true), "0:1");
    // Link lost while recording (camera switched off, or battery): one warning only.
    Test.assertEqual(watchEvents(w, 11, 400, true, false, false), "26:3");
    // Camera back and still recording: it was recording when the link went, so no event at all.
    Test.assertEqual(watchEvents(w, 401, 402, true, true, true), "");
    return true;
}

(:test)
function recordingWatchNoWarningAfterTimerStops(logger as Logger) as Boolean {
    var w = new RecordingWatch();
    Test.assertEqual(watchEvents(w, 0, 5, true, true, true), "0:1");
    Test.assertEqual(watchEvents(w, 6, 7, true, true, false), "6:2");    // stopped on the camera
    Test.assertEqual(watchEvents(w, 8, 200, false, true, false), "");     // timer stopped too: quiet
    return true;
}
