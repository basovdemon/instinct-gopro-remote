import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;

typedef BleWriteTarget as BluetoothLowEnergy.Characteristic or BluetoothLowEnergy.Descriptor;

// Serializes GATT writes: Connect IQ handles one outstanding request at a time, so the next
// write is issued only after the previous one's callback (or a timeout).
// The owner must call onComplete() from BleDelegate.onCharacteristicWrite / onDescriptorWrite,
// and tick() about once a second to detect timeouts (no Timer: data fields cannot use one).
class BleQueue {

    private const TIMEOUT_MS = 3000;

    private var _targets as Array<BleWriteTarget> = [];
    private var _values as Array<ByteArray> = [];
    private var _inFlight as Boolean = false;
    private var _deadline as Number = 0;   // System.getTimer() value, valid while _inFlight

    function write(characteristic as BluetoothLowEnergy.Characteristic, value as ByteArray) as Void {
        enqueue(characteristic, value);
    }

    function writeDescriptor(descriptor as BluetoothLowEnergy.Descriptor, value as ByteArray) as Void {
        enqueue(descriptor, value);
    }

    function onComplete() as Void {
        _inFlight = false;
        pump();
    }

    function clear() as Void {
        _targets = [];
        _values = [];
        _inFlight = false;
    }

    function tick() as Void {
        if (_inFlight && System.getTimer() - _deadline >= 0) {
            if (BLE_LOGGING) { System.println("BleQueue: write timed out, moving on"); }
            _inFlight = false;
            pump();
        }
    }

    private function enqueue(target as BleWriteTarget, value as ByteArray) as Void {
        _targets.add(target);
        _values.add(value);
        pump();
    }

    private function pump() as Void {
        while (!_inFlight && _targets.size() > 0) {
            var target = _targets[0];
            var value = _values[0];
            _targets = _targets.slice(1, null);
            _values = _values.slice(1, null);
            try {
                if (target instanceof BluetoothLowEnergy.Characteristic) {
                    // WRITE_TYPE_DEFAULT is write *without* response; we need the callback to advance.
                    target.requestWrite(value, {:writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE});
                } else {
                    target.requestWrite(value);
                }
                _inFlight = true;
                _deadline = System.getTimer() + TIMEOUT_MS;
            } catch (e instanceof BluetoothLowEnergy.InvalidRequestException) {
                if (BLE_LOGGING) { System.println("BleQueue: write rejected: " + e.getErrorMessage()); }
            }
        }
    }
}
