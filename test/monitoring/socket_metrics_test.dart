import 'package:socket_client/socket_client.dart';
import 'package:test/test.dart';

void main() {
  late SocketMetrics metrics;

  setUp(() => metrics = SocketMetrics());

  group('SocketMetrics', () {
    test('averageLatency returns zero when no samples', () {
      expect(metrics.averageLatency, Duration.zero);
    });

    test('averageLatency computes correctly', () {
      metrics
        ..recordLatency(const Duration(milliseconds: 100))
        ..recordLatency(const Duration(milliseconds: 200))
        ..recordLatency(const Duration(milliseconds: 300));
      expect(metrics.averageLatency.inMilliseconds, 200);
    });

    test('p95Latency returns correct percentile', () {
      for (var i = 1; i <= 100; i++) {
        metrics.recordLatency(Duration(milliseconds: i));
      }
      expect(metrics.p95Latency.inMilliseconds, greaterThanOrEqualTo(95));
    });

    test('latency sample buffer is capped at 100', () {
      for (var i = 0; i < 150; i++) {
        metrics.recordLatency(const Duration(milliseconds: 10));
      }
      // averageLatency should still compute without error
      expect(metrics.averageLatency.inMilliseconds, 10);
    });

    test('markConnected sets lastConnectedAt', () {
      metrics.markConnected();
      expect(metrics.lastConnectedAt, isNotNull);
    });

    test('markDisconnected accumulates totalUptime', () {
      metrics
        ..markConnected()
        ..markDisconnected();
      expect(metrics.totalUptime, greaterThan(Duration.zero));
      expect(metrics.lastDisconnectedAt, isNotNull);
    });

    test('markReconnect increments reconnectCount', () {
      metrics
        ..markReconnect()
        ..markReconnect();
      expect(metrics.reconnectCount, 2);
    });

    test('reset clears all counters', () {
      metrics
        ..messagesSent = 5
        ..messagesReceived = 3
        ..reconnectCount = 2
        ..markConnected()
        ..recordLatency(const Duration(milliseconds: 100))
        ..reset();

      expect(metrics.messagesSent, 0);
      expect(metrics.messagesReceived, 0);
      expect(metrics.reconnectCount, 0);
      expect(metrics.averageLatency, Duration.zero);
      expect(metrics.totalUptime, Duration.zero);
    });

    test('toMap contains expected keys', () {
      final map = metrics.toMap();
      expect(map, containsPair('messagesSent', 0));
      expect(map, containsPair('reconnectCount', 0));
      expect(map.containsKey('averageLatencyMs'), isTrue);
      expect(map.containsKey('p95LatencyMs'), isTrue);
      expect(map.containsKey('totalUptimeSeconds'), isTrue);
    });
  });
}
