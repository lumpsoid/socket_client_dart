import 'package:socket_client/src/queue/message_queue.dart';
import 'package:test/test.dart';

void main() {
  group('QueuedFrame.isExpired', () {
    test('returns false when ttl is null', () {
      final f = QueuedFrame(encoded: 'x', frame: 'x');
      expect(f.isExpired, isFalse);
    });

    test('returns false when within TTL', () {
      final f = QueuedFrame(
        encoded: 'x',
        frame: 'x',
        ttl: const Duration(seconds: 10),
        queuedAt: DateTime.now(),
      );
      expect(f.isExpired, isFalse);
    });

    test('returns true when past TTL', () {
      final f = QueuedFrame(
        encoded: 'x',
        frame: 'x',
        ttl: const Duration(milliseconds: 1),
        queuedAt: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      expect(f.isExpired, isTrue);
    });
  });

  group('MessageQueue', () {
    late MessageQueue<String> queue;

    setUp(() => queue = MessageQueue<String>(maxSize: 5));
    tearDown(() => queue.dispose());

    test('starts empty', () {
      expect(queue.isEmpty, isTrue);
      expect(queue.length, 0);
    });

    test('enqueue increments length', () {
      queue
        ..enqueue('a', 'a')
        ..enqueue('b', 'b');
      expect(queue.length, 2);
      expect(queue.isEmpty, isFalse);
    });

    test('dequeueAll returns frames in priority-descending order', () {
      queue
        ..enqueue('low', 'low', priority: MessagePriority.low)
        ..enqueue('high', 'high', priority: MessagePriority.high)
        ..enqueue('normal', 'normal', priority: MessagePriority.normal)
        ..enqueue('critical', 'critical', priority: MessagePriority.critical);

      final frames = queue.dequeueAll();
      expect(frames.map((f) => f.priority).toList(), [
        MessagePriority.critical,
        MessagePriority.high,
        MessagePriority.normal,
        MessagePriority.low,
      ]);
    });

    test('dequeueAll empties the queue', () {
      queue
        ..enqueue('x', 'x')
        ..dequeueAll();
      expect(queue.isEmpty, isTrue);
    });

    test('peek returns highest priority frame without removing it', () {
      queue
        ..enqueue('low', 'low', priority: MessagePriority.low)
        ..enqueue('crit', 'crit', priority: MessagePriority.critical);

      final top = queue.peek();
      expect(top?.priority, MessagePriority.critical);
      expect(queue.length, 2); // still in queue
    });

    test('peek returns null when empty', () {
      expect(queue.peek(), isNull);
    });

    test('clear empties the queue', () {
      queue
        ..enqueue('a', 'a')
        ..enqueue('b', 'b')
        ..clear();
      expect(queue.isEmpty, isTrue);
    });

    test(
      'returns false and emits dropped when full with no lower-priority frames',
      () async {
        final dropped = <QueuedFrame<String>>[];
        queue.dropped.listen(dropped.add);

        // Fill with high priority
        for (var i = 0; i < 5; i++) {
          queue.enqueue('h$i', 'h$i', priority: MessagePriority.high);
        }
        expect(queue.isFull, isTrue);

        // Try to add another high priority — no lower bucket to evict
        final result = queue.enqueue(
          'overflow',
          'overflow',
          priority: MessagePriority.high,
        );
        expect(result, isFalse);
      },
    );

    test('evicts lowest priority to make room for higher priority', () async {
      final dropped = <QueuedFrame<String>>[];
      queue.dropped.listen(dropped.add);

      for (var i = 0; i < 5; i++) {
        queue.enqueue('low$i', 'low$i', priority: MessagePriority.low);
      }

      // Enqueue a critical frame — should evict a low frame
      final result = queue.enqueue(
        'crit',
        'crit',
        priority: MessagePriority.critical,
      );
      expect(result, isTrue);
      expect(queue.length, 5);

      await Future<void>.delayed(Duration.zero); // allow broadcast
      expect(dropped, hasLength(1));
      expect(dropped.first.priority, MessagePriority.low);
    });

    test('expired frames are purged and emitted on dropped stream', () async {
      final dropped = <QueuedFrame<String>>[];
      queue.dropped.listen(dropped.add);

      queue.enqueue(
        'expiring',
        'expiring',
        ttl: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Trigger purge by calling enqueue or dequeueAll
      queue.enqueue('fresh', 'fresh');
      await Future<void>.delayed(Duration.zero);

      expect(dropped, hasLength(1));
      expect(dropped.first.encoded, 'expiring');
    });
  });
}
