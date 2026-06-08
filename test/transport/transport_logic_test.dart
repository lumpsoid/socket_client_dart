import 'dart:async';
import 'dart:io';

import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/transport_logic.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  group('classifyConnectError', () {
    test('TimeoutException → timeout, no originalError', () {
      final err = classifyConnectError(
        TimeoutException('boom'),
        StackTrace.empty,
        now,
      );
      expect(err.type, SocketErrorType.timeout);
      expect(err.message, 'boom');
      expect(err.timestamp, now);
      expect(err.originalError, isNull);
    });

    test('TimeoutException with null message falls back', () {
      final err = classifyConnectError(
        TimeoutException(null),
        StackTrace.empty,
        now,
      );
      expect(err.message, 'Connection timeout');
    });

    test('SocketException → network with originalError', () {
      const ex = SocketException('down');
      final err = classifyConnectError(ex, StackTrace.empty, now);
      expect(err.type, SocketErrorType.network);
      expect(err.message, 'Socket error: down');
      expect(err.originalError, same(ex));
    });

    test('WebSocketException → protocol', () {
      final err = classifyConnectError(
        const WebSocketException('bad frame'),
        StackTrace.empty,
        now,
      );
      expect(err.type, SocketErrorType.protocol);
      expect(err.message, 'WebSocket error: bad frame');
    });

    test('HandshakeException → tls', () {
      final err = classifyConnectError(
        const HandshakeException('cert'),
        StackTrace.empty,
        now,
      );
      expect(err.type, SocketErrorType.tls);
      expect(err.message, 'TLS handshake failed: cert');
    });

    test('unknown exception → unknown with stackTrace', () {
      final st = StackTrace.current;
      final err = classifyConnectError(const FormatException('x'), st, now);
      expect(err.type, SocketErrorType.unknown);
      expect(err.message, contains('Unexpected error:'));
      expect(err.stackTrace, same(st));
    });
  });

  group('builders', () {
    test('heartbeatTimeoutError', () {
      final err = heartbeatTimeoutError(now);
      expect(err.type, SocketErrorType.heartbeatTimeout);
      expect(err.message, 'No pong within pong timeout');
      expect(err.timestamp, now);
    });

    test('streamError', () {
      final st = StackTrace.current;
      final err = streamError('oops', st, now);
      expect(err.type, SocketErrorType.stream);
      expect(err.message, 'Stream error: oops');
      expect(err.originalError, 'oops');
      expect(err.stackTrace, same(st));
    });

    test('maxRetriesError', () {
      final err = maxRetriesError(5, now);
      expect(err.type, SocketErrorType.maxRetriesExceeded);
      expect(err.message, 'Exceeded 5 reconnect attempts');
    });
  });

  group('decideFailure', () {
    test('reconnect only when not intentional and strategy present', () {
      expect(
        decideFailure(intentionalClose: false, hasStrategy: true),
        FailureOutcome.reconnect,
      );
      expect(
        decideFailure(intentionalClose: true, hasStrategy: true),
        FailureOutcome.fail,
      );
      expect(
        decideFailure(intentionalClose: false, hasStrategy: false),
        FailureOutcome.fail,
      );
      expect(
        decideFailure(intentionalClose: true, hasStrategy: false),
        FailureOutcome.fail,
      );
    });
  });

  group('shouldReconnectOnClose', () {
    test('reconnect unless intentional', () {
      expect(shouldReconnectOnClose(intentionalClose: false), isTrue);
      expect(shouldReconnectOnClose(intentionalClose: true), isFalse);
    });
  });

  group('uptimeSince', () {
    test('null when never connected', () {
      expect(uptimeSince(null, now), isNull);
    });

    test('difference when connected', () {
      final started = now.subtract(const Duration(seconds: 30));
      expect(uptimeSince(started, now), const Duration(seconds: 30));
    });
  });
}
