import 'package:socket_client/src/transport/connection_config.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionConfig', () {
    const base = ConnectionConfig(
      url: 'wss://example.com/ws',
      connectTimeout: Duration(seconds: 10),
    );

    test('copyWith replaces url', () {
      final copy = base.copyWith(url: 'wss://other.com/ws');
      expect(copy.url, 'wss://other.com/ws');
      expect(copy.connectTimeout, base.connectTimeout);
    });

    test('copyWith replaces connectTimeout', () {
      final copy = base.copyWith(connectTimeout: const Duration(seconds: 30));
      expect(copy.connectTimeout, const Duration(seconds: 30));
      expect(copy.url, base.url);
    });

    test('copyWith replaces headers', () {
      final copy = base.copyWith(headers: {'Authorization': 'Bearer token'});
      expect(copy.headers, {'Authorization': 'Bearer token'});
    });

    test('copyWith replaces protocols', () {
      final copy = base.copyWith(protocols: ['v1', 'v2']);
      expect(copy.protocols, ['v1', 'v2']);
    });

    test('copyWith with no args returns equivalent config', () {
      final copy = base.copyWith();
      expect(copy.url, base.url);
      expect(copy.connectTimeout, base.connectTimeout);
      expect(copy.headers, base.headers);
    });
  });

  group('HeartbeatConfig', () {
    test('defaults', () {
      const cfg = HeartbeatConfig();
      expect(cfg.enabled, isTrue);
      expect(cfg.interval, const Duration(seconds: 30));
      expect(cfg.pongTimeout, const Duration(seconds: 10));
      expect(cfg.pingMessage, 'ping');
    });
  });

  group('ReconnectConfig', () {
    test('defaults', () {
      const cfg = ReconnectConfig();
      expect(cfg.enabled, isTrue);
      expect(cfg.maxAttempts, 10);
      expect(cfg.jitter, isTrue);
    });
  });
}
