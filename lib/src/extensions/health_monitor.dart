import 'dart:async';

import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:socket_client/src/util/logger.dart';

enum HealthStatus { healthy, degraded, unhealthy }

/// Connection health monitor driven by [SocketMetrics] thresholds.
///
/// Attach to a [SocketTransport] to automatically track connect/disconnect
/// events:
/// ```dart
/// final monitor = HealthMonitor.attach(
///   transport: transport,
///   metrics: metrics,
/// );
/// monitor.statusStream.listen((s) => print('Health: ${s.name}'));
/// monitor.start();
/// ```
class HealthMonitor {
  HealthMonitor({
    required this.metrics,
    this.checkInterval = const Duration(seconds: 30),
    this.maxLatency = const Duration(milliseconds: 5000),
    this.maxErrorsPerMinute = 5,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'Health');

  factory HealthMonitor.attach({
    required SocketTransport transport,
    required SocketMetrics metrics,
    Duration checkInterval = const Duration(seconds: 30),
    Duration maxLatency = const Duration(milliseconds: 5000),
    int maxErrorsPerMinute = 5,
    SocketLogger? logger,
  }) {
    final monitor = HealthMonitor(
      metrics: metrics,
      checkInterval: checkInterval,
      maxLatency: maxLatency,
      maxErrorsPerMinute: maxErrorsPerMinute,
      logger: logger,
    );
    transport.stateStream.listen((state) {
      if (state == SocketConnectionState.connected) {
        metrics.markConnected();
      } else if (state == SocketConnectionState.disconnected ||
          state == SocketConnectionState.failed) {
        metrics.markDisconnected();
      } else if (state == SocketConnectionState.reconnecting) {
        metrics.markReconnect();
      }
    });
    transport.errorStream.listen((_) => monitor.recordError());
    return monitor;
  }

  final SocketMetrics metrics;
  final Duration checkInterval;
  final Duration maxLatency;
  final int maxErrorsPerMinute;
  final SocketLogger _logger;

  Timer? _timer;
  HealthStatus _status = HealthStatus.healthy;
  final List<DateTime> _recentErrors = [];
  final _controller = StreamController<HealthStatus>.broadcast();

  HealthStatus get status => _status;
  Stream<HealthStatus> get statusStream => _controller.stream;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(checkInterval, (_) => check());
  }

  void stop() => _timer?.cancel();

  void recordError() => _recentErrors.add(DateTime.now());

  HealthStatus check() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    _recentErrors.removeWhere((t) => t.isBefore(cutoff));

    final next = _recentErrors.length >= maxErrorsPerMinute
        ? HealthStatus.unhealthy
        : metrics.averageLatency > maxLatency
        ? HealthStatus.degraded
        : _recentErrors.isNotEmpty
        ? HealthStatus.degraded
        : HealthStatus.healthy;

    if (next != _status) {
      _logger.info('Health: ${_status.name} → ${next.name}');
      _status = next;
      _controller.add(next);
    }
    return next;
  }

  Future<void> dispose() async {
    stop();
    await _controller.close();
  }
}

/// Real-time counters and latency percentiles for a socket session.
class SocketMetrics {
  int messagesSent = 0;
  int messagesReceived = 0;
  int bytesTransmitted = 0;
  int bytesReceived = 0;
  int reconnectCount = 0;
  int errorCount = 0;
  int droppedMessages = 0;

  DateTime? lastConnectedAt;
  DateTime? lastDisconnectedAt;
  DateTime? lastMessageSentAt;
  DateTime? lastMessageReceivedAt;

  Duration totalUptime = Duration.zero;

  final List<Duration> _latencySamples = [];
  DateTime? _uptimeStart;

  Duration get averageLatency {
    if (_latencySamples.isEmpty) return Duration.zero;
    final total = _latencySamples.fold<int>(
      0,
      (sum, d) => sum + d.inMilliseconds,
    );
    return Duration(milliseconds: total ~/ _latencySamples.length);
  }

  Duration get p95Latency {
    if (_latencySamples.isEmpty) return Duration.zero;
    final sorted = List.of(_latencySamples)
      ..sort((a, b) => a.inMilliseconds.compareTo(b.inMilliseconds));
    final i = (sorted.length * 0.95).floor().clamp(0, sorted.length - 1);
    return sorted[i];
  }

  void recordLatency(Duration d) {
    _latencySamples.add(d);
    if (_latencySamples.length > 100) _latencySamples.removeAt(0);
  }

  void markConnected() {
    lastConnectedAt = DateTime.now();
    _uptimeStart = DateTime.now();
  }

  void markDisconnected() {
    lastDisconnectedAt = DateTime.now();
    if (_uptimeStart != null) {
      totalUptime += DateTime.now().difference(_uptimeStart!);
      _uptimeStart = null;
    }
  }

  void markReconnect() => reconnectCount++;

  Map<String, dynamic> toMap() => {
    'messagesSent': messagesSent,
    'messagesReceived': messagesReceived,
    'bytesTransmitted': bytesTransmitted,
    'bytesReceived': bytesReceived,
    'reconnectCount': reconnectCount,
    'errorCount': errorCount,
    'droppedMessages': droppedMessages,
    'averageLatencyMs': averageLatency.inMilliseconds,
    'p95LatencyMs': p95Latency.inMilliseconds,
    'totalUptimeSeconds': totalUptime.inSeconds,
    'lastConnectedAt': lastConnectedAt?.toIso8601String(),
    'lastMessageReceivedAt': lastMessageReceivedAt?.toIso8601String(),
  };

  void reset() {
    messagesSent = messagesReceived = bytesTransmitted = bytesReceived =
        reconnectCount = errorCount = droppedMessages = 0;
    _latencySamples.clear();
    totalUptime = Duration.zero;
    _uptimeStart = null;
  }
}
