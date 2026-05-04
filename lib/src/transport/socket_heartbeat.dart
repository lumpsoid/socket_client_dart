import 'dart:typed_data';

import 'package:socket_client/src/transport/connection_config.dart';

/// Callback invoked when the heartbeat layer wants to send a ping frame.
typedef PingSender = void Function(dynamic frame);

/// Callback invoked when no pong is received within the configured window.
typedef PongTimeoutCallback = void Function();

/// Abstract heartbeat contract.
///
/// Implementations own the full ping/pong cycle: scheduling periodic pings,
/// detecting missed pongs, and resetting the timeout whenever *any* inbound
/// frame arrives (not just explicit pong frames, matching common server
/// behaviour).
///
/// ```dart
/// final hb = IntervalHeartbeat(
///   config: config.heartbeat,
///   refGen: _refGen,
///   logger: _logger,
/// );
///
/// hb.start(
///   send: (frame) => _socket!.add(frame),
///   onTimeout: () => _socket?.close(WebSocketStatus.goingAway, 'Heartbeat
///   timeout'),
/// );
///
/// // Call on every inbound frame — keeps pong timeout from firing.
/// hb.didReceiveFrame();
///
/// hb.stop(); // clean up before disconnect / dispose
/// ```
abstract interface class SocketHeartbeat {
  /// Whether the heartbeat cycle is currently running.
  bool get isRunning;

  /// Start the heartbeat cycle.
  ///
  /// [send] is called each time a ping frame is ready to be written to the
  /// socket. The frame is whatever [HeartbeatConfig.buildPing] produces —
  /// typically a [String] or [Uint8List].
  ///
  /// [onTimeout] is called once when a pong is not received within
  /// [HeartbeatConfig.pongTimeout]. The caller is responsible for closing or
  /// recycling the socket; the heartbeat only reports the condition.
  ///
  /// Calling [start] while already running is a no-op.
  void start({
    required PingSender send,
    required PongTimeoutCallback onTimeout,
  });

  /// Notify the heartbeat that a frame was received from the server.
  ///
  /// Resets the pong-timeout window. Should be called for *every* inbound
  /// frame, not just explicit pong responses, because many servers piggyback
  /// application data as an implicit keep-alive signal.
  void didReceiveFrame();

  /// Stop the heartbeat cycle and cancel all pending timers.
  ///
  /// Safe to call when already stopped. After [stop] the instance can be
  /// restarted via [start].
  void stop();
}
