import Toybox.Lang;
import Toybox.Test;

(:test)
function protocolGetHardwareInfoBytes(logger as Logger) as Boolean {
    assertBytes([0x01, 0x3C]b, GoProProtocol.getHardwareInfo());
    return true;
}

(:test)
function protocolSetShutterBytes(logger as Logger) as Boolean {
    // Spec "Set Shutter": 03 01 01 01 (on), 03 01 01 00 (off)
    assertBytes([0x03, 0x01, 0x01, 0x01]b, GoProProtocol.setShutter(true));
    assertBytes([0x03, 0x01, 0x01, 0x00]b, GoProProtocol.setShutter(false));
    return true;
}

(:test)
function protocolHilightAndKeepAliveBytes(logger as Logger) as Boolean {
    // Spec: Hilight Moment 01 18 (Command), Keep Alive 03 5B 01 42 (Settings)
    assertBytes([0x01, 0x18]b, GoProProtocol.hilightMoment());
    assertBytes([0x03, 0x5B, 0x01, 0x42]b, GoProProtocol.keepAlive());
    Test.assert(GoProProtocol.responseStatus([0x5B, 0x00]b, GoProProtocol.CMD_KEEP_ALIVE) == 0);
    return true;
}

(:test)
function protocolLoadPresetGroupBytes(logger as Logger) as Boolean {
    // Load Preset Group 0x3E with the group as 2 bytes, as GoPro's Python SDK sends it
    assertBytes([0x04, 0x3E, 0x02, 0x03, 0xE8]b, GoProProtocol.loadPresetGroup(GoProProtocol.PRESET_GROUP_VIDEO));
    assertBytes([0x04, 0x3E, 0x02, 0x03, 0xE9]b, GoProProtocol.loadPresetGroup(GoProProtocol.PRESET_GROUP_PHOTO));
    assertBytes([0x04, 0x3E, 0x02, 0x03, 0xEA]b, GoProProtocol.loadPresetGroup(GoProProtocol.PRESET_GROUP_TIMELAPSE));
    return true;
}

(:test)
function protocolNextPresetGroup(logger as Logger) as Boolean {
    Test.assert(GoProProtocol.nextPresetGroup(1000) == 1001);
    Test.assert(GoProProtocol.nextPresetGroup(1001) == 1002);
    Test.assert(GoProProtocol.nextPresetGroup(1002) == 1000);
    Test.assert(GoProProtocol.nextPresetGroup(null) == 1000);
    Test.assert(GoProProtocol.nextPresetGroup(2000) == 1000);
    return true;
}

(:test)
function protocolPresetGroupStatus(logger as Logger) as Boolean {
    // Status 96 as a 4-byte value inside a push: 93 00 60 04 00 00 03 E9 -> photo
    var statuses = GoProProtocol.parseStatuses([0x93, 0x00, 0x60, 0x04, 0x00, 0x00, 0x03, 0xE9]b);
    Test.assert(statuses != null && statuses[GoProProtocol.STATUS_PRESET_GROUP] == GoProProtocol.PRESET_GROUP_PHOTO);
    return true;
}

(:test)
function protocolSetCameraControlBytes(logger as Logger) as Boolean {
    // Protobuf F1 69 { camera_control_status (field 1, varint) }; response F1 E9 08 01 = success
    assertBytes([0x04, 0xF1, 0x69, 0x08, 0x02]b, GoProProtocol.setCameraControl(GoProProtocol.CAMERA_CONTROL_EXTERNAL));
    assertBytes([0x04, 0xF1, 0x69, 0x08, 0x00]b, GoProProtocol.setCameraControl(GoProProtocol.CAMERA_CONTROL_IDLE));
    Test.assert(GoProProtocol.cameraControlSucceeded([0xF1, 0xE9, 0x08, 0x01]b) == true);
    Test.assert(GoProProtocol.cameraControlSucceeded([0xF1, 0xE9, 0x08, 0x02]b) == false);
    Test.assert(GoProProtocol.cameraControlSucceeded([0x02, 0x01, 0x00]b) == null);
    return true;
}

(:test)
function protocolSleepBytes(logger as Logger) as Boolean {
    // Spec "Sleep": command 0x05 without parameters; response 02 05 00
    assertBytes([0x01, 0x05]b, GoProProtocol.sleep());
    Test.assert(GoProProtocol.responseStatus([0x05, 0x00]b, GoProProtocol.CMD_SLEEP) == 0);
    return true;
}

(:test)
function protocolSetLocalDateTimeBytes(logger as Logger) as Boolean {
    // Spec example: "2023-01-31 03:04:05 (utc-02:00) (dst: on)" -> 07 E7 01 1F 03 04 05 FF 88 01
    assertBytes([0x0C, 0x0F, 0x0A, 0x07, 0xE7, 0x01, 0x1F, 0x03, 0x04, 0x05, 0xFF, 0x88, 0x01]b,
        GoProProtocol.setLocalDateTime(2023, 1, 31, 3, 4, 5, -120, true));
    // Positive offset, no DST: UTC+03:00 = 180 min = 00 B4
    assertBytes([0x0C, 0x0F, 0x0A, 0x07, 0xEA, 0x0A, 0x1E, 0x17, 0x3B, 0x00, 0x00, 0xB4, 0x00]b,
        GoProProtocol.setLocalDateTime(2026, 10, 30, 23, 59, 0, 180, false));
    return true;
}

(:test)
function protocolSetDateTimeBytes(logger as Logger) as Boolean {
    // Spec "Set Date Time" (0x0D): "2023-01-31 03:04:05" -> 07:e7:01:1f:03:04:05
    assertBytes([0x09, 0x0D, 0x07, 0x07, 0xE7, 0x01, 0x1F, 0x03, 0x04, 0x05]b,
        GoProProtocol.setDateTime(2023, 1, 31, 3, 4, 5));
    return true;
}

(:test)
function protocolHardwareModel(logger as Logger) as Boolean {
    // Start of the HERO12 answer from the watch log (2026-10-29): 3C 00, model number 00 00 00 3E
    Test.assert(GoProProtocol.hardwareModel([0x3C, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3E, 0x0C]b) == 62);
    Test.assert(GoProProtocol.hardwareModel([0x3C, 0x01, 0x04, 0x00, 0x00, 0x00, 0x3E]b) == null);   // error status
    Test.assert(GoProProtocol.hardwareModel([0x3C, 0x00, 0x04, 0x00, 0x00]b) == null);               // truncated
    Test.assert(GoProProtocol.hardwareModel([0x01, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3E]b) == null);   // other command
    // Only HERO9 (55) and HERO10 (57) lack Set Local Date Time; unknown model: try it
    Test.assert(!GoProProtocol.hasLocalDateTime(55));
    Test.assert(!GoProProtocol.hasLocalDateTime(57));
    Test.assert(GoProProtocol.hasLocalDateTime(62));
    Test.assert(GoProProtocol.hasLocalDateTime(null));
    return true;
}

(:test)
function protocolRegisterStatusUpdatesBytes(logger as Logger) as Boolean {
    // Busy (8), Encoding (10), Battery % (70), Ready (82)
    assertBytes([0x05, 0x53, 0x08, 0x0A, 0x46, 0x52]b,
        GoProProtocol.registerStatusUpdates([8, 10, 70, 82]));
    return true;
}

(:test)
function protocolPairingFinishBytes(logger as Logger) as Boolean {
    // Spec example with phoneName "Watch": 0B 03 01 08 00 12 05 57 61 74 63 68
    assertBytes([0x0B, 0x03, 0x01, 0x08, 0x00, 0x12, 0x05, 0x57, 0x61, 0x74, 0x63, 0x68]b,
        GoProProtocol.pairingFinish("Watch"));
    return true;
}

(:test)
function protocolPairingFinishResponse(logger as Logger) as Boolean {
    Test.assert(GoProProtocol.pairingFinishSucceeded([0x03, 0x81, 0x08, 0x01]b) == true);
    Test.assert(GoProProtocol.pairingFinishSucceeded([0x03, 0x81, 0x08, 0x02]b) == false);
    Test.assert(GoProProtocol.pairingFinishSucceeded([0x03, 0x81]b) == false);
    Test.assert(GoProProtocol.pairingFinishSucceeded([0x01, 0x00]b) == null);
    return true;
}

(:test)
function protocolParseStatusesRegisterResponse(logger as Logger) as Boolean {
    // 53 00 | 08 01 00 | 0A 01 01 | 46 01 5A | 52 01 01
    var s = GoProProtocol.parseStatuses([0x53, 0x00, 0x08, 0x01, 0x00, 0x0A, 0x01, 0x01, 0x46, 0x01, 0x5A, 0x52, 0x01, 0x01]b);
    Test.assert(s != null);
    var statuses = s as Dictionary<Number, Number>;
    Test.assert(statuses[GoProProtocol.STATUS_BUSY] == 0);
    Test.assert(statuses[GoProProtocol.STATUS_ENCODING] == 1);
    Test.assert(statuses[GoProProtocol.STATUS_BATTERY_PERCENT] == 90);
    Test.assert(statuses[GoProProtocol.STATUS_READY] == 1);
    return true;
}

(:test)
function protocolParseStatusesRealHero12(logger as Logger) as Boolean {
    // Captured from a HERO12 Black: register response, then the push after Set Shutter on.
    var s = GoProProtocol.parseStatuses([0x53, 0x00, 0x08, 0x01, 0x00, 0x0A, 0x01, 0x00, 0x46, 0x01, 0x56, 0x52, 0x01, 0x01]b);
    var statuses = s as Dictionary<Number, Number>;
    Test.assert(statuses[GoProProtocol.STATUS_ENCODING] == 0);
    Test.assert(statuses[GoProProtocol.STATUS_BATTERY_PERCENT] == 86);
    Test.assert(statuses[GoProProtocol.STATUS_READY] == 1);

    // Pushes carry only the changed statuses; the camera is busy while encoding.
    var push = GoProProtocol.parseStatuses([0x93, 0x00, 0x08, 0x01, 0x01, 0x0A, 0x01, 0x01]b) as Dictionary<Number, Number>;
    Test.assertEqual(push.size(), 2);
    Test.assert(push[GoProProtocol.STATUS_BUSY] == 1);
    Test.assert(push[GoProProtocol.STATUS_ENCODING] == 1);
    return true;
}

(:test)
function protocolParseStatusesPush(logger as Logger) as Boolean {
    var s = GoProProtocol.parseStatuses([0x93, 0x00, 0x0A, 0x01, 0x00]b);
    Test.assert(s != null);
    Test.assert((s as Dictionary<Number, Number>)[GoProProtocol.STATUS_ENCODING] == 0);
    return true;
}

(:test)
function protocolParseStatusesMultiByteAndUnknown(logger as Logger) as Boolean {
    // 4-byte big-endian value, unknown id 200, then a 6-byte value that is skipped
    var s = GoProProtocol.parseStatuses([0x93, 0x00, 0x0D, 0x04, 0x00, 0x00, 0x01, 0x2C, 0xC8, 0x01, 0x07, 0x1E, 0x06, 1, 2, 3, 4, 5, 6, 0x46, 0x01, 0x32]b);
    var statuses = s as Dictionary<Number, Number>;
    Test.assert(statuses[13] == 300);
    Test.assert(statuses[200] == 7);
    Test.assert(!statuses.hasKey(0x1E));
    Test.assert(statuses[GoProProtocol.STATUS_BATTERY_PERCENT] == 50);
    return true;
}

(:test)
function protocolParseStatusesTruncatedTail(logger as Logger) as Boolean {
    // last entry claims 4 bytes but only 1 is there: keep what was parsed, ignore the tail
    var s = GoProProtocol.parseStatuses([0x53, 0x00, 0x0A, 0x01, 0x01, 0x46, 0x04, 0x01]b);
    var statuses = s as Dictionary<Number, Number>;
    Test.assert(statuses[GoProProtocol.STATUS_ENCODING] == 1);
    Test.assert(!statuses.hasKey(GoProProtocol.STATUS_BATTERY_PERCENT));
    return true;
}

(:test)
function protocolParseStatusesRejectsOthers(logger as Logger) as Boolean {
    Test.assert(GoProProtocol.parseStatuses([0x53, 0x01, 0x0A, 0x01, 0x01]b) == null);   // error status
    Test.assert(GoProProtocol.parseStatuses([0x32, 0x00, 0x0A, 0x01, 0x01]b) == null);   // other query
    Test.assert(GoProProtocol.parseStatuses([0x53]b) == null);
    return true;
}

(:test)
function protocolGetStatusValuesEncodingDuration(logger as Logger) as Boolean {
    // Get Status Values for status 13: 02 13 0D; response 13 00 0D 04 <4-byte seconds>
    assertBytes([0x02, 0x13, 0x0D]b, GoProProtocol.getStatusValues([GoProProtocol.STATUS_ENCODING_DURATION]));
    var s = GoProProtocol.parseStatuses([0x13, 0x00, 0x0D, 0x04, 0x00, 0x00, 0x01, 0x2D]b) as Dictionary<Number, Number>;
    Test.assert(s[GoProProtocol.STATUS_ENCODING_DURATION] == 301);
    return true;
}


// Advertising data laid out as in the spec (schema 2): Flags | 16-bit UUIDs (FEA6) | Manufacturer Data
function advertWithStatus(company0 as Number, company1 as Number, status as Number) as ByteArray {
    return [
        0x02, 0x01, 0x06,
        0x03, 0x02, 0xA6, 0xFE,
        0x0F, 0xFF, company0, company1, 0x02, status, 0x3E, 0x3F,
        0, 0, 0, 0, 0, 0, 0,
        0x0C
    ]b;
}

(:test)
function protocolAdvertCameraStatus(logger as Logger) as Boolean {
    // Camera status sits at byte 12 per the spec table
    Test.assert(advertWithStatus(0xF2, 0x02, 0x01)[12] == 0x01);
    Test.assert(GoProProtocol.advertCameraStatus(advertWithStatus(0xF2, 0x02, 0x01)) == 0x01);
    Test.assert(GoProProtocol.advertCameraStatus(advertWithStatus(0x02, 0xF2, 0x04)) == 0x04);
    return true;
}

(:test)
function protocolAdvertCameraStatusAsleepAndAwake(logger as Logger) as Boolean {
    var asleep = GoProProtocol.advertCameraStatus(advertWithStatus(0xF2, 0x02, 0x00)) as Number;
    var awakePairing = GoProProtocol.advertCameraStatus(advertWithStatus(0xF2, 0x02, 0x05)) as Number;
    Test.assert((asleep & GoProProtocol.ADVERT_STATUS_AWAKE) == 0);
    Test.assert((awakePairing & GoProProtocol.ADVERT_STATUS_AWAKE) != 0);
    Test.assert((awakePairing & GoProProtocol.ADVERT_STATUS_PAIRING) != 0);
    return true;
}

(:test)
function protocolAdvertCameraStatusMissingOrMalformed(logger as Logger) as Boolean {
    // Other company ID
    Test.assert(GoProProtocol.advertCameraStatus(advertWithStatus(0x4C, 0x00, 0x01)) == null);
    // No manufacturer data at all
    Test.assert(GoProProtocol.advertCameraStatus([0x02, 0x01, 0x06, 0x03, 0x02, 0xA6, 0xFE]b) == null);
    // Length runs past the end
    Test.assert(GoProProtocol.advertCameraStatus([0x02, 0x01, 0x06, 0x0F, 0xFF, 0xF2, 0x02]b) == null);
    // Zero length terminates
    Test.assert(GoProProtocol.advertCameraStatus([0x00, 0xFF, 0xF2, 0x02, 0x02, 0x01]b) == null);
    Test.assert(GoProProtocol.advertCameraStatus([]b) == null);
    return true;
}

(:test)
function protocolResponseStatusSuccess(logger as Logger) as Boolean {
    // Get Hardware Info response starts with 3C 00, followed by TLV data
    Test.assert(GoProProtocol.responseStatus([0x3C, 0x00, 0x04, 0x00]b, GoProProtocol.CMD_GET_HARDWARE_INFO) == 0);
    return true;
}

(:test)
function protocolResponseStatusError(logger as Logger) as Boolean {
    Test.assert(GoProProtocol.responseStatus([0x01, 0x02]b, 0x01) == 2);
    return true;
}

(:test)
function protocolResponseStatusOtherId(logger as Logger) as Boolean {
    Test.assert(GoProProtocol.responseStatus([0x01, 0x00]b, GoProProtocol.CMD_GET_HARDWARE_INFO) == null);
    return true;
}

(:test)
function protocolResponseStatusTooShort(logger as Logger) as Boolean {
    Test.assert(GoProProtocol.responseStatus([0x3C]b, GoProProtocol.CMD_GET_HARDWARE_INFO) == null);
    Test.assert(GoProProtocol.responseStatus([]b, GoProProtocol.CMD_GET_HARDWARE_INFO) == null);
    return true;
}

(:test)
function protocolToHex(logger as Logger) as Boolean {
    Test.assertEqual(GoProProtocol.toHex([0x03, 0x5B, 0x01, 0x42]b), "03 5B 01 42");
    Test.assertEqual(GoProProtocol.toHex([]b), "");
    return true;
}
