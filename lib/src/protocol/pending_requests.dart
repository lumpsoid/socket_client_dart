import 'dart:async';

import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/util/logger.dart';

/// Tracks in-flight request-reply correlations.
class PendingRequests<T> {
  PendingRequests({SocketLogger? logger})
    : _logger = logger ?? const SocketLogger(tag: 'PendingRequests');

  final SocketLogger _logger;
  final Map<String, _PendingEntry<T>> _entries = {};

  int get length => _entries.length;

  /// Register a pending request for [correlationId].
  ///
  /// Returns a [Future] that completes when [resolve] is called with the same
  /// ID, or errors with [SocketError] (timeout) after [timeout].
  Future<T> register(
    String correlationId, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final completer = Completer<T>.sync();
    final timer = Timer(timeout, () {
      if (_entries.remove(correlationId) != null) {
        _logger.warn(
          'Request $correlationId timed out after ${timeout.inSeconds}s',
        );
        completer.completeError(
          SocketError(
            type: SocketErrorType.timeout,
            message:
                'Request $correlationId timed out after ${timeout.inSeconds}s',
            timestamp: DateTime.now(),
          ),
        );
      }
    });
    _entries[correlationId] = _PendingEntry(completer, timer);
    return completer.future;
  }

  /// Resolve a pending request with [frame].
  ///
  /// No-ops if [correlationId] is not tracked (already resolved or timed out).
  void resolve(String correlationId, T frame) {
    final entry = _entries.remove(correlationId);
    if (entry == null) return;
    entry.timer.cancel();
    _logger.debug('Resolved request $correlationId');
    entry.completer.complete(frame);
  }

  /// Cancel all pending requests with a [SocketError].
  void dispose() {
    final entries = _entries.values.toList();
    _entries.clear();
    for (final entry in entries) {
      entry.timer.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          SocketError(
            type: SocketErrorType.stream,
            message: 'PendingRequests disposed while request in-flight',
            timestamp: DateTime.now(),
          ),
        );
      }
    }
  }
}

class _PendingEntry<T> {
  _PendingEntry(this.completer, this.timer);
  final Completer<T> completer;
  final Timer timer;
}
