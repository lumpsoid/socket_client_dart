// tests
// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';
import 'dart:convert';

import 'package:socket_client/socket_client.dart';
import 'package:test/test.dart';

import '../server/test_socket_server.dart';

class _Msg {
  _Msg({required this.type, this.ref, this.replyTo, this.payload});
  final String type;
  final String? ref;
  final String? replyTo;
  final String? payload;
}

class _MsgCodec implements FrameCodec<_Msg> {
  @override
  _Msg decode(String raw) {
    final m = json.decode(raw) as Map<String, dynamic>;
    return _Msg(
      type: m['type'] as String,
      ref: m['ref'] as String?,
      replyTo: m['replyTo'] as String?,
      payload: m['payload'] as String?,
    );
  }

  @override
  String encode(_Msg f) => json.encode({
    'type': f.type,
    if (f.ref != null) 'ref': f.ref,
    if (f.replyTo != null) 'replyTo': f.replyTo,
  });

  @override
  String? correlationId(_Msg f) => f.ref;

  @override
  String? replyCorrelationId(_Msg f) => f.replyTo;
}
//

void main() {
  late TestSocketServer server;
  late SocketClient<_Msg> client;

  setUp(() async {
    server = TestSocketServer();
    await server.start();

    client = SocketClient<_Msg>(
      config: ConnectionConfig(url: server.url),
      codec: _MsgCodec(),
      backoff: LinearBackoff(maxAttempts: -1),
    );
  });

  tearDown(() async {
    await client.dispose();
    await server.stop();
  });

  group('SocketClient integration', () {
    test('connect succeeds', () async {
      await client.connect();
      expect(client.isConnected, isTrue);
    });

    test('allFrames emits decoded inbound frames', () async {
      await client.connect();

      final received = Completer<_Msg>();
      client.allFrames.listen(received.complete);

      server.pushToAll('{"type":"announcement"}');
      final frame = await received.future.timeout(const Duration(seconds: 2));
      expect(frame.type, 'announcement');
    });

    test('emit sends a frame and server echoes it back', () async {
      await client.connect();

      final echo = Completer<_Msg>();
      client.allFrames.listen(echo.complete);

      client.emit(_Msg(type: 'hello'));
      final frame = await echo.future.timeout(const Duration(seconds: 2));
      expect(frame.type, 'hello');
    });

    test('request-reply round trip', () async {
      await client.connect();

      final reply = await client
          .request(
            _Msg(type: 'request', ref: 'r42'),
            timeout: const Duration(seconds: 3),
          )
          .timeout(const Duration(seconds: 4));

      expect(reply.replyTo, 'r42');
      expect(reply.payload, 'ok');
    });

    test('request times out when no reply arrives', () async {
      await client.connect();

      await Future<void>.delayed(const Duration(milliseconds: 100));

      await expectLater(
        client.request(
          _Msg(type: 'no-reply', ref: 'timeout-test'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<SocketError>()),
      );
    });

    test(
      'request timeout does not affect the connection or other requests',
      () async {
        await client.connect();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // A request that will never get a reply → should timeout cleanly
        await expectLater(
          client.request(
            _Msg(type: 'no-reply', ref: 'timeout-test'),
            timeout: const Duration(milliseconds: 50),
          ),
          throwsA(isA<SocketError>()),
        );

        // After the timeout, the connection must still be alive
        // and able to serve a normal request
        await expectLater(
          client.request(
            _Msg(type: 'request', ref: 'after-timeout'),
            timeout: const Duration(milliseconds: 500),
          ),

          completion(
            isA<_Msg>()
                .having((m) => m.type, 'type', 'response')
                .having((m) => m.replyTo, 'replyTo', 'after-timeout'),
          ),
        );
      },
    );

    test('disconnect sets state to disconnected', () async {
      await client.connect();
      await client.disconnect();
      expect(client.isConnected, isFalse);
    });

    test('dispose throws StateError on subsequent operations', () async {
      await client.connect();
      await client.dispose();
      expect(() => client.emit(_Msg(type: 'late')), throwsStateError);
    });

    test('uptime is non-null after connect', () async {
      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.uptime, isNotNull);
      expect(client.uptime!.inMilliseconds, greaterThan(0));
    });
  });
}
