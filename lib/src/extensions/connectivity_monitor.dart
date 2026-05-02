import 'dart:async';

import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:socket_client/src/util/logger.dart';

enum NetworkStatus { online, offline, unknown }

/// Monitors device network connectivity and emits debounced [NetworkStatus]
/// changes.
///
/// Integrate with `connectivity_plus` by mapping its results:
/// ```dart
/// final monitor = ConnectivityMonitor(
///   connectivityStream: Connectivity().onConnectivityChanged.map(
///     (result) => result.contains(ConnectivityResult.none)
///         ? NetworkStatus.offline
///         : NetworkStatus.online,
///   ),
/// );
/// ```
class ConnectivityMonitor {
  ConnectivityMonitor({
    Stream<NetworkStatus>? connectivityStream,
    this.debounce = const Duration(seconds: 2),
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'Connectivity') {
    if (connectivityStream != null) {
      _subscription = connectivityStream.listen(_handleRawChange);
    }
  }

  final Duration debounce;
  final SocketLogger _logger;

  NetworkStatus _status = NetworkStatus.unknown;
  StreamSubscription<NetworkStatus>? _subscription;
  Timer? _debounceTimer;

  final _controller = StreamController<NetworkStatus>.broadcast();

  NetworkStatus get status => _status;
  bool get isOnline => _status == NetworkStatus.online;
  Stream<NetworkStatus> get statusStream => _controller.stream;

  /// Push a status update manually (e.g. from a platform channel).
  void updateStatus(NetworkStatus status) => _handleRawChange(status);

  void _handleRawChange(NetworkStatus incoming) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      if (incoming == _status) return;
      final prev = _status;
      _status = incoming;
      _logger.info('Network: ${prev.name} → ${incoming.name}');
      _controller.add(incoming);
    });
  }

  Future<void> dispose() async {
    _debounceTimer?.cancel();
    await _subscription?.cancel();
    await _controller.close();
  }
}

/// Wires a [ConnectivityMonitor] to a [SocketTransport] so that the transport
/// reconnects automatically when the network comes back, and stops attempting
/// reconnects when the network is gone.
///
/// ```dart
/// final watcher = NetworkAwareReconnector.attach(
///   transport: transport,
///   monitor: connectivityMonitor,
/// );
/// // ...
/// await watcher.dispose();
/// ```
class NetworkAwareReconnector {
  NetworkAwareReconnector._({
    required SocketTransport transport,
    required ConnectivityMonitor monitor,
    SocketLogger? logger,
  }) : _transport = transport,
       _logger = logger ?? const SocketLogger(tag: 'NetReconnector') {
    _subscription = monitor.statusStream.listen(_onNetworkChange);
  }

  factory NetworkAwareReconnector.attach({
    required SocketTransport transport,
    required ConnectivityMonitor monitor,
    SocketLogger? logger,
  }) => NetworkAwareReconnector._(
    transport: transport,
    monitor: monitor,
    logger: logger,
  );

  final SocketTransport _transport;
  final SocketLogger _logger;
  StreamSubscription<NetworkStatus>? _subscription;

  Future<void> _onNetworkChange(NetworkStatus status) async {
    switch (status) {
      case NetworkStatus.online:
        _logger.info('Network restored — reconnecting');
        await _transport.connect();

      case NetworkStatus.offline:
        _logger.info('Network lost — disconnecting');
        await _transport.disconnect(
          closeCode: 4000,
          closeReason: 'Network offline',
        );

      case NetworkStatus.unknown:
        break;
    }
  }

  Future<void> dispose() async => _subscription?.cancel();
}
