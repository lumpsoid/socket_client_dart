import 'dart:async';

import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/protocol/pending_requests.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/util/logger.dart';

/// Routes decoded frames to per-topic [Stream]s and manages request-reply
/// correlation. No callbacks, no event registries — just streams.
///
/// ```dart
/// final router = TopicRouter(codec: MyCodec());
///
/// // Subscribe to a topic.
/// router.topic('room:lobby').listen((frame) { ... });
///
/// // Send a request and await the correlated reply.
/// final reply = await router.request(
///   myFrame,
///   send: (encoded) => transport.sendText(encoded),
/// );
/// ```
class TopicRouter<T> {
  TopicRouter({
    required FrameCodec<T> codec,
    SocketLogger? logger,
  }) : _codec = codec,
       _logger = logger ?? const SocketLogger(tag: 'TopicRouter'),
       _pending = PendingRequests<T>(
         logger: logger ?? const SocketLogger(tag: 'PendingRequests'),
       );

  final FrameCodec<T> _codec;
  final SocketLogger _logger;
  final PendingRequests<T> _pending;

  /// Lazily created per-topic broadcast controllers.
  final Map<String, StreamController<T>> _topics = {};

  /// A catch-all broadcast stream for every decoded frame, regardless of topic.
  final StreamController<T> _allFrames = StreamController<T>.broadcast();

  Stream<T> get allFrames => _allFrames.stream;

  //Topic Streams

  /// Returns the broadcast stream for [topic], creating it on first access.
  ///
  /// Streams are never closed by the router — dispose of your subscriptions
  /// when done.
  Stream<T> topic(String topic) {
    return _topicController(topic).stream;
  }

  StreamController<T> _topicController(String key) =>
      _topics.putIfAbsent(key, StreamController<T>.broadcast);

  // Inbound

  /// Ingest a raw text frame from the transport layer.
  ///
  /// Decodes via [FrameCodec.decode], resolves any pending reply, then
  /// emits on the appropriate topic stream.
  Future<void> ingest(String raw) async {
    T frame;
    try {
      frame = _codec.decode(raw);
    } on FrameDecodeException catch (e) {
      _logger.warn('Frame decode failed: $e');
      return;
    } on Exception catch (e) {
      _logger.warn('Unexpected decode error: $e');
      return;
    }

    _allFrames.add(frame);

    // Resolve a pending request if this is a reply.
    final replyId = _codec.replyCorrelationId(frame);
    if (replyId != null) {
      _pending.resolve(replyId, frame);
    }

    // Route to topic stream.
    final key = _codec.topicOf(frame);
    _topicController(key).add(frame);
    _logger.debug('Routed frame → topic "$key"');
  }

  // Outbound / Request-Reply

  /// Encode [frame] and pass it to [send], then wait for the correlated reply.
  ///
  /// [FrameCodec.correlationId] must return a non-null ID for [frame], or
  /// this method throws [ArgumentError].
  ///
  /// Throws [SocketError] (type: timeout) if no reply arrives within [timeout].
  Future<T> request(
    T frame, {
    required void Function(String encoded) send,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final id = _codec.correlationId(frame);
    if (id == null) {
      throw ArgumentError(
        'FrameCodec.correlationId returned null for a request frame. '
        'Ensure your codec assigns IDs to frames that expect replies.',
      );
    }
    final future = _pending.register(id, timeout: timeout);
    final encoded = _codec.encode(frame);
    send(encoded);
    return future;
  }

  /// Encode [frame] and pass it to [send]. No reply tracking.
  void emit(T frame, {required void Function(String encoded) send}) {
    send(_codec.encode(frame));
  }

  Future<void> dispose() async {
    _pending.dispose();
    for (final ctrl in _topics.values) {
      await ctrl.close();
    }
    _topics.clear();
    await _allFrames.close();
    _logger.info('TopicRouter disposed');
  }
}
