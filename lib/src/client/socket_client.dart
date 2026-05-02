import 'dart:async';

import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/protocol/topic_router.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:socket_client/src/util/logger.dart';

/// Optional convenience facade that wires [SocketTransport] and [TopicRouter]
/// together.
///
/// This class is **not** required — you can compose transport + router
/// directly. Use this when you want a simple unified API and are happy with
/// the defaults.
///
/// All protocol-specific behaviour (auth, channel join/leave, presence) is
/// handled via [onReconnected] and the caller's own codec — not hardcoded here.
///
/// ```dart
/// final client = SocketClient(
///   config: ConnectionConfig.fromUrl('wss://api.example.com/ws'),
///   codec: MyCodec(),
/// );
///
/// client.topic('room:lobby').listen((frame) { ... });
///
/// await client.connect();
/// client.emit(myFrame);
/// ```
class SocketClient<T> {
  SocketClient({
    required ConnectionConfig config,
    required FrameCodec<T> codec,
    SocketLogger? logger,
    this.onReconnected,
  }) : _logger = logger ?? const SocketLogger(tag: 'SocketClient'),
       transport = SocketTransport(
         config: config,
         logger: logger ?? const SocketLogger(tag: 'Transport'),
       ),
       router = TopicRouter<T>(
         codec: codec,
         logger: logger ?? const SocketLogger(tag: 'Router'),
       ) {
    _wire();
  }

  /// Access the underlying transport for advanced use.
  final SocketTransport transport;

  /// Access the underlying router for advanced use (e.g. streaming directly).
  final TopicRouter<T> router;

  final SocketLogger _logger;

  /// Called after each successful reconnect. Use this to re-authenticate,
  /// rejoin channels, or resend any application-level handshake.
  final Future<void> Function()? onReconnected;

  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;

  //Delegated API

  SocketConnectionState get state => transport.state;
  bool get isConnected => transport.isConnected;
  Stream<SocketConnectionState> get stateStream => transport.stateStream;
  Stream<SocketError> get errors => transport.errorStream;
  Duration? get uptime => transport.connectionUptime;

  /// Returns the broadcast stream for the given [topic].
  Stream<T> topic(String topic) => router.topic(topic);

  /// All decoded inbound frames regardless of topic.
  Stream<T> get allFrames => router.allFrames;

  //Actions

  Future<void> connect() async {
    _assertNotDisposed();
    await transport.connect();
  }

  Future<void> disconnect({int? closeCode, String? closeReason}) async {
    await transport.disconnect(closeCode: closeCode, closeReason: closeReason);
  }

  /// Encode [frame] and send it immediately.
  void emit(T frame) {
    _assertNotDisposed();
    router.emit(frame, send: transport.sendText);
  }

  /// Send [frame] and await a correlated reply.
  Future<T> request(T frame, {Duration timeout = const Duration(seconds: 30)}) {
    _assertNotDisposed();
    return router.request(frame, send: transport.sendText, timeout: timeout);
  }

  //Lifecycle

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await router.dispose();
    await transport.dispose();
    _logger.info('SocketClient disposed');
  }

  void _wire() {
    // Route raw text frames into the protocol layer.
    _subs.add(transport.textStream.listen(router.ingest));

    // Invoke reconnect hook on each successful connect after the first.
    var firstConnect = true;
    _subs.add(
      transport.stateStream.listen((state) async {
        if (state == SocketConnectionState.connected) {
          if (firstConnect) {
            firstConnect = false;
            return;
          }
          _logger.info('Reconnected — invoking onReconnected hook');
          try {
            await onReconnected?.call();
          } on Exception catch (e) {
            _logger.error('onReconnected hook threw: $e');
          }
        }
      }),
    );
  }

  void _assertNotDisposed() {
    if (_disposed) throw StateError('SocketClient has been disposed');
  }
}
