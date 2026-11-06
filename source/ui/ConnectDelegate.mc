import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class ConnectDelegate extends WatchUi.BehaviorDelegate {

    private var _ble as BleManager;

    function initialize(ble as BleManager) {
        BehaviorDelegate.initialize();
        _ble = ble;
    }

    // START (select): toggle recording when connected, try again after an error.
    function onSelect() as Boolean {
        var state = _ble.getState();
        if (state == BLE_READY) {
            _ble.toggleRecording();
            return true;
        }
        if (state == BLE_ERROR) {
            _ble.start();
            return true;
        }
        return false;
    }

    // UP while recording: HiLight. Hold UP is onMenu, so it does not trigger this.
    function onPreviousPage() as Boolean {
        return _ble.hilight();
    }

    // DOWN while not recording: next mode (video -> photo -> time lapse).
    function onNextPage() as Boolean {
        return _ble.cycleMode();
    }

    // BACK with a connected camera that is not recording: ask whether to put it to sleep.
    // Not always: the data field only connects to a camera that is on, so leaving it on
    // before starting an activity is a real choice. Otherwise BACK exits as usual.
    function onBack() as Boolean {
        if (_ble.getState() == BLE_READY && !_ble.isRecording()) {
            var menu = new WatchUi.Menu2({:title => WatchUi.loadResource(Rez.Strings.ExitTitle) as String});
            menu.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.ExitSleep) as String, null, :sleep, null));
            menu.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.ExitKeepOn) as String, null, :keep, null));
            WatchUi.pushView(menu, new ExitMenuDelegate(_ble), WatchUi.SLIDE_UP);
            return true;
        }
        return false;
    }
}

// Exit menu: sleep the camera, then exit; or exit leaving it on. BACK in the menu returns to the remote.
class ExitMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _ble as BleManager;

    function initialize(ble as BleManager) {
        Menu2InputDelegate.initialize();
        _ble = ble;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        // The remote screen shows "Camera going to sleep..." until the camera answers.
        if (item.getId() == :sleep && _ble.sleepCamera(method(:onCameraAsleep))) {
            return;
        }
        System.exit();
    }

    function onCameraAsleep(confirmed as Boolean) as Void {
        System.exit();
    }
}
