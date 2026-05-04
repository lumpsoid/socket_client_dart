import 'package:socket_client/src/ref_generator/ref_generator_i.dart';

/// Monotonically increasing integer ref, optionally prefixed.
class MonotonicRefGenerator implements RefGenerator {
  MonotonicRefGenerator({this.prefix = ''});

  final String prefix;
  int _counter = 0;

  static const int _maxCounter = 9223372036854775807; // int.maxValue (2^63 - 1)

  @override
  String next() {
    if (_counter >= _maxCounter) {
      throw StateError(
        'MonotonicRefGenerator overflow: counter has reached the maximum '
        'value of $_maxCounter and cannot be incremented further. '
        'Call reset() or create a new instance.',
      );
    }
    return '$prefix${++_counter}';
  }

  @override
  void reset() => _counter = 0;
}
