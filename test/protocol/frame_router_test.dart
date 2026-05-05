import 'dart:convert';

import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/protocol/topic_router.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:test/test.dart';

// Re-use the same minimal codec from frame_codec_test
class _Frame {
  _Frame({required this.type, this.ref, this.replyTo, this.payload});
  final String type;
  final String? ref;
  final String? replyTo;
  final String? payload;
}

class _Codec implements FrameCodec<_Frame> {
  @override
  _Frame decode(String raw) {
    final m = json.decode(raw) as Map<String, dynamic>;
    return _Frame(
      type: m['type'] as String,
      ref: m['ref'] as String?,
      replyTo: m['replyTo'] as String?,
      payload: m['payload'] as String?,
    );
  }

  @override
  String encode(_Frame f) => json.encode({
    'type': f.type,
    if (f.ref != null) 'ref': f.ref,
    if (f.replyTo != null) 'replyTo': f.replyTo,
  });

  @override
  String? correlationId(_Frame f) => f.ref;

  @override
  String? replyCorrelationId(_Frame f) => f.replyTo;
}

void main() {
  late FrameRouter<_Frame> router;

  setUp(() => router = FrameRouter<_Frame>(codec: _Codec()));
  tearDown(() => router.dispose());

  group('FrameRouter.ingest', () {
    test('decoded frame is emitted on allFrames', () async {
      final frames = <_Frame>[];
      router.allFrames.listen(frames.add);

      await router.ingest('{"type":"event"}');
      expect(frames, hasLength(1));
      expect(frames.first.type, 'event');
    });

    test('resolves a pending request when replyTo matches', () async {
      final sentFrames = <String>[];
      final request = _Frame(type: 'req', ref: 'r1');

      final replyFuture = router.request(
        request,
        send: sentFrames.add,
        timeout: const Duration(seconds: 2),
      );

      // Server-side reply arrives
      await router.ingest('{"type":"reply","replyTo":"r1"}');

      final reply = await replyFuture;
      expect(reply.replyTo, 'r1');
    });

    test('ingest returns the decoded frame', () async {
      final frame = await router.ingest('{"type":"ping"}');
      expect(frame.type, 'ping');
    });
  });

  group('FrameRouter.request', () {
    test('throws ArgumentError when codec returns null correlationId', () {
      final frame = _Frame(type: 'event'); // ref == null
      expect(
        () => router.request(frame, send: (_) {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('sends encoded frame via send callback', () {
      final sent = <String>[];
      final frame = _Frame(type: 'req', ref: 'x1');
      router.request(frame, send: sent.add).ignore();

      expect(sent, hasLength(1));
      final decoded = json.decode(sent.first) as Map<String, dynamic>;
      expect(decoded['ref'], 'x1');
    });

    test('times out with SocketError when no reply arrives', () async {
      final frame = _Frame(type: 'req', ref: 'timeout-id');
      await expectLater(
        router.request(
          frame,
          send: (_) {},
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<SocketError>().having(
            (e) => e.type,
            'type',
            SocketErrorType.timeout,
          ),
        ),
      );
    });
  });

  group('FrameRouter.emit', () {
    test('encodes and sends frame without tracking reply', () {
      final sent = <String>[];
      router.emit(_Frame(type: 'notify'), send: sent.add);

      expect(sent, hasLength(1));
      expect(
        (json.decode(sent.first) as Map<String, dynamic>)['type'],
        'notify',
      );
    });
  });
}
