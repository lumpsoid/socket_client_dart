import 'package:socket_client/src/util/logger.dart';
import 'package:test/test.dart';

void main() {
  group('SocketLogger', () {
    test('calls onLog for each level above minLevel', () {
      final calls = <(LogLevel, String, String)>[];
      SocketLogger(
          tag: 'Test',
          minLevel: LogLevel.info,
          onLog: (level, tag, msg) => calls.add((level, tag, msg)),
        )
        ..debug('debug msg') // should be suppressed
        ..info('info msg')
        ..warn('warn msg')
        ..error('error msg');

      expect(calls, hasLength(3));
      expect(calls[0].$1, LogLevel.info);
      expect(calls[1].$1, LogLevel.warn);
      expect(calls[2].$1, LogLevel.error);
    });

    test('suppresses messages below minLevel', () {
      final calls = <LogLevel>[];
      SocketLogger(
          tag: 'T',
          minLevel: LogLevel.error,
          onLog: (level, tag, msg) => calls.add(level),
        )
        ..debug('d')
        ..info('i')
        ..warn('w')
        ..error('e');

      expect(calls, equals([LogLevel.error]));
    });

    test('tag is passed through to onLog', () {
      String? capturedTag;
      SocketLogger(
        tag: 'MyTag',
        onLog: (_, tag, _) => capturedTag = tag,
      ).info('hello');
      expect(capturedTag, 'MyTag');
    });

    test('uses dart:developer when onLog is null (smoke test)', () {
      // Just verify no exception is thrown.
      const logger = SocketLogger(tag: 'Smoke');
      expect(() => logger.info('smoke'), returnsNormally);
    });
  });
}
