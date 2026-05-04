/// Generates correlation IDs for outbound frames.
abstract class RefGenerator {
  String next();
  void reset();
}
