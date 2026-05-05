import 'package:socket_client/src/protocol/socket_session.dart';
import 'package:socket_client/src/transport/connection_state.dart';

abstract interface class SocketClient<T> implements SocketSession<T> {
  SocketConnectionState get state;
  bool get isConnected;
  Stream<SocketConnectionState> get stateStream;
  Duration? get uptime;
  Stream<SocketError> get errors;
  Stream<T> get allFrames;

  Future<void> connect();
  Future<void> disconnect({int? closeCode, String? closeReason});
  Future<void> dispose();

  // SocketSession<T> contributes:
  // void emit(T frame);
  // Future<T> request(T frame, {Duration timeout});
}
