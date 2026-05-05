import 'dart:convert';

import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:test/test.dart';

//Minimal test codec
class TestFrame {
  TestFrame({required this.type, this.ref, this.replyTo, this.payload});
  final String type;
  final String? ref;
  final String? replyTo;
  final String? payload;
}

class TestCodec implements FrameCodec<TestFrame> {
  @override
  TestFrame decode(String raw) {
    try {
      final map = json.decode(raw) as Map<String, dynamic>;
      return TestFrame(
        type: map['type'] as String,
        ref: map['ref'] as String?,
        replyTo: map['replyTo'] as String?,
        payload: map['payload'] as String?,
      );
    } catch (e) {
      throw FrameDecodeException('Cannot decode', raw: raw, cause: e);
    }
  }

  @override
  String encode(TestFrame frame) => json.encode({
    'type': frame.type,
    if (frame.ref != null) 'ref': frame.ref,
    if (frame.replyTo != null) 'replyTo': frame.replyTo,
    if (frame.payload != null) 'payload': frame.payload,
  });

  @override
  String? correlationId(TestFrame frame) => frame.ref;

  @override
  String? replyCorrelationId(TestFrame frame) => frame.replyTo;
}
//

void main() {
  final codec = TestCodec();

  group('TestCodec (FrameCodec contract)', () {
    test('decode parses a valid JSON string', () {
      final frame = codec.decode('{"type":"ping","ref":"1"}');
      expect(frame.type, 'ping');
      expect(frame.ref, '1');
    });

    test('encode serialises a frame to JSON', () {
      final frame = TestFrame(type: 'ping', ref: '42');
      final encoded = codec.encode(frame);
      final map = json.decode(encoded) as Map<String, dynamic>;
      expect(map['type'], 'ping');
      expect(map['ref'], '42');
    });

    test('correlationId returns ref field', () {
      final frame = TestFrame(type: 'request', ref: 'abc');
      expect(codec.correlationId(frame), 'abc');
    });

    test('correlationId returns null when ref absent', () {
      final frame = TestFrame(type: 'event');
      expect(codec.correlationId(frame), isNull);
    });

    test('replyCorrelationId returns replyTo field', () {
      final frame = TestFrame(type: 'response', replyTo: 'abc');
      expect(codec.replyCorrelationId(frame), 'abc');
    });

    test('decode throws FrameDecodeException on invalid JSON', () {
      expect(
        () => codec.decode('not-json'),
        throwsA(isA<FrameDecodeException>()),
      );
    });

    test('FrameDecodeException.toString includes message and raw', () {
      const ex = FrameDecodeException('bad', raw: 'raw-data');
      expect(ex.toString(), contains('bad'));
      expect(ex.toString(), contains('raw-data'));
    });
  });
}
