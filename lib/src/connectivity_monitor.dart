import 'dart:async';

import 'package:socket_client/src/connection_state.dart';
import 'package:socket_client/src/logger.dart';

/// Represents the device's network connectivity status.
enum NetworkStatus {
  /// Device has network connectivity.
  online,

  /// Device has no network connectivity.
  offline,

  /// Network status is unknown (initial state).
  unknown,
}

/// Monitors network connectivity and provides debounced status changes.
///
/// In production, integrate this with `connectivity_plus` package:
///
/// ```dart
/// final monitor = ConnectivityMonitor(
///   connectivityStream: Connectivity().onConnectivityChanged.map((result) {
///     return result.contains(ConnectivityResult.none)
///         ? NetworkStatus.offline
///         : NetworkStatus.online;
///   }),
/// );
/// ```
class ConnectivityMonitor {
  ConnectivityMonitor({
    this.connectivityStream,
    this.debounce = const Duration(seconds: 2),
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'Connectivity') {
    _init();
  }
  final Stream<NetworkStatus>? connectivityStream;
  final Duration debounce;
  final SocketLogger _logger;

  NetworkStatus _status = NetworkStatus.unknown;
  StreamSubscription<NetworkStatus>? _subscription;
  Timer? _debounceTimer;

  final _statusController = StreamController<NetworkStatus>.broadcast();

  NetworkStatus get status => _status;
  bool get isOnline => _status == NetworkStatus.online;
  Stream<NetworkStatus> get statusStream => _statusController.stream;

  void _init() {
    if (connectivityStream != null) {
      _subscription = connectivityStream!.listen(_handleStatusChange);
    }
  }

  void _handleStatusChange(NetworkStatus newStatus) {
    _debounceTimer?.cancel();

    // Debounce to avoid flapping during network transitions
    _debounceTimer = Timer(debounce, () {
      if (newStatus != _status) {
        final oldStatus = _status;
        _status = newStatus;
        _logger.info('Network: ${oldStatus.name} → ${newStatus.name}');
        _statusController.add(newStatus);
      }
    });
  }

  /// Manually update the network status (e.g., from a platform channel).
  void updateStatus(NetworkStatus newStatus) {
    _handleStatusChange(newStatus);
  }

  Future<void> dispose() async {
    _debounceTimer?.cancel();
    await _subscription?.cancel();
    await _statusController.close();
  }
}

/// Coordinates between connectivity monitoring and socket reconnection.
///
/// Pauses reconnection when offline, resumes when back online.
class NetworkAwareReconnector {
  NetworkAwareReconnector({
    required this.monitor,
    required this.onReconnectRequested,
    required this.onDisconnectRequested,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'NetReconnector') {
    _subscription = monitor.statusStream.listen(_handleNetworkChange);
  }
  final ConnectivityMonitor monitor;
  final Future<void> Function() onReconnectRequested;
  final Future<void> Function() onDisconnectRequested;
  final SocketLogger _logger;

  StreamSubscription<NetworkStatus>? _subscription;

  void _handleNetworkChange(NetworkStatus status) {
    switch (status) {
      case NetworkStatus.online:
        _logger.info('Network restored — requesting reconnect');
        onReconnectRequested();
        break;
      case NetworkStatus.offline:
        _logger.info('Network lost — pausing connection');
        onDisconnectRequested();
        break;
      case NetworkStatus.unknown:
        break;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
  }
}
