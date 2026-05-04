/// Config for making a connection to a socket
class ConnectionConfig {
  const ConnectionConfig({
    required this.url,
    this.headers,
    this.protocols,
    this.connectTimeout = const Duration(seconds: 15),
  });

  final String url;
  final Map<String, dynamic>? headers;
  final Iterable<String>? protocols;
  final Duration connectTimeout;

  ConnectionConfig copyWith({
    String? url,
    Map<String, dynamic>? headers,
    Iterable<String>? protocols,
    Duration? connectTimeout,
  }) => ConnectionConfig(
    url: url ?? this.url,
    headers: headers ?? this.headers,
    protocols: protocols ?? this.protocols,
    connectTimeout: connectTimeout ?? this.connectTimeout,
  );
}

class HeartbeatConfig {
  const HeartbeatConfig({
    this.enabled = true,
    this.interval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.pingMessage = 'ping',
  });

  final bool enabled;
  final Duration interval;
  final Duration pongTimeout;
  final String pingMessage;
}

class ReconnectConfig {
  const ReconnectConfig({
    this.enabled = true,
    this.maxAttempts = 10,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 60),
    this.multiplier = 2.0,
    this.jitter = true,
  });

  final bool enabled;
  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;
  final bool jitter;
}
