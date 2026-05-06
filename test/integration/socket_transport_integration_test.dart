import 'dart:async';

import 'package:socket_client/src/transport/backoff_strategy.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/connection_config_provider.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/interval_heartbeat.dart';
import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:test/test.dart';

import '../server/test_socket_server.dart';

void main() {
  late TestSocketServer server;
  late SocketTransport transport;

  setUp(() async {
    server = TestSocketServer();
    await server.start();

    transport = SocketTransport(
      config: ConstantConfigProvider( ConnectionConfig(url: server.url)),

      heartbeat: IntervalHeartbeat(
        config: const HeartbeatConfig(
          enabled: false, // disable for most tests
        ),
      ),
      backoff: LinearBackoff(
        initialDelay: const Duration(milliseconds: 50),
        maxAttempts: 3,
      ),
    );
  });

  tearDown(() async {
    await transport.dispose();
    await server.stop();
  });

  group('SocketTransport integration', () {
    test('connects and transitions to connected state', () async {
      final states = <SocketConnectionState>[];
      transport.stateStream.listen(states.add);

      await transport.connect();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(transport.isConnected, isTrue);
      expect(transport.state, SocketConnectionState.connected);
      expect(states, contains(SocketConnectionState.connected));
    });

    test('receives text frames from server', () async {
      await transport.connect();

      final received = Completer<String>();
      transport.textStream.listen(received.complete);

      server.pushToAll('{"type":"hello"}');
      expect(
        await received.future.timeout(const Duration(seconds: 2)),
        '{"type":"hello"}',
      );
    });

    test('sends text frame to server', () async {
      await transport.connect();

      final echo = Completer<String>();
      transport.textStream.listen(echo.complete);

      transport.sendText('{"type":"echo_me"}');
      final reply = await echo.future.timeout(const Duration(seconds: 2));
      expect(reply, '{"type":"echo_me"}');
    });

    test('disconnects cleanly', () async {
      await transport.connect();
      expect(transport.isConnected, isTrue);

      await transport.disconnect();
      expect(transport.isConnected, isFalse);
      expect(transport.state, SocketConnectionState.disconnected);
    });

    test(
      'concurrent connect calls do not create duplicate connections',
      () async {
        await Future.wait([
          transport.connect(),
          transport.connect(),
          transport.connect(),
        ]);
        expect(transport.isConnected, isTrue);
        expect(server.clientCount, 1);
      },
    );

    test('sendText throws StateError when disconnected', () {
      expect(() => transport.sendText('hello'), throwsStateError);
    });

    test('connectedAt is set after connect', () async {
      await transport.connect();
      expect(transport.connectedAt, isNotNull);
    });

    test('connectionUptime increases over time', () async {
      await transport.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transport.connectionUptime!.inMilliseconds, greaterThan(0));
    });

    test('reconnects after server closes connection', () async {
      final states = <SocketConnectionState>[];
      transport.stateStream.listen(states.add);

      await transport.connect();

      // Server closes all clients
      await server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Restart server so reconnect can succeed
      await server.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        states,
        containsAllInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.reconnecting,
        ]),
      );
    });
  });
}
