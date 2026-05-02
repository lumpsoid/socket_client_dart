import 'dart:developer' as developer;

enum LogLevel { debug, info, warn, error }

/// Pluggable logger. Override [onLog] to integrate with your logging framework.
///
/// ```dart
/// final logger = SocketLogger(
///   tag: 'MyApp',
///   minLevel: LogLevel.info,
///   onLog: (level, tag, message) => myLogger.log('[$tag] $message'),
/// );
/// ```
class SocketLogger {
  const SocketLogger({
    this.tag = 'Socket',
    this.minLevel = LogLevel.debug,
    this.onLog,
  });

  final String tag;
  final LogLevel minLevel;
  final void Function(LogLevel level, String tag, String message)? onLog;

  void debug(String message) => _log(LogLevel.debug, message);
  void info(String message) => _log(LogLevel.info, message);
  void warn(String message) => _log(LogLevel.warn, message);
  void error(String message) => _log(LogLevel.error, message);

  void _log(LogLevel level, String message) {
    if (level.index < minLevel.index) return;
    if (onLog != null) {
      onLog!(level, tag, message);
      return;
    }
    developer.log(
      '[${level.name.toUpperCase()}][$tag] $message',
      name: tag,
      level: _devLevel(level),
      time: DateTime.now(),
    );
  }

  int _devLevel(LogLevel level) => switch (level) {
    LogLevel.debug => 500,
    LogLevel.info => 800,
    LogLevel.warn => 900,
    LogLevel.error => 1000,
  };
}
