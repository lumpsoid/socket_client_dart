import 'dart:async';

import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/protocol/socket_session.dart';
import 'package:socket_client/src/protocol/topic_router.dart';
import 'package:socket_client/src/ref_generator/ref_generator_i.dart';
import 'package:socket_client/src/transport/backoff_strategy.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/interval_heartbeat.dart';
import 'package:socket_client/src/transport/socket_heartbeat.dart';
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
class SocketClient<T> implements SocketSession<T> {
  SocketClient({
    required ConnectionConfig config,
    required FrameCodec<T> codec,
    required RefGenerator refGen,
    SocketHeartbeat? heartbeat,
    BackoffStrategy? backoff,
    SocketLogger? logger,
  }) : _refGen = refGen,
       _logger = logger ?? const SocketLogger(tag: 'SocketClient'),
       transport = SocketTransport(
         logger: logger ?? const SocketLogger(tag: 'Transport'),
         heartbeat:
             heartbeat ??
             IntervalHeartbeat(config: config.heartbeat, refGen: refGen),
         backoff: backoff ?? ExponentialBackoff(config: config.reconnect),
       ),
       router = TopicRouter<T>(
         codec: codec,
         logger: logger ?? const SocketLogger(tag: 'Router'),
       ) {
    _wire();
  }

  final RefGenerator _refGen;

  /// Access the underlying transport for advanced use.
  final SocketTransport transport;

  /// Access the underlying router for advanced use (e.g. streaming directly).
  final TopicRouter<T> router;

  final SocketLogger _logger;

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

  /// Called once after the first successful connection.
  Future<void> onConnected() {
    // no-op
    return Future.syncValue(null);
  }

  /// Called after every successful reconnect.
  Future<void> onReconnected() {
    // no-op
    return Future.syncValue(null);
  }

  /// Called when the transport reaches disconnected or failed.
  Future<void> onDisconnected() {
    // no-op
    return Future.syncValue(null);
  }

  //Actions

  Future<void> connect() async {
    _assertNotDisposed();
    await transport.connect();
  }

  Future<void> disconnect({int? closeCode, String? closeReason}) =>
      transport.disconnect(
        closeCode: closeCode,
        closeReason: closeReason,
      );

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

    var firstConnect = true;
    _subs.add(
      transport.stateStream.listen((state) async {
        switch (state) {
          case SocketConnectionState.connected:
            if (firstConnect) {
              firstConnect = false;
              _logger.info('Connected — invoking onConnected hook');
              try {
                await onConnected();
              } on Exception catch (e) {
                _logger.error('onConnected hook threw: $e');
              }
            } else {
              _logger.info('Reconnected — invoking onReconnected hook');
              try {
                await onReconnected();
              } on Exception catch (e) {
                _logger.error('onReconnected hook threw: $e');
              }
            }

          case SocketConnectionState.disconnected:
          case SocketConnectionState.failed:
            try {
              await onDisconnected();
            } on Exception catch (e) {
              _logger.error('onDisconnected hook threw: $e');
            }
          case SocketConnectionState.connecting:
          case SocketConnectionState.reconnecting:
          case SocketConnectionState.disconnecting:
            break;
        }
      }),
    );
  }

  void _assertNotDisposed() {
    if (_disposed) throw StateError('SocketClient has been disposed');
  }
}
