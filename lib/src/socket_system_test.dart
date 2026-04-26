import 'package:test/test.dart';
import 'package:socket_network_system/socket_network_system.dart';

void main() {
  // ─── SocketMessage Tests ───────────────────────────────────

  group('SocketMessage', () {
    test('create() generates unique IDs', () {
      final a = SocketMessage.create(event: 'test');
      final b = SocketMessage.create(event: 'test');
      expect(a.id, isNot(equals(b.id)));
    });

    test('serialization roundtrip preserves data', () {
      final original = SocketMessage.create(
        event: 'user.update',
        data: {'name': 'Alice', 'age': 30},
      );

      final json = original.toJson();
      final restored = SocketMessage.fromJson(json);

      expect(restored.event, equals('user.update'));
      expect(restored.data['name'], equals('Alice'));
      expect(restored.data['age'], equals(30));
      expect(restored.id, equals(original.id));
    });

    test('fromJson handles malformed input', () {
      expect(
        () => SocketMessage.fromJson('not json'),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson handles missing fields gracefully', () {
      final msg = SocketMessage.fromJson('{"event": "test"}');
      expect(msg.event, equals('test'));
      expect(msg.data, isEmpty);
    });

    test('replyTo is preserved in serialization', () {
      final msg = SocketMessage.create(
        event: 'response',
        data: {'result': 'ok'},
        replyTo: 'request-123',
      );

      final restored = SocketMessage.fromJson(msg.toJson());
      expect(restored.replyTo, equals('request-123'));
    });
  });

  // ─── MessageProtocol Tests ─────────────────────────────────

  group('MessageProtocol', () {
    late MessageProtocol protocol;

    setUp(() {
      protocol = MessageProtocol();
    });

    tearDown(() {
      protocol.dispose();
    });

    test('routes messages to registered handlers', () async {
      final received = <String>[];

      protocol.on('greet', (msg) {
        received.add(msg.data['name'] as String);
      });

      final msg = SocketMessage.create(
        event: 'greet',
        data: {'name': 'Bob'},
      );
      await protocol.handleRawMessage(msg.toJson());

      expect(received, equals(['Bob']));
    });

    test('wildcard handler receives all messages', () async {
      final events = <String>[];

      protocol.on('*', (msg) {
        events.add(msg.event);
      });

      await protocol.handleRawMessage(
        SocketMessage.create(event: 'a').toJson(),
      );
      await protocol.handleRawMessage(
        SocketMessage.create(event: 'b').toJson(),
      );

      expect(events, equals(['a', 'b']));
    });

    test('once() fires handler only once', () async {
      var count = 0;

      protocol.once('ping', (_) => count++);

      await protocol.handleRawMessage(
        SocketMessage.create(event: 'ping').toJson(),
      );
      await protocol.handleRawMessage(
        SocketMessage.create(event: 'ping').toJson(),
      );

      expect(count, equals(1));
    });

    test('unsubscribe callback works', () async {
      var count = 0;

      final unsub = protocol.on('tick', (_) => count++);

      await protocol.handleRawMessage(
        SocketMessage.create(event: 'tick').toJson(),
      );
      unsub();
      await protocol.handleRawMessage(
        SocketMessage.create(event: 'tick').toJson(),
      );

      expect(count, equals(1));
    });

    test('inbound middleware can block messages', () async {
      var reached = false;

      protocol.useInbound((msg) => null); // Block everything
      protocol.on('test', (_) => reached = true);

      await protocol.handleRawMessage(
        SocketMessage.create(event: 'test').toJson(),
      );

      expect(reached, isFalse);
    });

    test('inbound middleware can transform messages', () async {
      String? receivedEvent;

      protocol.useInbound((msg) {
        return SocketMessage(
          id: msg.id,
          event: 'transformed',
          data: msg.data,
          timestamp: msg.timestamp,
        );
      });

      protocol.on('transformed', (msg) {
        receivedEvent = msg.event;
      });

      await protocol.handleRawMessage(
        SocketMessage.create(event: 'original').toJson(),
      );

      expect(receivedEvent, equals('transformed'));
    });

    test('outbound middleware pipeline processes sequentially', () async {
      protocol.useOutbound((msg) {
        return SocketMessage(
          id: msg.id,
          event: msg.event,
          data: {...msg.data, 'step1': true},
          timestamp: msg.timestamp,
        );
      });

      protocol.useOutbound((msg) {
        return SocketMessage(
          id: msg.id,
          event: msg.event,
          data: {...msg.data, 'step2': true},
          timestamp: msg.timestamp,
        );
      });

      final msg = SocketMessage.create(event: 'test');
      final json = await protocol.prepareOutbound(msg);
      final restored = SocketMessage.fromJson(json!);

      expect(restored.data['step1'], isTrue);
      expect(restored.data['step2'], isTrue);
    });

    test('request-response correlates by ID', () async {
      final request = SocketMessage.create(event: 'getUser');
      final responseFuture = protocol.createRequest(
        request,
        timeout: const Duration(seconds: 5),
      );

      // Simulate server response
      final response = SocketMessage.create(
        event: 'getUser.response',
        data: {'name': 'Alice'},
        replyTo: request.id,
      );
      await protocol.handleRawMessage(response.toJson());

      final result = await responseFuture;
      expect(result.data['name'], equals('Alice'));
    });
  });

  // ─── MessageQueue Tests ────────────────────────────────────

  group('MessageQueue', () {
    late MessageQueue queue;

    setUp(() {
      queue = MessageQueue(maxSize: 5);
    });

    tearDown(() {
      queue.dispose();
    });

    test('enqueue and dequeue in priority order', () {
      queue.enqueue(
        SocketMessage.create(event: 'low'),
        priority: MessagePriority.low,
      );
      queue.enqueue(
        SocketMessage.create(event: 'critical'),
        priority: MessagePriority.critical,
      );
      queue.enqueue(
        SocketMessage.create(event: 'normal'),
        priority: MessagePriority.normal,
      );

      final messages = queue.dequeueAll();
      expect(messages.length, equals(3));
      expect(messages[0].message.event, equals('critical'));
      expect(messages[1].message.event, equals('normal'));
      expect(messages[2].message.event, equals('low'));
    });

    test('respects max size', () {
      for (var i = 0; i < 10; i++) {
        queue.enqueue(SocketMessage.create(event: 'msg$i'));
      }
      expect(queue.length, lessThanOrEqualTo(5));
    });

    test('evicts lower priority when full', () {
      // Fill with low priority
      for (var i = 0; i < 5; i++) {
        queue.enqueue(
          SocketMessage.create(event: 'low$i'),
          priority: MessagePriority.low,
        );
      }

      // Add high priority — should evict a low
      final added = queue.enqueue(
        SocketMessage.create(event: 'high'),
        priority: MessagePriority.high,
      );

      expect(added, isTrue);
      expect(queue.length, equals(5));
    });

    test('expired messages are purged', () async {
      queue.enqueue(
        SocketMessage.create(event: 'ephemeral'),
        ttl: const Duration(milliseconds: 50),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      final messages = queue.dequeueAll();
      expect(messages, isEmpty);
    });

    test('clear removes all messages', () {
      queue.enqueue(SocketMessage.create(event: 'a'));
      queue.enqueue(SocketMessage.create(event: 'b'));
      queue.clear();
      expect(queue.isEmpty, isTrue);
    });
  });

  // ─── BackoffStrategy Tests ─────────────────────────────────

  group('ExponentialBackoff', () {
    test('delays increase exponentially', () {
      final backoff = ExponentialBackoff(
        config: const ReconnectConfig(
          initialDelay: Duration(seconds: 1),
          multiplier: 2.0,
          maxDelay: Duration(seconds: 60),
          jitter: false,
        ),
      );

      final d1 = backoff.nextDelay();
      final d2 = backoff.nextDelay();
      final d3 = backoff.nextDelay();

      expect(d1.inMilliseconds, equals(1000));
      expect(d2.inMilliseconds, equals(2000));
      expect(d3.inMilliseconds, equals(4000));
    });

    test('caps at maxDelay', () {
      final backoff = ExponentialBackoff(
        config: const ReconnectConfig(
          initialDelay: Duration(seconds: 10),
          multiplier: 10.0,
          maxDelay: Duration(seconds: 30),
          jitter: false,
        ),
      );

      backoff.nextDelay(); // 10s
      backoff.nextDelay(); // capped at 30s
      final d3 = backoff.nextDelay(); // capped at 30s

      expect(d3.inSeconds, equals(30));
    });

    test('reset restarts the sequence', () {
      final backoff = ExponentialBackoff(
        config: const ReconnectConfig(
          initialDelay: Duration(seconds: 1),
          multiplier: 2.0,
          jitter: false,
        ),
      );

      backoff.nextDelay(); // 1s
      backoff.nextDelay(); // 2s
      backoff.reset();
      final d = backoff.nextDelay(); // back to 1s

      expect(d.inMilliseconds, equals(1000));
    });

    test('jitter produces variable delays', () {
      final backoff = ExponentialBackoff(
        config: const ReconnectConfig(
          initialDelay: Duration(seconds: 5),
          multiplier: 2.0,
          jitter: true,
        ),
      );

      // With jitter, delays should vary
      final delays = List.generate(20, (_) {
        backoff.reset();
        return backoff.nextDelay().inMilliseconds;
      });

      // Not all identical (statistically near-impossible with jitter)
      final unique = delays.toSet();
      expect(unique.length, greaterThan(1));
    });
  });

  // ─── SocketMetrics Tests ───────────────────────────────────

  group('SocketMetrics', () {
    test('averageLatency computes correctly', () {
      final metrics = SocketMetrics();
      metrics.recordLatency(const Duration(milliseconds: 100));
      metrics.recordLatency(const Duration(milliseconds: 200));
      metrics.recordLatency(const Duration(milliseconds: 300));

      expect(metrics.averageLatency.inMilliseconds, equals(200));
    });

    test('p95Latency returns correct percentile', () {
      final metrics = SocketMetrics();
      for (var i = 1; i <= 100; i++) {
        metrics.recordLatency(Duration(milliseconds: i));
      }

      expect(metrics.p95Latency.inMilliseconds, equals(95));
    });

    test('toMap returns complete snapshot', () {
      final metrics = SocketMetrics();
      metrics.messagesSent = 42;
      metrics.messagesReceived = 38;

      final map = metrics.toMap();
      expect(map['messagesSent'], equals(42));
      expect(map['messagesReceived'], equals(38));
    });

    test('reset clears everything', () {
      final metrics = SocketMetrics();
      metrics.messagesSent = 100;
      metrics.recordLatency(const Duration(milliseconds: 500));
      metrics.reset();

      expect(metrics.messagesSent, equals(0));
      expect(metrics.averageLatency, equals(Duration.zero));
    });
  });

  // ─── HealthMonitor Tests ───────────────────────────────────

  group('HealthMonitor', () {
    test('starts healthy', () {
      final health = HealthMonitor(metrics: SocketMetrics());
      expect(health.status, equals(HealthStatus.healthy));
      health.dispose();
    });

    test('degrades with errors', () {
      final health = HealthMonitor(
        metrics: SocketMetrics(),
        maxErrorsPerMinute: 3,
      );

      health.recordError();
      health.recordError();
      expect(health.check(), equals(HealthStatus.degraded));
      health.dispose();
    });

    test('becomes unhealthy at threshold', () {
      final health = HealthMonitor(
        metrics: SocketMetrics(),
        maxErrorsPerMinute: 3,
      );

      for (var i = 0; i < 5; i++) {
        health.recordError();
      }
      expect(health.check(), equals(HealthStatus.unhealthy));
      health.dispose();
    });

    test('degrades on high latency', () {
      final metrics = SocketMetrics();
      metrics.recordLatency(const Duration(milliseconds: 6000));

      final health = HealthMonitor(
        metrics: metrics,
        maxLatency: const Duration(milliseconds: 5000),
      );

      expect(health.check(), equals(HealthStatus.degraded));
      health.dispose();
    });
  });

  // ─── ConnectionConfig Tests ────────────────────────────────

  group('ConnectionConfig', () {
    test('fromUrl parses correctly', () {
      final config = ConnectionConfig.fromUrl('wss://example.com/ws');
      expect(config.uri.scheme, equals('wss'));
      expect(config.uri.host, equals('example.com'));
      expect(config.uri.path, equals('/ws'));
    });

    test('copyWith preserves unmodified fields', () {
      final original = ConnectionConfig.fromUrl(
        'wss://example.com/ws',
        connectTimeout: const Duration(seconds: 20),
      );

      final modified = original.copyWith(
        connectTimeout: const Duration(seconds: 5),
      );

      expect(modified.uri, equals(original.uri));
      expect(modified.connectTimeout.inSeconds, equals(5));
    });

    test('defaults are sensible', () {
      final config = ConnectionConfig.fromUrl('wss://example.com');
      expect(config.connectTimeout.inSeconds, equals(15));
      expect(config.heartbeat.enabled, isTrue);
      expect(config.reconnect.enabled, isTrue);
      expect(config.reconnect.maxAttempts, equals(10));
    });
  });

  // ─── Middleware Tests ──────────────────────────────────────

  group('SocketMiddleware', () {
    test('rateLimiter blocks excess messages', () async {
      final limiter = SocketMiddleware.rateLimiter(maxPerSecond: 2);

      final m1 = await limiter(SocketMessage.create(event: 'a'));
      final m2 = await limiter(SocketMessage.create(event: 'b'));
      final m3 = await limiter(SocketMessage.create(event: 'c'));

      expect(m1, isNotNull);
      expect(m2, isNotNull);
      expect(m3, isNull); // Blocked
    });

    test('eventFilter allows only listed events', () async {
      final filter = SocketMiddleware.eventFilter(
        allowList: {'chat', 'notification'},
      );

      final allowed = await filter(SocketMessage.create(event: 'chat'));
      final blocked = await filter(SocketMessage.create(event: 'internal'));

      expect(allowed, isNotNull);
      expect(blocked, isNull);
    });

    test('eventFilter blocks listed events', () async {
      final filter = SocketMiddleware.eventFilter(
        blockList: {'debug', 'trace'},
      );

      final allowed = await filter(SocketMessage.create(event: 'chat'));
      final blocked = await filter(SocketMessage.create(event: 'debug'));

      expect(allowed, isNotNull);
      expect(blocked, isNull);
    });

    test('deduplicator blocks duplicate IDs', () async {
      final dedup = SocketMiddleware.deduplicator();
      final msg = SocketMessage.create(event: 'test');

      final first = await dedup(msg);
      final second = await dedup(msg);

      expect(first, isNotNull);
      expect(second, isNull);
    });

    test('timestamper adds _sentAt field', () async {
      final ts = SocketMiddleware.timestamper();
      final msg = SocketMessage.create(event: 'test');

      final result = await ts(msg);
      expect(result!.data['_sentAt'], isNotNull);
    });
  });
}
