enum SocketConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  disconnecting,
  failed,
}

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

class SocketError implements Exception {
  const SocketError({
    required this.type,
    required this.message,
    required this.timestamp,
    this.originalError,
    this.stackTrace,
  });

  final SocketErrorType type;
  final String message;
  final DateTime timestamp;
  final Object? originalError;
  final StackTrace? stackTrace;

  bool get isRecoverable =>
      type == SocketErrorType.network ||
      type == SocketErrorType.timeout ||
      type == SocketErrorType.heartbeatTimeout;

  @override
  String toString() => 'SocketError(${type.name}): $message';
}
