import Toybox.Application;
import Toybox.Attention;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Data field: runs inside a native activity (any sport the field is added to).
// The camera records while the activity timer runs, but only if the camera is already on:
// the field never wakes it, so switching the camera on is how you choose to film.
class GoProFieldApp extends Application.AppBase {

    private var _ble as BleManager? = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        System.println("GoProField: onStart");
        // BLE setup belongs here, as in the SDK's data field BLE sample: from getInitialView
        // registerProfile failed in the simulator ("Failed invoking <symbol>").
        var ble = new BleManager();
        _ble = ble;
        ble.setWakeCamera(false);
        // The activity timer means video: a camera left in photo mode is switched back first.
        ble.setVideoOnly(true);
        ble.setHilightListener(method(:onHilight));
        ble.start();
    }

    function onStop(state as Dictionary?) as Void {
        System.println("GoProField: onStop");
        var ble = _ble;
        if (ble != null) {
            ble.stop();
        }
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [new GoProField(_ble as BleManager)];
    }

    // The camera confirmed a HiLight: a short buzz on top of the lap alert.
    function onHilight() as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(100, 150)]);
        }
    }
}
