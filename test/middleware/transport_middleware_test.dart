// tests
// ignore_for_file: avoid_redundant_argument_values

import 'package:socket_client/socket_client.dart';
import 'package:test/test.dart';

void main() {
  group('TransportMiddlewarePipeline', () {
    test('passes frame through all stages in order', () async {
      final log = <String>[];
      final pipeline = TransportMiddlewarePipeline()
        ..use((f) {
          log.add('stage1');
          return '${f}_1';
        })
        ..use((f) {
          log.add('stage2');
          return '${f}_2';
        });

      final result = await pipeline.process('hello');
      expect(result, 'hello_1_2');
      expect(log, ['stage1', 'stage2']);
    });

    test('returns null when a stage drops the frame', () async {
      final pipeline = TransportMiddlewarePipeline()
        ..use((_) => null) // drops
        ..use((f) => '${f}_never');

      final result = await pipeline.process('hello');
      expect(result, isNull);
    });

    test('supports async stages', () async {
      final pipeline = TransportMiddlewarePipeline()
        ..use((f) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return '${f}_async';
        });

      final result = await pipeline.process('hi');
      expect(result, 'hi_async');
    });
  });

  group('TransportMiddleware.logging', () {
    test('passes frame through unchanged', () async {
      final mw = TransportMiddleware.logging();
      expect(await mw('{"event":"test"}'), '{"event":"test"}');
    });

    test('logs truncated preview when frame exceeds maxLength', () async {
      final logs = <String>[];
      final mw = TransportMiddleware.logging(
        maxLength: 10,
        logger: _capturingLogger(logs),
      );
      await mw('A' * 20);
      expect(logs.first, contains('…'));
    });
  });

  group('TransportMiddleware.rateLimiter', () {
    test('allows frames up to maxPerSecond', () async {
      final mw = TransportMiddleware.rateLimiter(maxPerSecond: 5);
      for (var i = 0; i < 5; i++) {
        expect(await mw('frame$i'), isNotNull);
      }
    });

    test('drops frames beyond maxPerSecond within the same second', () async {
      final mw = TransportMiddleware.rateLimiter(maxPerSecond: 3);
      final results = <String?>[];
      for (var i = 0; i < 6; i++) {
        results.add(await mw('frame$i'));
      }
      final dropped = results.where((r) => r == null).length;
      expect(dropped, greaterThanOrEqualTo(2));
    });
  });

  group('TransportMiddleware compression round-trip', () {
    test('small frames pass through uncompressed', () async {
      final compress = TransportMiddleware.compressOutbound(
        thresholdBytes: 1024,
      );
      const small = '{"event":"ping"}';
      expect(await compress(small), small);
    });

    test('large frames are compressed and decompressed correctly', () async {
      final compress = TransportMiddleware.compressOutbound(thresholdBytes: 10);
      final decompress = TransportMiddleware.decompressInbound();

      final original = 'A' * 100;
      final compressed = await compress(original);
      expect(compressed, isNot(original));
      expect(compressed, startsWith('{"_gz":1'));

      final decompressed = await decompress(compressed!);
      expect(decompressed, original);
    });

    test('decompressInbound passes non-compressed frames through', () async {
      final decompress = TransportMiddleware.decompressInbound();
      const frame = '{"event":"normal"}';
      expect(await decompress(frame), frame);
    });
  });

  group('TransportMiddleware.deduplicator', () {
    test('allows unique frames', () async {
      final mw = TransportMiddleware.deduplicator();
      expect(await mw('a'), 'a');
      expect(await mw('b'), 'b');
    });

    test('drops duplicate frames within window', () async {
      final mw = TransportMiddleware.deduplicator(
        window: const Duration(seconds: 5),
      );
      expect(await mw('dup'), 'dup');
      expect(await mw('dup'), isNull);
    });

    test('allows repeated frame after window expires', () async {
      final mw = TransportMiddleware.deduplicator(
        window: const Duration(milliseconds: 30),
      );
      expect(await mw('x'), 'x');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await mw('x'), 'x'); // window expired, allowed again
    });
  });
}

// Helpers

SocketLogger _capturingLogger(List<String> sink) => SocketLogger(
  tag: 'T',
  onLog: (_, _, msg) => sink.add(msg),
);
