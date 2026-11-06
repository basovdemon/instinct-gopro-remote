import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

enum BleState {
    BLE_IDLE,
    BLE_REGISTERING,     // registerProfile -> onProfileRegister
    BLE_SCANNING,        // waiting for an advert with service 0xFEA6
    BLE_CONNECTING,      // pairDevice -> onConnectedStateChanged
    BLE_BONDING,         // requestBond -> onEncryptionStatus
    BLE_SUBSCRIBING,     // CCCD writes on the response characteristics
    BLE_WAITING_CAMERA,  // polling Get Hardware Info until success
    BLE_READY,
    BLE_ERROR,
    BLE_SLEEPING         // Sleep sent on exit; waiting for its response (or the camera dropping the link)
}

enum BleError {
    BLE_ERROR_NONE,
    BLE_ERROR_PROFILE,
    BLE_ERROR_NOT_FOUND,
    BLE_ERROR_CONNECT,
    BLE_ERROR_BOND,
    BLE_ERROR_NO_SERVICE,
    BLE_ERROR_NOTIFY,
    BLE_ERROR_CAMERA_NOT_READY,
    BLE_ERROR_DISCONNECTED,
    BLE_ERROR_KEYS_LOST,     // the camera no longer has our bond (e.g. its connections were reset)
    BLE_ERROR_CAMERA_OFF     // after a drop the camera only advertises as asleep; START wakes it
}

// Owns the BLE connection to one GoPro: scan -> connect -> bond -> notifications -> camera ready,
// then camera statuses and commands. It is the app's single BleDelegate (Connect IQ allows only one).
// Shared by the watch app and the data field. It owns no Timer (data fields cannot use one):
// the host calls tick() about once a second, and timeouts are deadlines checked there.
class BleManager extends BluetoothLowEnergy.BleDelegate {

    private const REGISTER_TIMEOUT_MS = 5000;
    private const SCAN_TIMEOUT_MS = 30000;
    private const CONNECT_TIMEOUT_MS = 20000;
    private const READY_POLL_MS = 1000;
    private const READY_POLL_MAX = 10;
    // While READY: keep-alive every 3 ticks (spec: every 3 s).
    private const KEEP_ALIVE_TICKS = 3;
    // After a drop: scan for the same camera this long, reconnecting only if it is awake.
    private const RECONNECT_WINDOW_MS = 120000;
    // Ignore adverts right after a drop: a camera being switched off may still advertise as awake.
    private const RECONNECT_SETTLE_MS = 3000;
    // Without waking the camera (data field): scan this long, pause, scan again; retry after errors.
    private const SCAN_PAUSE_MS = 15000;
    private const ERROR_RETRY_MS = 60000;
    // Shown on the camera's paired-devices list; the spec says it only has to be non-empty.
    private const CLIENT_NAME = "Instinct";
    // Exit with sleep: give up waiting for the camera's answer after this long and exit anyway.
    private const SLEEP_TIMEOUT_MS = 3000;
    // Data field: how many times a refused Set Shutter is sent again per connection.
    private const SHUTTER_RETRY_MAX = 3;

    // Indexes into _responseUuids / _assemblers
    private const RESPONSE_COMMAND = 0;
    private const RESPONSE_SETTINGS = 1;
    private const RESPONSE_QUERY = 2;
    private const RESPONSE_NET_MGMT = 3;

    private var _state as BleState = BLE_IDLE;
    private var _error as BleError = BLE_ERROR_NONE;
    private var _cameraName as String? = null;
    private var _listener as Method() as Void or Null = null;
    private var _hilightListener as Method() as Void or Null = null;
    private var _photoListener as Method() as Void or Null = null;
    private var _sleepListener as Method(confirmed as Boolean) as Void or Null = null;

    private var _device as BluetoothLowEnergy.Device? = null;
    private var _command as BluetoothLowEnergy.Characteristic? = null;
    private var _settings as BluetoothLowEnergy.Characteristic? = null;
    private var _query as BluetoothLowEnergy.Characteristic? = null;
    private var _netMgmtCommand as BluetoothLowEnergy.Characteristic? = null;
    private var _profilesRegistered as Boolean = false;
    private var _profilesPending as Number = 0;
    private var _needsPairingFinish as Boolean = false;
    private var _cccdPending as Number = 0;
    private var _readyPolls as Number = 0;

    // Reconnect after an unexpected drop
    private var _reconnecting as Boolean = false;
    private var _reconnectDeadline as Number = 0;            // System.getTimer() value
    private var _reconnectSettle as Number = 0;              // System.getTimer() value
    private var _cameraAsleep as Boolean = false;            // seen advertising as asleep while reconnecting
    private var _lastAdvertStatus as Number? = null;         // for logging changes only
    private var _lastScanResult as BluetoothLowEnergy.ScanResult? = null;   // the camera we were connected to
    private var _skippedName as String? = null;                  // for logging skipped cameras once
    private var _retryBond as Boolean = false;   // last failure was BLE_ERROR_KEYS_LOST; survives start()

    // Data field mode: connect only to a camera that is already on, never give up looking for it.
    private var _wakeCamera as Boolean = true;
    private var _scanPaused as Boolean = false;
    // Recording the host wants (data field: activity timer running); null = no wish (watch app).
    // Applied once per connection, so a recording stopped on the camera itself is not restarted.
    private var _wantRecording as Boolean? = null;
    private var _wantApplied as Boolean = false;
    // Data field: switch the camera to the video group before recording (it may be left in photo).
    private var _videoOnly as Boolean = false;
    private var _requestedGroup as Number? = null;   // Load Preset Group sent, waiting for its response
    private var _videoSwitchFailed as Boolean = false;  // per connection: then record in whatever mode
    private var _shutterRetries as Number = 0;          // per connection: refused shutters tried again
    // Watch app: claim control of the camera (Set Camera Control = EXTERNAL) on every connection.
    private var _claimControl as Boolean = false;

    // Camera statuses, null until the first status message
    private var _encoding as Boolean? = null;
    private var _busy as Boolean? = null;
    private var _cameraReady as Boolean? = null;
    private var _batteryPercent as Number? = null;
    private var _presetGroup as Number? = null;      // GoProProtocol.PRESET_GROUP_*
    private var _cameraModel as Number? = null;      // from Get Hardware Info (HERO12 = 62)
    private var _recordingStart as Number? = null;   // System.getTimer() when the current video started
    private var _ticks as Number = 0;
    private var _deadline as Number? = null;   // System.getTimer() value of the pending timeout

    private var _queue as BleQueue;

    private var _controlServiceUuid as BluetoothLowEnergy.Uuid;
    private var _netMgmtServiceUuid as BluetoothLowEnergy.Uuid;
    private var _responseUuids as Array<BluetoothLowEnergy.Uuid>;
    private var _assemblers as Array<PacketAssembler>;

    function initialize() {
        BleDelegate.initialize();
        _queue = new BleQueue();
        _controlServiceUuid = GoProUuids.uuid(GoProUuids.SERVICE);
        _netMgmtServiceUuid = GoProUuids.uuid(GoProUuids.NET_MGMT_SERVICE);
        _responseUuids = [
            GoProUuids.uuid(GoProUuids.COMMAND_RESPONSE),
            GoProUuids.uuid(GoProUuids.SETTINGS_RESPONSE),
            GoProUuids.uuid(GoProUuids.QUERY_RESPONSE),
            GoProUuids.uuid(GoProUuids.NET_MGMT_RESPONSE)
        ];
        _assemblers = [new PacketAssembler(), new PacketAssembler(), new PacketAssembler(), new PacketAssembler()];
    }

    function getState() as BleState {
        return _state;
    }

    function getError() as BleError {
        return _error;
    }

    function getCameraName() as String? {
        return _cameraName;
    }

    // True from an unexpected drop until READY again (covers the scan/connect steps too).
    function isReconnecting() as Boolean {
        return _reconnecting;
    }

    // While reconnecting: the camera advertises as asleep (switched off), so we wait for it.
    function isCameraAsleep() as Boolean {
        return _cameraAsleep;
    }

    // Video or time lapse being recorded. In the photo group the camera also reports Encoding = 1
    // for a moment while it processes a shot (seen on the watch): that is not a recording.
    function isRecording() as Boolean {
        return _encoding == true && _presetGroup != GoProProtocol.PRESET_GROUP_PHOTO;
    }

    function getBatteryPercent() as Number? {
        return _batteryPercent;
    }

    // GoProProtocol.PRESET_GROUP_* the camera is in, null until known.
    function getPresetGroup() as Number? {
        return _presetGroup;
    }

    // Called when the camera confirms a photo (shutter in the photo group).
    function setPhotoListener(listener as Method() as Void) as Void {
        _photoListener = listener;
    }

    // Data field: make sure the camera is in the video group before recording.
    function setVideoOnly(videoOnly as Boolean) as Void {
        _videoOnly = videoOnly;
    }

    // Watch app: tell the camera an external client controls it, as the spec asks. Not in the data
    // field until we know what it does to the camera's own buttons [VERIFY]. The camera is expected
    // to drop the claim when the link goes; we do not send IDLE on exit (the link drops right away).
    function setClaimControl(claim as Boolean) as Void {
        _claimControl = claim;
    }

    // DOWN button: next preset group (video -> photo -> time lapse) while not recording.
    function cycleMode() as Boolean {
        if (_state != BLE_READY || _encoding == true || _busy == true) {
            return false;
        }
        loadPresetGroup(GoProProtocol.nextPresetGroup(_presetGroup));
        return true;
    }

    private function loadPresetGroup(group as Number) as Void {
        _requestedGroup = group;
        sendCommand(GoProProtocol.loadPresetGroup(group));
    }

    // Seconds of the current video, or null when not recording.
    function getRecordingSeconds() as Number? {
        var start = _recordingStart;
        if (!isRecording() || start == null) {
            return null;
        }
        return (System.getTimer() - start) / 1000;
    }

    // Called on every state or camera status change.
    function setListener(listener as Method() as Void) as Void {
        _listener = listener;
    }

    // Called when the camera confirms a HiLight.
    function setHilightListener(listener as Method() as Void) as Void {
        _hilightListener = listener;
    }

    // false: never wake the camera. Connect only when its advert says it is awake, keep looking
    // for it without a time limit, and retry after errors on our own (no button to press).
    function setWakeCamera(wake as Boolean) as Void {
        _wakeCamera = wake;
    }

    // The host wants the camera recording (true) or stopped (false). Applied as soon as the camera
    // is ready, once per connection.
    function setRecordingWanted(want as Boolean) as Void {
        _wantRecording = want;
        _wantApplied = false;
        syncRecording();
    }

    function start() as Void {
        if (BLE_LOGGING) { log("start"); }
        _error = BLE_ERROR_NONE;
        _cameraName = null;
        _reconnecting = false;
        _cameraAsleep = false;
        _lastScanResult = null;
        resetCameraStatus();
        BluetoothLowEnergy.setDelegate(self);
        // Registration lives as long as the app; registering the same profile twice fails.
        if (_profilesRegistered) {
            startScan();
            return;
        }
        setState(BLE_REGISTERING);
        // Without BLE hardware (simulator with no nRF board) onProfileRegister never comes.
        startTimeout(REGISTER_TIMEOUT_MS);
        var profiles = GoProUuids.profiles();
        _profilesPending = profiles.size();
        for (var i = 0; i < profiles.size(); i++) {
            try {
                BluetoothLowEnergy.registerProfile(profiles[i]);
            } catch (e instanceof BluetoothLowEnergy.ProfileRegistrationException) {
                // Seen in the simulator: registrations outlive the app instance, so after a few launches
                // this throws "Too Many Profiles". Assume ours is still registered; if it is not,
                // subscribe() fails later with BLE_ERROR_NO_SERVICE.
                if (BLE_LOGGING) { log("registerProfile: " + e.getErrorMessage() + ", assuming already registered"); }
                _profilesPending--;
            }
        }
        if (_profilesPending == 0) {
            _profilesRegistered = true;
            startScan();
        }
    }

    // Called on app exit: stop everything and drop the connection.
    function stop() as Void {
        if (BLE_LOGGING) { log("stop"); }
        _deadline = null;
        _queue.clear();
        _reconnecting = false;
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        disconnect();
        _state = BLE_IDLE;
    }

    // START button: stop recording if the camera is encoding, otherwise start it.
    function toggleRecording() as Void {
        if (_state != BLE_READY) {
            return;
        }
        if (_encoding == true) {
            if (_presetGroup == GoProProtocol.PRESET_GROUP_PHOTO) {
                // Still processing the last shot: a shutter-off would not mean anything here.
                if (BLE_LOGGING) { log("photo still processing, ignoring START"); }
                return;
            }
            // Stopping is allowed while busy.
            sendCommand(GoProProtocol.setShutter(false));
            return;
        }
        if (!canStartRecording()) {
            if (BLE_LOGGING) { log("camera busy, not starting"); }
            return;
        }
        sendCommand(GoProProtocol.setShutter(true));
    }

    private function canStartRecording() as Boolean {
        return _busy != true && _cameraReady != false;
    }

    // Brings the camera to _wantRecording once per connection, when its statuses are known.
    private function syncRecording() as Void {
        var want = _wantRecording;
        if (want == null || _wantApplied || _state != BLE_READY || _encoding == null) {
            return;
        }
        // isRecording, not _encoding: in the photo group Encoding = 1 only means a shot is processed.
        if (want == isRecording()) {
            _wantApplied = true;
            return;
        }
        if (want && !canStartRecording()) {
            return;   // try again on the next status push
        }
        if (want && _videoOnly && !_videoSwitchFailed
                && _presetGroup != null && _presetGroup != GoProProtocol.PRESET_GROUP_VIDEO) {
            // A shutter in the photo group would take one picture. Switch first; the status push for
            // the new group runs this again.
            if (_requestedGroup == null) {
                if (BLE_LOGGING) { log("switching to video before recording"); }
                loadPresetGroup(GoProProtocol.PRESET_GROUP_VIDEO);
            }
            return;
        }
        _wantApplied = true;
        if (BLE_LOGGING) { log("recording wanted=" + want); }
        sendCommand(GoProProtocol.setShutter(want));
    }

    // UP button: mark the moment. The camera accepts it only while encoding.
    function hilight() as Boolean {
        if (_state != BLE_READY || !isRecording()) {
            return false;
        }
        sendCommand(GoProProtocol.hilightMoment());
        return true;
    }

    // Exit menu: put a camera that is not recording to sleep. listener gets true when the camera
    // confirmed (or dropped the link), false after SLEEP_TIMEOUT_MS. Returns false if not possible now.
    function sleepCamera(listener as Method(confirmed as Boolean) as Void) as Boolean {
        if (_state != BLE_READY || isRecording()) {
            return false;
        }
        _sleepListener = listener;
        setState(BLE_SLEEPING);
        if (_encoding == true) {
            // A photo is still being processed (Encoding = 1 in the photo group): Sleep goes when
            // the push says it is done (applyStatuses), so we do not cut the shot short.
            if (BLE_LOGGING) { log("sleep after the photo is processed"); }
            startTimeout(3 * SLEEP_TIMEOUT_MS);
        } else {
            sendCommand(GoProProtocol.sleep());
            startTimeout(SLEEP_TIMEOUT_MS);
        }
        return true;
    }

    private function finishSleep(confirmed as Boolean) as Void {
        if (_state != BLE_SLEEPING) {
            return;
        }
        if (BLE_LOGGING) { log("sleep confirmed=" + confirmed); }
        _deadline = null;
        setState(BLE_IDLE);
        var listener = _sleepListener;
        _sleepListener = null;
        if (listener != null) {
            listener.invoke(confirmed);
        }
    }

    // --- BleDelegate callbacks ---

    function onProfileRegister(uuid as BluetoothLowEnergy.Uuid, status as BluetoothLowEnergy.Status) as Void {
        if (BLE_LOGGING) { log("onProfileRegister " + uuid + " status=" + status); }
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            fail(BLE_ERROR_PROFILE, "status " + status);
            return;
        }
        _profilesPending--;
        if (_profilesPending > 0) {
            return;
        }
        _profilesRegistered = true;
        if (_state == BLE_REGISTERING) {
            startScan();
        }
    }

    function onScanStateChange(scanState as BluetoothLowEnergy.ScanState, status as BluetoothLowEnergy.Status) as Void {
        if (BLE_LOGGING) { log("onScanStateChange state=" + scanState + " status=" + status); }
    }

    function onScanResults(scanResults as BluetoothLowEnergy.Iterator) as Void {
        if (_state != BLE_SCANNING) {
            return;
        }
        for (var r = scanResults.next() as BluetoothLowEnergy.ScanResult?; r != null; r = scanResults.next() as BluetoothLowEnergy.ScanResult?) {
            if (!isGoPro(r) || !isOurCamera(r)) {
                continue;
            }
            var status = GoProProtocol.advertCameraStatus(r.getRawData());
            if (status != _lastAdvertStatus) {
                _lastAdvertStatus = status;
                if (BLE_LOGGING) { log("advert camera status=" + (status != null ? status.format("%02X") : "none")
                    + " raw=" + GoProProtocol.toHex(r.getRawData())); }
            }
            // On the first connect we wake the camera on purpose. After a drop we do not:
            // connecting wakes a camera that the user may just have switched off.
            if (_reconnecting && System.getTimer() - _reconnectSettle < 0) {
                continue;
            }
            if (_reconnecting || !_wakeCamera) {
                if (status != null && (status & GoProProtocol.ADVERT_STATUS_AWAKE) == 0) {
                    if (!_cameraAsleep) {
                        if (BLE_LOGGING) { log("camera is asleep, waiting for it to wake up"); }
                        _cameraAsleep = true;
                        notifyListener();
                    }
                    continue;
                }
            }
            connect(r);
            return;
        }
    }

    function onConnectedStateChanged(device as BluetoothLowEnergy.Device, connectionState as BluetoothLowEnergy.ConnectionState) as Void {
        if (BLE_LOGGING) { log("onConnectedStateChanged state=" + connectionState + " bonded=" + device.isBonded()); }
        if (connectionState != BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            _queue.clear();
            forgetCharacteristics();
            if (_state == BLE_SLEEPING) {
                // A sleeping camera may close the link: that is the goal, not a drop to recover from.
                finishSleep(true);
            } else if (_state == BLE_SUBSCRIBING || _state == BLE_WAITING_CAMERA || _state == BLE_READY) {
                startReconnect();
            } else if (_state == BLE_CONNECTING || _state == BLE_BONDING) {
                retryOrFail(BLE_ERROR_DISCONNECTED, "dropped while connecting");
            }
            // IDLE / ERROR / SCANNING: we disconnected on purpose.
            return;
        }
        if (_state != BLE_CONNECTING) {
            return;
        }
        _device = device;
        if (device.isBonded()) {
            if (_retryBond) {
                // Experiment: the camera lost our keys but we still have a bond. requestBond is documented
                // to throw when already bonded; try anyway and log what happens.
                try {
                    device.requestBond();
                    if (BLE_LOGGING) { log("requestBond on a bonded device accepted"); }
                    _needsPairingFinish = true;
                    setState(BLE_BONDING);
                    startTimeout(CONNECT_TIMEOUT_MS);
                    return;
                } catch (e instanceof BluetoothLowEnergy.InvalidRequestException) {
                    if (BLE_LOGGING) { log("requestBond on a bonded device refused: " + e.getErrorMessage()); }
                }
            }
            // Keys from an earlier bond; encryption is re-established by the stack.
            _needsPairingFinish = false;
            subscribe();
            return;
        }
        // A fresh bond: the camera keeps its pairing screen open until Set Pairing State.
        _needsPairingFinish = true;
        setState(BLE_BONDING);
        try {
            device.requestBond();
        } catch (e instanceof BluetoothLowEnergy.InvalidRequestException) {
            fail(BLE_ERROR_BOND, e.getErrorMessage());
        }
    }

    function onEncryptionStatus(device as BluetoothLowEnergy.Device, status as BluetoothLowEnergy.Status) as Void {
        if (BLE_LOGGING) { log("onEncryptionStatus status=" + status); }
        if (_state != BLE_BONDING) {
            // Reconnect to a bonded device: we did not wait for this, but a failure means our keys are stale.
            if (status != BluetoothLowEnergy.STATUS_SUCCESS && isConnectedState()) {
                fail(BLE_ERROR_KEYS_LOST, "encryption status " + status);
            }
            return;
        }
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            fail(BLE_ERROR_BOND, "status " + status);
            return;
        }
        subscribe();
    }

    function onDescriptorWrite(descriptor as BluetoothLowEnergy.Descriptor, status as BluetoothLowEnergy.Status) as Void {
        if (BLE_LOGGING) { log("onDescriptorWrite " + descriptor.getCharacteristic().getUuid() + " status=" + status); }
        _queue.onComplete();
        if (_state != BLE_SUBSCRIBING) {
            return;
        }
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            fail(isEncryptionFailure(status) ? BLE_ERROR_KEYS_LOST : BLE_ERROR_NOTIFY, "CCCD status " + status);
            return;
        }
        _cccdPending--;
        if (_cccdPending == 0) {
            onSubscribed();
        }
    }

    function onCharacteristicWrite(characteristic as BluetoothLowEnergy.Characteristic, status as BluetoothLowEnergy.Status) as Void {
        // Successful writes are not logged: keep-alive alone would add a line every 3 s.
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            if (BLE_LOGGING) { log("onCharacteristicWrite " + characteristic.getUuid() + " status=" + status); }
        }
        _queue.onComplete();
        if (isEncryptionFailure(status) && isConnectedState()) {
            fail(BLE_ERROR_KEYS_LOST, "write status " + status);
        }
    }

    function onCharacteristicChanged(characteristic as BluetoothLowEnergy.Characteristic, value as ByteArray) as Void {
        var uuid = characteristic.getUuid();
        for (var i = 0; i < _responseUuids.size(); i++) {
            if (_responseUuids[i].equals(uuid)) {
                if (i != RESPONSE_SETTINGS) {
                    if (BLE_LOGGING) { log("notify " + uuid + ": " + GoProProtocol.toHex(value)); }
                }
                var message = _assemblers[i].accept(value);
                if (message != null) {
                    onMessage(i, message);
                }
                return;
            }
        }
    }

    // --- flow ---

    private function startScan() as Void {
        setState(BLE_SCANNING);
        _scanPaused = false;
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
        startTimeout(SCAN_TIMEOUT_MS);
    }

    // Our camera: one this app has a bond with, or the one we were connected to when reconnecting.
    // Without this a friend's GoPro nearby gets connected and we try to pair with it.
    // A camera with no bond is taken only in pairing mode (then the HERO12 advert has no name; the
    // pairing bit in the advert stays 0), or while we have no bond at all. So switching to another
    // camera = put it in pairing mode; the old one stays known too (bonds cannot be removed by the app).
    private function isOurCamera(result as BluetoothLowEnergy.ScanResult) as Boolean {
        var last = _lastScanResult;
        if (_reconnecting && last != null) {
            return result.isSameDevice(last);
        }
        // Not logged when taken: a sleeping camera is seen for hours. connect() logs the name
        // (null = pairing mode), onConnectedStateChanged whether we had a bond.
        var name = result.getDeviceName();
        if (name == null) {
            return true;
        }
        // Bonded devices come as ScanResults [VERIFY on the watch: isSameDevice matches our camera].
        var bonded = BluetoothLowEnergy.getBondedDevices();
        var anyBond = false;
        for (var b = bonded.next() as BluetoothLowEnergy.ScanResult?; b != null; b = bonded.next() as BluetoothLowEnergy.ScanResult?) {
            if (result.isSameDevice(b)) {
                return true;
            }
            anyBond = true;
        }
        // A bare "if (BLE_LOGGING)": only that form is dropped by -O 3 in builds without logs.
        if (BLE_LOGGING) {
            if (anyBond && !name.equals(_skippedName)) {
                log("skipping " + name + ": no bond with it");
                _skippedName = name;
            }
        }
        return !anyBond;
    }

    private function isGoPro(result as BluetoothLowEnergy.ScanResult) as Boolean {
        var uuids = result.getServiceUuids();
        for (var u = uuids.next() as BluetoothLowEnergy.Uuid?; u != null; u = uuids.next() as BluetoothLowEnergy.Uuid?) {
            if (u.equals(_controlServiceUuid)) {
                return true;
            }
        }
        return false;
    }

    private function connect(result as BluetoothLowEnergy.ScanResult) as Void {
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        _lastScanResult = result;
        // Null while the camera is in pairing mode (the name is only in the scan response then).
        var name = result.getDeviceName();
        if (name != null) {
            _cameraName = name;
        }
        if (BLE_LOGGING) { log("found " + name + " rssi=" + result.getRssi()); }
        setState(BLE_CONNECTING);
        startTimeout(CONNECT_TIMEOUT_MS);
        try {
            _device = BluetoothLowEnergy.pairDevice(result);
        } catch (e instanceof BluetoothLowEnergy.DevicePairException) {
            retryOrFail(BLE_ERROR_CONNECT, "pairDevice: " + e.getErrorMessage());
            return;
        }
        if (_device == null) {
            retryOrFail(BLE_ERROR_CONNECT, "pairDevice returned null");
        }
    }

    private function subscribe() as Void {
        setState(BLE_SUBSCRIBING);
        startTimeout(CONNECT_TIMEOUT_MS);
        var device = _device;
        var control = device != null ? device.getService(_controlServiceUuid) : null;
        if (device == null || control == null) {
            fail(BLE_ERROR_NO_SERVICE, "service FEA6 missing");
            return;
        }
        _command = control.getCharacteristic(GoProUuids.uuid(GoProUuids.COMMAND));
        _settings = control.getCharacteristic(GoProUuids.uuid(GoProUuids.SETTINGS));
        _query = control.getCharacteristic(GoProUuids.uuid(GoProUuids.QUERY));
        if (_command == null || _settings == null || _query == null) {
            fail(BLE_ERROR_NO_SERVICE, "command/settings/query characteristic missing");
            return;
        }
        // Optional: only needed for Set Pairing State.
        var netMgmt = device.getService(_netMgmtServiceUuid);
        _netMgmtCommand = netMgmt != null ? netMgmt.getCharacteristic(GoProUuids.uuid(GoProUuids.NET_MGMT_COMMAND)) : null;

        // The camera does not remember subscriptions: enable notifications on every connection.
        _cccdPending = 0;
        for (var i = 0; i < _responseUuids.size(); i++) {
            _assemblers[i].reset();
            var service = i == RESPONSE_NET_MGMT ? netMgmt : control;
            if (service == null) {
                if (BLE_LOGGING) { log("no Net Mgmt service, skipping its notifications"); }
                continue;
            }
            var characteristic = service.getCharacteristic(_responseUuids[i]);
            var cccd = characteristic != null ? characteristic.getDescriptor(BluetoothLowEnergy.cccdUuid()) : null;
            if (cccd == null) {
                fail(BLE_ERROR_NO_SERVICE, "CCCD missing on " + _responseUuids[i]);
                return;
            }
            _cccdPending++;
            _queue.writeDescriptor(cccd, [0x01, 0x00]b);
        }
    }

    private function onSubscribed() as Void {
        var netMgmtCommand = _netMgmtCommand;
        if (_needsPairingFinish && netMgmtCommand != null) {
            _needsPairingFinish = false;
            var message = GoProProtocol.pairingFinish(CLIENT_NAME);
            if (BLE_LOGGING) { log("pairing finish " + GoProProtocol.toHex(message)); }
            _queue.write(netMgmtCommand, message);
        }
        setState(BLE_WAITING_CAMERA);
        _readyPolls = 0;
        pollCameraReady();
    }

    private function pollCameraReady() as Void {
        if (_readyPolls >= READY_POLL_MAX) {
            fail(BLE_ERROR_CAMERA_NOT_READY, "no successful Get Hardware Info");
            return;
        }
        _readyPolls++;
        sendCommand(GoProProtocol.getHardwareInfo());
        startTimeout(READY_POLL_MS);
    }

    private function onCameraReady() as Void {
        _deadline = null;
        _reconnecting = false;
        _cameraAsleep = false;
        _retryBond = false;
        _error = BLE_ERROR_NONE;
        var query = _query;
        if (query != null) {
            var message = GoProProtocol.registerStatusUpdates([
                GoProProtocol.STATUS_BUSY,
                GoProProtocol.STATUS_ENCODING,
                GoProProtocol.STATUS_BATTERY_PERCENT,
                GoProProtocol.STATUS_READY,
                GoProProtocol.STATUS_PRESET_GROUP
            ]);
            if (BLE_LOGGING) { log("query " + GoProProtocol.toHex(message)); }
            _queue.write(query, message);
        }
        _wantApplied = false;
        _videoSwitchFailed = false;
        _requestedGroup = null;   // a response lost with the old link must not block the video switch
        _shutterRetries = 0;
        if (_claimControl) {
            sendCommand(GoProProtocol.setCameraControl(GoProProtocol.CAMERA_CONTROL_EXTERNAL));
        }
        setState(BLE_READY);
        _ticks = 0;
        sendKeepAlive();
    }

    private function sendKeepAlive() as Void {
        var settings = _settings;
        if (settings != null) {
            _queue.write(settings, GoProProtocol.keepAlive());
        }
    }

    private function sendCommand(bytes as ByteArray) as Void {
        var command = _command;
        if (command == null) {
            if (BLE_LOGGING) { log("sendCommand: not connected"); }
            return;
        }
        if (BLE_LOGGING) { log("command " + GoProProtocol.toHex(bytes)); }
        _queue.write(command, bytes);
    }

    private function onMessage(index as Number, message as ByteArray) as Void {
        if (index != RESPONSE_SETTINGS) {
            if (BLE_LOGGING) { log("message[" + index + "] " + GoProProtocol.toHex(message)); }
        }
        if (index == RESPONSE_COMMAND) {
            if (_state == BLE_WAITING_CAMERA
                    && GoProProtocol.responseStatus(message, GoProProtocol.CMD_GET_HARDWARE_INFO) == GoProProtocol.RESULT_SUCCESS) {
                _cameraModel = GoProProtocol.hardwareModel(message);
                if (BLE_LOGGING) { log("camera model=" + _cameraModel); }
                onCameraReady();
                return;
            }
            var control = GoProProtocol.cameraControlSucceeded(message);
            if (control != null) {
                if (BLE_LOGGING) { log("camera control external ok=" + control); }
                return;
            }
            var shutter = GoProProtocol.responseStatus(message, GoProProtocol.CMD_SET_SHUTTER);
            if (shutter != null) {
                if (BLE_LOGGING) { log("set shutter result=" + shutter); }
                // A refused shutter (e.g. busy right after a group change) does not count as applied:
                // tick() tries again with the next keep-alive, a few times per connection.
                if (shutter != GoProProtocol.RESULT_SUCCESS && _wantRecording != null && _shutterRetries < SHUTTER_RETRY_MAX) {
                    _shutterRetries++;
                    _wantApplied = false;
                }
                var photoListener = _photoListener;
                if (shutter == GoProProtocol.RESULT_SUCCESS && _presetGroup == GoProProtocol.PRESET_GROUP_PHOTO
                        && photoListener != null) {
                    photoListener.invoke();
                }
            }
            var group = GoProProtocol.responseStatus(message, GoProProtocol.CMD_LOAD_PRESET_GROUP);
            if (group != null) {
                if (BLE_LOGGING) { log("load preset group " + _requestedGroup + " result=" + group); }
                if (group == GoProProtocol.RESULT_SUCCESS && _requestedGroup != null) {
                    // The status push confirms it too; this updates the screen without waiting.
                    _presetGroup = _requestedGroup;
                    notifyListener();
                } else if (_requestedGroup == GoProProtocol.PRESET_GROUP_VIDEO) {
                    _videoSwitchFailed = true;
                }
                _requestedGroup = null;
                syncRecording();
            }
            var sleep = GoProProtocol.responseStatus(message, GoProProtocol.CMD_SLEEP);
            if (sleep != null) {
                if (BLE_LOGGING) { log("sleep result=" + sleep); }
                finishSleep(sleep == GoProProtocol.RESULT_SUCCESS);
            }
            var dateTime = GoProProtocol.responseStatus(message, GoProProtocol.CMD_SET_LOCAL_DATE_TIME);
            if (dateTime != null) {
                if (BLE_LOGGING) { log("set local date time result=" + dateTime); }
                // A camera without it (not known by its model): the older command, without the zone.
                if (dateTime != GoProProtocol.RESULT_SUCCESS && _encoding != true) {
                    syncCameraTime(false);
                }
            }
            var plainDateTime = GoProProtocol.responseStatus(message, GoProProtocol.CMD_SET_DATE_TIME);
            if (plainDateTime != null) {
                if (BLE_LOGGING) { log("set date time (no zone) result=" + plainDateTime); }
            }
            var hilight = GoProProtocol.responseStatus(message, GoProProtocol.CMD_HILIGHT_MOMENT);
            if (hilight != null) {
                if (BLE_LOGGING) { log("hilight result=" + hilight); }
                var listener = _hilightListener;
                if (hilight == GoProProtocol.RESULT_SUCCESS && listener != null) {
                    listener.invoke();
                }
            }
        } else if (index == RESPONSE_SETTINGS) {
            var keepAlive = GoProProtocol.responseStatus(message, GoProProtocol.CMD_KEEP_ALIVE);
            if (keepAlive != GoProProtocol.RESULT_SUCCESS) {
                if (BLE_LOGGING) { log("settings response " + GoProProtocol.toHex(message)); }
            }
        } else if (index == RESPONSE_QUERY) {
            var statuses = GoProProtocol.parseStatuses(message);
            if (statuses != null) {
                applyStatuses(statuses, message[0]);
            }
        } else if (index == RESPONSE_NET_MGMT) {
            if (BLE_LOGGING) { log("pairing finish ok=" + GoProProtocol.pairingFinishSucceeded(message)); }
        }
    }

    private function applyStatuses(statuses as Dictionary<Number, Number>, queryId as Number) as Void {
        var wasEncoding = _encoding == true;
        var encoding = statuses[GoProProtocol.STATUS_ENCODING];
        if (encoding != null) {
            _encoding = encoding != 0;
        }
        updateRecordingStart(statuses, queryId, wasEncoding);
        var busy = statuses[GoProProtocol.STATUS_BUSY];
        if (busy != null) {
            _busy = busy != 0;
        }
        var ready = statuses[GoProProtocol.STATUS_READY];
        if (ready != null) {
            _cameraReady = ready != 0;
        }
        var group = statuses[GoProProtocol.STATUS_PRESET_GROUP];
        if (group != null) {
            _presetGroup = group;
        }
        var battery = statuses[GoProProtocol.STATUS_BATTERY_PERCENT];
        if (battery != null) {
            _batteryPercent = battery;
        }
        if (BLE_LOGGING) { log("status encoding=" + _encoding + " busy=" + _busy + " ready=" + _cameraReady + " battery=" + _batteryPercent
            + " group=" + _presetGroup); }
        notifyListener();
        if (_state == BLE_SLEEPING) {
            // sleepCamera waited for a photo to be processed.
            if (wasEncoding && _encoding == false) {
                sendCommand(GoProProtocol.sleep());
            }
            return;
        }
        // Once per connection (the register response), and not mid-video: before any shutter command,
        // so a video started now already carries the watch's time.
        if (queryId == GoProProtocol.QUERY_REGISTER_STATUS && _encoding == false) {
            syncCameraTime(GoProProtocol.hasLocalDateTime(_cameraModel));
        }
        syncRecording();
    }

    // Sets the camera clock to the watch's local time, so videos line up with the activity recording.
    // withZone = false: Set Date Time for HERO9 / HERO10, the same wall-clock time without the zone.
    private function syncCameraTime(withZone as Boolean) as Void {
        var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        if (!withZone) {
            sendCommand(GoProProtocol.setDateTime(now.year as Number, now.month as Number, now.day as Number,
                now.hour, now.min, now.sec));
            return;
        }
        var clock = System.getClockTime();
        // timeZoneOffset is the offset from UTC in seconds. Whether it includes DST is not verified yet
        // (only winter time was tested) [VERIFY in late March: camera clock == watch clock].
        sendCommand(GoProProtocol.setLocalDateTime(now.year as Number, now.month as Number, now.day as Number,
            now.hour, now.min, now.sec, clock.timeZoneOffset / 60, clock.dst != 0));
    }

    // Recording time is counted on the watch: registering status 13 would push it every second.
    private function updateRecordingStart(statuses as Dictionary<Number, Number>, queryId as Number, wasEncoding as Boolean) as Void {
        if (_encoding != true) {
            _recordingStart = null;
            return;
        }
        var now = System.getTimer();
        var duration = statuses[GoProProtocol.STATUS_ENCODING_DURATION];
        if (duration != null) {
            _recordingStart = now - duration * 1000;
            return;
        }
        if (!wasEncoding && queryId == GoProProtocol.QUERY_STATUS_PUSH) {
            // Started while we were watching.
            _recordingStart = now;
            return;
        }
        if (queryId == GoProProtocol.QUERY_REGISTER_STATUS) {
            // Connected (or reconnected) to a camera that is already recording: ask how long for.
            if (_recordingStart == null) {
                _recordingStart = now;
            }
            var query = _query;
            if (query != null) {
                _queue.write(query, GoProProtocol.getStatusValues([GoProProtocol.STATUS_ENCODING_DURATION]));
            }
        }
    }

    // Called by the host about once a second: the watch app from a Timer, the data field from compute().
    function tick() as Void {
        _queue.tick();
        if (_state == BLE_READY) {
            _ticks++;
            if (_ticks % KEEP_ALIVE_TICKS == 0) {
                sendKeepAlive();
                syncRecording();   // retries a refused shutter; does nothing once applied
            }
            if (_encoding == true) {
                notifyListener();
            }
            return;
        }
        var deadline = _deadline;
        if (deadline != null && System.getTimer() - deadline >= 0) {
            _deadline = null;
            onTimeout();
        }
    }

    private function onTimeout() as Void {
        if (_state == BLE_SCANNING && !_wakeCamera) {
            // Waiting for the user to switch the camera on: no time limit, but scan in bursts.
            _scanPaused = !_scanPaused;
            BluetoothLowEnergy.setScanState(_scanPaused ? BluetoothLowEnergy.SCAN_STATE_OFF : BluetoothLowEnergy.SCAN_STATE_SCANNING);
            startTimeout(_scanPaused ? SCAN_PAUSE_MS : SCAN_TIMEOUT_MS);
            return;
        }
        if (BLE_LOGGING) { log("timeout in state " + _state); }
        if (_state == BLE_SLEEPING) {
            finishSleep(false);
        } else if (_state == BLE_ERROR) {
            start();
        } else if (_state == BLE_REGISTERING) {
            fail(BLE_ERROR_PROFILE, "no onProfileRegister");
        } else if (_state == BLE_SCANNING) {
            retryOrFail(BLE_ERROR_NOT_FOUND, "no GoPro advert");
        } else if (_state == BLE_CONNECTING) {
            retryOrFail(BLE_ERROR_CONNECT, "connect timeout");
        } else if (_state == BLE_BONDING) {
            fail(BLE_ERROR_BOND, "timeout");
        } else if (_state == BLE_SUBSCRIBING) {
            retryOrFail(BLE_ERROR_NOTIFY, "subscribe timeout");
        } else if (_state == BLE_WAITING_CAMERA) {
            pollCameraReady();
        }
    }

    private function startReconnect() as Void {
        if (BLE_LOGGING) { log("link lost, looking for the camera again"); }
        var now = System.getTimer();
        _reconnecting = true;
        _cameraAsleep = false;
        _reconnectDeadline = now + RECONNECT_WINDOW_MS;
        _reconnectSettle = now + RECONNECT_SETTLE_MS;
        // Unpair right away. A device that stays paired is reconnected by the system at once
        // (verified on the watch), and that wakes a camera the user has just switched off.
        disconnect();
        startScan();
    }

    // While reconnecting and within the window: start over with a scan for the same camera.
    // Otherwise give up with the error.
    private function retryOrFail(error as BleError, detail as String) as Void {
        if (!_wakeCamera || (_reconnecting && System.getTimer() - _reconnectDeadline < 0)) {
            if (BLE_LOGGING) { log("reconnect: " + detail + ", scanning again"); }
            _queue.clear();
            disconnect();
            startScan();
            return;
        }
        if (_state == BLE_SCANNING) {
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        }
        fail(_reconnecting && _cameraAsleep ? BLE_ERROR_CAMERA_OFF : error, detail);
    }

    // --- helpers ---

    private function startTimeout(ms as Number) as Void {
        _deadline = System.getTimer() + ms;
    }

    private function fail(error as BleError, detail as String?) as Void {
        if (BLE_LOGGING) { log("ERROR " + error + ": " + detail); }
        // Nobody can press START in a data field: try again later on our own.
        _deadline = _wakeCamera ? null : System.getTimer() + ERROR_RETRY_MS;
        _queue.clear();
        _error = error;
        _reconnecting = false;
        _retryBond = error == BLE_ERROR_KEYS_LOST;
        resetCameraStatus();
        // Set the state before disconnecting so the disconnect callback is not treated as a new failure.
        setState(BLE_ERROR);
        disconnect();
    }

    private function disconnect() as Void {
        var device = _device;
        _device = null;
        forgetCharacteristics();
        if (device != null) {
            BluetoothLowEnergy.unpairDevice(device);
        }
    }

    // States where the link is up (or being set up after connect) and GATT failures matter.
    private function isConnectedState() as Boolean {
        return _state == BLE_SUBSCRIBING || _state == BLE_WAITING_CAMERA || _state == BLE_READY;
    }

    private function isEncryptionFailure(status as BluetoothLowEnergy.Status) as Boolean {
        return status == BluetoothLowEnergy.STATUS_GATT_INSUFFICIENT_AUTHENTICATION_FAIL
            || status == BluetoothLowEnergy.STATUS_GATT_INSUFFICIENT_ENCRYPTION_FAIL
            || status == BluetoothLowEnergy.STATUS_ENCRYPTION_BOND_FAIL
            || status == BluetoothLowEnergy.STATUS_ENCRYPTION_PEER_KEYS_LOST
            || status == BluetoothLowEnergy.STATUS_ENCRYPTION_SECURITY_INSUFFICIENT;
    }

    private function forgetCharacteristics() as Void {
        _command = null;
        _settings = null;
        _query = null;
        _netMgmtCommand = null;
    }

    private function resetCameraStatus() as Void {
        _encoding = null;
        _busy = null;
        _cameraReady = null;
        _batteryPercent = null;
        _presetGroup = null;
        _requestedGroup = null;
        _recordingStart = null;
    }

    private function setState(state as BleState) as Void {
        if (state == _state) {
            return;
        }
        if (BLE_LOGGING) { log("state " + _state + " -> " + state); }
        _state = state;
        notifyListener();
    }

    private function notifyListener() as Void {
        var listener = _listener;
        if (listener != null) {
            listener.invoke();
        }
    }

    private function log(message as String) as Void {
        if (BLE_LOGGING) {
            System.println("BLE: " + message);
        }
    }
}
