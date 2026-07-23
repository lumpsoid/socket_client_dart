// tests
// ignore_for_file: avoid_redundant_argument_values

import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/heartbeat_ping_builder.dart';
import 'package:socket_client/src/transport/interval_framed_heartbeat.dart';
import 'package:test/test.dart';

class _StringCodec implements FrameCodec<String> {
  @override
  String decode(String raw) => raw;
  @override
  String encode(String f) => f;
  @override
  String? correlationId(String f) => null;
  @override
  String? replyCorrelationId(String f) => null;
}

class _PingBuilder extends FrameHeartbeatPingBuilder<String> {
  _PingBuilder() : super(codec: _StringCodec());
  @override
  String getPingFrame() => '__ping__';
}

IntervalFramedHeartbeat<String> _hb(HeartbeatConfig config) =>
    IntervalFramedHeartbeat<String>(pingBuilder: _PingBuilder(), config: config);

void main() {
  group('IntervalFramedHeartbeat', () {
    test('sends the encoded ping frame periodically', () async {
      final pings = <dynamic>[];
      final hb = _hb(
        const HeartbeatConfig(
          interval: Duration(milliseconds: 30),
          pongTimeout: Duration(milliseconds: 200),
        ),
      )..start(send: pings.add, onTimeout: () {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      hb.stop();
      expect(pings.length, greaterThanOrEqualTo(2));
      expect(pings.first, '__ping__');
    });

    test('didReceiveFrame resets the pong timeout', () async {
      var timedOut = false;
      final hb = _hb(
        const HeartbeatConfig(
          interval: Duration(milliseconds: 30),
          pongTimeout: Duration(milliseconds: 50),
        ),
      )..start(send: (_) {}, onTimeout: () => timedOut = true);
      // Keep signalling inbound frames faster than the pong-timeout window.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        hb.didReceiveFrame();
      }
      hb.stop();
      expect(timedOut, isFalse);
    });

    test(
      'onTimeout fires on silence even when pongTimeout >= interval',
      () async {
        // Same footgun as IntervalHeartbeat: this is the heartbeat that
        // PhoenixClient uses in production, so it must detect a silently dead
        // link (no inbound frames) regardless of the pongTimeout/interval
        // relationship. An outbound ping must not re-arm the pong-timeout.
        var timedOut = false;
        final hb = _hb(
          const HeartbeatConfig(
            interval: Duration(milliseconds: 30),
            pongTimeout: Duration(milliseconds: 30),
          ),
        )..start(send: (_) {}, onTimeout: () => timedOut = true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        hb.stop();
        expect(timedOut, isTrue);
      },
    );
  });
}
