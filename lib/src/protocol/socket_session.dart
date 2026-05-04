/// What a lifecycle hook is allowed to do.
abstract class SocketSession<T> {
  /// Send a frame. Used for protocol handshakes, heartbeats, re-joins.
  void emit(T frame);

  /// Send a frame and await a correlated reply.
  Future<T> request(T frame, {Duration timeout});
}
