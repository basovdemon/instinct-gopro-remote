import Toybox.Lang;

// Data field feedback, as plain logic: fed once a second, it says when to buzz.
//   STARTED / STOPPED: the camera confirmed recording on / off (in gloves you cannot look).
//   WARNING: the activity timer runs but the camera is not recording.
// Only after the camera was connected during this run of the timer: a camera never switched on
// is the owner's way of not filming, so that stays silent. Connected but not recording repeats
// the warning; a lost link warns once, since switching the camera off may be on purpose.
class RecordingWatch {

    static const EVENT_NONE = 0;
    static const EVENT_STARTED = 1;
    static const EVENT_STOPPED = 2;
    static const EVENT_WARNING = 3;

    private const GRACE_S = 15;     // connect, switch to video, start: a few seconds in practice
    private const REPEAT_S = 120;

    private var _armed as Boolean = false;          // camera connected while the timer runs
    private var _wasRecording as Boolean = false;
    private var _problemSince as Number? = null;
    private var _lastWarning as Number? = null;
    private var _warning as Boolean = false;

    // True while the last warning still applies (the field shows "NOT REC").
    function isWarning() as Boolean {
        return _warning;
    }

    function update(now as Number, timerRunning as Boolean, connected as Boolean, recording as Boolean) as Number {
        var event = EVENT_NONE;
        if (connected) {
            if (recording && !_wasRecording) {
                event = EVENT_STARTED;
            } else if (!recording && _wasRecording) {
                event = EVENT_STOPPED;
            }
            _wasRecording = recording;
        }

        if (!timerRunning) {
            _armed = false;
            clearProblem();
            return event;
        }
        if (connected) {
            _armed = true;
        }
        if (!_armed || (connected && recording)) {
            clearProblem();
            return event;
        }

        var since = _problemSince;
        if (since == null) {
            _problemSince = now;
            return event;
        }
        var last = _lastWarning;
        if (now - since >= GRACE_S && (last == null || (connected && now - last >= REPEAT_S))) {
            _lastWarning = now;
            _warning = true;
            if (!connected) {
                // Possibly switched off on purpose: say it once, then wait for the camera to come back.
                _armed = false;
                _problemSince = null;
                _lastWarning = null;
            }
            return EVENT_WARNING;
        }
        return event;
    }

    private function clearProblem() as Void {
        _problemSince = null;
        _lastWarning = null;
        _warning = false;
    }
}
