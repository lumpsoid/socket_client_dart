/// Represents the lifecycle states of a socket connection.
enum SocketConnectionState {
  /// No active connection.
  disconnected,

  /// Attempting to establish connection.
  connecting,

  /// Connection is open and ready.
  connected,

  /// Attempting to re-establish a dropped connection.
  reconnecting,

  /// Gracefully closing.
  disconnecting,

  /// Terminal failure (e.g., max retries exceeded).
  failed,
}

/// Categorized socket error types.
enum SocketErrorType {
  network,
  timeout,
  protocol,
  tls,
  heartbeatTimeout,
  maxRetriesExceeded,
  authentication,
  serialization,
  stream,
  unknown,
}

/// Structured error emitted by the socket system.
class SocketError implements Exception {
  final SocketErrorType type;
  final String message;
  final DateTime timestamp;
  final Object? originalError;
  final StackTrace? stackTrace;

  const SocketError({
    required this.type,
    required this.message,
    required this.timestamp,
    this.originalError,
    this.stackTrace,
  });

  bool get isRecoverable =>
      type == SocketErrorType.network ||
      type == SocketErrorType.timeout ||
      type == SocketErrorType.heartbeatTimeout;

  @override
  String toString() => 'SocketError(${type.name}): $message';
}
