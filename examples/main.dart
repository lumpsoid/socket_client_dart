// example
// ignore_for_file: avoid_print

/// Comprehensive usage examples for the Socket Network System.
///
/// Run with: dart run example/main.dart
library;

import 'package:socket_client/socket_client.dart';

// EXAMPLE 1: Basic Connection & Messaging

Future<void> basicExample() async {
  final client = SocketClient(
    config: ConnectionConfig.fromUrl(
      'wss://echo.websocket.events',
      connectTimeout: const Duration(seconds: 10),
    ),
  );

  // Listen for state changes
  client.stateStream.listen((state) {
    print('Connection state: ${state.name}');
  });

  // Listen for errors
  client.errors.listen((error) {
    print('Error [${error.type.name}]: ${error.message}');
  });

  // Subscribe to events
  client.on('chat.message', (msg) {
    print('Chat: ${msg.data['text']}');
  });

  // Connect
  await client.connect();

  // Send a message
  client.emit('chat.send', data: {'text': 'Hello, World!'});

  // Cleanup
  await Future<void>.delayed(const Duration(seconds: 5));
  await client.dispose();
}

// EXAMPLE 2: With Authentication

Future<void> authenticatedExample() async {
  final client = SocketClient(
    config: ConnectionConfig.fromUrl(
      'wss://api.myapp.com/ws',
      auth: AuthConfig(
        type: AuthType.bearer,
        tokenProvider: () async {
          // In production, refresh from your auth service
          return 'eyJhbGciOiJIUzI1NiIs...';
        },
        transport: AuthTransport.header,
      ),
      reconnect: const ReconnectConfig(
        enabled: true,
        maxAttempts: 15,
        initialDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 30),
        jitter: true,
      ),
      heartbeat: const HeartbeatConfig(
        enabled: true,
        interval: Duration(seconds: 25),
        pongTimeout: Duration(seconds: 10),
      ),
    ),
  );

  await client.connect();
}

// EXAMPLE 3: Request-Response Pattern

Future<void> requestResponseExample() async {
  final client = SocketClient(
    config: ConnectionConfig.fromUrl('wss://api.myapp.com/ws'),
  );

  await client.connect();

  try {
    // Send a request and await a correlated response
    final response = await client.request(
      'user.getProfile',
      data: {'userId': '12345'},
      timeout: const Duration(seconds: 10),
    );

    print('User name: ${response.data['name']}');
    print('User email: ${response.data['email']}');
  } on SocketError catch (e) {
    if (e.type == SocketErrorType.timeout) {
      print('Request timed out');
    }
  }
}

// EXAMPLE 4: Channels (Pub/Sub)

Future<void> channelExample() async {
  final client = SocketClient(
    config: ConnectionConfig.fromUrl('wss://api.myapp.com/ws'),
  );

  await client.connect();

  // Join a chat room
  final chatRoom = client.channel('room:general');
  await chatRoom.join(params: {'username': 'alice'});

  // Listen for channel-specific events
  chatRoom.on('message', (msg) {
    print('[${msg.data['from']}] ${msg.data['text']}');
  });

  chatRoom.on('user.joined', (msg) {
    print('${msg.data['username']} joined the room');
  });

  // Send to channel
  await chatRoom.send('message', data: {'text': 'Hey everyone!'});

  // Join another channel simultaneously
  final notifications = client.channel('user:alice:notifications');
  await notifications.join();

  notifications.on('alert', (msg) {
    print('Alert: ${msg.data['title']}');
  });

  // Leave a channel
  await chatRoom.leave();
}

// EXAMPLE 5: Middleware Pipeline

Future<void> middlewareExample() async {
  final client =
      SocketClient(
          config: ConnectionConfig.fromUrl('wss://api.myapp.com/ws'),
        )
        // --- Inbound middleware (processing incoming messages) ---
        // Log all incoming messages
        ..useInbound(SocketMiddleware.logging(logData: true))
        // Deduplicate (server might send duplicates)
        ..useInbound(
          SocketMiddleware.deduplicator(
            window: const Duration(seconds: 5),
          ),
        )
        // Filter out internal events from reaching handlers
        ..useInbound(
          SocketMiddleware.eventFilter(
            blockList: {'_internal.ping', '_internal.metrics'},
          ),
        )
        // --- Outbound middleware (processing outgoing messages) ---
        // Log outbound
        ..useOutbound(SocketMiddleware.logging())
        // Rate limit outbound to 10/sec
        ..useOutbound(SocketMiddleware.rateLimiter(maxPerSecond: 10))
        // Inject auth token
        ..useOutbound(
          SocketMiddleware.authInjector(
            tokenProvider: () async => 'my-token',
          ),
        )
        // Add timestamps
        ..useOutbound(SocketMiddleware.timestamper());

  await client.connect();
}

// EXAMPLE 6: Offline Message Queue

Future<void> offlineQueueExample() async {
  final client = SocketClient(
    config: ConnectionConfig.fromUrl('wss://api.myapp.com/ws'),
  );

  final queue = MessageQueue(maxSize: 500);

  // Listen for dropped messages
  queue.droppedMessages.listen((dropped) {
    print('Dropped: ${dropped.message.event} (expired or evicted)');
  });

  // When disconnected, queue messages instead of dropping them
  client.stateStream.listen((state) async {
    if (state == SocketConnectionState.connected) {
      // Flush the queue
      final pending = queue.dequeueAll();
      for (final queued in pending) {
        await client.emit(queued.message.event, data: queued.message.data);
      }
      print('Flushed ${pending.length} queued messages');
    }
  });

  // Usage: buffer messages when offline
  void safeSend(
    String event,
    Map<String, dynamic> data, {
    MessagePriority priority = MessagePriority.normal,
  }) {
    if (client.isConnected) {
      client.emit(event, data: data);
    } else {
      final msg = SocketMessage.create(event: event, data: data);
      queue.enqueue(msg, priority: priority, ttl: const Duration(minutes: 5));
    }
  }

  safeSend('analytics.event', {'action': 'button_click'});
  safeSend('order.submit', {
    'orderId': '999',
  }, priority: MessagePriority.critical);
}

// EXAMPLE 7: Health Monitoring

Future<void> healthMonitorExample() async {
  final metrics = SocketMetrics();
  final health = HealthMonitor(
    metrics: metrics,
    checkInterval: const Duration(seconds: 15),
    maxLatency: const Duration(milliseconds: 3000),
    maxErrorsPerMinute: 5,
  );

  health.statusStream.listen((status) {
    switch (status) {
      case HealthStatus.healthy:
        print('✅ Connection healthy');
        break;
      case HealthStatus.degraded:
        print('⚠️ Connection degraded');
        break;
      case HealthStatus.unhealthy:
        print('🔴 Connection unhealthy — consider alerting');
        break;
    }
  });

  health.start();

  // Simulate recording metrics
  metrics.messagesSent++;
  metrics.recordLatency(const Duration(milliseconds: 45));

  // Check metrics snapshot
  print(metrics.toMap());
}

// EXAMPLE 8: Network-Aware Reconnection (Flutter/Mobile)

Future<void> networkAwareExample() async {
  final client = SocketClient(
    config: ConnectionConfig.fromUrl('wss://api.myapp.com/ws'),
  );

  // In a real Flutter app, use connectivity_plus:
  //
  // final connectivity = Connectivity();
  // final monitor = ConnectivityMonitor(
  //   connectivityStream: connectivity.onConnectivityChanged.map((result) {
  //     return result.contains(ConnectivityResult.none)
  //         ? NetworkStatus.offline
  //         : NetworkStatus.online;
  //   }),
  // );

  final monitor = ConnectivityMonitor(debounce: const Duration(seconds: 2));

  final reconnector = NetworkAwareReconnector(
    monitor: monitor,
    onReconnectRequested: () => client.connect(),
    onDisconnectRequested: () => client.disconnect(),
  );

  await client.connect();

  // Simulate network loss
  monitor.updateStatus(NetworkStatus.offline);
  // ... some time passes ...
  monitor.updateStatus(NetworkStatus.online);
  // → reconnector automatically calls client.connect()
}

// EXAMPLE 9: Custom Middleware — Message Encryption

Future<void> customMiddlewareExample() async {
  final client =
      SocketClient(
          config: ConnectionConfig.fromUrl('wss://api.myapp.com/ws'),
        )
        // Encrypt outbound payloads
        ..useOutbound((message) async {
          // In production, use a real encryption library
          final encrypted = _fakeEncrypt(message.data.toString());
          return SocketMessage(
            id: message.id,
            event: message.event,
            data: {'_encrypted': encrypted},
            timestamp: message.timestamp,
            replyTo: message.replyTo,
          );
        })
        // Decrypt inbound payloads
        ..useInbound((message) async {
          if (message.data.containsKey('_encrypted')) {
            final decrypted = _fakeDecrypt(
              message.data['_encrypted'] as String,
            );
            return SocketMessage(
              id: message.id,
              event: message.event,
              data: {'content': decrypted},
              timestamp: message.timestamp,
              replyTo: message.replyTo,
            );
          }
          return message;
        });

  await client.connect();
}

String _fakeEncrypt(String data) => 'ENC:$data';
String _fakeDecrypt(String data) => data.replaceFirst('ENC:', '');

// EXAMPLE 10: Full Production Setup

Future<void> productionExample() async {
  // 1. Configure
  final config = ConnectionConfig.fromUrl(
    'wss://api.production.com/ws/v2',
    headers: {'X-App-Version': '3.2.1'},
    connectTimeout: const Duration(seconds: 15),
    auth: AuthConfig(
      type: AuthType.bearer,
      tokenProvider: () async => 'refreshed-jwt-token',
      transport: AuthTransport.header,
    ),
    heartbeat: const HeartbeatConfig(
      enabled: true,
      interval: Duration(seconds: 25),
      pongTimeout: Duration(seconds: 10),
    ),
    reconnect: const ReconnectConfig(
      enabled: true,
      maxAttempts: 20,
      initialDelay: Duration(seconds: 1),
      maxDelay: Duration(minutes: 2),
      multiplier: 1.5,
      jitter: true,
    ),
  );

  // 2. Create client with custom logger
  final client =
      SocketClient(
          config: config,
          logger: const SocketLogger(
            tag: 'App',
            minLevel: LogLevel.info,
          ),
        )
        // 3. Middleware pipeline
        ..useInbound(SocketMiddleware.logging())
        ..useInbound(SocketMiddleware.deduplicator())
        ..useOutbound(SocketMiddleware.rateLimiter(maxPerSecond: 20))
        ..useOutbound(SocketMiddleware.timestamper());

  // 4. Metrics & health
  final metrics = SocketMetrics();
  final health = HealthMonitor(metrics: metrics);

  client.stateStream.listen((state) {
    if (state == SocketConnectionState.connected) {
      metrics.markConnected();
    } else if (state == SocketConnectionState.disconnected) {
      metrics.markDisconnected();
    } else if (state == SocketConnectionState.reconnecting) {
      metrics.markReconnect();
    }
  });

  client.errors.listen((_) {
    metrics.errorCount++;
    health.recordError();
  });

  // 5. Message queue for offline buffering
  final queue = MessageQueue(maxSize: 1000);

  client.stateStream.listen((state) async {
    if (state == SocketConnectionState.connected && !queue.isEmpty) {
      final pending = queue.dequeueAll();
      for (final msg in pending) {
        await client.emit(msg.message.event, data: msg.message.data);
      }
    }
  });

  // 6. Event handlers
  client.on('notification', (msg) {
    print('📢 ${msg.data['title']}: ${msg.data['body']}');
  });

  client.on('error', (msg) {
    print('⚠️ Server error: ${msg.data}');
  });

  // 7. Start
  health.start();
  await client.connect();

  // 8. Use channels
  final feed = client.channel('feed:main');
  await feed.join();
  feed.on('post.new', (msg) => print('New post: ${msg.data['title']}'));

  // 9. Periodic health report
  // Timer.periodic(Duration(minutes: 1), (_) {
  //   print('Health: ${health.status.name}');
  //   print('Metrics: ${metrics.toMap()}');
  // });
}

// Main

void main() async {
  print('Socket Network System — Examples\n');
  print('Run individual examples by uncommenting below.\n');

  // await basicExample();
  // await authenticatedExample();
  // await requestResponseExample();
  // await channelExample();
  // await middlewareExample();
  // await offlineQueueExample();
  // await healthMonitorExample();
  // await networkAwareExample();
  // await customMiddlewareExample();
  // await productionExample();

  print('See source code for 10 complete examples.');
}
