// tests
// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';

import 'package:socket_client/src/transport/backoff_strategy.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/interval_heartbeat.dart';
import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:test/test.dart';

import '../server/test_socket_server.dart';

void main() {
  late TestSocketServer server;

  setUp(() async {
    server = TestSocketServer();
    await server.start();
  });

  tearDown(() => server.stop());

  group('Heartbeat integration', () {
    test(
      'heartbeat keeps connection alive over multiple ping cycles',
      () async {
        final transport = SocketTransport(
          config: ConnectionConfig(url: server.url),
          heartbeat: IntervalHeartbeat(
            config: const HeartbeatConfig(
              enabled: true,
              interval: Duration(milliseconds: 40),
              pongTimeout: Duration(milliseconds: 200),
              pingMessage: '{"type":"ping","ref":"hb"}',
            ),
          ),
          backoff: LinearBackoff(maxAttempts: -1),
        );

        await transport.connect();
        // Let multiple ping cycles elapse — connection should remain open
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(transport.isConnected, isTrue);

        await transport.dispose();
      },
    );

    test(
      'heartbeat timeout triggers reconnect when server stops responding',
      () async {
        final errors = <SocketError>[];
        final transport = SocketTransport(
          config: ConnectionConfig(url: server.url),
          heartbeat: IntervalHeartbeat(
            config: const HeartbeatConfig(
              enabled: true,
              interval: Duration(milliseconds: 100),
              pongTimeout: Duration(milliseconds: 50),
            ),
          ),
          backoff: LinearBackoff(
            initialDelay: const Duration(milliseconds: 100),
            maxAttempts: 1,
          ),
        );
        transport.errorStream.listen(errors.add);

        await transport.connect();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Freeze (not stop) so connection stays open but server goes silent —
        // this lets the pong timeout fire rather than a clean close winning the
        // race.
        server.freeze();

        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(
          errors.map((e) => e.type),
          anyElement(equals(SocketErrorType.heartbeatTimeout)),
        );

        await transport.dispose();

        server.unfreeze();
      },
    );
  });
}
