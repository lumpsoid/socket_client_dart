import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:socket_client/src/transport/backoff_strategy.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/socket_heartbeat.dart';
import 'package:socket_client/src/util/logger.dart';

/// Raw WebSocket transport: reconnect, heartbeat, TLS. No protocol assumptions.
///
/// Speaks [String] and [Uint8List] only. All framing/parsing belongs upstream.
///
/// ```dart
/// final transport = SocketTransport(config: ConnectionConfig.fromUrl('wss://...'));
/// transport.textStream.listen((raw) => router.ingest(raw));
/// await transport.connect();
/// transport.sendText('{"event":"ping"}');
/// ```
class SocketTransport {
  SocketTransport({
    required ConnectionConfig config,
    required SocketHeartbeat heartbeat,
    ReconnectionStrategy? backoff,
    SocketLogger? logger,
  }) : _connectionConfig = config,
       _logger = logger ?? const SocketLogger(tag: 'Transport'),
       _reconnectionStrategy = backoff,
       _heartbeat = heartbeat;

  final ConnectionConfig _connectionConfig;
  final SocketLogger _logger;
  final ReconnectionStrategy? _reconnectionStrategy;

  final SocketHeartbeat _heartbeat;

  WebSocket? _socket;
  Timer? _reconnectTimer;
  Completer<void>? _connectionLock;

  bool _intentionalClose = false;
  DateTime? _connectedAt;
  DateTime? _lastMessageAt;

  SocketConnectionState _state = SocketConnectionState.disconnected;

  final _stateController = StreamController<SocketConnectionState>.broadcast();
  final _textController = StreamController<String>.broadcast();
  final _binaryController = StreamController<Uint8List>.broadcast();
  final _errorController = StreamController<SocketError>.broadcast();

  //Public API

  SocketConnectionState get state => _state;
  bool get isConnected => _state == SocketConnectionState.connected;

  /// Broadcast stream of connection state transitions.
  Stream<SocketConnectionState> get stateStream => _stateController.stream;

  /// Broadcast stream of raw inbound text frames.
  Stream<String> get textStream => _textController.stream;

  /// Broadcast stream of raw inbound binary frames.
  Stream<Uint8List> get binaryStream => _binaryController.stream;

  /// Broadcast stream of transport-level errors.
  Stream<SocketError> get errorStream => _errorController.stream;

  DateTime? get connectedAt => _connectedAt;
  DateTime? get lastMessageAt => _lastMessageAt;

  Duration? get connectionUptime {
    if (_connectedAt == null) return null;
    return DateTime.now().difference(_connectedAt!);
  }

  //Lifecycle

  Future<void> connect() async {
    if (_state == SocketConnectionState.connected) return;

    // If connection already in progress, join the existing attempt.
    if (_connectionLock != null) {
      return _connectionLock!.future;
    }

    _connectionLock = Completer<void>();
    try {
      _intentionalClose = false;
      await _doConnect();
      _connectionLock!.complete();
    } catch (e, st) {
      _connectionLock!.completeError(e, st);
      rethrow;
    } finally {
      _connectionLock = null;
    }
  }

  void sendText(String frame) {
    _assertConnected();
    _socket!.add(frame);
    _logger.debug('TX text ${frame.length}b');
  }

  void sendBytes(Uint8List frame) {
    _assertConnected();
    _socket!.add(frame);
    _logger.debug('TX binary ${frame.length}b');
  }

  Future<void> disconnect({int? closeCode, String? closeReason}) async {
    _intentionalClose = true;
    _cancelTimers();
    _transitionTo(SocketConnectionState.disconnecting);
    try {
      await _socket?.close(
        closeCode ?? WebSocketStatus.normalClosure,
        closeReason ?? 'Client disconnect',
      );
    } on Exception catch (e) {
      _logger.warn('Error during disconnect: $e');
    } finally {
      _socket = null;
      _connectedAt = null;
      _transitionTo(SocketConnectionState.disconnected);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await Future.wait([
      _stateController.close(),
      _textController.close(),
      _binaryController.close(),
      _errorController.close(),
    ]);
    _logger.info('Transport disposed');
  }

  //Connection

  Future<void> _doConnect() async {
    _transitionTo(SocketConnectionState.connecting);
    try {
      _logger.info('Connecting to ${_connectionConfig.url}');
      _socket =
          await WebSocket.connect(
            _connectionConfig.url,
            headers: _connectionConfig.headers,
            protocols: _connectionConfig.protocols,
          ).timeout(
            _connectionConfig.connectTimeout,
            onTimeout: () => throw TimeoutException(
              'Connection timed out after'
              ' ${_connectionConfig.connectTimeout.inSeconds}s',
            ),
          );

      _reconnectionStrategy?.reset();
      _connectedAt = DateTime.now();
      _transitionTo(SocketConnectionState.connected);
      _logger.info('Connected');
      _startHeartbeat();
      _listenToSocket();
    } on TimeoutException catch (e) {
      _handleFailure(
        SocketError(
          type: SocketErrorType.timeout,
          message: e.message ?? 'Connection timeout',
          timestamp: DateTime.now(),
        ),
      );
    } on SocketException catch (e) {
      _handleFailure(
        SocketError(
          type: SocketErrorType.network,
          message: 'Socket error: ${e.message}',
          timestamp: DateTime.now(),
          originalError: e,
        ),
      );
    } on WebSocketException catch (e) {
      _handleFailure(
        SocketError(
          type: SocketErrorType.protocol,
          message: 'WebSocket error: ${e.message}',
          timestamp: DateTime.now(),
          originalError: e,
        ),
      );
    } on HandshakeException catch (e) {
      _handleFailure(
        SocketError(
          type: SocketErrorType.tls,
          message: 'TLS handshake failed: ${e.message}',
          timestamp: DateTime.now(),
          originalError: e,
        ),
      );
    } on Exception catch (e, st) {
      _handleFailure(
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
          _textController.add(data);
        } else if (data is List<int>) {
          _binaryController.add(Uint8List.fromList(data));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _logger.error('Stream error: $error');
        _emitError(
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
          'Connection closed: code=${_socket?.closeCode} '
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

  //Heartbeat

  void _startHeartbeat() => _heartbeat.start(
    send: (frame) => _socket!.add(frame),
    onTimeout: () async {
      _emitError(
        SocketError(
          type: SocketErrorType.heartbeatTimeout,
          message: 'No pong within pong timeout',
          timestamp: DateTime.now(),
        ),
      );
      _heartbeat.stop();
      await _socket?.close(WebSocketStatus.goingAway, 'Heartbeat timeout');
    },
  );

  void _resetHeartbeatTimeout() => _heartbeat.didReceiveFrame();

  //Reconnect

  void _handleFailure(SocketError error) {
    _logger.error('Connection failure: ${error.message}');
    _emitError(error);
    if (!_intentionalClose && _reconnectionStrategy != null) {
      _transitionTo(SocketConnectionState.reconnecting);
      _scheduleReconnect();
    } else {
      _transitionTo(SocketConnectionState.failed);
    }
  }

  void _scheduleReconnect() {
    if (_reconnectionStrategy!.isExhausted) {
      _logger.error(
        'Max reconnect attempts (${_reconnectionStrategy.maxAttempts}) reached',
      );
      _transitionTo(SocketConnectionState.failed);
      _emitError(
        SocketError(
          type: SocketErrorType.maxRetriesExceeded,
          message:
              'Exceeded ${_reconnectionStrategy.maxAttempts} reconnect'
              ' attempts',
          timestamp: DateTime.now(),
        ),
      );
      return;
    }

    final delay = _reconnectionStrategy.nextDelay();
    _logger.info(
      'Reconnecting in ${delay.inMilliseconds}ms '
      '(attempt ${_reconnectionStrategy.attempt}/${_reconnectionStrategy.maxAttempts})',
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (!_intentionalClose) {
        await _doConnect();
      }
    });
  }

  //Helpers

  void _transitionTo(SocketConnectionState next) {
    if (_state == next) return;
    _logger.info('State: ${_state.name} → ${next.name}');
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _emitError(SocketError error) {
    if (!_errorController.isClosed) _errorController.add(error);
  }

  void _cancelTimers() {
    _heartbeat.stop();
    _reconnectTimer?.cancel();
  }

  void _assertConnected() {
    if (!isConnected || _socket == null) {
      throw StateError(
        'Transport not connected. Current state: ${_state.name}',
      );
    }
  }
}
