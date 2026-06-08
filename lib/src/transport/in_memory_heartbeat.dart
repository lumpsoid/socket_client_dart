import 'package:socket_client/src/transport/socket_heartbeat.dart';

/// A [SocketHeartbeat] that performs no real timing and instead records what
/// the transport asks of it, exposing manual triggers.
///
/// It schedules nothing on its own: pings are only sent when [emitPing] is
/// called, and the pong-timeout only fires when [expireTimeout] is called. This
/// makes heartbeat-driven behaviour (ping delivery, timeout-induced reconnect)
/// fully deterministic in tests, with no wall-clock waits.
///
/// ```dart
/// final hb = InMemoryHeartbeat();
/// final transport = SocketTransport(config: ..., heartbeat: hb);
/// await transport.connect();
/// hb.emitPing('{"type":"ping"}'); // writes to the live socket
/// hb.expireTimeout();             // simulates a missed pong
/// ```
class InMemoryHeartbeat implements SocketHeartbeat {
  PingSender? _send;
  PongTimeoutCallback? _onTimeout;

  bool _running = false;

  /// Number of times [start] was called.
  int startCount = 0;

  /// Number of times [stop] was called.
  int stopCount = 0;

  /// Number of times [didReceiveFrame] was called.
  int receivedFrameCount = 0;

  @override
  bool get isRunning => _running;

  @override
  void start({
    required PingSender send,
    required PongTimeoutCallback onTimeout,
  }) {
    startCount++;
    _running = true;
    _send = send;
    _onTimeout = onTimeout;
  }

  @override
  void didReceiveFrame() => receivedFrameCount++;

  @override
  void stop() {
    stopCount++;
    _running = false;
  }

  /// Send [frame] through the [PingSender] the transport bound on [start].
  ///
  /// Throws [StateError] if the heartbeat is not running.
  void emitPing(dynamic frame) {
    final send = _send;
    if (send == null) {
      throw StateError('Heartbeat not started; no send callback bound');
    }
    send(frame);
  }

  /// Fire the [PongTimeoutCallback] the transport bound on [start], simulating
  /// a missed pong.
  ///
  /// Throws [StateError] if the heartbeat is not running.
  void expireTimeout() {
    final onTimeout = _onTimeout;
    if (onTimeout == null) {
      throw StateError('Heartbeat not started; no timeout callback bound');
    }
    onTimeout();
  }
}
