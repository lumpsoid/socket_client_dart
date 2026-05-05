import 'package:socket_client/src/transport/connection_state.dart';
import 'package:test/test.dart';

void main() {
  group('SocketError', () {
    test('isRecoverable is true for network, timeout, heartbeatTimeout', () {
      for (final type in [
        SocketErrorType.network,
        SocketErrorType.timeout,
        SocketErrorType.heartbeatTimeout,
      ]) {
        final err = SocketError(
          type: type,
          message: 'test',
          timestamp: DateTime.now(),
        );
        expect(
          err.isRecoverable,
          isTrue,
          reason: '${type.name} should be recoverable',
        );
      }
    });

    test('isRecoverable is false for non-recoverable types', () {
      for (final type in [
        SocketErrorType.protocol,
        SocketErrorType.tls,
        SocketErrorType.maxRetriesExceeded,
        SocketErrorType.authentication,
        SocketErrorType.serialization,
        SocketErrorType.stream,
        SocketErrorType.unknown,
      ]) {
        final err = SocketError(
          type: type,
          message: 'test',
          timestamp: DateTime.now(),
        );
        expect(
          err.isRecoverable,
          isFalse,
          reason: '${type.name} should not be recoverable',
        );
      }
    });

    test('toString includes type name and message', () {
      final err = SocketError(
        type: SocketErrorType.network,
        message: 'connection refused',
        timestamp: DateTime.now(),
      );
      expect(err.toString(), contains('network'));
      expect(err.toString(), contains('connection refused'));
    });
  });
}
