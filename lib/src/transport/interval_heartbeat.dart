import 'dart:async';

import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/heartbeat_ping_builder.dart';
import 'package:socket_client/src/transport/socket_heartbeat.dart';
import 'package:socket_client/src/util/logger.dart';

/// Default heartbeat implementation driven by a fixed [Timer.periodic] interval
///
/// Behaviour:
/// - Sends a ping frame every [HeartbeatConfig.interval].
/// - Starts a pong-timeout window ([HeartbeatConfig.pongTimeout]) after each
/// ping.
/// - Any inbound frame ([didReceiveFrame]) cancels the active timeout window —
///   the next ping resets the cycle.
/// - Calls [PongTimeoutCallback] once if no frame arrives within the timeout.
///   Does **not** close the socket itself; that decision belongs to the caller.
///
/// ```dart
/// final hb = IntervalHeartbeat(
///   config: config.heartbeat,
///   refGen: _refGen,
///   logger: _logger,
/// );
/// ```
class IntervalHeartbeat implements SocketHeartbeat {
  IntervalHeartbeat({
    required HeartbeatConfig config,
    HeartbeatPingBuilder? pingBuilder,
    SocketLogger? logger,
  }) : _pingBuilder = pingBuilder ?? ConfigHeartbeatPingBuilder(config: config),
       _config = config,
       _logger = logger ?? const SocketLogger(tag: 'Heartbeat');

  final HeartbeatConfig _config;
  final HeartbeatPingBuilder _pingBuilder;
  final SocketLogger _logger;

  Timer? _pingTimer;
  Timer? _pongTimeoutTimer;
  PingSender? _send;
  PongTimeoutCallback? _onTimeout;

  @override
  bool get isRunning => _pingTimer != null;

  @override
  void start({
    required PingSender send,
    required PongTimeoutCallback onTimeout,
  }) {
    if (!_config.enabled || isRunning) return;

    _send = send;
    _onTimeout = onTimeout;

    _pingTimer = Timer.periodic(_config.interval, (_) => _sendPing());
    _logger.debug(
      'Started — interval=${_config.interval.inSeconds}s '
      'pongTimeout=${_config.pongTimeout.inSeconds}s',
    );
  }

  @override
  void didReceiveFrame() => _cancelPongTimeout();

  @override
  void stop() {
    _cancelPingTimer();
    _cancelPongTimeout();
    _send = null;
    _onTimeout = null;
    _logger.debug('Stopped');
  }

  void _sendPing() {
    final send = _send;
    if (send == null) return;

    try {
      send(_pingBuilder.buildPing());
      _logger.debug('Ping sent');
      _startPongTimeout();
    } on Exception catch (e) {
      _logger.error('Failed to send ping: $e');
    }
  }

  void _startPongTimeout() {
    // Arm the pong-timeout only if one isn't already pending. An outbound ping
    // is not proof of life, so it must not reset the timeout — otherwise, when
    // pongTimeout >= interval, each ping would cancel the still-pending timer
    // before it can fire and a silently dead link would never be detected.
    // Only didReceiveFrame() (a genuine inbound frame) clears the timer.
    _pongTimeoutTimer ??= Timer(_config.pongTimeout, _handlePongTimeout);
  }

  void _handlePongTimeout() {
    // Clear the (now-fired) timer reference so a still-running heartbeat can
    // re-arm on the next ping via _startPongTimeout's `??=`.
    _pongTimeoutTimer = null;
    _logger.warn(
      'Pong timeout — no frame within ${_config.pongTimeout.inSeconds}s',
    );
    _onTimeout?.call();
  }

  void _cancelPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _cancelPongTimeout() {
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;
  }
}
