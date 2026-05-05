import 'dart:async';

import 'package:socket_client/src/client/socket_client.dart';
import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/protocol/topic_router.dart';
import 'package:socket_client/src/transport/backoff_strategy.dart';
import 'package:socket_client/src/transport/connection_config.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/interval_heartbeat.dart';
import 'package:socket_client/src/transport/socket_heartbeat.dart';
import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:socket_client/src/util/logger.dart';

/// Optional convenience facade that wires [SocketTransport] and [FrameRouter]
/// together.
///
/// This class is **not** required — you can compose transport + router
/// directly.
///
/// ```dart
/// final client = SocketClient(
///   config: ConnectionConfig.fromUrl('wss://api.example.com/ws'),
///   codec: MyCodec(),
/// );
///
/// client.allFrames.listen((frame) { ... });
///
/// await client.connect();
/// client.emit(myFrame);
/// ```
class DefaultSocketClient<T> implements SocketClient<T> {
  DefaultSocketClient({
    required ConnectionConfig config,
    required FrameCodec<T> codec,
    SocketHeartbeat? heartbeat,
    ReconnectionStrategy? backoff,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'SocketClient'),
       transport = SocketTransport(
         config: config,
         logger: logger ?? const SocketLogger(tag: 'Transport'),
         heartbeat:
             heartbeat ?? IntervalHeartbeat(config: const HeartbeatConfig()),
         backoff:
             backoff ?? ExponentialBackoff(config: const ReconnectConfig()),
       ),
       router = FrameRouter<T>(
         codec: codec,
         logger: logger ?? const SocketLogger(tag: 'Router'),
       ) {
    _wire();
  }

  /// Access the underlying transport for advanced use.
  final SocketTransport transport;

  /// Access the underlying router for advanced use (e.g. streaming directly).
  final FrameRouter<T> router;

  final SocketLogger _logger;

  bool _disposed = false;

  StreamSubscription<String>? _parsingSub;

  @override
  SocketConnectionState get state => transport.state;
  @override
  bool get isConnected => transport.isConnected;
  @override
  Stream<SocketConnectionState> get stateStream => transport.stateStream;
  @override
  Stream<SocketError> get errors => transport.errorStream;
  @override
  Duration? get uptime => transport.connectionUptime;

  /// All decoded inbound frames;
  @override
  Stream<T> get allFrames => router.allFrames;

  @override
  Future<void> connect() async {
    _assertNotDisposed();
    await transport.connect();
  }

  @override
  Future<void> disconnect({int? closeCode, String? closeReason}) =>
      transport.disconnect(
        closeCode: closeCode,
        closeReason: closeReason,
      );

  /// Encode [frame] and send it immediately.
  @override
  void emit(T frame) {
    _assertNotDisposed();
    router.emit(frame, send: transport.sendText);
  }

  /// Send [frame] and await a correlated reply.
  @override
  Future<T> request(T frame, {Duration timeout = const Duration(seconds: 30)}) {
    _assertNotDisposed();
    return router.request(frame, send: transport.sendText, timeout: timeout);
  }

  //Lifecycle

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _parsingSub?.cancel();
    _parsingSub = null;

    await router.dispose();
    await transport.dispose();
    _logger.info('SocketClient disposed');
  }

  void _wire() {
    // Route raw text frames into the protocol layer.
    _parsingSub = transport.textStream.listen(router.ingest);
  }

  void _assertNotDisposed() {
    if (_disposed) throw StateError('SocketClient has been disposed');
  }
}
