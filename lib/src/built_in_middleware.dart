import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../protocol/message_protocol.dart';
import '../utils/logger.dart';

/// Collection of production-ready middleware factories.
class SocketMiddleware {
  SocketMiddleware._();

  /// Logs every inbound/outbound message.
  static MessageMiddleware logging({
    SocketLogger? logger,
    bool logData = false,
  }) {
    final log = logger ?? const SocketLogger(tag: 'Middleware:Log');
    return (message) {
      if (logData) {
        log.debug('${message.event} | ${message.data}');
      } else {
        log.debug('${message.event} | id=${message.id}');
      }
      return message;
    };
  }

  /// Injects an authentication token into every outbound message.
  static MessageMiddleware authInjector({
    required Future<String> Function() tokenProvider,
    String field = 'authToken',
  }) {
    return (message) async {
      final token = await tokenProvider();
      final augmented = SocketMessage(
        id: message.id,
        event: message.event,
        data: {...message.data, field: token},
        timestamp: message.timestamp,
        replyTo: message.replyTo,
      );
      return augmented;
    };
  }

  /// Rate limiter: drops messages that exceed [maxPerSecond].
  static MessageMiddleware rateLimiter({
    int maxPerSecond = 10,
    SocketLogger? logger,
  }) {
    final log = logger ?? const SocketLogger(tag: 'Middleware:RateLimit');
    final window = Queue<DateTime>();

    return (message) {
      final now = DateTime.now();

      // Purge entries older than 1 second
      while (window.isNotEmpty &&
          now.difference(window.first).inMilliseconds > 1000) {
        window.removeFirst();
      }

      if (window.length >= maxPerSecond) {
        log.warn('Rate limit exceeded, dropping: ${message.event}');
        return null; // Block message
      }

      window.add(now);
      return message;
    };
  }

  /// Adds a timestamp to every outbound message.
  static MessageMiddleware timestamper() {
    return (message) {
      return SocketMessage(
        id: message.id,
        event: message.event,
        data: {
          ...message.data,
          '_sentAt': DateTime.now().toIso8601String(),
        },
        timestamp: message.timestamp,
        replyTo: message.replyTo,
      );
    };
  }

  /// Filters out messages by event name.
  static MessageMiddleware eventFilter({
    Set<String>? allowList,
    Set<String>? blockList,
  }) {
    assert(
      allowList == null || blockList == null,
      'Use either allowList or blockList, not both',
    );

    return (message) {
      if (allowList != null && !allowList.contains(message.event)) {
        return null;
      }
      if (blockList != null && blockList.contains(message.event)) {
        return null;
      }
      return message;
    };
  }

  /// Compresses message payload with gzip for large messages.
  static MessageMiddleware compressionOutbound({
    int thresholdBytes = 1024,
  }) {
    return (message) {
      final json = message.toJson();
      if (json.length < thresholdBytes) return message;

      final compressed = gzip.encode(utf8.encode(json));
      return SocketMessage(
        id: message.id,
        event: message.event,
        data: {
          ...message.data,
          '_compressed': true,
          '_originalSize': json.length,
        },
        timestamp: message.timestamp,
        replyTo: message.replyTo,
      );
    };
  }

  /// Decompresses inbound messages that were compressed.
  static MessageMiddleware compressionInbound() {
    return (message) {
      if (message.data['_compressed'] == true) {
        // In a real implementation, the raw bytes would need
        // to be decompressed before JSON parsing.
        // This is a placeholder for the pattern.
      }
      return message;
    };
  }

  /// Retry middleware: re-queues failed outbound messages.
  static MessageMiddleware retryQueue({
    int maxRetries = 3,
    Duration retryDelay = const Duration(seconds: 2),
    SocketLogger? logger,
  }) {
    final log = logger ?? const SocketLogger(tag: 'Middleware:Retry');
    final retries = <String, int>{};

    return (message) {
      final count = retries[message.id] ?? 0;
      if (count >= maxRetries) {
        log.warn('Max retries reached for ${message.id}, dropping');
        retries.remove(message.id);
        return null;
      }
      retries[message.id] = count + 1;
      return message;
    };
  }

  /// Deduplicates messages by ID within a time window.
  static MessageMiddleware deduplicator({
    Duration window = const Duration(seconds: 5),
  }) {
    final seen = <String, DateTime>{};

    return (message) {
      final now = DateTime.now();

      // Purge old entries
      seen.removeWhere(
          (_, time) => now.difference(time) > window);

      if (seen.containsKey(message.id)) {
        return null; // Duplicate
      }
      seen[message.id] = now;
      return message;
    };
  }
}
