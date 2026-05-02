import 'dart:async';

import 'package:socket_client/src/channel.dart';
import 'package:socket_client/src/connection_config.dart';
import 'package:socket_client/src/connection_state.dart';
import 'package:socket_client/src/logger.dart';
import 'package:socket_client/src/message_protocol.dart';
import 'package:socket_client/src/socket_connection.dart';

/// High-level client that composes connection, protocol, and channels.
///
/// This is the primary API surface for consumers.
///
/// ```dart
/// final client = SocketClient(
///   config: ConnectionConfig.fromUrl('wss://api.example.com/ws'),
/// );
///
/// client.on('chat.message', (msg) {
///   print('New message: ${msg.data}');
/// });
///
/// await client.connect();
/// client.emit('chat.send', data: {'text': 'Hello!'});
/// ```
class SocketClient {
  SocketClient({
    required this.config,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'SocketClient') {
    _connection = SocketConnection(
      config: config,
      logger: const SocketLogger(tag: 'Connection'),
    );

    _protocol = MessageProtocol(
      logger: const SocketLogger(tag: 'Protocol'),
    );

    _channelManager = ChannelManager(
      protocol: _protocol,
      sendRaw: _connection.sendText,
      logger: const SocketLogger(tag: 'Channels'),
    );

    _wireUp();
  }
  final ConnectionConfig config;
  final SocketLogger _logger;

  late final SocketConnection _connection;
  late final MessageProtocol _protocol;
  late final ChannelManager _channelManager;

  final List<StreamSubscription> _subscriptions = [];
  bool _disposed = false;

  /// Current connection state.
  SocketConnectionState get state => _connection.state;

  /// Whether the client is connected.
  bool get isConnected => _connection.isConnected;

  /// Stream of connection state changes.
  Stream<SocketConnectionState> get stateStream => _connection.stateStream;

  /// Stream of all parsed inbound messages.
  Stream<SocketMessage> get messages => _protocol.messages;

  /// Stream of connection errors.
  Stream<SocketError> get errors => _connection.errorStream;

  /// The channel manager for pub/sub.
  ChannelManager get channels => _channelManager;

  /// Connection uptime.
  Duration? get uptime => _connection.connectionUptime;

  // Connection Lifecycle

  /// Connect to the server.
  Future<void> connect() async {
    _assertNotDisposed();

    // Handle authentication if configured
    if (config.auth != null) {
      await _authenticateConnection();
    }

    await _connection.connect();
  }

  /// Disconnect from the server.
  Future<void> disconnect({int? closeCode, String? closeReason}) async {
    await _channelManager.leaveAll();
    await _connection.disconnect(
      closeCode: closeCode,
      closeReason: closeReason,
    );
  }

  // ─── Messaging ───────────────────────────────────────────────

  /// Emit a typed event with data.
  Future<void> emit(
    String event, {
    Map<String, dynamic> data = const {},
  }) async {
    _assertNotDisposed();

    final message = SocketMessage.create(event: event, data: data);
    final json = await _protocol.prepareOutbound(message);
    if (json != null) {
      _connection.sendText(json);
    }
  }

  /// Emit an event and wait for a correlated response.
  Future<SocketMessage> request(
    String event, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _assertNotDisposed();

    final message = SocketMessage.create(event: event, data: data);

    // Register pending request before sending
    final responseFuture = _protocol.createRequest(
      message,
      timeout: timeout,
    );

    final json = await _protocol.prepareOutbound(message);
    if (json != null) {
      _connection.sendText(json);
    }

    return responseFuture;
  }

  /// Subscribe to messages of a specific event type.
  VoidCallback on(String event, MessageHandler handler) {
    return _protocol.on(event, handler);
  }

  /// Subscribe to a single occurrence of an event.
  void once(String event, MessageHandler handler) {
    _protocol.once(event, handler);
  }

  /// Remove all handlers for an event.
  void off(String event) {
    _protocol.off(event);
  }

  // ─── Middleware ───────────────────────────────────────────────

  /// Add inbound message middleware.
  void useInbound(MessageMiddleware middleware) {
    _protocol.useInbound(middleware);
  }

  /// Add outbound message middleware.
  void useOutbound(MessageMiddleware middleware) {
    _protocol.useOutbound(middleware);
  }

  /// Get or create a channel.
  SocketChannel channel(String name) => _channelManager.channel(name);

  /// Release all resources. The client cannot be reused after this.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    await _channelManager.dispose();
    _protocol.dispose();
    await _connection.dispose();

    _logger.info('Client disposed');
  }

  void _wireUp() {
    // Route raw text messages through the protocol layer
    _subscriptions
      ..add(
        _connection.messageStream.listen((data) async {
          if (data is String) {
            await _protocol.handleRawMessage(data);
          }
        }),
      )
      // Auto-rejoin channels on reconnect
      ..add(
        _connection.stateStream.listen((state) async {
          if (state == SocketConnectionState.connected) {
            await _channelManager.rejoinAll();

            // Re-authenticate on reconnect
            if (config.auth != null &&
                config.auth!.transport == AuthTransport.message) {
              await _sendAuthMessage();
            }
          }
        }),
      );
  }

  Future<void> _authenticateConnection() async {
    final auth = config.auth!;
    final token = await auth.resolveToken();

    switch (auth.transport) {
      case AuthTransport.header:
        // Headers are set in config, but may need refreshing
        final prefix = auth.type == AuthType.bearer ? 'Bearer ' : '';
        config.headers?[auth.headerName] = '$prefix$token';

      case AuthTransport.queryParam:
        // Append token to URI
        // Handled by config.uri modification upstream
        break;
      case AuthTransport.message:
        // Will be sent after connection is established
        break;
    }
  }

  Future<void> _sendAuthMessage() async {
    if (config.auth == null) return;
    final token = await config.auth!.resolveToken();

    await emit('auth', data: {'token': token});
    _logger.info('Auth message sent');
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('SocketClient has been disposed');
    }
  }
}
