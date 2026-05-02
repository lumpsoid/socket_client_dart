import 'dart:async';

import 'package:socket_client/src/logger.dart';

/// Real-time metrics for the socket connection.
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

  /// Average latency from recent samples.
  Duration get averageLatency {
    if (_latencySamples.isEmpty) return Duration.zero;
    final totalMs = _latencySamples.fold<int>(
      0,
      (sum, d) => sum + d.inMilliseconds,
    );
    return Duration(milliseconds: totalMs ~/ _latencySamples.length);
  }

  /// P95 latency from recent samples.
  Duration get p95Latency {
    if (_latencySamples.isEmpty) return Duration.zero;
    final sorted = List.of(_latencySamples)
      ..sort((a, b) => a.inMilliseconds.compareTo(b.inMilliseconds));
    final index = (sorted.length * 0.95).floor().clamp(0, sorted.length - 1);
    return sorted[index];
  }

  void recordLatency(Duration latency) {
    _latencySamples.add(latency);
    // Keep only last 100 samples
    if (_latencySamples.length > 100) {
      _latencySamples.removeAt(0);
    }
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

  void markReconnect() {
    reconnectCount++;
  }

  /// Snapshot of current metrics as a map.
  Map<String, dynamic> toMap() {
    return {
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
  }

  void reset() {
    messagesSent = 0;
    messagesReceived = 0;
    bytesTransmitted = 0;
    bytesReceived = 0;
    reconnectCount = 0;
    errorCount = 0;
    droppedMessages = 0;
    _latencySamples.clear();
    totalUptime = Duration.zero;
    _uptimeStart = null;
  }
}

/// Health check status.
enum HealthStatus { healthy, degraded, unhealthy }

/// Monitors connection health based on metrics thresholds.
class HealthMonitor {
  HealthMonitor({
    required this.metrics,
    this.checkInterval = const Duration(seconds: 30),
    this.maxLatency = const Duration(milliseconds: 5000),
    this.maxErrorsPerMinute = 5,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'Health');

  final SocketMetrics metrics;
  final Duration checkInterval;
  final Duration maxLatency;
  final int maxErrorsPerMinute;
  final SocketLogger _logger;

  Timer? _timer;
  HealthStatus _status = HealthStatus.healthy;

  final _statusController = StreamController<HealthStatus>.broadcast();
  final List<DateTime> _recentErrors = [];

  HealthStatus get status => _status;
  Stream<HealthStatus> get statusStream => _statusController.stream;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(checkInterval, (_) => check());
  }

  void stop() {
    _timer?.cancel();
  }

  void recordError() {
    _recentErrors.add(DateTime.now());
  }

  HealthStatus check() {
    // Purge errors older than 1 minute
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    _recentErrors.removeWhere((t) => t.isBefore(cutoff));

    HealthStatus newStatus;

    if (_recentErrors.length >= maxErrorsPerMinute) {
      newStatus = HealthStatus.unhealthy;
    } else if (metrics.averageLatency > maxLatency) {
      newStatus = HealthStatus.degraded;
    } else if (_recentErrors.isNotEmpty) {
      newStatus = HealthStatus.degraded;
    } else {
      newStatus = HealthStatus.healthy;
    }

    if (newStatus != _status) {
      _logger.info('Health: ${_status.name} → ${newStatus.name}');
      _status = newStatus;
      _statusController.add(newStatus);
    }

    return newStatus;
  }

  Future<void> dispose() async {
    stop();
    await _statusController.close();
  }
}
