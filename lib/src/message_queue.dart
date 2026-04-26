import 'dart:async';
import 'dart:collection';

import '../protocol/message_protocol.dart';
import '../utils/logger.dart';

/// Priority levels for queued messages.
enum MessagePriority {
  /// Deliver best-effort. May be dropped if queue is full.
  low,

  /// Standard delivery. Queued and retried.
  normal,

  /// High priority. Sent first when connection resumes.
  high,

  /// Critical. Never dropped, unlimited retries.
  critical,
}

/// A queued message with metadata for delivery tracking.
class QueuedMessage {
  final SocketMessage message;
  final MessagePriority priority;
  final DateTime queuedAt;
  final Duration? ttl;
  int attempts;

  QueuedMessage({
    required this.message,
    this.priority = MessagePriority.normal,
    DateTime? queuedAt,
    this.ttl,
    this.attempts = 0,
  }) : queuedAt = queuedAt ?? DateTime.now();

  bool get isExpired {
    if (ttl == null) return false;
    return DateTime.now().difference(queuedAt) > ttl!;
  }
}

/// Offline message buffer with priority queue and TTL.
///
/// Buffers outbound messages when the connection is down,
/// and flushes them (in priority order) when connectivity resumes.
class MessageQueue {
  final int maxSize;
  final SocketLogger _logger;
  final _queue = SplayTreeMap<int, Queue<QueuedMessage>>();
  int _totalSize = 0;

  final _droppedController = StreamController<QueuedMessage>.broadcast();

  MessageQueue({
    this.maxSize = 1000,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'MessageQueue') {
    // Initialize priority buckets
    for (final p in MessagePriority.values) {
      _queue[p.index] = Queue<QueuedMessage>();
    }
  }

  int get length => _totalSize;
  bool get isEmpty => _totalSize == 0;
  bool get isFull => _totalSize >= maxSize;

  /// Stream of messages that were dropped from the queue.
  Stream<QueuedMessage> get droppedMessages => _droppedController.stream;

  /// Enqueue a message for later delivery.
  bool enqueue(SocketMessage message, {
    MessagePriority priority = MessagePriority.normal,
    Duration? ttl,
  }) {
    // Evict expired messages first
    _purgeExpired();

    if (_totalSize >= maxSize) {
      // Try to drop lowest priority message
      if (!_evictLowest(priority)) {
        _logger.warn('Queue full, dropping message: ${message.event}');
        return false;
      }
    }

    final queued = QueuedMessage(
      message: message,
      priority: priority,
      ttl: ttl,
    );

    _queue[priority.index]!.add(queued);
    _totalSize++;
    _logger.debug('Queued: ${message.event} (priority: ${priority.name}, total: $_totalSize)');
    return true;
  }

  /// Dequeue all messages in priority order (highest first).
  List<QueuedMessage> dequeueAll() {
    _purgeExpired();

    final result = <QueuedMessage>[];

    // Iterate from highest to lowest priority
    for (var i = MessagePriority.values.length - 1; i >= 0; i--) {
      final bucket = _queue[i]!;
      while (bucket.isNotEmpty) {
        result.add(bucket.removeFirst());
      }
    }

    _totalSize = 0;
    _logger.info('Dequeued ${result.length} messages for delivery');
    return result;
  }

  /// Peek at the next message without removing it.
  QueuedMessage? peek() {
    for (var i = MessagePriority.values.length - 1; i >= 0; i--) {
      if (_queue[i]!.isNotEmpty) {
        return _queue[i]!.first;
      }
    }
    return null;
  }

  /// Clear all queued messages.
  void clear() {
    for (final bucket in _queue.values) {
      bucket.clear();
    }
    _totalSize = 0;
    _logger.info('Queue cleared');
  }

  void _purgeExpired() {
    for (final bucket in _queue.values) {
      final expired = <QueuedMessage>[];
      bucket.removeWhere((msg) {
        if (msg.isExpired) {
          expired.add(msg);
          return true;
        }
        return false;
      });
      _totalSize -= expired.length;
      for (final msg in expired) {
        _droppedController.add(msg);
      }
    }
  }

  bool _evictLowest(MessagePriority incomingPriority) {
    // Don't evict critical messages
    for (var i = 0; i < incomingPriority.index; i++) {
      if (_queue[i]!.isNotEmpty) {
        final evicted = _queue[i]!.removeFirst();
        _totalSize--;
        _droppedController.add(evicted);
        _logger.debug('Evicted: ${evicted.message.event} (${MessagePriority.values[i].name})');
        return true;
      }
    }
    return false;
  }

  void dispose() {
    clear();
    _droppedController.close();
  }
}
