import Toybox.Lang;
import Toybox.Test;

// Packet examples follow the header formats from the Open GoPro spec ("Packetization").

function bytesOf(n as Number, first as Number) as ByteArray {
    var b = []b;
    for (var i = 0; i < n; i++) {
        b.add((first + i) & 0xFF);
    }
    return b;
}

function ascii(s as String) as ByteArray {
    var chars = s.toUtf8Array();
    var b = []b;
    for (var i = 0; i < chars.size(); i++) {
        b.add(chars[i]);
    }
    return b;
}

function assertBytes(expected as ByteArray, actual as ByteArray?) as Void {
    Test.assertMessage(actual != null, "expected a complete message, got null");
    var a = actual as ByteArray;
    Test.assertEqualMessage(a.size(), expected.size(), "size mismatch: " + GoProProtocol.toHex(a));
    for (var i = 0; i < expected.size(); i++) {
        Test.assertEqualMessage(a[i], expected[i], "byte " + i + ": " + GoProProtocol.toHex(a));
    }
}

(:test)
function packetGeneralHeaderSinglePacket(logger as Logger) as Boolean {
    // Set Shutter response: 02 01 00
    var asm = new PacketAssembler();
    assertBytes([0x01, 0x00]b, asm.accept([0x02, 0x01, 0x00]b));
    Test.assert(!asm.isPending());
    return true;
}

(:test)
function packetZeroLength(logger as Logger) as Boolean {
    var asm = new PacketAssembler();
    assertBytes([]b, asm.accept([0x00]b));
    return true;
}

(:test)
function packetEmptyNotificationIgnored(logger as Logger) as Boolean {
    var asm = new PacketAssembler();
    Test.assert(asm.accept([]b) == null);
    return true;
}

(:test)
function packetExtended13BitAcrossTwoPackets(logger as Logger) as Boolean {
    // 30-byte message: 2-byte header + 18 bytes, then continuation 0x80 + 12 bytes
    var payload = bytesOf(30, 0x10);
    var first = [0x20, 0x1E]b.addAll(payload.slice(0, 18));
    var second = [0x80]b.addAll(payload.slice(18, null));
    var asm = new PacketAssembler();
    Test.assert(asm.accept(first) == null);
    Test.assert(asm.isPending());
    assertBytes(payload, asm.accept(second));
    Test.assert(!asm.isPending());
    return true;
}

(:test)
function packetExtended16Bit(logger as Logger) as Boolean {
    // 16-bit header 0x40 LL LL, 20-byte message: 17 bytes in the first packet, 3 in the next
    var payload = bytesOf(20, 0x00);
    var first = [0x40, 0x00, 0x14]b.addAll(payload.slice(0, 17));
    var second = [0x80]b.addAll(payload.slice(17, null));
    var asm = new PacketAssembler();
    Test.assert(asm.accept(first) == null);
    assertBytes(payload, asm.accept(second));
    return true;
}

(:test)
function packetGeneralHeaderWithContinuation(logger as Logger) as Boolean {
    // General header allows up to 31 bytes, so it can also span packets
    var payload = bytesOf(25, 0xA0);
    var first = [0x19]b.addAll(payload.slice(0, 19));
    var second = [0x80]b.addAll(payload.slice(19, null));
    var asm = new PacketAssembler();
    Test.assert(asm.accept(first) == null);
    assertBytes(payload, asm.accept(second));
    return true;
}

(:test)
function packetContinuationCounterWraps(logger as Logger) as Boolean {
    // 18 bytes in the first packet + 18 continuation packets of 19 bytes: counter goes 0..F, 0, 1
    var length = 18 + 18 * 19;
    var payload = bytesOf(length, 0x00);
    var asm = new PacketAssembler();
    Test.assert(asm.accept([0x20 | (length >> 8), length & 0xFF]b.addAll(payload.slice(0, 18))) == null);
    var result = null;
    for (var i = 0; i < 18; i++) {
        var start = 18 + i * 19;
        result = asm.accept([0x80 | (i & 0x0F)]b.addAll(payload.slice(start, start + 19)));
        if (i < 17) {
            Test.assert(result == null);
        }
    }
    assertBytes(payload, result);
    return true;
}

(:test)
function packetRealHero12HardwareInfo(logger as Logger) as Boolean {
    // Get Hardware Info response captured from a HERO12 Black (serial, AP SSID and MAC zeroed),
    // split exactly as the camera sent it: 13-bit header 20 5B (91 bytes) + continuations 80..83.
    var message = [0x3C, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3E, 0x0C]b;
    message.addAll(ascii("HERO12 Black"));
    message.add(0x04);
    message.addAll(ascii("0x05"));
    message.add(0x0F);
    message.addAll(ascii("H23.01.02.40.00"));
    message.add(0x0E);
    message.addAll(ascii("C3500000000000"));
    message.add(0x0A);
    message.addAll(ascii("GoPro00000"));
    message.add(0x0C);
    message.addAll(ascii("000000000000"));
    message.addAll([0x01, 0x00, 0x01, 0x01, 0x01, 0x00, 0x02, 0x5B, 0x5D, 0x01, 0x01]b);
    Test.assertEqual(message.size(), 91);

    var asm = new PacketAssembler();
    Test.assert(asm.accept([0x20, 0x5B]b.addAll(message.slice(0, 18))) == null);
    Test.assert(asm.accept([0x80]b.addAll(message.slice(18, 37))) == null);
    Test.assert(asm.accept([0x81]b.addAll(message.slice(37, 56))) == null);
    Test.assert(asm.accept([0x82]b.addAll(message.slice(56, 75))) == null);
    var result = asm.accept([0x83]b.addAll(message.slice(75, null)));
    assertBytes(message, result);
    Test.assert(GoProProtocol.responseStatus(result as ByteArray, GoProProtocol.CMD_GET_HARDWARE_INFO) == GoProProtocol.RESULT_SUCCESS);
    return true;
}

(:test)
function packetContinuationWithoutStartIgnored(logger as Logger) as Boolean {
    var asm = new PacketAssembler();
    Test.assert(asm.accept([0x80, 0x01, 0x02]b) == null);
    Test.assert(!asm.isPending());
    return true;
}

(:test)
function packetCounterMismatchDropsMessage(logger as Logger) as Boolean {
    var payload = bytesOf(30, 0x00);
    var asm = new PacketAssembler();
    asm.accept([0x20, 0x1E]b.addAll(payload.slice(0, 18)));
    // expected counter 0, got 1: a packet was lost
    Test.assert(asm.accept([0x81]b.addAll(payload.slice(18, null))) == null);
    Test.assert(!asm.isPending());
    return true;
}

(:test)
function packetNewStartReplacesPendingMessage(logger as Logger) as Boolean {
    var asm = new PacketAssembler();
    asm.accept([0x20, 0x1E]b.addAll(bytesOf(18, 0x00)));
    assertBytes([0x13, 0x00]b, asm.accept([0x02, 0x13, 0x00]b));
    Test.assert(!asm.isPending());
    return true;
}

(:test)
function packetTrailingBytesTruncated(logger as Logger) as Boolean {
    var asm = new PacketAssembler();
    assertBytes([0x01, 0x00]b, asm.accept([0x02, 0x01, 0x00, 0xFF, 0xFF]b));
    return true;
}

(:test)
function packetReservedHeaderTypeIgnored(logger as Logger) as Boolean {
    var asm = new PacketAssembler();
    Test.assert(asm.accept([0x60, 0x01, 0x02]b) == null);
    return true;
}

(:test)
function packetTruncatedExtendedHeaderIgnored(logger as Logger) as Boolean {
    var asm = new PacketAssembler();
    Test.assert(asm.accept([0x20]b) == null);
    Test.assert(asm.accept([0x40, 0x00]b) == null);
    return true;
}
