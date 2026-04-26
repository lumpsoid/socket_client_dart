import 'dart:math';

import '../models/connection_config.dart';

/// Strategy for computing reconnection delays.
abstract class BackoffStrategy {
  Duration nextDelay();
  void reset();
}

/// Exponential backoff with optional full jitter.
///
/// delay = min(maxDelay, initialDelay * multiplier^attempt)
/// With jitter: delay = random(0, delay)
class ExponentialBackoff implements BackoffStrategy {
  final ReconnectConfig config;
  final Random _random = Random();
  int _attempt = 0;

  ExponentialBackoff({required this.config});

  @override
  Duration nextDelay() {
    final exponentialMs =
        config.initialDelay.inMilliseconds *
        pow(config.multiplier, _attempt).toDouble();

    final cappedMs = min(exponentialMs, config.maxDelay.inMilliseconds.toDouble());

    final delayMs = config.jitter
        ? (_random.nextDouble() * cappedMs).round()
        : cappedMs.round();

    _attempt++;
    return Duration(milliseconds: max(delayMs, 100));
  }

  @override
  void reset() {
    _attempt = 0;
  }
}

/// Linear backoff: delay = initialDelay + (step * attempt).
class LinearBackoff implements BackoffStrategy {
  final Duration initialDelay;
  final Duration step;
  final Duration maxDelay;
  int _attempt = 0;

  LinearBackoff({
    this.initialDelay = const Duration(seconds: 1),
    this.step = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 60),
  });

  @override
  Duration nextDelay() {
    final delayMs = initialDelay.inMilliseconds +
        (step.inMilliseconds * _attempt);
    _attempt++;
    return Duration(
      milliseconds: min(delayMs, maxDelay.inMilliseconds),
    );
  }

  @override
  void reset() {
    _attempt = 0;
  }
}
