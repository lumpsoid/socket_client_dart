import 'dart:async';
import 'dart:convert';

import 'package:socket_client/src/connection_state.dart';
import 'package:socket_client/src/logger.dart';

/// Convenience typedef.
typedef VoidCallback = void Function();

/// A typed message envelope used by the protocol layer.
class SocketMessage {
  SocketMessage({
    required this.id,
    required this.event,
    required this.data,
    DateTime? timestamp,
    this.replyTo,
  }) : timestamp = timestamp ?? DateTime.now();

  factory SocketMessage.create({
    required String event,
    Map<String, dynamic> data = const {},
    String? replyTo,
  }) {
    return SocketMessage(
      id: _generateId(),
      event: event,
      data: data,
      replyTo: replyTo,
    );
  }

  /// Deserialize from a JSON string.
  factory SocketMessage.fromJson(String raw) {
    try {
      final map = json.decode(raw) as Map<String, dynamic>;
      return SocketMessage(
        id: map['id'] as String? ?? _generateId(),
        event: map['event'] as String? ?? 'unknown',
        data: map['data'] as Map<String, dynamic>? ?? {},
        timestamp: map['timestamp'] != null
            ? DateTime.tryParse(map['timestamp'] as String) ?? DateTime.now()
            : DateTime.now(),
        replyTo: map['replyTo'] as String?,
      );
    } catch (e) {
      throw FormatException('Failed to parse SocketMessage: $e\nRaw: $raw');
    }
  }

  /// Unique message ID for correlation.
  final String id;

  /// Message event/type name (e.g., 'chat.send', 'user.joined').
  final String event;

  /// Payload data.
  final Map<String, dynamic> data;

  /// Timestamp of creation.
  final DateTime timestamp;

  /// Optional correlation ID for request-response patterns.
  final String? replyTo;

  /// Serialize to a JSON string.
  String toJson() {
    return json.encode({
      'id': id,
      'event': event,
      'data': data,
      'timestamp': timestamp.toIso8601String(),
      if (replyTo != null) 'replyTo': replyTo,
    });
  }

  static int _counter = 0;
  static String _generateId() {
    _counter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_counter';
  }

  @override
  String toString() => 'SocketMessage($event, id=$id)';
}

/// Callback type for message handlers.
typedef MessageHandler = FutureOr<void> Function(SocketMessage message);

/// Middleware that can intercept, transform, or block messages.
typedef MessageMiddleware =
    FutureOr<SocketMessage?> Function(SocketMessage message);

/// Protocol layer that adds structured messaging on top of raw socket I/O.
///
/// Features:
/// - Event-based routing (subscribe to specific event types)
/// - Request-response with timeout (awaitable replies)
/// - Middleware pipeline (auth injection, logging, compression)
/// - Automatic serialization/deserialization
/// - Message acknowledgement tracking
class MessageProtocol {
  MessageProtocol({SocketLogger? logger})
    : _logger = logger ?? const SocketLogger(tag: 'Protocol');
  final SocketLogger _logger;

  final Map<String, List<MessageHandler>> _handlers = {};
  final List<MessageMiddleware> _inboundMiddleware = [];
  final List<MessageMiddleware> _outboundMiddleware = [];
  final Map<String, Completer<SocketMessage>> _pendingRequests = {};

  final _allMessagesController = StreamController<SocketMessage>.broadcast();

  /// Stream of all decoded inbound messages.
  Stream<SocketMessage> get messages => _allMessagesController.stream;

  // ─── Event Handlers ──────────────────────────────────────────

  /// Subscribe to messages of a specific event type.
  /// Returns an unsubscribe callback.
  VoidCallback on(String event, MessageHandler handler) {
    _handlers.putIfAbsent(event, () => []);
    _handlers[event]!.add(handler);
    return () => _handlers[event]?.remove(handler);
  }

  /// Subscribe to a single occurrence of an event.
  void once(String event, MessageHandler handler) {
    late VoidCallback unsub;
    unsub = on(event, (msg) {
      unsub();
      handler(msg);
    });
  }

  /// Remove all handlers for an event.
  void off(String event) {
    _handlers.remove(event);
  }

  // ─── Middleware ───────────────────────────────────────────────

  /// Add middleware to the inbound pipeline.
  void useInbound(MessageMiddleware middleware) {
    _inboundMiddleware.add(middleware);
  }

  /// Add middleware to the outbound pipeline.
  void useOutbound(MessageMiddleware middleware) {
    _outboundMiddleware.add(middleware);
  }

  // ─── Inbound Processing ──────────────────────────────────────

  /// Process a raw incoming message string.
  Future<void> handleRawMessage(String raw) async {
    SocketMessage message;
    try {
      message = SocketMessage.fromJson(raw);
    } on FormatException catch (e) {
      _logger.warn('Malformed message: $e');
      return;
    }

    // Run inbound middleware pipeline
    SocketMessage? processed = message;
    for (final mw in _inboundMiddleware) {
      processed = await mw(processed!);
      if (processed == null) {
        _logger.debug('Message ${message.id} blocked by middleware');
        return;
      }
    }
    message = processed!;

    _allMessagesController.add(message);

    // Check for pending request-response correlation
    if (message.replyTo != null &&
        _pendingRequests.containsKey(message.replyTo)) {
      _pendingRequests[message.replyTo]!.complete(message);
      _pendingRequests.remove(message.replyTo);
    }

    // Route to event handlers
    final handlers = _handlers[message.event];
    if (handlers != null && handlers.isNotEmpty) {
      for (final handler in List.of(handlers)) {
        try {
          await handler(message);
        } catch (e, st) {
          _logger.error('Handler error for "${message.event}": $e\n$st');
        }
      }
    }

    // Wildcard handlers
    final wildcardHandlers = _handlers['*'];
    if (wildcardHandlers != null) {
      for (final handler in List.of(wildcardHandlers)) {
        try {
          await handler(message);
        } catch (e, st) {
          _logger.error('Wildcard handler error: $e\n$st');
        }
      }
    }
  }

  // ─── Outbound Processing ─────────────────────────────────────

  /// Prepare a message for sending (runs outbound middleware).
  /// Returns the serialized JSON string, or null if blocked.
  Future<String?> prepareOutbound(SocketMessage message) async {
    SocketMessage? processed = message;
    for (final mw in _outboundMiddleware) {
      processed = await mw(processed!);
      if (processed == null) {
        _logger.debug('Outbound message ${message.id} blocked by middleware');
        return null;
      }
    }
    return processed!.toJson();
  }

  // ─── Request-Response Pattern ────────────────────────────────

  /// Send a request and wait for a correlated response.
  ///
  /// The response message must have `replyTo` set to this message's `id`.
  Future<SocketMessage> createRequest(
    SocketMessage message, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final completer = Completer<SocketMessage>();
    _pendingRequests[message.id] = completer;

    // Timeout cleanup
    Timer(timeout, () {
      if (!completer.isCompleted) {
        _pendingRequests.remove(message.id);
        completer.completeError(
          SocketError(
            type: SocketErrorType.timeout,
            message:
                'Request ${message.id} timed out after ${timeout.inSeconds}s',
            timestamp: DateTime.now(),
          ),
        );
      }
    });

    return completer.future;
  }

  Future<void> dispose() async {
    _handlers.clear();
    _inboundMiddleware.clear();
    _outboundMiddleware.clear();
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          SocketError(
            type: SocketErrorType.stream,
            message: 'Protocol disposed while request pending',
            timestamp: DateTime.now(),
          ),
        );
      }
    }
    _pendingRequests.clear();
    await _allMessagesController.close();
  }
}
