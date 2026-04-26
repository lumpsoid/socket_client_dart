import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/connection_config.dart';
import '../models/connection_state.dart';
import '../utils/logger.dart';
import '../utils/backoff_strategy.dart';

/// Production-grade WebSocket connection manager.
///
/// Features:
/// - Automatic reconnection with exponential backoff + jitter
/// - Heartbeat/ping-pong keep-alive
/// - Connection state machine
/// - Graceful shutdown
/// - SSL/TLS support
/// - Connection timeout handling
/// - Thread-safe state transitions
class SocketConnection {
  final ConnectionConfig config;
  final SocketLogger _logger;
  final BackoffStrategy _backoff;

  WebSocket? _socket;
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _intentionalClose = false;
  DateTime? _connectedAt;
  DateTime? _lastMessageAt;

  Completer<void>? _connectionLock;

  final _stateController = StreamController<SocketConnectionState>.broadcast();
  final _messageController = StreamController<dynamic>.broadcast();
  final _errorController = StreamController<SocketError>.broadcast();
  final _rawBytesController = StreamController<Uint8List>.broadcast();

  SocketConnectionState _state = SocketConnectionState.disconnected;

  SocketConnection({
    required this.config,
    SocketLogger? logger,
    BackoffStrategy? backoff,
  }) : _logger = logger ?? SocketLogger(tag: 'SocketConnection'),
       _backoff = backoff ?? ExponentialBackoff(config: config.reconnect);

  // ─── Public API ──────────────────────────────────────────────

  /// Current connection state.
  SocketConnectionState get state => _state;

  /// Whether the socket is currently connected and ready.
  bool get isConnected => _state == SocketConnectionState.connected;

  /// Stream of connection state changes.
  Stream<SocketConnectionState> get stateStream => _stateController.stream;

  /// Stream of decoded messages (String or List<int>).
  Stream<dynamic> get messageStream => _messageController.stream;

  /// Stream of raw binary messages.
  Stream<Uint8List> get rawBytesStream => _rawBytesController.stream;

  /// Stream of connection errors.
  Stream<SocketError> get errorStream => _errorController.stream;

  /// Timestamp of when the connection was established.
  DateTime? get connectedAt => _connectedAt;

  /// Timestamp of the last received message.
  DateTime? get lastMessageAt => _lastMessageAt;

  /// Duration of the current connection session.
  Duration? get connectionUptime {
    if (_connectedAt == null) return null;
    return DateTime.now().difference(_connectedAt!);
  }

  /// Establishes the WebSocket connection.
  Future<void> connect() async {
    // Fast path: already connected with same token
    if (_state == SocketConnectionState.connected) {
      return;
    }

    // Fast path: connection already in progress — wait for it
    if (_connectionLock != null) {
      return _connectionLock!.future;
    }

    // Slow path: must acquire lock and connect
    _connectionLock = Completer<void>();
    try {
      if (_state == SocketConnectionState.connected) {
        await disconnect();
      }
      _intentionalClose = false;
      await _doConnect();
      _connectionLock?.complete(null);
      return;
    } catch (e) {
      _connectionLock?.completeError(e);
      rethrow;
    } finally {
      _connectionLock = null;
    }
  }

  /// Sends a text message over the socket.
  void sendText(String message) {
    _assertConnected();
    _socket!.add(message);
    _logger.debug('Sent text: ${message.length} chars');
  }

  /// Sends binary data over the socket.
  void sendBytes(List<int> bytes) {
    _assertConnected();
    _socket!.add(bytes);
    _logger.debug('Sent binary: ${bytes.length} bytes');
  }

  /// Gracefully closes the connection.
  Future<void> disconnect({int? closeCode, String? closeReason}) async {
    _intentionalClose = true;
    _cancelTimers();
    _transitionTo(SocketConnectionState.disconnecting);

    try {
      await _socket?.close(
        closeCode ?? WebSocketStatus.normalClosure,
        closeReason ?? 'Client disconnect',
      );
    } catch (e) {
      _logger.warn('Error during disconnect: $e');
    } finally {
      _socket = null;
      _transitionTo(SocketConnectionState.disconnected);
      _connectedAt = null;
    }
  }

  /// Releases all resources. Instance should not be reused after this.
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
    await _messageController.close();
    await _errorController.close();
    await _rawBytesController.close();
    _logger.info('Disposed');
  }

  // ─── Connection Logic ────────────────────────────────────────

  Future<void> _doConnect() async {
    _transitionTo(SocketConnectionState.connecting);

    try {
      final uri = config.uri;
      _logger.info('Connecting to $uri ...');

      _socket =
          await WebSocket.connect(
            uri.toString(),
            headers: config.headers,
            protocols: config.protocols,
          ).timeout(
            config.connectTimeout,
            onTimeout: () => throw TimeoutException(
              'Connection timed out after ${config.connectTimeout.inSeconds}s',
            ),
          );

      _reconnectAttempts = 0;
      _backoff.reset();
      _connectedAt = DateTime.now();

      _transitionTo(SocketConnectionState.connected);
      _logger.info('Connected to $uri');

      _startHeartbeat();
      _listenToSocket();
    } on TimeoutException catch (e) {
      _handleConnectionFailure(
        SocketError(
          type: SocketErrorType.timeout,
          message: e.message ?? 'Connection timeout',
          timestamp: DateTime.now(),
        ),
      );
    } on SocketException catch (e) {
      _handleConnectionFailure(
        SocketError(
          type: SocketErrorType.network,
          message: 'Socket error: ${e.message}',
          timestamp: DateTime.now(),
          originalError: e,
        ),
      );
    } on WebSocketException catch (e) {
      _handleConnectionFailure(
        SocketError(
          type: SocketErrorType.protocol,
          message: 'WebSocket error: ${e.message}',
          timestamp: DateTime.now(),
          originalError: e,
        ),
      );
    } on HandshakeException catch (e) {
      _handleConnectionFailure(
        SocketError(
          type: SocketErrorType.tls,
          message: 'TLS handshake failed: ${e.message}',
          timestamp: DateTime.now(),
          originalError: e,
        ),
      );
    } catch (e, st) {
      _handleConnectionFailure(
        SocketError(
          type: SocketErrorType.unknown,
          message: 'Unexpected error: $e',
          timestamp: DateTime.now(),
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  void _listenToSocket() {
    _socket!.listen(
      (data) {
        _lastMessageAt = DateTime.now();
        _resetHeartbeatTimeout();

        if (data is String) {
          _messageController.add(data);
        } else if (data is List<int>) {
          final bytes = Uint8List.fromList(data);
          _rawBytesController.add(bytes);
          _messageController.add(bytes);
        }
      },
      onError: (error, stackTrace) {
        _logger.error('Stream error: $error');
        _errorController.add(
          SocketError(
            type: SocketErrorType.stream,
            message: 'Stream error: $error',
            timestamp: DateTime.now(),
            originalError: error,
            stackTrace: stackTrace,
          ),
        );
      },
      onDone: () {
        _logger.info(
          'Connection closed: code=${_socket?.closeCode}, '
          'reason=${_socket?.closeReason}',
        );
        _cancelTimers();

        if (!_intentionalClose) {
          _transitionTo(SocketConnectionState.reconnecting);
          _scheduleReconnect();
        } else {
          _transitionTo(SocketConnectionState.disconnected);
        }
      },
      cancelOnError: false,
    );
  }

  // ─── Heartbeat / Keep-Alive ──────────────────────────────────

  void _startHeartbeat() {
    if (!config.heartbeat.enabled) return;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(config.heartbeat.interval, (_) {
      if (isConnected) {
        try {
          _socket!.add(config.heartbeat.pingMessage);
          _logger.debug('Heartbeat ping sent');
          _startHeartbeatTimeout();
        } catch (e) {
          _logger.error('Failed to send heartbeat: $e');
        }
      }
    });
  }

  void _startHeartbeatTimeout() {
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = Timer(config.heartbeat.pongTimeout, () {
      _logger.warn('Heartbeat pong timeout — closing connection');
      _errorController.add(
        SocketError(
          type: SocketErrorType.heartbeatTimeout,
          message:
              'No pong received within ${config.heartbeat.pongTimeout.inSeconds}s',
          timestamp: DateTime.now(),
        ),
      );
      _socket?.close(WebSocketStatus.goingAway, 'Heartbeat timeout');
    });
  }

  void _resetHeartbeatTimeout() {
    _heartbeatTimeoutTimer?.cancel();
  }

  // ─── Reconnection ───────────────────────────────────────────

  void _handleConnectionFailure(SocketError error) {
    _logger.error('Connection failure: ${error.message}');
    _errorController.add(error);

    if (!_intentionalClose && config.reconnect.enabled) {
      _transitionTo(SocketConnectionState.reconnecting);
      _scheduleReconnect();
    } else {
      _transitionTo(SocketConnectionState.failed);
    }
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= config.reconnect.maxAttempts) {
      _logger.error(
        'Max reconnect attempts (${config.reconnect.maxAttempts}) reached',
      );
      _transitionTo(SocketConnectionState.failed);
      _errorController.add(
        SocketError(
          type: SocketErrorType.maxRetriesExceeded,
          message:
              'Exceeded ${config.reconnect.maxAttempts} reconnect attempts',
          timestamp: DateTime.now(),
        ),
      );
      return;
    }

    final delay = _backoff.nextDelay();
    _reconnectAttempts++;

    _logger.info(
      'Reconnecting in ${delay.inMilliseconds}ms '
      '(attempt $_reconnectAttempts/${config.reconnect.maxAttempts})',
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_intentionalClose) {
        _doConnect();
      }
    });
  }

  // ─── State Management ────────────────────────────────────────

  void _transitionTo(SocketConnectionState newState) {
    if (_state == newState) return;

    final oldState = _state;
    _state = newState;
    _logger.info('State: ${oldState.name} → ${newState.name}');

    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  // ─── Utilities ───────────────────────────────────────────────

  void _cancelTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();
  }

  void _assertConnected() {
    if (!isConnected || _socket == null) {
      throw StateError(
        'Socket is not connected. Current state: ${_state.name}',
      );
    }
  }
}
