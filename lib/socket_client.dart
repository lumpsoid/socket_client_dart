/// socket_client — a transport-owns-nothing WebSocket library.
///
/// Core layers (always available):
/// - [SocketTransport] — raw WebSocket with reconnect + heartbeat
/// - [FrameCodec] — implement this for your wire protocol
/// - [TopicRouter] — stream-per-topic routing + request-reply
/// - [PendingRequests] — standalone correlation tracker
///
/// Optional add-ons:
/// - [SocketClient] — thin facade over transport + router
/// - [QueuedTransport] — offline-buffering wrapper
/// - [TransportMiddlewarePipeline] — raw-frame middleware (logging, gzip,
/// rate-limit)
/// - [ConnectivityMonitor] — network status observation
/// - [NetworkAwareReconnector] — auto reconnect on network restore
/// - [HealthMonitor] — latency/error health thresholds
/// - [SocketMetrics] — per-session counters + percentiles
library;

import 'package:socket_client/src/client/socket_client.dart' show SocketClient;
import 'package:socket_client/src/extensions/connectivity_monitor.dart'
    show ConnectivityMonitor, NetworkAwareReconnector;
import 'package:socket_client/src/extensions/health_monitor.dart'
    show HealthMonitor, SocketMetrics;
import 'package:socket_client/src/middleware/transport_middleware.dart'
    show TransportMiddlewarePipeline;
import 'package:socket_client/src/protocol/frame_codec.dart' show FrameCodec;
import 'package:socket_client/src/protocol/pending_requests.dart'
    show PendingRequests;
import 'package:socket_client/src/protocol/topic_router.dart' show TopicRouter;
import 'package:socket_client/src/queue/queued_transport.dart'
    show QueuedTransport;
import 'package:socket_client/src/transport/socket_transport.dart'
    show SocketTransport;

// Facade
export 'src/client/socket_client.dart';
// Extensions
export 'src/extensions/connectivity_monitor.dart';
export 'src/extensions/health_monitor.dart';
// Middleware
export 'src/middleware/transport_middleware.dart';
// Protocol
export 'src/protocol/frame_codec.dart';
export 'src/protocol/pending_requests.dart';
export 'src/protocol/topic_router.dart';
// Queue
export 'src/queue/message_queue.dart';
export 'src/queue/queued_transport.dart';
export 'src/transport/backoff_strategy.dart';
export 'src/transport/connection_config.dart';
export 'src/transport/connection_state.dart';
// Transport
export 'src/transport/socket_transport.dart';
// Utilities
export 'src/util/logger.dart';
