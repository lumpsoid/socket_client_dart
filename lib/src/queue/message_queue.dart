import 'dart:async';
import 'dart:collection';

import 'package:socket_client/src/util/logger.dart';

enum MessagePriority { low, normal, high, critical }

/// A frame buffered for offline delivery.
class QueuedFrame<T> {
  QueuedFrame({
    required this.encoded,
    required this.frame,
    this.priority = MessagePriority.normal,
    this.ttl,
    DateTime? queuedAt,
    this.attempts = 0,
  }) : queuedAt = queuedAt ?? DateTime.now();

  /// Pre-encoded wire representation.
  final String encoded;

  /// Original decoded frame (for inspection/logging).
  final T frame;

  final MessagePriority priority;
  final DateTime queuedAt;
  final Duration? ttl;
  int attempts;

  bool get isExpired {
    if (ttl == null) return false;
    return DateTime.now().difference(queuedAt) > ttl!;
  }
}

/// Priority queue that buffers outbound frames while the transport is offline.
///
/// Integration pattern:
/// ```dart
/// // On send while disconnected:
/// queue.enqueue(encoded, frame, priority: MessagePriority.high);
///
/// // On reconnect:
/// transport.stateStream
///   .where((s) => s == SocketConnectionState.connected)
///   .listen((_) {
///     for (final queued in queue.dequeueAll()) {
///       transport.sendText(queued.encoded);
///     }
///   });
/// ```
class MessageQueue<T> {
  MessageQueue({
    this.maxSize = 1000,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'MessageQueue') {
    for (final p in MessagePriority.values) {
      _buckets[p.index] = Queue<QueuedFrame<T>>();
    }
  }

  final int maxSize;
  final SocketLogger _logger;
  final _buckets = SplayTreeMap<int, Queue<QueuedFrame<T>>>();
  int _size = 0;

  final _droppedController = StreamController<QueuedFrame<T>>.broadcast();

  int get length => _size;
  bool get isEmpty => _size == 0;
  bool get isFull => _size >= maxSize;

  /// Emits frames dropped due to TTL expiry or queue-full eviction.
  Stream<QueuedFrame<T>> get dropped => _droppedController.stream;

  bool enqueue(
    String encoded,
    T frame, {
    MessagePriority priority = MessagePriority.normal,
    Duration? ttl,
  }) {
    _purgeExpired();

    if (_size >= maxSize) {
      if (!_evictLowest(priority)) {
        final dropped = QueuedFrame(
          encoded: encoded,
          frame: frame,
          priority: priority,
          ttl: ttl,
        );
        _droppedController.add(dropped);
        _logger.warn('Queue full; dropping frame');
        return false;
      }
    }

    _buckets[priority.index]!.add(
      QueuedFrame(
        encoded: encoded,
        frame: frame,
        priority: priority,
        ttl: ttl,
      ),
    );
    _size++;
    _logger.debug('Enqueued (${priority.name}) total=$_size');
    return true;
  }

  /// Dequeue all frames in priority-descending order.
  List<QueuedFrame<T>> dequeueAll() {
    _purgeExpired();
    final result = <QueuedFrame<T>>[];
    for (var i = MessagePriority.values.length - 1; i >= 0; i--) {
      while (_buckets[i]!.isNotEmpty) {
        result.add(_buckets[i]!.removeFirst());
      }
    }
    _size = 0;
    _logger.info('Dequeued ${result.length} frames');
    return result;
  }

  QueuedFrame<T>? peek() {
    for (var i = MessagePriority.values.length - 1; i >= 0; i--) {
      if (_buckets[i]!.isNotEmpty) return _buckets[i]!.first;
    }
    return null;
  }

  void clear() {
    for (final b in _buckets.values) {
      b.clear();
    }
    _size = 0;
  }

  void _purgeExpired() {
    for (final bucket in _buckets.values) {
      final expired = bucket.where((f) => f.isExpired).toList();
      for (final f in expired) {
        bucket.remove(f);
        _size--;
        _droppedController.add(f);
      }
    }
  }

  bool _evictLowest(MessagePriority incoming) {
    for (var i = 0; i < incoming.index; i++) {
      if (_buckets[i]!.isNotEmpty) {
        final evicted = _buckets[i]!.removeFirst();
        _size--;
        _droppedController.add(evicted);
        _logger.debug(
          'Evicted ${MessagePriority.values[i].name} frame to make room',
        );
        return true;
      }
    }
    return false;
  }

  Future<void> dispose() async {
    clear();
    await _droppedController.close();
  }
}
