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

    test(
      'onTimeout fires on silence even when pongTimeout >= interval',
      () async {
        // Regression test for a config footgun: when the pong-timeout is not
        // strictly shorter than the ping interval, every outbound ping used to
        // cancel + re-arm the still-pending pong-timeout timer before it could
        // fire — so a silently dead link (no inbound frames ever) was never
        // detected. An outbound ping must NOT reset the "have we heard from the
        // server" clock; only didReceiveFrame() should.
        final hb = IntervalHeartbeat(
          config: const HeartbeatConfig(
            enabled: true,
            interval: Duration(milliseconds: 30),
            pongTimeout: Duration(milliseconds: 30),
            pingMessage: '__ping__',
          ),
        );
        var timedOut = false;
        // Never call didReceiveFrame() → the server is silent the whole time.
        hb.start(send: (_) {}, onTimeout: () => timedOut = true);
        // Wait for many ping cycles; with the bug this window elapses with the
        // pong-timeout perpetually re-armed and timedOut still false.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        hb.stop();
        expect(timedOut, isTrue);
      },
    );

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
