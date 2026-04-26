/// Configuration for the socket connection.
class ConnectionConfig {
  /// WebSocket URI (ws:// or wss://).
  final Uri uri;

  /// Optional HTTP headers for the handshake.
  final Map<String, dynamic>? headers;

  /// Optional sub-protocols.
  final Iterable<String>? protocols;

  /// Timeout for the initial connection attempt.
  final Duration connectTimeout;

  /// Heartbeat / keep-alive configuration.
  final HeartbeatConfig heartbeat;

  /// Reconnection configuration.
  final ReconnectConfig reconnect;

  /// Authentication configuration.
  final AuthConfig? auth;

  const ConnectionConfig({
    required this.uri,
    this.headers,
    this.protocols,
    this.connectTimeout = const Duration(seconds: 15),
    this.heartbeat = const HeartbeatConfig(),
    this.reconnect = const ReconnectConfig(),
    this.auth,
  });

  /// Convenience constructor from a URL string.
  factory ConnectionConfig.fromUrl(
    String url, {
    Map<String, dynamic>? headers,
    Iterable<String>? protocols,
    Duration connectTimeout = const Duration(seconds: 15),
    HeartbeatConfig heartbeat = const HeartbeatConfig(),
    ReconnectConfig reconnect = const ReconnectConfig(),
    AuthConfig? auth,
  }) {
    return ConnectionConfig(
      uri: Uri.parse(url),
      headers: headers,
      protocols: protocols,
      connectTimeout: connectTimeout,
      heartbeat: heartbeat,
      reconnect: reconnect,
      auth: auth,
    );
  }

  ConnectionConfig copyWith({
    Uri? uri,
    Map<String, dynamic>? headers,
    Iterable<String>? protocols,
    Duration? connectTimeout,
    HeartbeatConfig? heartbeat,
    ReconnectConfig? reconnect,
    AuthConfig? auth,
  }) {
    return ConnectionConfig(
      uri: uri ?? this.uri,
      headers: headers ?? this.headers,
      protocols: protocols ?? this.protocols,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      heartbeat: heartbeat ?? this.heartbeat,
      reconnect: reconnect ?? this.reconnect,
      auth: auth ?? this.auth,
    );
  }
}

/// Heartbeat / ping-pong keep-alive settings.
class HeartbeatConfig {
  final bool enabled;
  final Duration interval;
  final Duration pongTimeout;
  final String pingMessage;

  const HeartbeatConfig({
    this.enabled = true,
    this.interval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.pingMessage = 'ping',
  });
}

/// Reconnection behavior settings.
class ReconnectConfig {
  final bool enabled;
  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;
  final bool jitter;

  const ReconnectConfig({
    this.enabled = true,
    this.maxAttempts = 10,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 60),
    this.multiplier = 2.0,
    this.jitter = true,
  });
}

/// Authentication configuration for the socket.
class AuthConfig {
  /// Authentication type.
  final AuthType type;

  /// Token or credential string.
  final String? token;

  /// Callback to dynamically provide a token (e.g., refresh).
  final Future<String> Function()? tokenProvider;

  /// How to send the token.
  final AuthTransport transport;

  /// Header name when using [AuthTransport.header].
  final String headerName;

  /// Query parameter name when using [AuthTransport.queryParam].
  final String queryParamName;

  const AuthConfig({
    this.type = AuthType.bearer,
    this.token,
    this.tokenProvider,
    this.transport = AuthTransport.header,
    this.headerName = 'Authorization',
    this.queryParamName = 'token',
  }) : assert(
          token != null || tokenProvider != null,
          'Either token or tokenProvider must be provided',
        );

  /// Resolves the current token, calling the provider if needed.
  Future<String> resolveToken() async {
    if (tokenProvider != null) {
      return await tokenProvider!();
    }
    return token!;
  }
}

enum AuthType { bearer, apiKey, custom }

enum AuthTransport { header, queryParam, message }
