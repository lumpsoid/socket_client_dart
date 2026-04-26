// Not required for test files
// ignore_for_file: prefer_const_constructors
import 'package:socket_client/socket_client.dart';
import 'package:test/test.dart';

void main() {
  group('SocketClient', () {
    test('can be instantiated', () {
      expect(SocketClient(), isNotNull);
    });
  });
}
