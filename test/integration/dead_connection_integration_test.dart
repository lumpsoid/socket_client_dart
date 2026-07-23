// tests
// ignore_for_file: avoid_redundant_argument_values

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

/// Polls [predicate] until it returns true or [timeout] elapses.
Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Condition not met within $timeout');
    }
    await Future<void>.delayed(step);
  }
}
//

void main() {
  late TestSocketServer server;
  late SocketClient<_Msg> client;

  setUp(() async {
    server = TestSocketServer();
    await server.start();

    client = DefaultSocketClient<_Msg>(
      config: ConstantConfigProvider(ConnectionConfig(url: server.url)),
      codec: _MsgCodec(),
      // Short heartbeat so the pong-timeout trips quickly after the server
      // stops replying. pongTimeout (400ms) is kept much larger than the
      // request timeout below (100ms) so a request can time out while the
      // heartbeat still considers the link alive.
      heartbeat: IntervalHeartbeat(
        config: const HeartbeatConfig(
          enabled: true,
          interval: Duration(milliseconds: 800),
          pongTimeout: Duration(milliseconds: 400),
        ),
      ),
      // Long reconnect delay: once the socket is torn down we want it to stay
      // torn down for the duration of the assertions, rather than silently
      // reconnecting to the still-listening (but frozen) server.
      backoff: LinearBackoff(initialDelay: const Duration(seconds: 30)),
    );
  });

  tearDown(() async {
    await client.dispose();
    await server.stop();
  });

  group('dead connection', () {
    test(
      'isConnected reports true while the link is silently dead, '
      'then flips to false once the heartbeat pong-timeout trips',
      () async {
        // 1. Connect and confirm a normal request round-trips.
        await client.connect();
        expect(client.isConnected, isTrue);

        final reply = await client
            .request(
              _Msg(type: 'request', ref: 'warmup'),
              timeout: const Duration(seconds: 2),
            )
            .timeout(const Duration(seconds: 3));
        expect(reply.type, 'response');
        expect(reply.replyTo, 'warmup');
        expect(reply.payload, 'ok');

        // 2. Silently drop the link: the server goes mute but keeps the socket
        //    open and sends no close frame (airplane mode / NAT timeout).
        server.freeze();

        // 3. A request fired into the dead link times out with a SocketError,
        //    yet at that moment the client still believes it is connected —
        //    the heartbeat has not yet noticed the silence. This is the core
        //    of the bug: isConnected reads true while the link is already dead.
        await expectLater(
          client.request(
            _Msg(type: 'request', ref: 'into-the-void'),
            timeout: const Duration(milliseconds: 100),
          ),
          throwsA(isA<SocketError>()),
        );
        expect(
          client.isConnected,
          isTrue,
          reason: 'connection should still read as alive at the moment a '
              'request times out over a silently dropped link',
        );

        // 4. Once the heartbeat pong-timeout trips, the transport tears the
        //    socket down and isConnected finally flips to false.
        await _waitUntil(() => !client.isConnected);
        expect(client.isConnected, isFalse);
      },
    );
  });
}
