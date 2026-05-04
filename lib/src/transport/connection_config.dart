/// Full configuration for transport.
class ConnectionConfig {
  const ConnectionConfig({
    required this.uri,
    this.headers,
    this.protocols,
    this.connectTimeout = const Duration(seconds: 15),
    this.heartbeat = const HeartbeatConfig(),
    this.reconnect = const ReconnectConfig(),
  });

  factory ConnectionConfig.fromUrl(
    String url, {
    Map<String, dynamic>? headers,
    Iterable<String>? protocols,
    Duration connectTimeout = const Duration(seconds: 15),
    HeartbeatConfig heartbeat = const HeartbeatConfig(),
    ReconnectConfig reconnect = const ReconnectConfig(),
  }) => ConnectionConfig(
    uri: Uri.parse(url),
    headers: headers,
    protocols: protocols,
    connectTimeout: connectTimeout,
    heartbeat: heartbeat,
    reconnect: reconnect,
  );

  final Uri uri;
  final Map<String, dynamic>? headers;
  final Iterable<String>? protocols;
  final Duration connectTimeout;
  final HeartbeatConfig heartbeat;
  final ReconnectConfig reconnect;

  ConnectionConfig copyWith({
    Uri? uri,
    Map<String, dynamic>? headers,
    Iterable<String>? protocols,
    Duration? connectTimeout,
    HeartbeatConfig? heartbeat,
    ReconnectConfig? reconnect,
  }) => ConnectionConfig(
    uri: uri ?? this.uri,
    headers: headers ?? this.headers,
    protocols: protocols ?? this.protocols,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    heartbeat: heartbeat ?? this.heartbeat,
    reconnect: reconnect ?? this.reconnect,
  );
}

class HeartbeatConfig {
  const HeartbeatConfig({
    this.enabled = true,
    this.interval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.pingMessage = 'ping',
    this.frameBuilder,
  });

  final bool enabled;
  final Duration interval;
  final Duration pongTimeout;
  final String pingMessage;

  /// If provided, called each tick to build the outbound ping frame.
  /// Receives a fresh ref string.
  final String Function(String ref)? frameBuilder;

  String buildPing(String ref) => frameBuilder?.call(ref) ?? pingMessage;
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
