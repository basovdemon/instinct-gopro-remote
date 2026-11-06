import Toybox.BluetoothLowEnergy;
import Toybox.Lang;

typedef BleProfile as {
    :uuid as BluetoothLowEnergy.Uuid,
    :characteristics as Array<{ :uuid as BluetoothLowEnergy.Uuid, :descriptors as Array<BluetoothLowEnergy.Uuid> }>
};

// Open GoPro BLE UUIDs, verified against the spec ("BLE Setup" -> characteristics).
// GP-XXXX = b5f9XXXX-aa8d-11e3-9046-0002a5d5c51b
module GoProUuids {

    // "Control & Query" service: the 16-bit UUID 0xFEA6 in Bluetooth base UUID form.
    const SERVICE = "0000FEA6-0000-1000-8000-00805F9B34FB";

    const COMMAND = "B5F90072-AA8D-11E3-9046-0002A5D5C51B";
    const COMMAND_RESPONSE = "B5F90073-AA8D-11E3-9046-0002A5D5C51B";
    const SETTINGS = "B5F90074-AA8D-11E3-9046-0002A5D5C51B";
    const SETTINGS_RESPONSE = "B5F90075-AA8D-11E3-9046-0002A5D5C51B";
    const QUERY = "B5F90076-AA8D-11E3-9046-0002A5D5C51B";
    const QUERY_RESPONSE = "B5F90077-AA8D-11E3-9046-0002A5D5C51B";

    // "Camera Management" service, used for Set Pairing State after the first bond.
    const NET_MGMT_SERVICE = "B5F90090-AA8D-11E3-9046-0002A5D5C51B";
    const NET_MGMT_COMMAND = "B5F90091-AA8D-11E3-9046-0002A5D5C51B";
    const NET_MGMT_RESPONSE = "B5F90092-AA8D-11E3-9046-0002A5D5C51B";

    function uuid(s as String) as BluetoothLowEnergy.Uuid {
        return BluetoothLowEnergy.stringToUuid(s);
    }

    // Connect IQ allows 3 profiles; we register these two. Notify characteristics get a CCCD.
    function profiles() as Array<BleProfile> {
        return [controlProfile(), netMgmtProfile()];
    }

    function netMgmtProfile() as BleProfile {
        return {
            :uuid => uuid(NET_MGMT_SERVICE),
            :characteristics => [
                { :uuid => uuid(NET_MGMT_COMMAND), :descriptors => [] as Array<BluetoothLowEnergy.Uuid> },
                { :uuid => uuid(NET_MGMT_RESPONSE), :descriptors => [BluetoothLowEnergy.cccdUuid()] }
            ]
        };
    }

    function controlProfile() as BleProfile {
        var cccd = [BluetoothLowEnergy.cccdUuid()];
        return {
            :uuid => uuid(SERVICE),
            :characteristics => [
                { :uuid => uuid(COMMAND), :descriptors => [] as Array<BluetoothLowEnergy.Uuid> },
                { :uuid => uuid(COMMAND_RESPONSE), :descriptors => cccd },
                { :uuid => uuid(SETTINGS), :descriptors => [] as Array<BluetoothLowEnergy.Uuid> },
                { :uuid => uuid(SETTINGS_RESPONSE), :descriptors => cccd },
                { :uuid => uuid(QUERY), :descriptors => [] as Array<BluetoothLowEnergy.Uuid> },
                { :uuid => uuid(QUERY_RESPONSE), :descriptors => cccd }
            ]
        };
    }
}
