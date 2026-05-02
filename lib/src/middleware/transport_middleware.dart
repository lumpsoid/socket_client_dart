import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:socket_client/src/util/logger.dart';

/// Middleware that operates on raw text frames at the transport boundary.
///
/// These are intentionally low-level (pre-codec) so they can handle
/// compression, logging, and rate-limiting on the wire format — not on
/// protocol-specific types.
typedef RawFrameMiddleware = FutureOr<String?> Function(String frame);

/// Pipeline builder for [RawFrameMiddleware].
class TransportMiddlewarePipeline {
  TransportMiddlewarePipeline();

  final List<RawFrameMiddleware> _stages = [];

  void use(RawFrameMiddleware middleware) => _stages.add(middleware);

  /// Run [frame] through all middleware stages.
  ///
  /// Returns `null` if any stage drops the frame.
  Future<String?> process(String frame) async {
    String? current = frame;
    for (final stage in _stages) {
      current = await stage(current!);
      if (current == null) return null;
    }
    return current;
  }
}

/// Factory for common transport-level middleware.
///
/// These operate on raw wire strings, not decoded frames.
class TransportMiddleware {
  TransportMiddleware._();

  /// Logs each raw frame (truncated to [maxLength] chars).
  static RawFrameMiddleware logging({
    SocketLogger? logger,
    int maxLength = 200,
  }) {
    final log = logger ?? const SocketLogger(tag: 'MW:Log');
    return (frame) {
      final preview = frame.length > maxLength
          ? '${frame.substring(0, maxLength)}…'
          : frame;
      log.debug('Frame: $preview');
      return frame;
    };
  }

  /// Drops frames exceeding [maxPerSecond] per second.
  static RawFrameMiddleware rateLimiter({
    int maxPerSecond = 10,
    SocketLogger? logger,
  }) {
    final log = logger ?? const SocketLogger(tag: 'MW:RateLimit');
    final window = Queue<DateTime>();
    return (frame) {
      final now = DateTime.now();
      while (window.isNotEmpty &&
          now.difference(window.first).inMilliseconds > 1000) {
        window.removeFirst();
      }
      if (window.length >= maxPerSecond) {
        log.warn('Rate limit exceeded — dropping frame');
        return null;
      }
      window.add(now);
      return frame;
    };
  }

  /// gzip-compresses frames exceeding [thresholdBytes] bytes.
  ///
  /// Compressed frames are base64-encoded and wrapped in a simple envelope:
  /// `{"_gz":1,"d":"<base64>"}` so the receiver can detect and decompress.
  static RawFrameMiddleware compressOutbound({int thresholdBytes = 1024}) {
    return (frame) {
      if (frame.length < thresholdBytes) return frame;
      final compressed = gzip.encode(utf8.encode(frame));
      final b64 = base64.encode(compressed);
      return '{"_gz":1,"d":"$b64"}';
    };
  }

  /// Decompresses frames compressed by [compressOutbound].
  static RawFrameMiddleware decompressInbound() {
    return (frame) {
      if (!frame.startsWith('{"_gz":1')) return frame;
      try {
        final map = json.decode(frame) as Map<String, dynamic>;
        final b64 = map['d'] as String;
        final bytes = gzip.decode(base64.decode(b64));
        return utf8.decode(bytes);
      } catch (_) {
        return frame; // Not actually a compressed envelope — pass through.
      }
    };
  }

  /// Deduplicates frames with the same content within [window].
  ///
  /// Uses content hash — codec-agnostic.
  static RawFrameMiddleware deduplicator({
    Duration window = const Duration(seconds: 5),
  }) {
    final seen = <int, DateTime>{};
    return (frame) {
      final now = DateTime.now();
      seen.removeWhere((_, time) => now.difference(time) > window);
      final hash = frame.hashCode;
      if (seen.containsKey(hash)) return null;
      seen[hash] = now;
      return frame;
    };
  }
}
