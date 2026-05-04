import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/transport/connection_config.dart';

// dependency inject pattern
// ignore: one_member_abstracts
abstract class HeartbeatPingBuilder {
  String buildPing();
}

class ConfigHeartbeatPingBuilder implements HeartbeatPingBuilder {
  ConfigHeartbeatPingBuilder({required HeartbeatConfig config})
    : _config = config;

  final HeartbeatConfig _config;
  @override
  String buildPing() => _config.pingMessage;
}

abstract class FrameHeartbeatPingBuilder<T> implements HeartbeatPingBuilder {
  FrameHeartbeatPingBuilder({required FrameCodec<T> codec}) : _codec = codec;

  final FrameCodec<T> _codec;

  T getPingFrame();

  @override
  String buildPing() => _codec.encode(getPingFrame());
}
