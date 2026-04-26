import 'dart:developer' as developer;

/// Log severity levels.
enum LogLevel {
  debug,
  info,
  warn,
  error,
}

/// Pluggable logger for the socket system.
///
/// By default, logs to `dart:developer`. Override [onLog] to
/// integrate with your preferred logging framework (e.g., logger, fimber).
class SocketLogger {
  final String tag;
  final LogLevel minLevel;
  final void Function(LogLevel level, String tag, String message)? onLog;

  const SocketLogger({
    this.tag = 'Socket',
    this.minLevel = LogLevel.debug,
    this.onLog,
  });

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

    final prefix = '[${level.name.toUpperCase()}][$tag]';
    final logMessage = '$prefix $message';

    developer.log(
      logMessage,
      name: tag,
      level: _toDevLevel(level),
      time: DateTime.now(),
    );
  }

  int _toDevLevel(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warn:
        return 900;
      case LogLevel.error:
        return 1000;
    }
  }
}
