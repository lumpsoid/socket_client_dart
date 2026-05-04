// example
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:socket_client/socket_client.dart';

// Example: Phoenix Channels codec
//
// This lives in the CONSUMER's code, not the library.
// The library ships zero protocol implementations.

/// A Phoenix Channels wire frame.
///
/// Phoenix format: [join_ref, ref, topic, event, payload]
class PhoenixFrame {
  const PhoenixFrame({
    required this.topic,
    required this.event,
    required this.payload,
    this.joinRef,
    this.ref,
  });

  final String? joinRef;
  final String? ref;
  final String topic;
  final String event;
  final Map<String, dynamic> payload;

  @override
  String toString() => 'PhoenixFrame($topic:$event ref=$ref)';
}

/// [FrameCodec] implementation for the Phoenix Channels protocol.
class PhoenixCodec implements FrameCodec<PhoenixFrame> {
  PhoenixCodec({required RefGenerator refGen}) : _refGen = refGen;

  final RefGenerator _refGen;

  @override
  PhoenixFrame decode(String raw) {
    try {
      final list = json.decode(raw) as List<dynamic>;
      return PhoenixFrame(
        joinRef: list[0] as String?,
        ref: list[1] as String?,
        topic: list[2] as String,
        event: list[3] as String,
        payload: (list[4] as Map<String, dynamic>?) ?? {},
      );
    } on Exception catch (e) {
      throw FrameDecodeException('Bad Phoenix frame', raw: raw, cause: e);
    }
  }

  @override
  String encode(PhoenixFrame frame) {
    return json.encode([
      frame.joinRef,
      frame.ref ?? _refGen.next(),
      frame.topic,
      frame.event,
      frame.payload,
    ]);
  }

  @override
  String? correlationId(PhoenixFrame frame) => frame.ref;

  @override
  String? replyCorrelationId(PhoenixFrame frame) {
    // Phoenix replies have event "phx_reply" and carry the original ref.
    if (frame.event == 'phx_reply') return frame.ref;
    return null;
  }
}

// Usage

Future<void> main() async {
  final refGen = MonotonicRefGenerator();
  final client = SocketClient(
    config: const ConnectionConfig(
      url: 'wss://my-phoenix-server.com/socket/websocket',
    ),
    codec: PhoenixCodec(refGen: refGen),
  );

  // Subscribe to a channel topic.
  client.allFrames.where((f) => f.topic == 'room:lobby').listen((frame) {
    print('room:lobby received: ${frame.event} payload=${frame.payload}');
  });

  // Connect.
  await client.connect();

  // Join a channel by emitting the Phoenix join message.
  client.emit(
    const PhoenixFrame(
      joinRef: '1',
      ref: '1',
      topic: 'room:lobby',
      event: 'phx_join',
      payload: {},
    ),
  );

  // Request-reply: send a message and await the server's phx_reply.
  final reply = await client.request(
    const PhoenixFrame(
      ref: '2',
      topic: 'room:lobby',
      event: 'new_msg',
      payload: {'body': 'Hello channel!'},
    ),
    timeout: const Duration(seconds: 10),
  );
  print('Got reply: ${reply.payload}');

  await client.dispose();
}
