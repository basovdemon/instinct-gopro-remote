import Toybox.Application;
import Toybox.Attention;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

class GoProRemoteApp extends Application.AppBase {

    private const TICK_MS = 1000;

    private var _ble as BleManager? = null;
    // Drives BleManager.tick(): timeouts, keep-alive, recording time on screen.
    private var _timer as Timer.Timer? = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        System.println("GoProRemote: onStart");
    }

    // Also runs when the glance closes; _ble is only set by getInitialView, so it is null there.
    (:typecheck(disableGlanceCheck))
    function onStop(state as Dictionary?) as Void {
        System.println("GoProRemote: onStop");
        var timer = _timer;
        if (timer != null) {
            timer.stop();
        }
        var ble = _ble;
        if (ble != null) {
            ble.stop();
        }
    }

    // The glance runs in its own small process (32 KB) and only reads what the app saved.
    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new GoProGlanceView()];
    }

    // Only the full app calls this, never the glance process, so its foreground-only classes are fine.
    // Without the annotation the type checker flags them because the app class also serves the glance.
    (:typecheck(disableGlanceCheck))
    function getInitialView() as [Views] or [Views, InputDelegates] {
        var ble = new BleManager();
        _ble = ble;
        ble.setListener(method(:onBleStateChanged));
        ble.setHilightListener(method(:onHilight));
        // A photo changes nothing on screen either: the same buzz confirms it.
        ble.setPhotoListener(method(:onHilight));
        ble.setClaimControl(true);
        ble.start();
        var timer = new Timer.Timer();
        timer.start(ble.method(:tick), TICK_MS, true);
        _timer = timer;
        return [new ConnectView(ble), new ConnectDelegate(ble)];
    }

    function onBleStateChanged() as Void {
        WatchUi.requestUpdate();
    }

    // The camera confirmed a HiLight: a short buzz, since the screen does not change.
    function onHilight() as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(100, 150)]);
        }
    }
}
