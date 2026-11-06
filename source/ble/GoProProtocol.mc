import Toybox.Lang;

// Open GoPro BLE message building and parsing. No BLE or UI dependencies.
// Byte values verified against https://gopro.github.io/OpenGoPro/ and its references.json
// (see AGENTS.md -> Open GoPro protocol).
module GoProProtocol {

    // TLV command IDs (Command characteristic)
    const CMD_SET_SHUTTER = 0x01;
    const CMD_SLEEP = 0x05;
    const CMD_SET_DATE_TIME = 0x0D;          // without time zone: the only one on HERO9 / HERO10
    const CMD_SET_LOCAL_DATE_TIME = 0x0F;    // HERO11 and newer
    const CMD_HILIGHT_MOMENT = 0x18;
    const CMD_GET_HARDWARE_INFO = 0x3C;
    const CMD_LOAD_PRESET_GROUP = 0x3E;

    // EnumPresetGroup (spec protos); also the values of STATUS_PRESET_GROUP
    const PRESET_GROUP_VIDEO = 1000;
    const PRESET_GROUP_PHOTO = 1001;
    const PRESET_GROUP_TIMELAPSE = 1002;

    // Keep Alive goes to the Settings characteristic (it is an operation, not setting 91).
    const CMD_KEEP_ALIVE = 0x5B;
    const KEEP_ALIVE_VALUE = 0x42;

    // Query IDs (Query characteristic)
    const QUERY_GET_STATUS = 0x13;
    const QUERY_REGISTER_STATUS = 0x53;
    const QUERY_STATUS_PUSH = 0x93;    // asynchronous updates after QUERY_REGISTER_STATUS

    // Status IDs, 1-byte values on HERO12
    const STATUS_BUSY = 8;
    const STATUS_ENCODING = 10;
    const STATUS_ENCODING_DURATION = 13;   // seconds of the current video, 0 when not encoding
    const STATUS_BATTERY_PERCENT = 70;
    const STATUS_READY = 82;
    const STATUS_PRESET_GROUP = 96;        // current preset group: PRESET_GROUP_*

    const RESULT_SUCCESS = 0;

    // Model numbers from Get Hardware Info (references.json -> cameras -> id)
    const MODEL_HERO9 = 55;
    const MODEL_HERO10 = 57;

    // Advertisement Manufacturer Data, Camera Status byte (spec "BLE Setup" -> Advertising Data)
    const ADVERT_STATUS_AWAKE = 0x01;      // bit 0: processor state, 0 = low power (asleep)
    const ADVERT_STATUS_PAIRING = 0x04;    // bit 2: peripheral pairing state

    // Protobuf: Set Pairing State (feature 0x03, action 0x01) -> Net Mgmt Command (GP-0091);
    // response feature 0x03, action 0x81 + ResponseGeneric on GP-0092.
    const FEATURE_NETWORK_MANAGEMENT = 0x03;
    const ACTION_PAIRING_FINISH = 0x01;
    const ACTION_PAIRING_FINISH_RESPONSE = 0x81;
    const PROTOBUF_RESULT_SUCCESS = 1;   // EnumResultGeneric.RESULT_SUCCESS

    // Protobuf: Set Camera Control (feature 0xF1, action 0x69) -> Command (GP-0072);
    // response 0xF1 / 0xE9 + ResponseGeneric on GP-0073. EnumCameraControlStatus values:
    const FEATURE_COMMAND = 0xF1;
    const ACTION_SET_CAMERA_CONTROL = 0x69;
    const ACTION_SET_CAMERA_CONTROL_RESPONSE = 0xE9;
    const CAMERA_CONTROL_IDLE = 0;
    const CAMERA_CONTROL_EXTERNAL = 2;

    // All builders return complete single-packet messages: the first byte is the
    // general 5-bit header (= payload length), so the result must stay <= 20 bytes.

    // Get Hardware Info. The spec recommends polling it after connecting until it returns
    // success: that means the camera is ready to accept commands.
    function getHardwareInfo() as ByteArray {
        return [0x01, CMD_GET_HARDWARE_INFO]b;
    }

    function setShutter(on as Boolean) as ByteArray {
        return [0x03, CMD_SET_SHUTTER, 0x01, on ? 0x01 : 0x00]b;
    }

    // Set Local Date Time: local wall-clock time, then the UTC offset in minutes (int16) and a DST flag.
    // Gives video files the same clock as the watch's activity recording.
    function setLocalDateTime(year as Number, month as Number, day as Number, hour as Number,
            minute as Number, second as Number, utcOffsetMinutes as Number, dst as Boolean) as ByteArray {
        var offset = utcOffsetMinutes & 0xFFFF;
        return [0x0C, CMD_SET_LOCAL_DATE_TIME, 0x0A,
            (year >> 8) & 0xFF, year & 0xFF, month, day, hour, minute, second,
            offset >> 8, offset & 0xFF, dst ? 0x01 : 0x00]b;
    }

    // Set Date Time: the same local wall-clock time without the time zone, for cameras that lack
    // Set Local Date Time (HERO9, HERO10 per the spec's camera lists).
    function setDateTime(year as Number, month as Number, day as Number, hour as Number,
            minute as Number, second as Number) as ByteArray {
        return [0x09, CMD_SET_DATE_TIME, 0x07,
            (year >> 8) & 0xFF, year & 0xFF, month, day, hour, minute, second]b;
    }

    // Whether the camera has Set Local Date Time; true while the model is unknown (null).
    function hasLocalDateTime(model as Number?) as Boolean {
        return model != MODEL_HERO9 && model != MODEL_HERO10;
    }

    // Model number from a successful Get Hardware Info response: [3C, status, len, value...],
    // the first field (4 bytes) is the model number (HERO12: 00 00 00 3E = 62). Null otherwise.
    function hardwareModel(payload as ByteArray) as Number? {
        if (payload.size() < 7 || payload[0] != CMD_GET_HARDWARE_INFO || payload[1] != RESULT_SUCCESS || payload[2] != 4) {
            return null;
        }
        return (payload[3] << 24) | (payload[4] << 16) | (payload[5] << 8) | payload[6];
    }

    // Puts the camera to sleep; it stays connectable over BLE (and keeps advertising).
    function sleep() as ByteArray {
        return [0x01, CMD_SLEEP]b;
    }

    // Load Preset Group: the camera switches to the group's last used preset.
    // The spec page lists the parameter as uint32, but GoPro's Python SDK sends 2 bytes (Int16ub);
    // we follow the SDK. Verified on HERO12 (2026-11-02): the camera answers 02 3E 00.
    function loadPresetGroup(group as Number) as ByteArray {
        return [0x04, CMD_LOAD_PRESET_GROUP, 0x02, (group >> 8) & 0xFF, group & 0xFF]b;
    }

    // Video -> photo -> time lapse -> video; video when the current group is unknown or another one.
    function nextPresetGroup(current as Number?) as Number {
        if (current == PRESET_GROUP_VIDEO) {
            return PRESET_GROUP_PHOTO;
        }
        if (current == PRESET_GROUP_PHOTO) {
            return PRESET_GROUP_TIMELAPSE;
        }
        return PRESET_GROUP_VIDEO;
    }

    // Only valid while encoding.
    function hilightMoment() as ByteArray {
        return [0x01, CMD_HILIGHT_MOMENT]b;
    }

    // Send every 3 s while connected, or the camera goes to sleep. Settings characteristic.
    function keepAlive() as ByteArray {
        return [0x03, CMD_KEEP_ALIVE, 0x01, KEEP_ALIVE_VALUE]b;
    }

    // Register for value updates of the given statuses (Query characteristic).
    function registerStatusUpdates(statusIds as Array<Number>) as ByteArray {
        return statusQuery(QUERY_REGISTER_STATUS, statusIds);
    }

    // One-off read of the given statuses (Query characteristic).
    function getStatusValues(statusIds as Array<Number>) as ByteArray {
        return statusQuery(QUERY_GET_STATUS, statusIds);
    }

    function statusQuery(queryId as Number, statusIds as Array<Number>) as ByteArray {
        var message = [1 + statusIds.size(), queryId]b;
        for (var i = 0; i < statusIds.size(); i++) {
            message.add(statusIds[i]);
        }
        return message;
    }

    // RequestPairingFinish { result = SUCCESS (0); phoneName = name }.
    // phoneName must be non-empty; the camera does not use it.
    function pairingFinish(name as String) as ByteArray {
        var chars = name.toUtf8Array();
        var payload = [FEATURE_NETWORK_MANAGEMENT, ACTION_PAIRING_FINISH, 0x08, 0x00, 0x12, chars.size()]b;
        for (var i = 0; i < chars.size(); i++) {
            payload.add(chars[i]);
        }
        return [payload.size()]b.addAll(payload);
    }

    // RequestSetCameraControlStatus { camera_control_status = status }: the spec asks third-party
    // clients to claim control (EXTERNAL) so the camera and the client do not fight over it.
    function setCameraControl(status as Number) as ByteArray {
        return [0x04, FEATURE_COMMAND, ACTION_SET_CAMERA_CONTROL, 0x08, status]b;
    }

    // Reassembled TLV response payload is [id, status, ...].
    // Returns the status for the expected id, or null if the payload is for another id or too short.
    function responseStatus(payload as ByteArray, id as Number) as Number? {
        if (payload.size() < 2 || payload[0] != id) {
            return null;
        }
        return payload[1];
    }

    // Parses a status query response or push: [query id, status, {id, len, value}...].
    // Returns {status id => value} or null if this is not a successful status message.
    // Values are big-endian unsigned; unknown IDs are kept, malformed tails are ignored.
    function parseStatuses(payload as ByteArray) as Dictionary<Number, Number>? {
        if (payload.size() < 2) {
            return null;
        }
        var queryId = payload[0];
        if (queryId != QUERY_REGISTER_STATUS && queryId != QUERY_STATUS_PUSH && queryId != QUERY_GET_STATUS) {
            return null;
        }
        if (payload[1] != RESULT_SUCCESS) {
            return null;
        }
        var statuses = {} as Dictionary<Number, Number>;
        var i = 2;
        while (i + 2 <= payload.size()) {
            var id = payload[i];
            var length = payload[i + 1];
            var start = i + 2;
            if (start + length > payload.size()) {
                break;
            }
            // Longer values (strings, 64-bit) do not fit a Number and are not needed for the MVP.
            if (length >= 1 && length <= 4) {
                var value = 0;
                for (var j = start; j < start + length; j++) {
                    value = (value << 8) | payload[j];
                }
                statuses[id] = value;
            }
            i = start + length;
        }
        return statuses;
    }

    // Returns true if a reassembled Net Mgmt message is a successful Set Pairing State response,
    // false if it is that response with an error, null if it is something else.
    function pairingFinishSucceeded(payload as ByteArray) as Boolean? {
        return protobufSucceeded(payload, FEATURE_NETWORK_MANAGEMENT, ACTION_PAIRING_FINISH_RESPONSE);
    }

    // Same for a Set Camera Control response.
    function cameraControlSucceeded(payload as ByteArray) as Boolean? {
        return protobufSucceeded(payload, FEATURE_COMMAND, ACTION_SET_CAMERA_CONTROL_RESPONSE);
    }

    // [feature, action, ResponseGeneric...]: true / false for that response, null for anything else.
    function protobufSucceeded(payload as ByteArray, feature as Number, action as Number) as Boolean? {
        if (payload.size() < 2 || payload[0] != feature || payload[1] != action) {
            return null;
        }
        // ResponseGeneric: field 1 (varint) = result
        return payload.size() >= 4 && payload[2] == 0x08 && payload[3] == PROTOBUF_RESULT_SUCCESS;
    }

    // Finds the GoPro Manufacturer Data AD structure in raw advertising data and returns its
    // Camera Status byte: [len][0xFF][company ID, 2 bytes][schema version][camera status]...
    // Returns null if there is no such structure. The spec writes the company ID as 0xF202
    // without saying which byte order it means on air, so both orders are accepted.
    function advertCameraStatus(raw as ByteArray) as Number? {
        var i = 0;
        while (i + 1 < raw.size()) {
            var length = raw[i];
            if (length == 0) {
                break;
            }
            var end = i + 1 + length;
            if (end > raw.size()) {
                break;
            }
            if (raw[i + 1] == 0xFF && length >= 5) {
                var c0 = raw[i + 2];
                var c1 = raw[i + 3];
                if ((c0 == 0xF2 && c1 == 0x02) || (c0 == 0x02 && c1 == 0xF2)) {
                    return raw[i + 5];
                }
            }
            i = end;
        }
        return null;
    }

    function toHex(bytes as ByteArray) as String {
        var s = "";
        for (var i = 0; i < bytes.size(); i++) {
            if (i > 0) {
                s += " ";
            }
            s += bytes[i].format("%02X");
        }
        return s;
    }
}
