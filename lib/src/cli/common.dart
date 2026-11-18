import 'dart:io';

import 'package:path/path.dart' as p;

/// Exit codes shared by the CLI and the daemon.
abstract final class ExitCode {
  static const int success = 0;
  static const int failure = 1;
  static const int usage = 2;
  static const int noApp = 3;
}

/// A failure that is reported as one `✗` line, plus an optional hint line.
class FluteException implements Exception {
  FluteException(this.message, {this.hint, this.exitCode = ExitCode.failure, this.details});

  final String message;
  final String? hint;
  final int exitCode;

  /// Extra lines printed after the message, such as compiler output.
  final List<String>? details;

  @override
  String toString() => message;
}

/// Prefix for `--verbose` lines, so they are easy to tell from output.
const String verbosePrefix = 'verbose: ';

/// Detail printed to stderr when the CLI runs with `--verbose`.
abstract final class Verbose {
  static bool enabled = false;

  /// Prints [message] to stderr if `--verbose` is on.
  static void log(String message) {
    if (enabled) {
      stderr.writeln('$verbosePrefix$message');
    }
  }
}

/// The directory that holds all sessions.
///
/// `FLUTE_HOME` overrides the default, which tests use to stay isolated.
Directory fluteHome() {
  final String? override = Platform.environment['FLUTE_HOME'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  if (Platform.isWindows) {
    final String base =
        Platform.environment['LOCALAPPDATA'] ??
        p.join(Platform.environment['USERPROFILE']!, 'AppData', 'Local');
    return Directory(p.join(base, 'flute'));
  }
  return Directory(p.join(Platform.environment['HOME']!, '.flute'));
}

final RegExp _sessionName = RegExp(r'^[A-Za-z0-9_.-]+$');

/// The files that make up one session's state.
class SessionPaths {
  SessionPaths(this.name) {
    if (!_sessionName.hasMatch(name) || name == '.' || name == '..') {
      throw FluteException(
        'Invalid session name "$name".',
        hint: 'Use letters, digits, ".", "_" and "-".',
        exitCode: ExitCode.usage,
      );
    }
  }

  final String name;

  Directory get directory => Directory(p.join(fluteHome().path, 'sessions', name));
  File get daemonJson => File(p.join(directory.path, 'daemon.json'));
  File get appJson => File(p.join(directory.path, 'app.json'));
  File get exitJson => File(p.join(directory.path, 'exit.json'));
  File get lock => File(p.join(directory.path, 'daemon.lock'));
  File get daemonLog => File(p.join(directory.path, 'daemon.log'));
  File get appLog => File(p.join(directory.path, 'app.log'));
  Directory get screenshots => Directory(p.join(directory.path, 'screenshots'));

  static Directory get root => Directory(p.join(fluteHome().path, 'sessions'));
}

final RegExp _duration = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h)?$');

/// Parses durations such as `500ms`, `10s`, `5m` and `1h`. A bare number is
/// seconds.
Duration parseDuration(String text) {
  final RegExpMatch? match = _duration.firstMatch(text.trim());
  if (match == null) {
    throw FluteException(
      'Invalid duration "$text".',
      hint: 'Use a number with ms, s, m or h, such as 10s.',
      exitCode: ExitCode.usage,
    );
  }
  final double value = double.parse(match[1]!);
  final double millis = switch (match[2]) {
    'ms' => value,
    'm' => value * 60 * 1000,
    'h' => value * 60 * 60 * 1000,
    _ => value * 1000,
  };
  return Duration(milliseconds: millis.round());
}

/// Formats a duration the way [parseDuration] reads it.
String formatDuration(Duration duration) {
  final int ms = duration.inMilliseconds;
  if (ms % (60 * 60 * 1000) == 0 && ms > 0) {
    return '${ms ~/ (60 * 60 * 1000)}h';
  }
  if (ms % (60 * 1000) == 0 && ms > 0) {
    return '${ms ~/ (60 * 1000)}m';
  }
  if (ms % 1000 == 0) {
    return '${ms ~/ 1000}s';
  }
  return '${ms}ms';
}

final RegExp _ref = RegExp(r'^(?:s#)?(\d+)$');

/// Parses an `s#<id>` ref. A bare id is accepted too.
int parseRef(String text) {
  final RegExpMatch? match = _ref.firstMatch(text.trim());
  if (match == null) {
    throw FluteException(
      'Invalid ref "$text".',
      hint: 'Refs look like s#7. Run: flute dump semantics',
      exitCode: ExitCode.usage,
    );
  }
  return int.parse(match[1]!);
}
