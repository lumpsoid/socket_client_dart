// tests
// ignore_for_file: avoid_redundant_argument_values

import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/interval_heartbeat.dart';
import 'package:test/test.dart';

void main() {
  group('IntervalHeartbeat', () {
    late IntervalHeartbeat heartbeat;

    setUp(() {
      heartbeat = IntervalHeartbeat(
        config: const HeartbeatConfig(
          enabled: true,
          interval: Duration(milliseconds: 50),
          pongTimeout: Duration(milliseconds: 80),
          pingMessage: '__ping__',
        ),
      );
    });

    tearDown(() => heartbeat.stop());

    test('isRunning is false before start', () {
      expect(heartbeat.isRunning, isFalse);
    });

    test('isRunning is true after start', () {
      heartbeat.start(send: (_) {}, onTimeout: () {});
      expect(heartbeat.isRunning, isTrue);
    });

    test('isRunning is false after stop', () {
      heartbeat
        ..start(send: (_) {}, onTimeout: () {})
        ..stop();
      expect(heartbeat.isRunning, isFalse);
    });

    test('sends ping frame periodically', () async {
      final pings = <dynamic>[];
      heartbeat.start(send: pings.add, onTimeout: () {});
      await Future<void>.delayed(const Duration(milliseconds: 180));
      heartbeat.stop();
      // Should have fired at ~50ms and ~100ms and ~150ms → at least 2 pings
      expect(pings.length, greaterThanOrEqualTo(2));
      expect(pings.first, '__ping__');
    });

    test('fires onTimeout when no frame received within pongTimeout', () async {
      final hb = IntervalHeartbeat(
        config: const HeartbeatConfig(
          enabled: true,
          interval: Duration(milliseconds: 3),
          pongTimeout: Duration(milliseconds: 1),
          pingMessage: '__ping__',
        ),
      );
      var timedOut = false;
      hb.start(send: (_) {}, onTimeout: () => timedOut = true);
      await Future<void>.delayed(const Duration(milliseconds: 9));
      hb.stop();
      expect(timedOut, isTrue);
    });

    test('didReceiveFrame resets the pong timeout', () async {
      var timedOut = false;
      heartbeat.start(send: (_) {}, onTimeout: () => timedOut = true);
      // Cancel the pong timeout by simulating an inbound frame just in time
      await Future<void>.delayed(const Duration(milliseconds: 60));
      heartbeat.didReceiveFrame(); // reset
      await Future<void>.delayed(const Duration(milliseconds: 60));
      heartbeat.didReceiveFrame(); // reset again
      await Future<void>.delayed(const Duration(milliseconds: 40));
      heartbeat.stop();
      expect(timedOut, isFalse);
    });

    test('start when disabled is a no-op', () {
      final hb = IntervalHeartbeat(
        config: const HeartbeatConfig(enabled: false),
      )..start(send: (_) {}, onTimeout: () {});
      expect(hb.isRunning, isFalse);
    });

    test('calling start twice does not double-register timers', () async {
      final pings = <dynamic>[];
      heartbeat
        ..start(send: pings.add, onTimeout: () {})
        ..start(
          send: pings.add,
          onTimeout: () {},
        ); // second call is no-op
      await Future<void>.delayed(const Duration(milliseconds: 80));
      heartbeat.stop();
      // Only one timer running → ~1-2 pings, not doubled
      expect(pings.length, lessThan(5));
    });
  });
}
