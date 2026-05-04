import 'dart:math';

import 'package:socket_client/src/transport/connection_config.dart';

abstract class ReconnectionStrategy {
  int get maxAttempts;
  int get attempt;
  bool get isExhausted;
  Duration nextDelay();
  void reset();
}

/// Exponential backoff with optional full jitter.
///
/// delay = min(maxDelay, initialDelay × multiplier^attempt)
/// With jitter: delay = random(0, delay)
class ExponentialBackoff implements ReconnectionStrategy {
  ExponentialBackoff({required ReconnectConfig config}) : _config = config;

  final ReconnectConfig _config;
  final Random _rng = Random();
  int _attempt = 0;

  @override
  bool get isExhausted => _attempt == _config.maxAttempts;

  @override
  int get maxAttempts => _config.maxAttempts;

  @override
  int get attempt => _attempt;

  @override
  Duration nextDelay() {
    final exponentialMs =
        _config.initialDelay.inMilliseconds *
        pow(_config.multiplier, _attempt).toDouble();
    final cappedMs = min(
      exponentialMs,
      _config.maxDelay.inMilliseconds.toDouble(),
    );
    final delayMs = _config.jitter
        ? (_rng.nextDouble() * cappedMs).round()
        : cappedMs.round();
    _attempt++;
    return Duration(milliseconds: max(delayMs, 100));
  }

  @override
  void reset() => _attempt = 0;
}

/// Linear backoff: delay = initialDelay + step × attempt, capped at maxDelay.
class LinearBackoff implements ReconnectionStrategy {
  LinearBackoff({
    this.initialDelay = const Duration(seconds: 1),
    this.step = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 60),
    this.maxAttempts = -1,
  });

  final Duration initialDelay;
  final Duration step;
  final Duration maxDelay;

  /// -1 signals unlimited
  @override
  final int maxAttempts;

  int _attempt = 0;

  @override
  int get attempt => _attempt;

  @override
  Duration nextDelay() {
    final ms = initialDelay.inMilliseconds + (step.inMilliseconds * _attempt);
    _attempt++;
    return Duration(milliseconds: min(ms, maxDelay.inMilliseconds));
  }

  @override
  void reset() => _attempt = 0;

  @override
  bool get isExhausted => maxAttempts != -1 && _attempt >= maxAttempts;
}
