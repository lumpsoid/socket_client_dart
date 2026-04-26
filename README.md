# Socket Network System

A production-ready WebSocket networking system for Dart & Flutter — zero external dependencies.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    SocketClient                      │  ← High-level API
│  (facade: connect, emit, request, channels, dispose) │
├──────────────────────────────────────────────────────┤
│        MessageProtocol          │   ChannelManager   │  ← Protocol layer
│  (event routing, req/res,       │  (pub/sub, rooms,  │
│   middleware pipeline)          │   multiplexing)    │
├──────────────────────────────────────────────────────┤
│               SocketConnection                       │  ← Transport layer
│  (WebSocket I/O, reconnection, heartbeat, TLS)       │
├──────────────────────────────────────────────────────┤
│  ConnectivityMonitor │ MessageQueue  │ SocketMetrics │  ← Infrastructure
│  (network awareness) │ (offline buf) │ (health/perf) │
└──────────────────────────────────────────────────────┘
```

## Features

| Feature | Description |
|---|---|
| **Auto-reconnect** | Exponential backoff with jitter, configurable max attempts |
| **Heartbeat** | Ping/pong keep-alive with configurable timeout |
| **Typed messages** | JSON envelope with event routing, IDs, and timestamps |
| **Request/response** | Await correlated replies with timeout |
| **Channels** | Named pub/sub rooms with join/leave lifecycle |
| **Middleware** | Inbound & outbound pipelines (logging, auth, rate-limit, dedup, compression) |
| **Offline queue** | Priority-based buffer with TTL and eviction |
| **Health monitor** | Latency tracking, error rates, health status stream |
| **Network awareness** | Connectivity monitoring with debounce, auto-pause/resume |
| **Authentication** | Bearer/API key via header, query param, or post-connect message |
| **Zero dependencies** | Pure Dart — no external packages required |

## Quick Start

```dart
import 'package:socket_network_system/socket_network_system.dart';

final client = SocketClient(
  config: ConnectionConfig.fromUrl('wss://api.example.com/ws'),
);

client.on('chat.message', (msg) {
  print('${msg.data['from']}: ${msg.data['text']}');
});

await client.connect();
client.emit('chat.send', data: {'text': 'Hello!'});
```

## Configuration

```dart
final config = ConnectionConfig.fromUrl(
  'wss://api.example.com/ws',
  headers: {'X-App-Version': '2.0.0'},
  connectTimeout: Duration(seconds: 15),
  auth: AuthConfig(
    type: AuthType.bearer,
    tokenProvider: () async => refreshToken(),
    transport: AuthTransport.header,
  ),
  heartbeat: HeartbeatConfig(
    enabled: true,
    interval: Duration(seconds: 25),
    pongTimeout: Duration(seconds: 10),
  ),
  reconnect: ReconnectConfig(
    enabled: true,
    maxAttempts: 20,
    initialDelay: Duration(seconds: 1),
    maxDelay: Duration(minutes: 2),
    multiplier: 1.5,
    jitter: true,
  ),
);
```

## Request-Response

```dart
try {
  final response = await client.request(
    'user.getProfile',
    data: {'userId': '123'},
    timeout: Duration(seconds: 10),
  );
  print(response.data['name']);
} on SocketError catch (e) {
  print('Failed: ${e.message}');
}
```

## Channels

```dart
final room = client.channel('room:general');
await room.join(params: {'username': 'alice'});

room.on('message', (msg) => print(msg.data['text']));
await room.send('message', data: {'text': 'Hi!'});

await room.leave();
```

## Middleware

```dart
// Inbound
client.useInbound(SocketMiddleware.logging(logData: true));
client.useInbound(SocketMiddleware.deduplicator());
client.useInbound(SocketMiddleware.eventFilter(
  blockList: {'_internal.ping'},
));

// Outbound
client.useOutbound(SocketMiddleware.rateLimiter(maxPerSecond: 10));
client.useOutbound(SocketMiddleware.authInjector(
  tokenProvider: () async => getToken(),
));
client.useOutbound(SocketMiddleware.timestamper());

// Custom
client.useOutbound((message) async {
  return SocketMessage(
    id: message.id,
    event: message.event,
    data: {...message.data, 'encrypted': encrypt(message.data)},
    timestamp: message.timestamp,
  );
});
```

## Offline Queue

```dart
final queue = MessageQueue(maxSize: 500);

void safeSend(String event, Map<String, dynamic> data) {
  if (client.isConnected) {
    client.emit(event, data: data);
  } else {
    queue.enqueue(
      SocketMessage.create(event: event, data: data),
      priority: MessagePriority.high,
      ttl: Duration(minutes: 5),
    );
  }
}

client.stateStream.listen((state) {
  if (state == SocketConnectionState.connected) {
    for (final msg in queue.dequeueAll()) {
      client.emit(msg.message.event, data: msg.message.data);
    }
  }
});
```

## Health Monitoring

```dart
final metrics = SocketMetrics();
final health = HealthMonitor(
  metrics: metrics,
  maxLatency: Duration(milliseconds: 3000),
  maxErrorsPerMinute: 5,
);

health.statusStream.listen((status) {
  if (status == HealthStatus.unhealthy) {
    alertOps('Socket connection degraded');
  }
});

health.start();
```

## Connection States

```
disconnected → connecting → connected
                    ↓              ↓
                 failed      disconnecting → disconnected
                    ↑              ↓
               reconnecting ← (connection lost)
```

## File Structure

```
lib/
├── socket_network_system.dart       # Barrel exports
└── src/
    ├── socket_client.dart           # High-level facade
    ├── core/
    │   ├── socket_connection.dart   # WebSocket transport
    │   ├── connectivity_monitor.dart # Network awareness
    │   ├── message_queue.dart       # Offline buffer
    │   └── metrics.dart             # Health & performance
    ├── models/
    │   ├── connection_config.dart   # Configuration
    │   └── connection_state.dart    # States & errors
    ├── protocol/
    │   ├── message_protocol.dart    # Event routing & middleware
    │   └── channel.dart             # Pub/sub channels
    ├── middleware/
    │   └── built_in_middleware.dart  # Logging, auth, rate-limit, etc.
    └── utils/
        ├── backoff_strategy.dart    # Reconnection timing
        └── logger.dart              # Structured logging
```

## License

MIT
