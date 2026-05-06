import 'package:socket_client/src/transport/connection_config.dart';

/// Resolves the [ConnectionConfig] to use for the next connection attempt.
// ignore: one_member_abstracts
abstract interface class ConnectionConfigProvider {
  ConnectionConfig provideConfig();
}

/// Always returns the same [ConnectionConfig].
class ConstantConfigProvider implements ConnectionConfigProvider {
  const ConstantConfigProvider(this._config);

  final ConnectionConfig _config;

  @override
  ConnectionConfig provideConfig() => _config;
}

/// Holds a [ConnectionConfig] that can be swapped at runtime via [swap].
class SwappableConfigProvider implements ConnectionConfigProvider {
  SwappableConfigProvider(this._config);

  ConnectionConfig _config;

  void swap(ConnectionConfig config) => _config = config;

  @override
  ConnectionConfig provideConfig() => _config;
}
