// tests
// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';
import 'dart:convert';

import 'package:socket_client/socket_client.dart';
import 'package:test/test.dart';

import '../server/test_socket_server.dart';

// Minimal frame + codec
class _F {
  _F(this.type);
  final String type;
}

class _FC implements FrameCodec<_F> {
  @override
  _F decode(String raw) =>
      _F((json.decode(raw) as Map<String, dynamic>)['type'] as String);
  @override
  String encode(_F f) => json.encode({'type': f.type});
  @override
  String? correlationId(_F f) => null;
  @override
  String? replyCorrelationId(_F f) => null;
}

void main() {
  late TestSocketServer server;

  setUp(() async {
    server = TestSocketServer();
    await server.start();
  });

  tearDown(() => server.stop());

  group('QueuedTransport integration', () {
    test('frames sent while disconnected are flushed on reconnect', () async {
      final transport = SocketTransport(
        config: ConstantConfigProvider(ConnectionConfig(url: server.url)),
        heartbeat: IntervalHeartbeat(
          config: const HeartbeatConfig(enabled: false),
        ),
        backoff: LinearBackoff(maxAttempts: -1),
      );
      final queued =
          QueuedTransport<_F>(
              transport: transport,
              codec: _FC(),
            )
            // Queue frames before connecting
            ..send(_F('queued_1'))
            ..send(_F('queued_2'));

      final received = <String>[];
      queued.textStream.listen(received.add);

      // Connect — should flush automatically
      await transport.connect();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Server echoes back; verify at least 2 messages received
      expect(received.length, greaterThanOrEqualTo(2));

      await queued.dispose();
    });

    test('frames sent while connected are delivered immediately', () async {
      final transport = SocketTransport(
        config: ConstantConfigProvider(ConnectionConfig(url: server.url)),
        heartbeat: IntervalHeartbeat(
          config: const HeartbeatConfig(enabled: false),
        ),
      );
      final queued = QueuedTransport<_F>(
        transport: transport,
        codec: _FC(),
      );

      await transport.connect();

      final received = Completer<String>();
      queued.textStream.listen(received.complete);

      queued.send(_F('live_frame'));
      final echo = await received.future.timeout(const Duration(seconds: 2));
      final decoded = json.decode(echo) as Map<String, dynamic>;
      expect(decoded['type'], 'live_frame');

      await queued.dispose();
    });

    test('dropped frames are emitted on droppedFrames stream', () async {
      final transport = SocketTransport(
        config: ConstantConfigProvider(ConnectionConfig(url: server.url)),
        heartbeat: IntervalHeartbeat(
          config: const HeartbeatConfig(enabled: false),
        ),
      );
      final q = MessageQueue<_F>(maxSize: 1);
      final queued = QueuedTransport<_F>(
        transport: transport,
        codec: _FC(),
        queue: q,
      );

      final dropped = <QueuedFrame<_F>>[];
      queued.droppedFrames.listen(dropped.add);

      // Fill the queue with one high-priority frame
      queued
        ..send(_F('blocking'), priority: MessagePriority.high)
        // This should be dropped (same priority, no room)
        ..send(_F('dropped'), priority: MessagePriority.high);

      await Future<void>.delayed(Duration.zero);
      expect(dropped, hasLength(1));

      await queued.dispose();
    });
  });
}
