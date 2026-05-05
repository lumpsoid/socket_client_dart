import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A minimal WebSocket server for integration tests.
///
/// Behaviours:
/// - Echoes every text frame back to the sender.
/// - Responds to `{"type":"ping"}` with `{"type":"pong","replyTo":"<ref>"}`.
/// - No respond to `{"type":"ping-silent"}`.
/// - Throws on `{"type":"pingThrow"}`.
/// - Responds to `{"type":"request","ref":"<id>"}` with
/// `{"type":"response","replyTo":"<id>","payload":"ok"}`.
/// - Broadcasts `{"type":"broadcast","payload":"hello"}` to all clients
/// when it receives `{"type":"triggerBroadcast"}`.
/// - Sends `{"_gz":1,"d":"<b64>"}` frames untouched (compression passthrough).
class TestSocketServer {
  TestSocketServer({this.port = 0}); // port 0 → OS picks a free port

  final int port;
  HttpServer? _server;
  final List<WebSocket> _clients = [];

  int get boundPort => _server!.port;
  String get url => 'ws://localhost:$boundPort';
  int get clientCount => _clients.length;

  bool _frozen = false;

  /// Stops the server from responding to any frames without closing connections.
  /// Existing clients stay connected but get no replies — simulates a hung server.
  void freeze() => _frozen = true;
  void unfreeze() => _frozen = false;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _serve();
  }

  void _serve() {
    _server!.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _clients.add(ws);
      ws.listen(
        (data) => _handleFrame(ws, data as String),
        onDone: () => _clients.remove(ws),
        onError: (_) => _clients.remove(ws),
        cancelOnError: false,
      );
    });
  }

  void _handleFrame(WebSocket ws, String raw) {
    if (_frozen) return; // swallow everything silently

    Map<String, dynamic> msg;
    try {
      msg = json.decode(raw) as Map<String, dynamic>;
    } on Exception catch (_) {
      // Plain text echo
      ws.add(raw);
      return;
    }

    final type = msg['type'] as String?;

    switch (type) {
      case 'ping':
        ws.add(
          json.encode({
            'type': 'pong',
            'replyTo': msg['ref'],
          }),
        );
      case 'ping-silent':
        break;

      case 'request':
        ws.add(
          json.encode({
            'type': 'response',
            'replyTo': msg['ref'],
            'payload': 'ok',
          }),
        );
      case 'triggerBroadcast':
        final payload = json.encode({
          'type': 'broadcast',
          'payload': 'hello',
        });
        for (final client in List.of(_clients)) {
          client.add(payload);
        }

      case 'no-reply':
        // intentionally silent
        break;

      default:
        // Echo everything else
        ws.add(raw);
    }
  }

  /// Send [message] to all connected clients from the server side.
  void pushToAll(String message) {
    for (final client in List.of(_clients)) {
      client.add(message);
    }
  }

  Future<void> stop() async {
    for (final c in List.of(_clients)) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
