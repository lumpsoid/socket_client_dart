import 'dart:async';

import 'package:socket_client/src/logger.dart';
import 'package:socket_client/src/message_protocol.dart';

/// Represents a named channel for topic-based pub/sub.
///
/// Channels provide:
/// - Isolated message streams per topic
/// - Join/leave lifecycle with server negotiation
/// - Presence tracking
/// - Channel-scoped event handling
class SocketChannel {
  SocketChannel({
    required this.name,
    required MessageProtocol protocol,
    required void Function(String json) sendRaw,
    SocketLogger? logger,
  }) : _protocol = protocol,
       _sendRaw = sendRaw,
       _logger = logger ?? SocketLogger(tag: 'Channel[$name]');

  final String name;
  final MessageProtocol _protocol;
  final void Function(String json) _sendRaw;
  final SocketLogger _logger;

  ChannelState _state = ChannelState.idle;
  final Map<String, List<MessageHandler>> _handlers = {};
  final List<VoidCallback> _unsubscribers = [];

  final _stateController = StreamController<ChannelState>.broadcast();
  final _messageController = StreamController<SocketMessage>.broadcast();

  ChannelState get state => _state;
  Stream<ChannelState> get stateStream => _stateController.stream;
  Stream<SocketMessage> get messageStream => _messageController.stream;
  bool get isJoined => _state == ChannelState.joined;

  /// Join the channel.
  Future<void> join({Map<String, dynamic>? params}) async {
    if (_state == ChannelState.joining || _state == ChannelState.joined) {
      _logger.warn('Already ${_state.name}');
      return;
    }

    _transitionTo(ChannelState.joining);

    // Register protocol-level listener for this channel's messages
    final unsub = _protocol.on('channel:$name', (msg) {
      _messageController.add(msg);
      _routeToHandlers(msg);
    });
    _unsubscribers.add(unsub);

    // Send join request
    final joinMsg = SocketMessage.create(
      event: 'channel:join',
      data: {'channel': name, if (params != null) 'params': params},
    );

    try {
      final prepared = await _protocol.prepareOutbound(joinMsg);
      if (prepared != null) {
        _sendRaw(prepared);
      }
      _transitionTo(ChannelState.joined);
      _logger.info('Joined channel: $name');
    } catch (e) {
      _transitionTo(ChannelState.error);
      _logger.error('Failed to join channel $name: $e');
      rethrow;
    }
  }

  /// Leave the channel.
  Future<void> leave() async {
    if (_state == ChannelState.idle || _state == ChannelState.left) return;

    _transitionTo(ChannelState.leaving);

    final leaveMsg = SocketMessage.create(
      event: 'channel:leave',
      data: {'channel': name},
    );

    try {
      final prepared = await _protocol.prepareOutbound(leaveMsg);
      if (prepared != null) {
        _sendRaw(prepared);
      }
    } catch (e) {
      _logger.warn('Error sending leave: $e');
    }

    for (final unsub in _unsubscribers) {
      unsub();
    }
    _unsubscribers.clear();
    _handlers.clear();

    _transitionTo(ChannelState.left);
    _logger.info('Left channel: $name');
  }

  /// Send a message to this channel.
  Future<void> send(
    String event, {
    Map<String, dynamic>? data,
  }) async {
    if (!isJoined) {
      throw StateError('Cannot send: channel "$name" is not joined');
    }

    final msg = SocketMessage.create(
      event: 'channel:$name',
      data: {'event': event, ...?data},
    );

    final prepared = await _protocol.prepareOutbound(msg);
    if (prepared != null) {
      _sendRaw(prepared);
    }
  }

  /// Listen for a specific event within this channel.
  VoidCallback on(String event, MessageHandler handler) {
    _handlers.putIfAbsent(event, () => []);
    _handlers[event]!.add(handler);
    return () => _handlers[event]?.remove(handler);
  }

  void _routeToHandlers(SocketMessage message) {
    final event = message.data['event'] as String?;
    if (event == null) return;

    final handlers = _handlers[event];
    if (handlers != null) {
      for (final handler in List.of(handlers)) {
        try {
          handler(message);
        } catch (e) {
          _logger.error('Channel handler error for "$event": $e');
        }
      }
    }
  }

  void _transitionTo(ChannelState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  Future<void> dispose() async {
    await leave();
    await _stateController.close();
    await _messageController.close();
  }
}

enum ChannelState {
  idle,
  joining,
  joined,
  leaving,
  left,
  error,
}

/// Manages multiple channels over a single socket connection.
class ChannelManager {
  ChannelManager({
    required this.protocol,
    required this.sendRaw,
    SocketLogger? logger,
  }) : _logger = logger ?? const SocketLogger(tag: 'ChannelManager');
  final MessageProtocol protocol;
  final void Function(String json) sendRaw;
  final SocketLogger _logger;
  final Map<String, SocketChannel> _channels = {};

  /// Get or create a channel by name.
  SocketChannel channel(String name) {
    return _channels.putIfAbsent(
      name,
      () => SocketChannel(
        name: name,
        protocol: protocol,
        sendRaw: sendRaw,
        logger: SocketLogger(tag: 'Channel[$name]'),
      ),
    );
  }

  /// Get all active (joined) channels.
  List<SocketChannel> get activeChannels =>
      _channels.values.where((c) => c.isJoined).toList();

  /// Leave and remove a channel.
  Future<void> removeChannel(String name) async {
    final ch = _channels.remove(name);
    await ch?.dispose();
  }

  /// Leave all channels.
  Future<void> leaveAll() async {
    for (final ch in _channels.values) {
      await ch.dispose();
    }
    _channels.clear();
    _logger.info('Left all channels');
  }

  /// Rejoin all previously joined channels (e.g., after reconnect).
  Future<void> rejoinAll() async {
    for (final ch in _channels.values) {
      if (ch.state == ChannelState.left || ch.state == ChannelState.error) {
        try {
          await ch.join();
        } catch (e) {
          _logger.error('Failed to rejoin channel ${ch.name}: $e');
        }
      }
    }
  }

  Future<void> dispose() async {
    await leaveAll();
  }
}
