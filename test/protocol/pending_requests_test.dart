import 'dart:async';

import 'package:socket_client/src/protocol/pending_requests.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:test/test.dart';

void main() {
  group('PendingRequests', () {
    late PendingRequests<String> pending;

    setUp(() => pending = PendingRequests<String>());
    tearDown(() => pending.dispose());

    test('register returns a future that completes on resolve', () async {
      final future = pending.register('req-1');
      pending.resolve('req-1', 'response-payload');
      expect(await future, 'response-payload');
    });

    test('resolve is a no-op for unknown correlationId', () {
      expect(() => pending.resolve('ghost', 'value'), returnsNormally);
    });

    test('times out with SocketError after timeout', () async {
      final future = pending.register(
        'req-timeout',
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        future,
        throwsA(
          isA<SocketError>().having(
            (e) => e.type,
            'type',
            SocketErrorType.timeout,
          ),
        ),
      );
    });

    test('length reflects in-flight count', () async {
      unawaited(pending.register('a'));
      unawaited(pending.register('b'));
      expect(pending.length, 2);
      pending.resolve('a', 'ok');
      expect(pending.length, 1);

      // clearing
      pending.resolve('b', 'ok');
    });

    test('dispose cancels all pending futures with SocketError', () async {
      final future = pending.register('disposed-req');
      final expectation = expectLater(future, throwsA(isA<SocketError>()));
      pending.dispose();
      await expectation;
    });

    test('after timeout, resolve is silently ignored', () async {
      final future = pending.register(
        'stale',
        timeout: const Duration(milliseconds: 20),
      );

      // Let it time out
      await future.then((_) {}, onError: (_) {});

      // Should not throw
      expect(() => pending.resolve('stale', 'late-reply'), returnsNormally);
    });
  });
}
