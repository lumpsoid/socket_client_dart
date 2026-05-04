/// The single seam between the library and any wire protocol.
///
/// Implement this for Phoenix, STOMP, JSON-RPC, SignalR, or your own protocol.
/// The library ships no concrete implementations — protocol specifics belong
/// to the consumer or a separate package.
///
/// Type parameter [T] is the decoded frame type your application works with.
///
/// ## Example (minimal JSON map codec)
/// ```dart
/// class JsonMapCodec implements FrameCodec<Map<String, dynamic>> {
///   @override
///   Map<String, dynamic> decode(String raw) => json.decode(raw);
///
///   @override
///   String encode(Map<String, dynamic> frame) => json.encode(frame);
///
///   @override
///   String? correlationId(Map<String, dynamic> frame) =>
///       frame['id'] as String?;
///
///   @override
///   String? replyCorrelationId(Map<String, dynamic> frame) =>
///       frame['replyTo'] as String?;
///
///   @override
///   String topicOf(Map<String, dynamic> frame) =>
///       frame['event'] as String? ?? 'unknown';
/// }
/// ```
abstract class FrameCodec<T> {
  /// Decode a raw text frame from the wire into [T].
  ///
  /// Throw a [FrameDecodeException] on malformed input.
  T decode(String raw);

  /// Encode a frame of type [T] into a raw text frame for the wire.
  String encode(T frame);

  /// Extract the correlation ID from [frame], if this frame is a request
  /// that expects a correlated response.
  ///
  /// Return `null` if this frame type never expects a reply.
  String? correlationId(T frame);

  /// Extract the ID this [frame] is replying to, if any.
  String? replyCorrelationId(T frame);
}

/// Thrown by [FrameCodec.decode] when a raw frame cannot be parsed.
class FrameDecodeException implements Exception {
  const FrameDecodeException(this.message, {this.raw, this.cause});

  final String message;
  final String? raw;
  final Object? cause;

  @override
  String toString() =>
      'FrameDecodeException: $message${raw != null ? '\nRaw: $raw' : ''}';
}
