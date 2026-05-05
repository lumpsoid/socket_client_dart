import 'dart:async';
import 'dart:typed_data';

import 'package:socket_client/src/protocol/frame_codec.dart';
import 'package:socket_client/src/queue/message_queue.dart';
import 'package:socket_client/src/transport/connection_state.dart';
import 'package:socket_client/src/transport/socket_transport.dart';
import 'package:socket_client/src/util/logger.dart';

/// Wraps [SocketTransport] with a [MessageQueue] so that frames sent while
/// disconnected are buffered and flushed automatically on reconnect.
///
/// Drop-in replacement anywhere [SocketTransport] is used directly.
class QueuedTransport<T> {
  QueuedTransport({
    required SocketTransport transport,
    required FrameCodec<T> codec,
    MessageQueue<T>? queue,
    SocketLogger? logger,
  }) : _transport = transport,
       _codec = codec,
       _queue = queue ?? MessageQueue<T>(),
       _logger = logger ?? const SocketLogger(tag: 'QueuedTransport') {
    _stateSub = _transport.stateStream.listen(_onStateChange);
  }

  final SocketTransport _transport;
  final FrameCodec<T> _codec;
  final MessageQueue<T> _queue;
  final SocketLogger _logger;

  Stream<SocketConnectionState> get stateStream => _transport.stateStream;
  Stream<String> get textStream => _transport.textStream;
  Stream<Uint8List> get binaryStream => _transport.binaryStream;
  Stream<SocketError> get errorStream => _transport.errorStream;
  Stream<QueuedFrame<T>> get droppedFrames => _queue.dropped;

  bool get isConnected => _transport.isConnected;

  StreamSubscription<SocketConnectionState>? _stateSub;

  /// Send a frame. If disconnected, the frame is queued.
  void send(
    T frame, {
    MessagePriority priority = MessagePriority.normal,
    Duration? ttl,
  }) {
    final encoded = _codec.encode(frame);
    if (_transport.isConnected) {
      _transport.sendText(encoded);
    } else {
      _queue.enqueue(encoded, frame, priority: priority, ttl: ttl);
      _logger.debug('Queued frame while offline (${_queue.length} pending)');
    }
  }

  /// Send a pre-encoded string frame. If disconnected, enqueues with the
  /// decoded frame for inspection purposes.
  void sendEncoded(
    String encoded,
    T frame, {
    MessagePriority priority = MessagePriority.normal,
    Duration? ttl,
  }) {
    if (_transport.isConnected) {
      _transport.sendText(encoded);
    } else {
      _queue.enqueue(encoded, frame, priority: priority, ttl: ttl);
    }
  }

  void _onStateChange(SocketConnectionState state) {
    if (state == SocketConnectionState.connected && !_queue.isEmpty) {
      _flush();
    }
  }

  void _flush() {
    final frames = _queue.dequeueAll();
    _logger.info('Flushing ${frames.length} queued frames');
    for (final queued in frames) {
      try {
        _transport.sendText(queued.encoded);
      } on Exception catch (e) {
        _logger.error('Failed to flush queued frame: $e');
      }
    }
  }

  Future<void> dispose() async {
    await _stateSub?.cancel();
    await _queue.dispose();
    await _transport.dispose();
  }
}
