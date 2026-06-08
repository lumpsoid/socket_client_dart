import 'dart:async';
import 'dart:io';

import 'package:socket_client/src/transport/connection_state.dart';

/// Functional core for `SocketTransport`.
///
/// Pure decision logic and error construction — no I/O, no mutable state, no
/// field access. The transport (imperative shell) reads its own state, calls
/// these functions, and applies the results. The current time is injected as
/// `now` so every function is deterministic and unit-testable in isolation.

/// Map a low-level connect exception to a typed [SocketError].
///
/// Dispatch order mirrors the typed `catch` arms it replaces: timeout,
/// network, protocol, TLS, then unknown. Only the timeout case omits
/// `originalError`.
SocketError classifyConnectError(Object error, StackTrace st, DateTime now) {
  if (error is TimeoutException) {
    return SocketError(
      type: SocketErrorType.timeout,
      message: error.message ?? 'Connection timeout',
      timestamp: now,
    );
  }
  if (error is SocketException) {
    return SocketError(
      type: SocketErrorType.network,
      message: 'Socket error: ${error.message}',
      timestamp: now,
      originalError: error,
    );
  }
  if (error is WebSocketException) {
    return SocketError(
      type: SocketErrorType.protocol,
      message: 'WebSocket error: ${error.message}',
      timestamp: now,
      originalError: error,
    );
  }
  if (error is HandshakeException) {
    return SocketError(
      type: SocketErrorType.tls,
      message: 'TLS handshake failed: ${error.message}',
      timestamp: now,
      originalError: error,
    );
  }
  return SocketError(
    type: SocketErrorType.unknown,
    message: 'Unexpected error: $error',
    timestamp: now,
    originalError: error,
    stackTrace: st,
  );
}

/// Error emitted when no pong arrives within the configured window.
SocketError heartbeatTimeoutError(DateTime now) => SocketError(
  type: SocketErrorType.heartbeatTimeout,
  message: 'No pong within pong timeout',
  timestamp: now,
);

/// Error emitted when the inbound socket stream reports an error.
SocketError streamError(Object error, StackTrace st, DateTime now) =>
    SocketError(
      type: SocketErrorType.stream,
      message: 'Stream error: $error',
      timestamp: now,
      originalError: error,
      stackTrace: st,
    );

/// Error emitted when the reconnect strategy is exhausted.
SocketError maxRetriesError(int maxAttempts, DateTime now) => SocketError(
  type: SocketErrorType.maxRetriesExceeded,
  message: 'Exceeded $maxAttempts reconnect attempts',
  timestamp: now,
);

/// Outcome of a connect failure: try to reconnect, or give up.
enum FailureOutcome {
  /// Schedule a reconnect attempt.
  reconnect,

  /// Move to the terminal failed state.
  fail,
}

/// Decide what to do after a connect failure.
///
/// Reconnect only when the close was not intentional and a strategy exists;
/// otherwise the transport moves to a terminal failed state.
FailureOutcome decideFailure({
  required bool intentionalClose,
  required bool hasStrategy,
}) => (!intentionalClose && hasStrategy)
    ? FailureOutcome.reconnect
    : FailureOutcome.fail;

/// Whether an `onDone` close should trigger reconnect.
///
/// Reconnect unless the client closed the socket intentionally.
bool shouldReconnectOnClose({required bool intentionalClose}) =>
    !intentionalClose;

/// Connection uptime, or null when never connected.
Duration? uptimeSince(DateTime? connectedAt, DateTime now) =>
    connectedAt == null ? null : now.difference(connectedAt);
