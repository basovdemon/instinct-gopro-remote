import Toybox.Lang;

// Reassembles Open GoPro BLE messages that arrive split into packets of up to 20 bytes.
// Use one instance per notify characteristic: messages on different characteristics may interleave.
//
// Header formats (Open GoPro BLE spec, "Packetization", big endian):
//   General 5-bit    0b000LLLLL
//   Extended 13-bit  0b001LLLLL LLLLLLLL
//   Extended 16-bit  0b010xxxxx LLLLLLLL LLLLLLLL
//   Continuation     0b1xxxCCCC, CCCC = counter starting at 0, wraps after 0xF
class PacketAssembler {

    private var _buffer as ByteArray? = null;
    private var _expected as Number = 0;
    private var _nextCounter as Number = 0;

    function initialize() {
    }

    // Feeds one notification value. Returns the complete message payload (headers stripped)
    // once its last packet arrives, otherwise null. Malformed input drops the partial message.
    function accept(packet as ByteArray) as ByteArray? {
        if (packet.size() == 0) {
            return null;
        }
        var b0 = packet[0];
        if ((b0 & 0x80) != 0) {
            return acceptContinuation(packet, b0 & 0x0F);
        }
        return acceptStart(packet, b0);
    }

    function reset() as Void {
        _buffer = null;
        _expected = 0;
        _nextCounter = 0;
    }

    function isPending() as Boolean {
        return _buffer != null;
    }

    private function acceptStart(packet as ByteArray, b0 as Number) as ByteArray? {
        // A new start while a message is pending means we lost the tail of the previous one.
        reset();

        var headerSize;
        var length;
        var type = (b0 >> 5) & 0x03;
        if (type == 0) {
            headerSize = 1;
            length = b0 & 0x1F;
        } else if (type == 1) {
            if (packet.size() < 2) {
                return null;
            }
            headerSize = 2;
            length = ((b0 & 0x1F) << 8) | packet[1];
        } else if (type == 2) {
            if (packet.size() < 3) {
                return null;
            }
            headerSize = 3;
            length = (packet[1] << 8) | packet[2];
        } else {
            return null;
        }

        var payload = packet.slice(headerSize, null);
        if (payload.size() >= length) {
            return payload.slice(0, length);
        }
        _buffer = payload;
        _expected = length;
        _nextCounter = 0;
        return null;
    }

    private function acceptContinuation(packet as ByteArray, counter as Number) as ByteArray? {
        var buffer = _buffer;
        if (buffer == null) {
            return null;
        }
        if (counter != _nextCounter) {
            reset();
            return null;
        }
        buffer = buffer.addAll(packet.slice(1, null));
        _buffer = buffer;
        _nextCounter = (_nextCounter + 1) & 0x0F;
        if (buffer.size() < _expected) {
            return null;
        }
        var message = buffer.slice(0, _expected);
        reset();
        return message;
    }
}
