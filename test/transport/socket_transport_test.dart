import 'dart:async';
import 'dart:typed_data';

import 'package:socket_client/src/transport/backoff_strategy.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/connection_config_provider.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/in_memory_heartbeat.dart';
import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:test/test.dart';

import '../server/test_socket_server.dart';

void main() {
  late TestSocketServer server;
  late InMemoryHeartbeat heartbeat;
  late SocketTransport transport;

  SocketTransport buildTransport({
    ConnectionConfigProvider? config,
    ReconnectionStrategy? backoff,
  }) => SocketTransport(
    config: config ?? ConstantConfigProvider(ConnectionConfig(url: server.url)),
    heartbeat: heartbeat,
    backoff:
        backoff ??
        ConstantBackoff(
          delay: const Duration(milliseconds: 20),
          maxAttempts: 3,
        ),
  );

  // Broadcast streams deliver asynchronously; let queued events flush.
  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() async {
    server = TestSocketServer();
    await server.start();
    heartbeat = InMemoryHeartbeat();
    transport = buildTransport();
  });

  tearDown(() async {
    await transport.dispose();
    await server.stop();
  });

  group('lifecycle', () {
    test('connect transitions connecting -> connected', () async {
      final states = <SocketConnectionState>[];
      transport.stateStream.listen(states.add);

      await transport.connect();
      await pump();

      expect(transport.isConnected, isTrue);
      expect(transport.state, SocketConnectionState.connected);
      expect(
        states,
        containsAllInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );
      expect(transport.connectedAt, isNotNull);
    });

    test('connect is idempotent when already connected', () async {
      await transport.connect();
      await transport.connect();
      expect(server.clientCount, 1);
    });

    test('concurrent connect calls join one attempt', () async {
      await Future.wait([
        transport.connect(),
        transport.connect(),
        transport.connect(),
      ]);
      expect(transport.isConnected, isTrue);
      expect(server.clientCount, 1);
    });

    test('disconnect transitions to disconnected and clears state', () async {
      final states = <SocketConnectionState>[];
      transport.stateStream.listen(states.add);

      await transport.connect();
      await transport.disconnect();
      await pump();

      expect(transport.isConnected, isFalse);
      expect(transport.state, SocketConnectionState.disconnected);
      expect(transport.connectedAt, isNull);
      expect(
        states,
        containsAllInOrder([
          SocketConnectionState.disconnecting,
          SocketConnectionState.disconnected,
        ]),
      );
    });

    test('dispose closes the state stream', () async {
      await transport.connect();
      final done = Completer<void>();
      transport.stateStream.listen(null, onDone: done.complete);

      await transport.dispose();
      await done.future.timeout(const Duration(seconds: 1));
    });
  });

  group('send guards', () {
    test('sendText throws StateError when disconnected', () {
      expect(() => transport.sendText('x'), throwsStateError);
    });

    test('sendBytes throws StateError when disconnected', () {
      expect(() => transport.sendBytes(Uint8List(0)), throwsStateError);
    });

    test('sendText reaches the server (echo)', () async {
      await transport.connect();
      final echo = Completer<String>();
      transport.textStream.listen(echo.complete);

      transport.sendText('{"type":"echo"}');
      expect(
        await echo.future.timeout(const Duration(seconds: 2)),
        '{"type":"echo"}',
      );
    });
  });

  group('inbound frames', () {
    test('text frame delivered and lastMessageAt updated', () async {
      await transport.connect();
      final received = Completer<String>();
      transport.textStream.listen(received.complete);

      server.pushToAll('hello');
      final frame = await received.future.timeout(const Duration(seconds: 2));
      expect(frame, 'hello');
      expect(transport.lastMessageAt, isNotNull);
    });

    test('inbound frame feeds heartbeat.didReceiveFrame', () async {
      await transport.connect();
      final received = Completer<String>();
      transport.textStream.listen(received.complete);

      server.pushToAll('ping-back');
      await received.future.timeout(const Duration(seconds: 2));
      expect(heartbeat.receivedFrameCount, greaterThan(0));
    });
  });

  group('heartbeat wiring', () {
    test('heartbeat starts on connect and stops on disconnect', () async {
      await transport.connect();
      expect(heartbeat.startCount, 1);

      await transport.disconnect();
      expect(heartbeat.stopCount, greaterThan(0));
    });

    test('bound send writes to the live socket', () async {
      await transport.connect();
      final echo = Completer<String>();
      transport.textStream.listen(echo.complete);

      heartbeat.emitPing('{"type":"from-heartbeat"}');
      expect(
        await echo.future.timeout(const Duration(seconds: 2)),
        '{"type":"from-heartbeat"}',
      );
    });

    test('pong-timeout closes socket and triggers reconnect', () async {
      final errors = <SocketError>[];
      transport.errorStream.listen(errors.add);
      final states = <SocketConnectionState>[];
      transport.stateStream.listen(states.add);

      await transport.connect();

      // Fire the captured pong-timeout closure: closes the socket.
      heartbeat.expireTimeout();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        errors.map((e) => e.type),
        contains(SocketErrorType.heartbeatTimeout),
      );
      expect(states, contains(SocketConnectionState.reconnecting));
    });
  });

  group('reconnect', () {
    test('reconnects after server drops the connection', () async {
      // Unlimited retries so the brief downtime doesn't exhaust attempts.
      transport = buildTransport(
        backoff: ConstantBackoff(delay: const Duration(milliseconds: 40)),
      );
      final states = <SocketConnectionState>[];
      transport.stateStream.listen(states.add);

      await transport.connect();

      // Restart on the SAME port so the reconnect (fixed url) can land.
      final port = server.boundPort;
      await server.stop();
      await pump(80);
      server = TestSocketServer(port: port);
      await server.start();
      await pump(500);

      expect(
        states,
        containsAllInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.reconnecting,
          SocketConnectionState.connected,
        ]),
      );
      expect(transport.isConnected, isTrue);
    });

    test('emits maxRetriesExceeded and fails when exhausted', () async {
      // Point at a dead server so every attempt fails.
      final dead = SocketTransport(
        config: ConstantConfigProvider(ConnectionConfig(url: server.url)),
        heartbeat: InMemoryHeartbeat(),
        backoff: ConstantBackoff(
          delay: const Duration(milliseconds: 20),
          maxAttempts: 2,
        ),
      );
      addTearDown(dead.dispose);

      final errors = <SocketError>[];
      dead.errorStream.listen(errors.add);

      await server.stop();
      await dead.connect();
      await pump(300);

      expect(
        errors.map((e) => e.type),
        contains(SocketErrorType.maxRetriesExceeded),
      );
      expect(dead.state, SocketConnectionState.failed);
    });
  });

  group('stale-closure guard', () {
    test('reconnect leaves exactly one live client (old socket dropped)',
        () async {
      await transport.connect();
      expect(server.clientCount, 1);

      // Drop via pong-timeout: closes socket A, transport reconnects to B.
      heartbeat.expireTimeout();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(transport.isConnected, isTrue);
      expect(server.clientCount, 1);
    });

    test('only one reconnect per drop — no stale onDone double-fire',
        () async {
      final states = <SocketConnectionState>[];
      transport.stateStream.listen(states.add);

      await transport.connect();
      heartbeat.expireTimeout();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final reconnects =
          states.where((s) => s == SocketConnectionState.reconnecting).length;
      expect(reconnects, 1);
    });

    test('frames flow on the new socket after reconnect', () async {
      await transport.connect();
      heartbeat.expireTimeout();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(transport.isConnected, isTrue);

      final echo = Completer<String>();
      transport.textStream.listen(echo.complete);
      transport.sendText('{"type":"after-reconnect"}');
      expect(
        await echo.future.timeout(const Duration(seconds: 2)),
        '{"type":"after-reconnect"}',
      );
    });

    test('bound send re-targets the new socket after reconnect', () async {
      await transport.connect();
      heartbeat.expireTimeout();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(transport.isConnected, isTrue);

      // start() called again on reconnect -> bound send rebound to new socket.
      expect(heartbeat.startCount, greaterThanOrEqualTo(2));
      final echo = Completer<String>();
      transport.textStream.listen(echo.complete);
      heartbeat.emitPing('{"type":"new-socket-send"}');
      expect(
        await echo.future.timeout(const Duration(seconds: 2)),
        '{"type":"new-socket-send"}',
      );
    });
  });
}
