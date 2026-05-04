import 'dart:async';

import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/heartbeat_ping_builder.dart';
import 'package:socket_client/src/transport/socket_heartbeat.dart';
import 'package:socket_client/src/util/logger.dart';

class IntervalFramedHeartbeat<T> implements SocketHeartbeat {
  IntervalFramedHeartbeat({
    required FrameHeartbeatPingBuilder<T> pingBuilder,
    required HeartbeatConfig config,
    SocketLogger? logger,
  }) : _pingBuilder = pingBuilder,
       _config = config,
       _logger = logger ?? const SocketLogger(tag: 'Heartbeat');

  final HeartbeatConfig _config;
  final FrameHeartbeatPingBuilder<T> _pingBuilder;
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
      final frame = _pingBuilder.buildPing();
      send(frame);
      _logger.debug('Ping sent');
      _startPongTimeout();
    } on Exception catch (e) {
      _logger.error('Failed to send ping: $e');
    }
  }

  void _startPongTimeout() {
    _cancelPongTimeout();
    _pongTimeoutTimer = Timer(_config.pongTimeout, _handlePongTimeout);
  }

  void _handlePongTimeout() {
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
