// Not required for test files
// ignore_for_file: avoid_redundant_argument_values, prefer_const_constructors

import 'package:socket_client/src/transport/backoff_strategy.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:test/test.dart';

void main() {
  group('ExponentialBackoff', () {
    late ReconnectConfig config;

    setUp(() {
      config = const ReconnectConfig(
        maxAttempts: 5,
        initialDelay: Duration(milliseconds: 100),
        maxDelay: Duration(milliseconds: 3200),
        multiplier: 2,
        jitter: false,
      );
    });

    test('delays grow exponentially without jitter', () {
      final backoff = ExponentialBackoff(config: config);
      final delays = List.generate(
        5,
        (_) => backoff.nextDelay().inMilliseconds,
      );

      // 100, 200, 400, 800, 1600
      expect(delays[0], 100);
      expect(delays[1], 200);
      expect(delays[2], 400);
      expect(delays[3], 800);
      expect(delays[4], 1600);
    });

    test('caps at maxDelay', () {
      final cfg = ReconnectConfig(
        maxAttempts: 10,
        initialDelay: Duration(milliseconds: 1000),
        maxDelay: Duration(milliseconds: 2000),
        multiplier: 10,
        jitter: false,
      );
      final backoff = ExponentialBackoff(config: cfg)..nextDelay(); // 1000
      final capped = backoff.nextDelay(); // would be 10000, capped to 2000
      expect(capped.inMilliseconds, 2000);
    });

    test('isExhausted after maxAttempts calls to nextDelay', () {
      final backoff = ExponentialBackoff(config: config);
      expect(backoff.isExhausted, isFalse);
      for (var i = 0; i < 5; i++) {
        backoff.nextDelay();
      }
      expect(backoff.isExhausted, isTrue);
    });

    test('reset restarts attempt counter', () {
      final backoff = ExponentialBackoff(config: config);
      for (var i = 0; i < 5; i++) {
        backoff.nextDelay();
      }
      backoff.reset();
      expect(backoff.attempt, 0);
      expect(backoff.isExhausted, isFalse);
      expect(backoff.nextDelay().inMilliseconds, 100);
    });

    test('with jitter returns value in [100, cappedDelay]', () {
      final cfg = ReconnectConfig(
        maxAttempts: 20,
        initialDelay: Duration(milliseconds: 500),
        maxDelay: Duration(milliseconds: 5000),
        multiplier: 2,
        jitter: true,
      );
      final backoff = ExponentialBackoff(config: cfg);
      for (var i = 0; i < 10; i++) {
        final delay = backoff.nextDelay().inMilliseconds;
        expect(delay, greaterThanOrEqualTo(100));
        expect(delay, lessThanOrEqualTo(5000));
      }
    });
  });

  group('LinearBackoff', () {
    test('grows linearly by step', () {
      final backoff = LinearBackoff(
        initialDelay: const Duration(milliseconds: 1000),
        step: const Duration(milliseconds: 500),
        maxDelay: const Duration(seconds: 60),
        maxAttempts: -1,
      );
      expect(backoff.nextDelay().inMilliseconds, 1000);
      expect(backoff.nextDelay().inMilliseconds, 1500);
      expect(backoff.nextDelay().inMilliseconds, 2000);
    });

    test('caps at maxDelay', () {
      final backoff =
          LinearBackoff(
              initialDelay: const Duration(milliseconds: 1000),
              step: const Duration(milliseconds: 1000),
              maxDelay: const Duration(milliseconds: 2000),
            )
            ..nextDelay() // 1000
            ..nextDelay(); // 2000
      expect(backoff.nextDelay().inMilliseconds, 2000); // capped
    });

    test('isExhausted respects maxAttempts', () {
      final backoff = LinearBackoff(maxAttempts: 3);
      expect(backoff.isExhausted, isFalse);
      backoff
        ..nextDelay()
        ..nextDelay()
        ..nextDelay();
      expect(backoff.isExhausted, isTrue);
    });

    test('maxAttempts=-1 is never exhausted', () {
      final backoff = LinearBackoff(maxAttempts: -1);
      for (var i = 0; i < 100; i++) {
        backoff.nextDelay();
      }
      expect(backoff.isExhausted, isFalse);
    });

    test('reset restarts counter', () {
      final backoff =
          LinearBackoff(
              initialDelay: const Duration(milliseconds: 500),
              step: const Duration(milliseconds: 500),
              maxAttempts: 2,
            )
            ..nextDelay()
            ..nextDelay();
      expect(backoff.isExhausted, isTrue);
      backoff.reset();
      expect(backoff.isExhausted, isFalse);
      expect(backoff.nextDelay().inMilliseconds, 500);
    });
  });
}
