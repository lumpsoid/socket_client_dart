import 'dart:async';

import 'package:socket_client/socket_client.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectivityMonitor', () {
    test('initial status is unknown', () {
      final monitor = ConnectivityMonitor(
        debounce: const Duration(milliseconds: 10),
      );
      expect(monitor.status, NetworkStatus.unknown);
      addTearDown(monitor.dispose);
    });

    test('updateStatus transitions to online after debounce', () async {
      final monitor = ConnectivityMonitor(
        debounce: const Duration(milliseconds: 20),
      );
      addTearDown(monitor.dispose);

      monitor.updateStatus(NetworkStatus.online);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(monitor.status, NetworkStatus.online);
      expect(monitor.isOnline, isTrue);
    });

    test('debounce ignores rapid changes and takes last value', () async {
      final monitor = ConnectivityMonitor(
        debounce: const Duration(milliseconds: 30),
      );
      addTearDown(monitor.dispose);

      monitor
        ..updateStatus(NetworkStatus.offline)
        ..updateStatus(NetworkStatus.online); // wins
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(monitor.status, NetworkStatus.online);
    });

    test('emits events on statusStream', () async {
      final events = <NetworkStatus>[];
      final monitor = ConnectivityMonitor(
        debounce: const Duration(milliseconds: 10),
      );
      addTearDown(monitor.dispose);
      monitor.statusStream.listen(events.add);

      monitor.updateStatus(NetworkStatus.online);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      monitor.updateStatus(NetworkStatus.offline);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        events,
        containsAll([NetworkStatus.online, NetworkStatus.offline]),
      );
    });

    test('wires to a provided stream', () async {
      final controller = StreamController<NetworkStatus>();
      final monitor = ConnectivityMonitor(
        connectivityStream: controller.stream,
        debounce: const Duration(milliseconds: 10),
      );
      addTearDown(() async {
        await monitor.dispose();
        await controller.close();
      });

      controller.add(NetworkStatus.online);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(monitor.status, NetworkStatus.online);
    });
  });
}
